import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pantrace/src/can.dart';
import 'package:pantrace/src/log/log.dart';
import 'package:pantrace/src/trace.dart';
import 'package:pantrace/src/transmit.dart';

Uint8List b(List<int> x) => Uint8List.fromList(x);

/// Real timers, so wait for a condition with a deadline that a slow CI runner
/// will not hit, rather than for a fixed time.
Future<void> until(bool Function() done, {Duration timeout = const Duration(seconds: 10)}) async {
  final end = DateTime.now().add(timeout);
  while (!done()) {
    if (DateTime.now().isAfter(end)) fail('timed out');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  group('TxScheduler', () {
    test('sends at once, then every period, until stopped', () async {
      final sent = <(int, CanFrame)>[];
      final tx = TxScheduler((ch, f) async => sent.add((ch, f)));
      var notified = 0;
      tx.addListener(() => notified++);
      final job = tx.add(1, CanFrame(id: 0x10, data: b([1])), const Duration(milliseconds: 10));
      expect(sent.length, 1); // the first frame does not wait a period
      expect(tx.running, 1);
      await until(() => job.sent >= 4);
      expect(sent.every((s) => s.$1 == 1 && s.$2.id == 0x10), isTrue);

      tx.stop(job);
      final n = sent.length;
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(sent.length, n);
      expect(tx.running, 0);

      tx.start(job);
      await until(() => sent.length > n);
      tx.remove(job);
      expect(tx.jobs, isEmpty);
      expect(notified, greaterThanOrEqualTo(4));
      tx.dispose();
    });

    test('a job that cannot send stops and says why', () async {
      final tx = TxScheduler((ch, f) async => throw CanBusException('CAN2 is not connected'));
      final job = tx.add(1, CanFrame(id: 1, data: b([])), const Duration(milliseconds: 5));
      await until(() => !job.running);
      expect(job.error, contains('not connected'));
      expect(job.sent, 0);
      tx.dispose();
    });

    test('stopAll can be limited to one channel', () {
      final tx = TxScheduler((ch, f) async {});
      final a = tx.add(0, CanFrame(id: 1, data: b([])), const Duration(seconds: 1));
      final c = tx.add(1, CanFrame(id: 2, data: b([])), const Duration(seconds: 1));
      tx.stopAll(channel: 1);
      expect((a.running, c.running), (true, false));
      tx.stopAll();
      expect(a.running, isFalse);
      expect(() => tx.add(0, CanFrame(id: 1, data: b([])), Duration.zero), throwsArgumentError);
      tx.dispose();
    });
  });

  group('LogReplay', () {
    final t0 = DateTime(2026);
    List<CanFrame> log(int n, Duration gap) => [
          for (var i = 0; i < n; i++)
            CanFrame(id: 0x100 + i, data: b([i]), timestamp: t0.add(gap * i), channel: i % 2),
        ];

    test('plays every frame in order, on its channel, with the log timing', () async {
      final sent = <(int, int)>[];
      final frames = log(5, const Duration(milliseconds: 40))..insert(2, CanFrame.error('x', timestamp: t0));
      final r = LogReplay(frames, (ch, f) async => sent.add((ch, f.id)));
      expect(r.frames.length, 5); // error frames are not replayable
      final clock = Stopwatch()..start();
      r.start();
      expect(r.running, isTrue);
      await until(() => !r.running);
      // 4 gaps of 40 ms; allow for coarse timers but not for "all at once".
      expect(clock.elapsedMilliseconds, greaterThanOrEqualTo(150));
      expect(sent, [(0, 0x100), (1, 0x101), (0, 0x102), (1, 0x103), (0, 0x104)]);
      expect((r.sent, r.failed, r.progress, r.finished), (5, 0, 1.0, true));
    });

    test('speed scales the timing and unsendable frames are counted', () async {
      final r = LogReplay(log(4, const Duration(seconds: 1)), (ch, f) async {
        if (ch == 1) throw CanBusException('CAN2 is not connected');
      }, speed: 100);
      final clock = Stopwatch()..start();
      r.start();
      await until(() => !r.running);
      expect(clock.elapsedMilliseconds, lessThan(2000)); // 3 s of log at 100x
      expect((r.sent, r.failed), (2, 2));
    });

    test('loops until stopped, and can be restarted', () async {
      var sent = 0;
      final r = LogReplay(log(3, Duration.zero), (ch, f) async => sent++, loop: true);
      r.start();
      await until(() => sent > 9);
      r.stop();
      expect(r.running, isFalse);
      final n = sent;
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(sent, n);
      r.loop = false;
      r.start();
      await until(() => !r.running);
      r.dispose();
      expect(LogReplay(const [], (c, f) async {}).progress, 1.0);
    });
  });

  group('TraceModel logging', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('pantrace_model'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('records every frame, paused or not, until stopped', () async {
      final m = TraceModel();
      final path = '${dir.path}/r.asc';
      m.startRecording(path);
      expect(m.recorder!.format, LogFormat.asc);
      m.add(CanFrame(id: 1, data: b([1])));
      m.setPaused(true);
      m.add(CanFrame(id: 2, data: b([2])));
      m.add(CanFrame.error('bus off'));
      expect(m.liveFrames.length, 1); // the view is frozen...
      final r = await m.stopRecording();
      expect(r!.frames, 3); // ...the log is not
      expect(m.recorder, isNull);
      expect(await m.stopRecording(), isNull);
      expect((await readLogFile(path)).frames.map((f) => f.isError ? 'E' : f.idHex),
          ['001', '002', 'E']);
      expect(m.statusLog.last, contains('recorded 3 frames'));
      m.dispose();
    });

    test('a failing recording stops itself and tracing goes on', () async {
      final m = TraceModel();
      // ASC, not BLF: text is not compressed, so the writes reach the file.
      m.startRecording('${dir.path}/r.asc');
      await m.recorder!.stop(); // file closed under the recorder's feet
      for (var i = 0; i < 5000; i++) {
        m.add(CanFrame(id: 3, data: b([1, 2, 3, 4, 5, 6, 7, 8])));
      }
      expect(m.recorder, isNull);
      expect(m.statusLog.last, contains('stopped'));
      expect(m.totalFrames, 5000);
      m.dispose();
    });

    test('offline frames fill the views but not the live statistics', () async {
      final m = TraceModel();
      final t = DateTime(2026);
      final dropped = m.addOffline([
        CanFrame(id: 1, data: b([1]), timestamp: t),
        CanFrame(id: 1, data: b([2]), timestamp: t.add(const Duration(milliseconds: 10))),
        CanFrame(id: 9, data: b([]), channel: 5, timestamp: t),
        CanFrame.error('x', timestamp: t),
      ]);
      expect(dropped, 1);
      expect((m.totalFrames, m.errorFrames), (2, 1));
      expect(m.groupedRows.single.periodMs, 10.0);
      expect(m.measurementStart, t);
      expect(m.bufferedFrames.length, 3);
      await Future<void>.delayed(const Duration(milliseconds: 70));
      expect(m.framesPerSecond, 0);
      expect(m.busLoadPercent[0], 0);
      m.clear();
      expect(m.measurementStart, isNull);
      m.dispose();
    });

    test('the live buffer stays capped when a big log is imported', () {
      final m = TraceModel();
      final t = DateTime(2026);
      final clock = Stopwatch()..start();
      m.addOffline([
        for (var i = 0; i < 200000; i++)
          CanFrame(id: i & 0x7FF, data: b([i & 0xFF]), timestamp: t.add(Duration(microseconds: i))),
      ]);
      expect(m.bufferedFrames.length, TraceModel.liveCapacity);
      expect(m.bufferedFrames.last.data[0], 199999 & 0xFF);
      expect(m.totalFrames, 200000);
      // A ring buffer, not a list shifted per frame: well under a second.
      expect(clock.elapsedMilliseconds, lessThan(5000));
      m.dispose();
    });

    test('time mode', () {
      final m = TraceModel();
      expect(m.timeMode, TimeMode.absolute);
      m.setTimeMode(TimeMode.delta);
      expect(m.timeMode, TimeMode.delta);
      m.dispose();
    });
  });
}
