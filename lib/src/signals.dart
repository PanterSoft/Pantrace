// Signal graphics (CANoe's Graphics window): DBC signals sampled out of the
// trace into time series, plus the pure maths the plot needs — decimation to
// screen pixels and round axis ticks. No widgets here, so it is unit-tested.
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'can.dart';
import 'dbc.dart';

/// Identifies a plotted signal: which bus, which message, which signal.
@immutable
class SignalKey {
  final int channel;
  final int id;
  final bool extended;
  final String signal;
  const SignalKey(this.channel, this.id, this.extended, this.signal);

  @override
  bool operator ==(Object other) =>
      other is SignalKey &&
      other.channel == channel &&
      other.id == id &&
      other.extended == extended &&
      other.signal == signal;

  @override
  int get hashCode => Object.hash(channel, id, extended, signal);
}

/// One signal's samples, oldest first. Time is microseconds since epoch.
class SignalSeries {
  final SignalKey key;
  final String message;
  final DbcSignal signal;

  /// Palette slot (0-7). Fixed for the life of the series, so removing another
  /// signal never repaints this one.
  final int slot;

  final _t = <int>[];
  final _v = <double>[];

  SignalSeries(this.key, this.message, this.signal, this.slot);

  /// ponytail: per-signal sample cap. Past it the oldest half is dropped, so a
  /// long capture keeps its recent history without growing without bound.
  static const capacity = 200000;

  String get label => '${key.channel + 1}: $message.${signal.name}';
  String get unit => signal.unit;

  /// Enumerations and flags hold a level rather than slope between samples.
  bool get stepped => signal.valueTable.isNotEmpty || signal.length == 1;

  int get length => _t.length;
  bool get isEmpty => _t.isEmpty;
  int timeAt(int i) => _t[i];
  double valueAt(int i) => _v[i];
  int get firstTime => _t.first;
  int get lastTime => _t.last;
  double get lastValue => _v.last;

  void add(int t, double v) {
    // Frames from a replayed or merged log can arrive out of order; keep the
    // series sorted so binary search and drawing stay correct.
    if (_t.isNotEmpty && t < _t.last) {
      final i = indexAtOrAfter(t);
      _t.insert(i, t);
      _v.insert(i, v);
    } else {
      _t.add(t);
      _v.add(v);
    }
    if (_t.length > capacity) {
      _t.removeRange(0, capacity ~/ 2);
      _v.removeRange(0, capacity ~/ 2);
    }
  }

  void clear() {
    _t.clear();
    _v.clear();
  }

  /// First index with time >= [t] (== length when all are earlier).
  int indexAtOrAfter(int t) {
    var lo = 0, hi = _t.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_t[mid] < t) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  /// The sample closest in time to [t], or null when there are none.
  int? nearest(int t) {
    if (_t.isEmpty) return null;
    final i = indexAtOrAfter(t);
    if (i == 0) return 0;
    if (i == _t.length) return i - 1;
    return t - _t[i - 1] <= _t[i] - t ? i - 1 : i;
  }

  /// The value in force at [t]: the last sample at or before it (CAN signals
  /// hold until the next frame). Null before the first sample.
  double? heldAt(int t) {
    final i = indexAtOrAfter(t + 1);
    return i == 0 ? null : _v[i - 1];
  }

  /// Min and max over samples in [from, to], or null when there are none.
  (double, double)? range(int from, int to) {
    var i = indexAtOrAfter(from);
    if (i >= _t.length || _t[i] > to) return null;
    var lo = double.infinity, hi = double.negativeInfinity;
    for (; i < _t.length && _t[i] <= to; i++) {
      lo = math.min(lo, _v[i]);
      hi = math.max(hi, _v[i]);
    }
    return (lo, hi);
  }

  /// Human-readable value, with the value-table name when there is one.
  String format(double v) {
    final named = signal.valueTable[v.round()];
    if (named != null && v == v.roundToDouble()) return named;
    return formatNumber(v) + (unit.isEmpty ? '' : ' $unit');
  }
}

/// A number without float noise: 12.5, not 12.500000000001.
String formatNumber(double v) {
  if (v == v.roundToDouble() && v.abs() < 1e15) return v.toInt().toString();
  return double.parse(v.toStringAsPrecision(6)).toString();
}

/// The set of plotted signals and their samples.
class SignalPlot extends ChangeNotifier {
  /// Eight palette slots; a ninth signal would need a ninth hue, which no
  /// colour-blind-safe palette has.
  static const maxSeries = 8;

  final series = <SignalSeries>[];

  /// Messages any plotted signal lives in, for a cheap reject in [feed].
  final _watched = <(int, int)>{};

  bool contains(SignalKey k) => series.any((s) => s.key == k);
  SignalSeries? operator [](SignalKey k) => series.where((s) => s.key == k).firstOrNull;
  bool get full => series.length >= maxSeries;

