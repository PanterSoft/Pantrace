// Stability under sustained load: the paths that see real traffic volume,
// pushed far past what any bus can carry, checking bounded memory, no lost
// frames within the ring, and no exception anywhere in the pipeline.
import 'dart:math';
import 'dart:typed_data';

import 'dart:ffi';

import 'package:flutter_test/flutter_test.dart';
import 'package:pantrace/src/backends/pcan.dart';
import 'package:pantrace/src/backends/slcan.dart';
import 'package:pantrace/src/can.dart';
import 'package:pantrace/src/trace.dart';

Uint8List b(List<int> x) => Uint8List.fromList(x);


void main() {
  group('TraceModel under sustained load', () {
    test('a long burst across many ids stays within the ring and tallies right', () {
      final m = TraceModel();
      const burst = 60000; // far more than any single bus could carry
      final rng = Random(1);
      for (var i = 0; i < burst; i++) {
        // Every (channel, id) combination recurs many times over the burst;
        // a plain i % N would alias channel and id together and never visit
        // some combinations at all.
        final id = 0x100 + (i % 32); // a realistic, bounded id space
        final channel = (i ~/ 32) % TraceModel.channels;
        m.add(CanFrame(
          id: id,
          channel: channel,
          data: b([rng.nextInt(256), rng.nextInt(256)]),
        ));
      }
      expect(m.totalFrames, burst);
      // The live buffer is capped; it never grows past its declared bound
      // no matter how much traffic runs through it.
      expect(m.liveFrames.length, TraceModel.liveCapacity);
      // One row per (channel, id): 32 ids * 2 channels, none dropped, none
      // duplicated.
      expect(m.groupedRows.length, 32 * TraceModel.channels);
      expect(m.groupedRows.fold<int>(0, (sum, r) => sum + r.count), burst);
      m.dispose();
    });

    test('a flood of error frames does not starve or corrupt normal traffic', () {
      final m = TraceModel();
      for (var i = 0; i < 50000; i++) {
        m.add(i.isEven
            ? CanFrame.error('bus error')
            : CanFrame(id: 0x123, data: b([1])));
      }
      expect(m.errorFrames, 25000);
      expect(m.totalFrames, 25000); // errors excluded, per the documented contract
      expect(m.groupedRows.single.count, 25000);
      m.dispose();
    });

    test('sort and filter stay correct once the ring is full and wrapping', () {
      final m = TraceModel();
      for (var i = 0; i < TraceModel.liveCapacity * 3; i++) {
        m.add(CanFrame(id: 0x100 + (i % 4), data: b([i & 0xFF])));
      }
      m.setFilter('101');
      expect(m.liveFrames.every((f) => f.id == 0x101), isTrue);
      expect(m.liveFrames, isNotEmpty);
      m.setSort(TraceSort.count);
      final counts = m.groupedRows.map((r) => r.count).toList();
      expect(counts, orderedEquals(List.of(counts)..sort()));
      m.dispose();
    });
  });

  group('SLCAN receive buffer under load', () {
    test('a sustained flood of valid frames is parsed with none lost', () {
      // Simulates SlcanBus._onData being fed everything a fast adapter could
      // produce in one read, well beyond a single serial chunk.
      final frames = <CanFrame>[];
      var buffer = '';
      for (var i = 0; i < 20000; i++) {
        buffer += encodeSlcan(CanFrame(id: 0x123, data: b([i & 0xFF])));
      }
      while (buffer.isNotEmpty) {
        final (lines, rest) = splitSlcanLines(buffer);
        buffer = rest;
        for (final line in lines) {
          final f = parseSlcan(line);
          if (f != null) frames.add(f);
        }
        if (lines.isEmpty) break; // no full line yet: matches the real drain loop
      }
      expect(frames.length, 20000);
    });

    test('continuous noise with no line terminator does not grow forever',
        () async {
      // A device that is not actually an SLCAN adapter (or a noisy cable) can
      // stream junk with no \r. feedForTest runs the exact code path a real
      // serial read would, so this exercises the bound for real, not a
      // reimplementation of it.
      final bus = SlcanBus();
      final status = <String>[];
      bus.status.listen(status.add); // broadcast stream: delivery is async
      // Comfortably past the cap, many times over, in chunks the size a
      // real read callback would deliver.
      for (var i = 0; i < 50; i++) {
        bus.feedForTest(Uint8List.fromList(List.filled(500, 0x41))); // 'A' * 500
      }
      await Future<void>.delayed(Duration.zero);
      // Every oversized chunk is reclaimed on the spot — the buffer is
      // never allowed to carry noise forward and accumulate across chunks.
      expect(status, everyElement(contains('discarding')));
      expect(status.length, 50);
    });

    test('a large chunk of complete lines (after App Nap) is not discarded',
        () async {
      final bus = SlcanBus();
      final frames = <CanFrame>[];
      bus.frames.listen(frames.add);
      // One 4 KB serial read holding hundreds of valid frames.
      bus.feedForTest(Uint8List.fromList(('t1238DEADBEEFDEADBEEF\r' * 300).codeUnits));
      await Future<void>.delayed(Duration.zero);
      expect(frames.length, 300);
    });
  });

  group('PCAN drain loop under a backlog bigger than one tick', () {
    test('a queue deeper than 512 frames survives across ticks, none lost', () async {
      // The real driver hands frames back one CAN_Read() at a time; a queue
      // deeper than the 512-per-tick cap must drain fully over enough ticks
      // instead of ever dropping the tail.
      const backlog = 5000;
      final rx = List.generate(
          backlog, (i) => encodePcanMsg(CanFrame(id: 0x123, data: b([i & 0xFF, i >> 8]))));
      pcanDriver = PcanDriver(
        init: (a, b, c, d, e) => 0,
        uninit: (a) => 0,
        read: (ch, msg, ts) {
          if (rx.isEmpty) return 0x20; // PCAN_ERROR_QRCVEMPTY
          msg.asTypedList(16).setAll(0, rx.removeAt(0));
          return 0;
        },
        write: (a, b) => 0,
        getValue: (a, b, c, d) => 0,
        errText: (a, b, c) => 0,
      );
      final bus = PcanBus();
      final got = <CanFrame>[];
      bus.frames.listen(got.add);
      await bus.open('81', 500000);
      // backlog/512 drain passes of 1ms ticks; a loaded CI runner stretches
      // ticks, so wait for the drain rather than a fixed time.
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (got.length < backlog && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await bus.close();
      pcanDriver = null;

      expect(got.length, backlog);
      expect(got.map((f) => f.data[0] | (f.data[1] << 8)),
          List.generate(backlog, (i) => i));
    });
  });
}
