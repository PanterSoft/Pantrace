import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:pantrace/src/can.dart';
import 'package:pantrace/src/dbc.dart';
import 'package:pantrace/src/trace.dart';

Uint8List b(List<int> x) => Uint8List.fromList(x);
CanFrame f(int id, List<int> data, {bool ext = false, DateTime? t}) =>
    CanFrame(id: id, data: b(data), extended: ext, timestamp: t);

void main() {
  group('error frames', () {
    test('are counted, shown live, and kept out of rows and rate stats', () {
      final m = TraceModel();
      m.add(f(0x123, [1]));
      m.add(CanFrame.error('bus off'));
      expect(m.errorFrames, 1);
      expect(m.totalFrames, 1); // error frames do not inflate the frame count
      expect(m.groupedRows.length, 1);
      expect(m.liveFrames.first.error, 'bus off');
      m.clear();
      expect(m.errorFrames, 0);
      m.dispose();
    });

    test('stay visible through an id filter and land in the CSV', () {
      final m = TraceModel();
      m.add(f(0x123, [1]));
      m.add(CanFrame.error('no ACK'));
      m.setFilter('456');
      expect(m.liveFrames.map((x) => x.error), ['no ACK']);
      expect(m.toCsv(), contains(',error,,,,"no ACK"'));
      m.dispose();
    });
  });

  group('channels', () {
    test('the same id on two buses is two rows, adjacent by default', () {
      final m = TraceModel();
      m.add(f(0x200, [0]).withChannel(1));
      m.add(f(0x100, [0]).withChannel(1));
      m.add(f(0x100, [0]).withChannel(0));
      expect(m.groupedRows.map((r) => (r.id, r.channel)),
          [(0x100, 0), (0x100, 1), (0x200, 1)]);
      m.setSort(TraceSort.channel);
      expect(m.groupedRows.map((r) => r.channel), [0, 1, 1]);
      m.dispose();
    });

    test('bus load is tracked per channel', () async {
      final m = TraceModel();
      m.bitrates[1] = 125000;
      m.add(f(0x100, [0, 0, 0, 0, 0, 0, 0, 0]).withChannel(1));
      await Future<void>.delayed(const Duration(milliseconds: 70));
      expect(m.busLoadPercent[0], 0);
      expect(m.busLoadPercent[1], greaterThan(0));
      m.dispose();
    });
  });

  group('grouping', () {
    test('sorts by the selected column and toggles direction', () {
      final m = TraceModel();
      m.add(f(0x200, [0]));
      m.add(f(0x100, [0, 0, 0]));
      m.add(f(0x100, [0, 0, 0]));

      m.setSort(TraceSort.count);
      expect(m.groupedRows.map((r) => r.id), [0x200, 0x100]);
      m.setSort(TraceSort.count); // same column again flips
      expect(m.sortAscending, isFalse);
      expect(m.groupedRows.map((r) => r.id), [0x100, 0x200]);

      m.setSort(TraceSort.length);
      expect(m.sortAscending, isTrue);
      expect(m.groupedRows.map((r) => r.id), [0x200, 0x100]);

      m.dispose();
    });

    test('sorting by cycle keeps rows without one last in both directions', () {
      final m = TraceModel();
      final t = DateTime(2024);
      m.add(f(0x100, [0], t: t)); // seen once: no cycle time
      m.add(f(0x300, [0], t: t));
      m.add(f(0x300, [0], t: t.add(const Duration(milliseconds: 10))));

      m.setSort(TraceSort.cycle);
      expect(m.groupedRows.map((r) => r.id), [0x300, 0x100]);
      m.setSort(TraceSort.cycle);
      expect(m.groupedRows.map((r) => r.id), [0x300, 0x100]);
      m.dispose();
    });

    test('sorting by data compares bytes, then shorter payload first', () {
      final m = TraceModel();
      m.add(f(0x100, [1, 2]));
      m.add(f(0x200, [1, 2, 3])); // shares the [1, 2] prefix, one byte longer
      m.add(f(0x300, [1, 1]));

      m.setSort(TraceSort.data);
      expect(m.groupedRows.map((r) => r.id), [0x300, 0x100, 0x200]);
      m.dispose();
    });

    test('two rows that both have a cycle time compare by period', () {
      final m = TraceModel();
      final t = DateTime(2024);
      m.add(f(0x100, [0], t: t));
      m.add(f(0x100, [0], t: t.add(const Duration(milliseconds: 50))));
      m.add(f(0x200, [0], t: t));
      m.add(f(0x200, [0], t: t.add(const Duration(milliseconds: 10))));

      m.setSort(TraceSort.cycle);
      expect(m.groupedRows.map((r) => r.id), [0x200, 0x100]);
      m.dispose();
    });

    test('collapses repeats of one id into a single row', () {
      final m = TraceModel();
      for (var i = 0; i < 10; i++) {
        m.add(f(0x123, [i]));
      }
      expect(m.groupedRows.length, 1);
      expect(m.groupedRows.first.count, 10);
      expect(m.groupedRows.first.data, b([9]));
      m.dispose();
    });

    test('keeps standard and extended ids with the same number apart', () {
      final m = TraceModel();
      m.add(f(0x123, [1]));
      m.add(f(0x123, [2], ext: true));
      expect(m.groupedRows.length, 2);
      m.dispose();
    });

    test('sorts standard ids before extended, ascending', () {
      final m = TraceModel();
      m.add(f(0x200, [0]));
      m.add(f(0x100, [0]));
      m.add(f(0x50, [0], ext: true));
      expect(m.groupedRows.map((r) => r.id), [0x100, 0x200, 0x50]);
      m.dispose();
    });

    test('flags which bytes changed since the previous frame', () {
      final m = TraceModel();
      m.add(f(0x123, [0x00, 0x00, 0x00]));
      m.add(f(0x123, [0x00, 0xFF, 0x00]));
      expect(m.groupedRows.first.changedMask, 0x02);
      m.add(f(0x123, [0x01, 0xFF, 0x01]));
      expect(m.groupedRows.first.changedMask, 0x05);
      m.dispose();
    });

    test('computes the cycle time between occurrences', () {
      final m = TraceModel();
      final t0 = DateTime(2026, 1, 1);
      m.add(f(0x123, [0], t: t0));
      m.add(f(0x123, [0], t: t0.add(const Duration(milliseconds: 100))));
      expect(m.groupedRows.first.periodMs, closeTo(100, 0.001));
      m.dispose();
    });

    test('a first sighting has no cycle time yet', () {
      final m = TraceModel();
      m.add(f(0x123, [0]));
      expect(m.groupedRows.first.periodMs, isNull);
      m.dispose();
    });
  });

  group('live buffer', () {
    test('newest frame comes first', () {
      final m = TraceModel();
      m.add(f(0x1, [1]));
      m.add(f(0x2, [2]));
      expect(m.liveFrames.map((x) => x.id), [0x2, 0x1]);
      m.dispose();
    });

    test('is capped so a long capture cannot exhaust memory', () {
      final m = TraceModel();
      for (var i = 0; i < TraceModel.liveCapacity + 500; i++) {
        m.add(f(i & 0x7FF, [0]));
      }
      expect(m.liveFrames.length, TraceModel.liveCapacity);
      expect(m.totalFrames, TraceModel.liveCapacity + 500);
      m.dispose();
    });

    test('pause stops recording but keeps counting', () {
      final m = TraceModel();
      m.add(f(0x1, [1]));
      m.setPaused(true);
      m.add(f(0x2, [2]));
      expect(m.liveFrames.length, 1);
      expect(m.totalFrames, 2);
      m.dispose();
    });

    test('clear empties both views', () {
      final m = TraceModel();
      m.add(f(0x1, [1]));
      m.clear();
      expect(m.liveFrames, isEmpty);
      expect(m.groupedRows, isEmpty);
      expect(m.totalFrames, 0);
      m.dispose();
    });
  });

  group('id filter', () {
    test('empty filter accepts everything', () {
      expect(TraceModel.matchesIdFilter(0x123, ''), isTrue);
    });

    test('matches a single hex id', () {
      expect(TraceModel.matchesIdFilter(0x123, '123'), isTrue);
      expect(TraceModel.matchesIdFilter(0x124, '123'), isFalse);
    });

    test('matches a hex range inclusively', () {
      expect(TraceModel.matchesIdFilter(0x200, '200-2FF'), isTrue);
      expect(TraceModel.matchesIdFilter(0x2FF, '200-2FF'), isTrue);
      expect(TraceModel.matchesIdFilter(0x300, '200-2FF'), isFalse);
    });

    test('accepts a comma-separated mix', () {
      const filter = '100, 200-2FF, 7FF';
      expect(TraceModel.matchesIdFilter(0x100, filter), isTrue);
      expect(TraceModel.matchesIdFilter(0x250, filter), isTrue);
      expect(TraceModel.matchesIdFilter(0x7FF, filter), isTrue);
      expect(TraceModel.matchesIdFilter(0x123, filter), isFalse);
    });

    test('ignores junk instead of throwing', () {
      expect(TraceModel.matchesIdFilter(0x123, 'zzz'), isFalse);
      expect(TraceModel.matchesIdFilter(0x123, ',,'), isFalse);
    });

    test('filters both views', () {
      final m = TraceModel();
      m.add(f(0x100, [1]));
      m.add(f(0x500, [2]));
      m.setFilter('100');
      expect(m.groupedRows.length, 1);
      expect(m.liveFrames.length, 1);
      m.dispose();
    });
  });

  group('dbc integration', () {
    const dbc = '''
BU_: ECM
BO_ 291 EngineData: 8 ECM
 SG_ EngineSpeed : 0|16@1+ (0.25,0) [0|16383] "rpm" ECM
''';

    test('lookup resolves a message for a traced id', () {
      final m = TraceModel()..loadDbc(0, parseDbc(dbc), 'test.dbc');
      expect(m.messageFor(0, 291, false)!.name, 'EngineData');
      expect(m.messageFor(0, 292, false), isNull);
      m.dispose();
    });
  });

  group('statistics', () {
    test('counts nominal bits per frame type', () {
      expect(TraceModel.frameBits(f(0x1, [])), 47);
      expect(TraceModel.frameBits(f(0x1, [1, 2, 3, 4, 5, 6, 7, 8])), 47 + 64);
      expect(TraceModel.frameBits(f(0x1, [], ext: true)), 67);
    });
  });

  group('csv export', () {
    test('writes a header and one row per frame, oldest first', () {
      final m = TraceModel();
      m.add(f(0x123, [0xDE, 0xAD]));
      m.add(f(0x7FF, [], ext: true));
      final lines = m.toCsv().trim().split('\n');
      expect(lines[0], startsWith('timestamp,channel,direction,id'));
      expect(lines.length, 3);
      expect(lines[1], contains('123'));
      expect(lines[1], contains('DEAD'));
      expect(lines[2], contains('true'));
      m.dispose();
    });
  });
}