  /// Starts plotting [signal] of [msg] on [channel]. Returns null when all
  /// slots are taken or it is already plotted. Fill history with [sample].
  SignalSeries? add(int channel, DbcMessage msg, DbcSignal signal) {
    final key = SignalKey(channel, msg.id, msg.extended, signal.name);
    if (full || contains(key)) return null;
    final used = series.map((s) => s.slot).toSet();
    final slot = List.generate(maxSeries, (i) => i).firstWhere((i) => !used.contains(i));
    final s = SignalSeries(key, msg.name, signal, slot);
    series.add(s);
    _rewatch();
    notifyListeners();
    return s;
  }

  void remove(SignalKey k) {
    series.removeWhere((s) => s.key == k);
    _rewatch();
    notifyListeners();
  }

  /// Drops every signal of [channel], e.g. when its DBC is unloaded.
  void removeChannel(int channel) {
    series.removeWhere((s) => s.key.channel == channel);
    _rewatch();
    notifyListeners();
  }

  /// Forgets the samples, keeps the selection.
  void clearData() {
    for (final s in series) {
      s.clear();
    }
    notifyListeners();
  }

  void _rewatch() {
    _watched
      ..clear()
      ..addAll(series.map((s) => (s.key.channel, DbcDatabase.key(s.key.id, s.key.extended))));
  }

  /// Samples every plotted signal [f] carries. [msg] is its DBC message.
  /// Called for each traced frame; returns quickly for everything unplotted.
  void feed(CanFrame f, DbcMessage? msg) {
    if (msg == null || series.isEmpty) return;
    if (!_watched.contains((f.channel, DbcDatabase.key(msg.id, msg.extended)))) return;
    for (final s in series) {
      if (s.key.channel == f.channel && s.key.id == msg.id && s.key.extended == msg.extended) {
        sample(s, msg, f);
      }
    }
  }

  /// Appends [s]'s value in [f] (a frame of [msg]) — also how a newly added
  /// series is filled from the trace buffer.
  static void sample(SignalSeries s, DbcMessage msg, CanFrame f) {
    // A multiplexed signal is only in frames whose selector picks its page.
    if (!msg.signalsFor(f.data).any((x) => x.name == s.signal.name)) return;
    if (f.rtr || f.isError) return;
    s.add(f.timestamp.microsecondsSinceEpoch, s.signal.decode(f.data));
  }

  /// Newest sample time over all series, or null when nothing is plotted.
  int? get lastTime {
    int? t;
    for (final s in series) {
      if (!s.isEmpty && (t == null || s.lastTime > t)) t = s.lastTime;
    }
    return t;
  }

  int? get firstTime {
    int? t;
    for (final s in series) {
      if (!s.isEmpty && (t == null || s.firstTime < t)) t = s.firstTime;
    }
    return t;
  }
}

/// Reduces the samples of [s] within [from, to] to at most two points per
/// pixel column (the column's first and extreme values), so drawing costs
/// O(width) however dense the data. Keeps the sample just before [from] and
/// just after [to] so lines run to the plot edges. Returns (time, value) pairs.
List<(int, double)> decimate(SignalSeries s, int from, int to, int columns) {
  if (s.isEmpty || to <= from || columns <= 0) return const [];
  final start = math.max(0, s.indexAtOrAfter(from) - 1);
  final end = math.min(s.length, s.indexAtOrAfter(to + 1) + 1);
  final n = end - start;
  if (n <= columns * 4) {
    return [for (var i = start; i < end; i++) (s.timeAt(i), s.valueAt(i))];
  }
  final out = <(int, double)>[];
  final span = to - from;
  var col = -1;
  int minI = -1, maxI = -1;
  void flush() {
    if (minI < 0) return;
    final a = math.min(minI, maxI), b = math.max(minI, maxI);
    out.add((s.timeAt(a), s.valueAt(a)));
    if (b != a) out.add((s.timeAt(b), s.valueAt(b)));
  }

  for (var i = start; i < end; i++) {
    final t = s.timeAt(i);
    final c = ((t - from) * columns ~/ span).clamp(-1, columns);
    if (c != col) {
      flush();
      col = c;
      minI = maxI = i;
    } else {
      if (s.valueAt(i) < s.valueAt(minI)) minI = i;
      if (s.valueAt(i) > s.valueAt(maxI)) maxI = i;
    }
  }
  flush();
  return out;
}

/// Round axis ticks covering [lo, hi]: about [count] steps of 1, 2 or 5 × 10^n.
List<double> niceTicks(double lo, double hi, {int count = 4}) {
  if (!lo.isFinite || !hi.isFinite) return const [];
  if (hi <= lo) return [lo];
  final raw = (hi - lo) / count;
  final mag = math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
  final norm = raw / mag;
  final step = (norm < 1.5 ? 1 : norm < 3 ? 2 : norm < 7 ? 5 : 10) * mag;
  final first = (lo / step).ceil() * step;
  return [
    for (var v = first; v <= hi + step * 1e-9; v += step)
      // Snap float drift (0.30000000000000004) back onto the grid.
      double.parse((v).toStringAsPrecision(12)),
  ];
}
