import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pantrace/src/can.dart';
import 'package:pantrace/src/dbc.dart';
import 'package:pantrace/src/signals.dart';
import 'package:pantrace/src/trace.dart';

final db = parseDbc(File('example/demo.dbc').readAsStringSync());
DbcMessage msg(String name) => db.messages.values.firstWhere((m) => m.name == name);
DbcSignal sig(DbcMessage m, String name) => m.signals.firstWhere((s) => s.name == name);

final t0 = DateTime(2026, 9, 26, 12);
CanFrame at(int ms, int id, List<int> data, {int ch = 0}) => CanFrame(
    id: id, data: Uint8List.fromList(data), timestamp: t0.add(Duration(milliseconds: ms)), channel: ch);

/// EngineData with EngineSpeed = rpm (0.25 rpm/bit, little endian).
CanFrame engine(int ms, double rpm, {int ch = 0}) {
  final raw = (rpm / 0.25).round();
  return at(ms, 0x123, [raw & 0xFF, raw >> 8, 0, 0, 0, 0, 0, 0], ch: ch);
}

int us(int ms) => t0.add(Duration(milliseconds: ms)).microsecondsSinceEpoch;

void main() {
  group('SignalPlot', () {
    test('samples plotted signals from matching frames only', () {
      final plot = SignalPlot();
      final m = msg('EngineData');
      final s = plot.add(0, m, sig(m, 'EngineSpeed'))!;
      expect(s.label, '1: EngineData.EngineSpeed');
      expect((s.unit, s.stepped), ('rpm', false));
      plot.feed(engine(0, 800), m);
      plot.feed(engine(10, 1200), m);
      plot.feed(engine(20, 9999, ch: 1), m); // other bus
      plot.feed(at(30, 0x100, [1, 0]), msg('GearStatus')); // other message
      plot.feed(engine(40, 1), null); // no DBC match
      expect([for (var i = 0; i < s.length; i++) s.valueAt(i)], [800, 1200]);
      expect((s.firstTime, s.lastTime), (us(0), us(10)));
    });

    test('colour slots stay with their signal; eight at most', () {
      final plot = SignalPlot();
      final m = msg('EngineData');
      final a = plot.add(0, m, sig(m, 'EngineSpeed'))!;
      final b = plot.add(0, m, sig(m, 'CoolantTemp'))!;
      final c = plot.add(1, m, sig(m, 'EngineSpeed'))!;
      expect([a.slot, b.slot, c.slot], [0, 1, 2]);
      expect(plot.add(0, m, sig(m, 'EngineSpeed')), isNull); // already plotted
      plot.remove(b.key);
      expect(c.slot, 2); // not repainted
      expect(plot.add(0, m, sig(m, 'ThrottlePos'))!.slot, 1); // reuses the gap
      final g = msg('GearStatus');
      final extra = [
        for (var ch = 0; ch < 2; ch++) plot.add(ch, g, sig(g, 'GearState')),
        plot.add(1, m, sig(m, 'CoolantTemp')),
        plot.add(1, m, sig(m, 'ThrottlePos')),
      ];
      expect(extra.every((s) => s != null), isTrue);
      final j = msg('J1939Heartbeat');
      expect(plot.add(0, j, sig(j, 'Counter')), isNotNull);
      expect(plot.full, isTrue);
      expect(plot.add(1, j, sig(j, 'Counter')), isNull);
      plot.removeChannel(1);
      expect(plot.series.map((s) => s.key.channel).toSet(), {0});
      plot.dispose();
    });

    test('multiplexed signals are only sampled on their page', () {
      final plot = SignalPlot();
      final m = msg('SensorMux');
      final p = plot.add(0, m, sig(m, 'ManifoldPressure'))!;
      final v = plot.add(0, m, sig(m, 'BatteryVoltage'))!;
      plot.feed(at(0, 0x200, [0, 100, 0, 0, 0, 0, 0, 0]), m); // page 0
      plot.feed(at(1, 0x200, [1, 10, 0, 0, 0, 0, 0, 0]), m); // page 1
      expect((p.length, v.length), (1, 1));
      expect(p.lastValue, 100);
      expect(v.lastValue, 10 * 2 + 100);
    });

    test('enumerations plot as steps and format with their names', () {
      final plot = SignalPlot();
      final g = msg('GearStatus');
      final s = plot.add(0, g, sig(g, 'GearState'))!;
      expect(s.stepped, isTrue);
      expect(s.format(3), 'Drive');
      expect(s.format(9), '9');
      final e = msg('EngineData');
      expect(plot.add(0, e, sig(e, 'EngineSpeed'))!.format(812.5), '812.5 rpm');
    });

    test('lookup: held value, nearest sample, range, out-of-order inserts', () {
      final plot = SignalPlot();
      final m = msg('EngineData');
      final s = plot.add(0, m, sig(m, 'EngineSpeed'))!;
      expect((s.nearest(0), s.heldAt(0), s.range(0, 1)), (null, null, null));
      for (final (ms, rpm) in [(0, 100.0), (20, 300.0), (10, 200.0), (30, 50.0)]) {
        plot.feed(engine(ms, rpm), m);
      }
      expect([for (var i = 0; i < s.length; i++) s.timeAt(i)], [us(0), us(10), us(20), us(30)]);
      expect(s.heldAt(us(15)), 200); // holds until the next frame
      expect(s.heldAt(us(0) - 1), isNull);
      expect(s.nearest(us(14)), 1);
      expect(s.nearest(us(16)), 2);
      expect(s.nearest(us(99)), 3);
      expect(s.nearest(us(-5)), 0);
      expect(s.range(us(5), us(25)), (200, 300));
      expect(s.range(us(31), us(40)), isNull);
      plot.clearData();
      expect(s.isEmpty, isTrue);
    });

    test('a long capture keeps its newest samples within the cap', () {
      final plot = SignalPlot();
      final m = msg('EngineData');
      final s = plot.add(0, m, sig(m, 'EngineSpeed'))!;
      for (var i = 0; i < SignalSeries.capacity + 10; i++) {
        s.add(i, i.toDouble());
      }
      expect(s.length, SignalSeries.capacity ~/ 2 + 10);
      expect(s.lastValue, SignalSeries.capacity + 9);
    });
  });

  group('decimate', () {
    SignalSeries series(int n) {
      final m = msg('EngineData');
      final s = SignalSeries(const SignalKey(0, 0x123, false, 'EngineSpeed'), m.name, sig(m, 'EngineSpeed'), 0);
      for (var i = 0; i < n; i++) {
        s.add(i * 10, (i % 100 == 50) ? 1000 : (i % 7).toDouble());
      }
      return s;
    }

    test('sparse data passes through, with one point either side of the window', () {
      final s = series(20);
      final pts = decimate(s, 55, 125, 800);
      expect(pts.first.$1, 50);
      expect(pts.last.$1, 130);
      expect(decimate(s, 10, 10, 100), isEmpty);
      expect(decimate(s, 0, 100, 0), isEmpty);
    });

    test('dense data shrinks to two points per column and keeps the peaks', () {
      final s = series(100000);
      final pts = decimate(s, 0, 999990, 200);
      expect(pts.length, lessThanOrEqualTo(2 * 202));
      // 1000 spikes over 200 columns: no column loses its peak, however many
      // samples share the pixel.
      expect(pts.where((p) => p.$2 == 1000).length, 200);
      for (var i = 1; i < pts.length; i++) {
        expect(pts[i].$1, greaterThanOrEqualTo(pts[i - 1].$1));
      }
    });
  });

  group('niceTicks', () {
    test('round steps covering the range', () {
      expect(niceTicks(0, 100), [0, 20, 40, 60, 80, 100]);
      expect(niceTicks(-0.3, 0.3, count: 3), [-0.2, 0, 0.2]);
      expect(niceTicks(812, 3790, count: 3), [1000, 2000, 3000]);
      expect(niceTicks(0.1, 0.35), [0.1, 0.15, 0.2, 0.25, 0.3, 0.35]);
      expect(niceTicks(5, 5), [5]);
      expect(niceTicks(double.nan, 1), isEmpty);
    });

    test('number formatting drops float noise', () {
      expect(formatNumber(3), '3');
      expect(formatNumber(0.1 + 0.2), '0.3');
      expect(formatNumber(-12.5), '-12.5');
    });
  });

  group('TraceModel', () {
    test('plotting fills from the buffer, then samples live frames', () {
      final model = TraceModel();
      model.loadDbc(0, db, 'demo.dbc');
      model.add(engine(0, 800));
      model.add(engine(10, 900));
      final m = msg('EngineData');
      expect(model.plotSignal(0, m, sig(m, 'EngineSpeed')), isTrue);
      expect(model.plotSignal(0, m, sig(m, 'EngineSpeed')), isFalse);
      final s = model.plot.series.single;
      expect(s.length, 2);
      model.add(engine(20, 1000));
      expect(s.lastValue, 1000);
      model.clear();
      expect((s.isEmpty, model.plot.series.length), (true, 1));

      // Offline logs plot too.
      model.addOffline([engine(0, 42)]);
      expect(s.lastValue, 42);

      // A new or unloaded DBC drops that channel's signals.
      model.loadDbc(0, db, 'again.dbc');
      expect(model.plot.series, isEmpty);
      model.plotSignal(0, m, sig(m, 'EngineSpeed'));
      model.clearDbc(0);
      expect(model.plot.series, isEmpty);
      model.dispose();
    });
  });
}
