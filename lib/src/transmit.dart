// Cyclic transmission (CANoe's Interactive Generator) and log replay (its
// Replay block). Neither knows about buses: they call [SendFn] and the page
// routes the frame to whatever interface is connected on that channel.
import 'dart:async';

import 'package:flutter/foundation.dart';

import 'can.dart';

/// Sends [frame] on app channel [channel]; throws when it cannot.
typedef SendFn = Future<void> Function(int channel, CanFrame frame);

class TxJob {
  final int channel;
  final CanFrame frame;
  final Duration period;
  int sent = 0;
  String? error;
  Timer? _timer;

  TxJob(this.channel, this.frame, this.period);

  bool get running => _timer != null;
}

/// A list of periodically transmitted frames.
class TxScheduler extends ChangeNotifier {
  final SendFn send;
  final jobs = <TxJob>[];

  TxScheduler(this.send);

  int get running => jobs.where((j) => j.running).length;

  /// Adds a job; it starts right away, first frame immediately.
  TxJob add(int channel, CanFrame frame, Duration period) {
    if (period <= Duration.zero) {
      throw ArgumentError.value(period, 'period', 'must be positive');
    }
    final j = TxJob(channel, frame, period);
    jobs.add(j);
    start(j);
    return j;
  }

  void start(TxJob j) {
    if (j.running) return;
    j.error = null;
    j._timer = Timer.periodic(j.period, (_) => _fire(j));
    _fire(j);
    notifyListeners();
  }

  void stop(TxJob j) {
    if (!j.running) return;
    j._timer?.cancel();
    j._timer = null;
    notifyListeners();
  }

  void remove(TxJob j) {
    stop(j);
    jobs.remove(j);
    notifyListeners();
  }

  /// Stops the jobs on [channel] (its interface went away), or all of them.
  void stopAll({int? channel}) {
    for (final j in jobs) {
      if (channel == null || j.channel == channel) stop(j);
    }
  }

  Future<void> _fire(TxJob j) async {
    try {
      await send(j.channel, j.frame);
      j.sent++;
    } catch (e) {
      // A job that cannot send stops rather than failing a hundred times a
      // second; the list shows why.
      j.error = '$e';
      stop(j);
    }
  }

  /// Silent: whoever listens is being torn down too.
  @override
  void dispose() {
    for (final j in jobs) {
      j._timer?.cancel();
      j._timer = null;
    }
    super.dispose();
  }
}

/// Plays recorded frames back onto the buses with their original timing.
class LogReplay extends ChangeNotifier {
  final List<CanFrame> frames;
  final SendFn send;
  final String name;

  /// 2.0 plays twice as fast.
  double speed;
  bool loop;

  var position = 0;
  var sent = 0;
  var failed = 0;
  Timer? _timer;
  final _clock = Stopwatch();
  var _base = 0; // microseconds of log time at the clock's zero

  /// Error frames cannot be transmitted, so they are left out up front.
  LogReplay(List<CanFrame> frames, this.send,
      {this.name = '', this.speed = 1.0, this.loop = false})
      : frames = frames.where((f) => !f.isError).toList();

  bool get running => _timer != null;
  bool get finished => position >= frames.length && !running;
  double get progress => frames.isEmpty ? 1 : position / frames.length;

  int _logMicros(int i) =>
      frames[i].timestamp.difference(frames.first.timestamp).inMicroseconds;

  void start() {
    if (running || frames.isEmpty) return;
    if (position >= frames.length) position = 0;
    _base = _logMicros(position);
    _clock
      ..reset()
      ..start();
    _timer = Timer(Duration.zero, _pump);
    notifyListeners();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _clock.stop();
    notifyListeners();
  }

  /// ponytail: frames sent per turn of the event loop when a burst is due at
  /// once, so a log with thousands of same-stamp frames cannot freeze the UI.
  static const burst = 256;

  /// Sends everything that is due, then sleeps until the next frame is.
  Future<void> _pump() async {
    var inBurst = 0;
    while (running && position < frames.length) {
      final due = ((_logMicros(position) - _base) / speed).round();
      final wait = due - _clock.elapsedMicroseconds;
      if (wait > 1000 || inBurst++ >= burst) {
        _timer = Timer(Duration(microseconds: wait > 0 ? wait : 0), _pump);
        return;
      }
      final f = frames[position++];
      try {
        await send(f.channel, f);
        sent++;
      } catch (_) {
        failed++; // channel not connected: skip, like CANoe's replay
      }
    }
    if (!running) return;
    if (loop && frames.isNotEmpty) {
      position = 0;
      _base = 0;
      _clock.reset();
      // At least a millisecond per pass: a log that is one instant long would
      // otherwise spin as fast as the CPU can go.
      _timer = Timer(const Duration(milliseconds: 1), _pump);
      return;
    }
    _timer = null;
    _clock.stop();
    notifyListeners();
  }

  /// Silent: whoever listens is being torn down too.
  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    _clock.stop();
    super.dispose();
  }
}
