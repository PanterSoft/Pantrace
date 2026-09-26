// Trace buffer and statistics.
//
// The hot path is [add], which is called once per received frame — at 1 Mbit
// that can be several thousand times a second. It does bookkeeping only; the
// UI is told to repaint on a fixed 20 Hz timer instead of per frame, because
// rebuilding a table per frame is what makes naive tracers unusable under load.
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'package:flutter/foundation.dart';

import 'can.dart';
import 'dbc.dart';
import 'log/csv.dart';
import 'log/log.dart';

/// One row of the grouped ("fixed position") view: the latest state of an id.
class TraceRow {
  final int id;
  final bool extended;
  final int channel;
  int count = 0;
  Uint8List data;
  FrameDirection direction;
  DateTime lastSeen;
  DateTime? prevSeen;

  /// Bytes that differed between the last two frames — drives change highlighting.
  int changedMask = 0;

  TraceRow(this.id, this.extended, this.channel, this.data, this.lastSeen,
      this.direction);

  /// Mean interval over the last two occurrences, in milliseconds.
  double? get periodMs {
    final p = prevSeen;
    if (p == null) return null;
    return lastSeen.difference(p).inMicroseconds / 1000.0;
  }

  /// Unique per (channel, id, extended); the same id on two buses is two rows.
  int get key => rowKey(channel, id, extended);

  static int rowKey(int channel, int id, bool extended) =>
      (channel << 32) | DbcDatabase.key(id, extended);
}

enum TraceView { live, grouped }

/// How the live view shows time: wall clock, seconds since the measurement
/// started, or the gap to the previous frame — CANoe's trace time modes.
enum TimeMode { absolute, relative, delta }

/// Sortable columns of the grouped view.
enum TraceSort { channel, id, name, length, data, count, cycle }

class TraceModel extends ChangeNotifier {
  /// ponytail: two buses is what a gateway needs; the model is index-based so
  /// raising this is a constant, the toolbar is the part that would need work.
  static const channels = 2;

  /// ponytail: fixed-size ring of the most recent frames. A tracer that keeps
  /// every frame forever eventually eats all RAM; raise the cap or spill to
  /// disk if you need a long capture.
  static const liveCapacity = 20000;

  final _live = ListQueue<CanFrame>();
  final Map<int, TraceRow> _rows = {};
  Timer? _repaint;

  final dbcs = List<DbcDatabase?>.filled(channels, null);
  final dbcPaths = List<String?>.filled(channels, null);

  bool paused = false;
  TraceView view = TraceView.grouped;
  TimeMode timeMode = TimeMode.absolute;

  /// First frame since the last [clear]; the zero of [TimeMode.relative].
  DateTime? measurementStart;

  /// Set while frames are being logged to disk. Recording sees every frame,
  /// whatever the pause state or view filter.
  LogRecorder? recorder;

  TraceSort sort = TraceSort.id;
  bool sortAscending = true;

  // Filters
  String idFilter = '';

  // Statistics
  int totalFrames = 0;
  int errorFrames = 0;
  int _framesSinceTick = 0;
  double framesPerSecond = 0;
  final _bitsSinceTick = List<int>.filled(channels, 0);
  final busLoadPercent = List<double>.filled(channels, 0);
  final bitrates = List<int>.filled(channels, 500000);
  final List<String> statusLog = [];

  TraceModel() {
    _repaint = Timer.periodic(const Duration(milliseconds: 50), _tick);
  }

  void _tick(Timer _) {
    framesPerSecond = _framesSinceTick * 20.0;
    for (var c = 0; c < channels; c++) {
      final br = bitrates[c];
      busLoadPercent[c] =
          br == 0 ? 0 : (_bitsSinceTick[c] * 20.0 / br * 100).clamp(0, 100);
      _bitsSinceTick[c] = 0;
    }
    _framesSinceTick = 0;
    notifyListeners();
  }

  /// Nominal frame length on the wire, ignoring bit stuffing (which adds up to
  /// ~20% on pathological payloads). Good enough for a load indicator.
  static int frameBits(CanFrame f) =>
      (f.extended ? 67 : 47) + 8 * f.data.length;

  void add(CanFrame frame) {
    final r = recorder;
    if (r != null) {
      try {
        r.write(frame);
      } catch (e) {
        // Disk full, drive unplugged: stop logging, keep tracing.
        recorder = null;
        addStatus('recording to ${r.path} stopped: $e');
      }
    }
    // Error frames carry no payload, so they are counted on their own and kept
    // out of the rate and bus-load figures and out of the grouped view.
    if (!frame.isError) {
      _framesSinceTick++;
      _bitsSinceTick[frame.channel] += frameBits(frame);
    }
    if (paused) {
      // Still counted; only the views are frozen.
      if (frame.isError) {
        errorFrames++;
      } else {
        totalFrames++;
      }
      return;
    }
    _ingest(frame);
  }

  /// Loads frames read from a log file into the trace (CANoe's offline mode).
  /// They go into the views and counters, but not into the live rate, the bus
  /// load or a running recording. Frames on channels this trace does not have
  /// are dropped; returns how many.
  int addOffline(Iterable<CanFrame> frames) {
    var dropped = 0;
    for (final f in frames) {
      if (f.channel < 0 || f.channel >= channels) {
        dropped++;
        continue;
      }
      _ingest(f);
    }
    notifyListeners();
    return dropped;
  }

  void _ingest(CanFrame frame) {
    measurementStart ??= frame.timestamp;
    _live.addLast(frame);
    if (_live.length > liveCapacity) _live.removeFirst();
    if (frame.isError) {
      errorFrames++;
      return;
    }
    totalFrames++;

    final key = TraceRow.rowKey(frame.channel, frame.id, frame.extended);
    final existing = _rows[key];
    if (existing == null) {
      _rows[key] = TraceRow(frame.id, frame.extended, frame.channel, frame.data,
          frame.timestamp, frame.direction)
        ..count = 1;
    } else {
      var mask = 0;
      final n = frame.data.length;
      for (var i = 0; i < n; i++) {
        if (i >= existing.data.length || existing.data[i] != frame.data[i]) {
          mask |= 1 << i;
        }
      }
      existing
        ..changedMask = mask
        ..data = frame.data
        ..count += 1
        ..prevSeen = existing.lastSeen
        ..lastSeen = frame.timestamp
        ..direction = frame.direction;
    }
  }

  void addStatus(String message) {
    statusLog.add('${DateTime.now().toIso8601String().substring(11, 23)}  $message');
    if (statusLog.length > 500) statusLog.removeAt(0);
  }

  void clear() {
    _live.clear();
    _rows.clear();
    totalFrames = 0;
    errorFrames = 0;
    measurementStart = null;
    notifyListeners();
  }

  void setTimeMode(TimeMode m) {
    timeMode = m;
    notifyListeners();
  }

  /// Starts logging every frame to [path]; the format follows the extension.
  void startRecording(String path, {LogFormat format = LogFormat.blf}) {
    recorder = LogRecorder.start(path, format: format);
    addStatus('recording to $path (${recorder!.format.label})');
    notifyListeners();
  }

  /// Finishes the log file. Returns the recorder that was running, if any.
  Future<LogRecorder?> stopRecording() async {
    final r = recorder;
    if (r == null) return null;
    recorder = null;
    await r.stop();
    addStatus('recorded ${r.frames} frames to ${r.path}');
    notifyListeners();
    return r;
  }

  /// Everything in the live buffer, oldest first — what an export writes.
  List<CanFrame> get bufferedFrames => List.unmodifiable(_live);

  void setPaused(bool v) {
    paused = v;
    notifyListeners();
  }

  void setView(TraceView v) {
    view = v;
    notifyListeners();
  }

  /// Clicking the same header again flips the direction; a new one starts
  /// ascending.
  void setSort(TraceSort column) {
    if (sort == column) {
      sortAscending = !sortAscending;
    } else {
      sort = column;
      sortAscending = true;
    }
    notifyListeners();
  }

  void setFilter(String text) {
    idFilter = text.trim();
    notifyListeners();
  }

  void loadDbc(int channel, DbcDatabase db, String path) {
    dbcs[channel] = db;
    dbcPaths[channel] = path;
    notifyListeners();
  }

  void clearDbc(int channel) {
    dbcs[channel] = null;
    dbcPaths[channel] = null;
    notifyListeners();
  }

  DbcMessage? messageFor(int channel, int id, bool extended) =>
      dbcs[channel]?.lookup(id, extended);

  /// Accepts an id filter of comma-separated hex ids and hex ranges,
  /// e.g. "123, 200-2FF". Empty means everything.
  static bool matchesIdFilter(int id, String filter) {
    if (filter.isEmpty) return true;
    for (final part in filter.split(',')) {
      final p = part.trim();
      if (p.isEmpty) continue;
      final dash = p.indexOf('-');
      if (dash > 0) {
        final lo = int.tryParse(p.substring(0, dash).trim(), radix: 16);
        final hi = int.tryParse(p.substring(dash + 1).trim(), radix: 16);
        if (lo != null && hi != null && id >= lo && id <= hi) return true;
      } else {
        if (int.tryParse(p, radix: 16) == id) return true;
      }
    }
    return false;
  }

  /// Error frames have no id to filter on, and hiding them behind an id filter
  /// would hide exactly what the filter is usually being used to chase.
  bool _passes(int id, bool extended) => matchesIdFilter(id, idFilter);

  /// Newest first, so the interesting end is at the top and no scroll
  /// management is needed.
  List<CanFrame> get liveFrames {
    final out = <CanFrame>[];
    for (var i = _live.length - 1; i >= 0; i--) {
      final f = _live.elementAt(i); // O(1) on a ListQueue
      if (f.isError || _passes(f.id, f.extended)) out.add(f);
    }
    return out;
  }

  static int _byId(TraceRow a, TraceRow b) {
    if (a.extended != b.extended) return a.extended ? 1 : -1;
    return a.id.compareTo(b.id);
  }

  /// Unsigned lexicographic compare of the payloads, shorter first on a tie.
  static int _byData(TraceRow a, TraceRow b) {
    final n = a.data.length < b.data.length ? a.data.length : b.data.length;
    for (var i = 0; i < n; i++) {
      final c = a.data[i].compareTo(b.data[i]);
      if (c != 0) return c;
    }
    return a.data.length.compareTo(b.data.length);
  }

  /// Rows without a cycle time yet sort last in both directions — they carry
  /// no information to order by.
  static int _byCycle(TraceRow a, TraceRow b, bool ascending) {
    final x = a.periodMs, y = b.periodMs;
    if (x == null || y == null) {
      if (x == y) return 0;
      return (x == null ? 1 : -1) * (ascending ? 1 : -1);
    }
    return x.compareTo(y);
  }

  List<TraceRow> get groupedRows {
    final out = _rows.values.where((r) => _passes(r.id, r.extended)).toList();
    final sign = sortAscending ? 1 : -1;
    out.sort((a, b) {
      final c = switch (sort) {
        TraceSort.channel => a.channel.compareTo(b.channel),
        TraceSort.id => _byId(a, b),
        TraceSort.name => (messageFor(a.channel, a.id, a.extended)?.name ?? '')
            .compareTo(messageFor(b.channel, b.id, b.extended)?.name ?? ''),
        TraceSort.length => a.data.length.compareTo(b.data.length),
        TraceSort.data => _byData(a, b),
        TraceSort.count => a.count.compareTo(b.count),
        TraceSort.cycle => _byCycle(a, b, sortAscending),
      };
      // Ties keep a stable, predictable order instead of hash order; the same
      // id on both buses ends up adjacent, which is what a gateway check wants.
      if (c != 0) return sign * c;
      final byId = _byId(a, b);
      return byId != 0 ? byId : a.channel.compareTo(b.channel);
    });
    return out;
  }

  /// CSV of the live buffer, in chronological order.
  String toCsv() {
    final sink = MemorySink();
    final w = CsvWriter(sink, DateTime.now());
    _live.forEach(w.write);
    return utf8.decode(sink.bytes);
  }

  @override
  void dispose() {
    _repaint?.cancel();
    super.dispose();
  }
}
