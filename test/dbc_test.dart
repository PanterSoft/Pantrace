import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:pantrace/src/dbc.dart';

Uint8List bytes(List<int> b) => Uint8List.fromList(b);

const sampleDbc = '''
VERSION "1.0"

NS_ :
	BA_
	CM_

BS_:

BU_: ECM TCM Dashboard

BO_ 291 EngineData: 8 ECM
 SG_ EngineSpeed : 0|16@1+ (0.25,0) [0|16383.75] "rpm" Dashboard,TCM
 SG_ CoolantTemp : 16|8@1+ (1,-40) [-40|215] "degC" Dashboard
 SG_ ThrottlePos : 24|8@1+ (0.4,0) [0|102] "%" Dashboard
 SG_ TorqueRequest : 32|16@1- (0.1,0) [-3276.8|3276.7] "Nm" TCM

BO_ 1024 BigEndianMsg: 8 TCM
 SG_ GearRatio : 7|16@0+ (0.001,0) [0|65.535] "" ECM
 SG_ SignedBE : 23|12@0- (1,0) [-2048|2047] "" ECM

BO_ 2566811646 ExtendedMsg: 8 ECM
 SG_ ExtSignal : 0|8@1+ (1,0) [0|255] "" Dashboard

BO_ 512 MuxedMsg: 8 Dashboard
 SG_ Selector M : 0|8@1+ (1,0) [0|255] "" ECM
 SG_ SensorA m0 : 8|16@1+ (1,0) [0|65535] "kPa" ECM
 SG_ SensorB m1 : 8|16@1+ (2,100) [100|131170] "mV" ECM

BO_ 256 StatusMsg: 2 ECM
 SG_ GearState : 0|4@1+ (1,0) [0|15] "" Dashboard

VAL_ 256 GearState 0 "Park" 1 "Reverse" 2 "Neutral" 3 "Drive" ;

CM_ BO_ 291 "Primary engine data broadcast";
CM_ SG_ 291 EngineSpeed "Crankshaft speed, 0.25 rpm resolution";
''';

void main() {
  group('parser', () {
    late DbcDatabase db;
    setUpAll(() => db = parseDbc(sampleDbc));

    test('reads nodes', () {
      expect(db.nodes, ['ECM', 'TCM', 'Dashboard']);
    });

    test('reads messages and counts', () {
      expect(db.messageCount, 5);
      expect(db.signalCount, 11);
    });

    test('message header fields', () {
      final m = db.lookup(291, false)!;
      expect(m.name, 'EngineData');
      expect(m.length, 8);
      expect(m.sender, 'ECM');
      expect(m.signals.length, 4);
      expect(m.comment, 'Primary engine data broadcast');
    });

    test('signal attributes', () {
      final s = db.lookup(291, false)!.signals[0];
      expect(s.name, 'EngineSpeed');
      expect(s.startBit, 0);
      expect(s.length, 16);
      expect(s.byteOrder, ByteOrder.intel);
      expect(s.signed, isFalse);
      expect(s.factor, 0.25);
      expect(s.offset, 0);
      expect(s.unit, 'rpm');
      expect(s.receivers, ['Dashboard', 'TCM']);
      expect(s.comment, 'Crankshaft speed, 0.25 rpm resolution');
    });

    test('a comment can wrap across multiple lines', () {
      final db2 = parseDbc('''
BO_ 100 Msg: 1 ECU
 SG_ Sig : 0|8@1+ (1,0) [0|255] "" Dashboard

CM_ BO_ 100 "line one
line two";
''');
      expect(db2.lookup(100, false)!.comment, 'line one\nline two');
    });

    test('extended id strips the DBC flag bit', () {
      // 2566811646 == 0x98FE6FFE, flag bit set -> 0x18FE6FFE extended.
      final m = db.lookup(0x18FE6FFE, true)!;
      expect(m.name, 'ExtendedMsg');
      expect(m.extended, isTrue);
      expect(m.id, 0x18FE6FFE);
    });

    test('value tables attach to the right signal', () {
      final s = db.lookup(256, false)!.signals[0];
      expect(s.valueTable[0], 'Park');
      expect(s.valueTable[3], 'Drive');
    });

    test('rejects malformed message lines', () {
      expect(() => parseDbc('BO_ notanumber Foo: 8 ECM'),
          throwsA(isA<DbcParseException>()));
    });

    test('tolerates unknown sections', () {
      final d = parseDbc('$sampleDbc\nBA_DEF_ SG_ "GenSigStartValue" INT 0 0;\n'
          'BA_ "GenMsgCycleTime" BO_ 291 100;\n');
      expect(d.messageCount, 5);
    });
  });

  group('intel (little endian) extraction', () {
    test('16-bit spanning two bytes', () {
      final s = DbcSignal(
          name: 'x', startBit: 0, length: 16, byteOrder: ByteOrder.intel,
          signed: false, factor: 1, offset: 0, min: 0, max: 0, unit: '',
          receivers: []);
      expect(s.rawFrom(bytes([0x34, 0x12])), 0x1234);
    });

    test('unaligned 12-bit field', () {
      final s = DbcSignal(
          name: 'x', startBit: 4, length: 12, byteOrder: ByteOrder.intel,
          signed: false, factor: 1, offset: 0, min: 0, max: 0, unit: '',
          receivers: []);
      // byte0 = 0xA5 -> upper nibble 0xA; byte1 = 0x3C -> 0x3CA
      expect(s.rawFrom(bytes([0xA5, 0x3C])), 0x3CA);
    });

    test('signed 8-bit two\'s complement', () {
      final s = DbcSignal(
          name: 'x', startBit: 0, length: 8, byteOrder: ByteOrder.intel,
          signed: true, factor: 1, offset: 0, min: 0, max: 0, unit: '',
          receivers: []);
      expect(s.rawFrom(bytes([0xFF])), -1);
      expect(s.rawFrom(bytes([0x80])), -128);
      expect(s.rawFrom(bytes([0x7F])), 127);
    });
  });

  group('motorola (big endian) extraction', () {
    test('byte-aligned 16-bit', () {
      final s = DbcSignal(
          name: 'x', startBit: 7, length: 16, byteOrder: ByteOrder.motorola,
          signed: false, factor: 1, offset: 0, min: 0, max: 0, unit: '',
          receivers: []);
      expect(s.rawFrom(bytes([0x12, 0x34])), 0x1234);
    });

    test('sawtooth crossing a byte boundary', () {
      // startBit 3, length 8: bits 3..0 of byte0 then bits 7..4 of byte1.
      final s = DbcSignal(
          name: 'x', startBit: 3, length: 8, byteOrder: ByteOrder.motorola,
          signed: false, factor: 1, offset: 0, min: 0, max: 0, unit: '',
          receivers: []);
      expect(s.rawFrom(bytes([0x0A, 0xB0])), 0xAB);
    });

    test('signed 12-bit', () {
      final s = DbcSignal(
          name: 'x', startBit: 23, length: 12, byteOrder: ByteOrder.motorola,
          signed: true, factor: 1, offset: 0, min: 0, max: 0, unit: '',
          receivers: []);
      // bits 23..12: byte2 = 0xFF, high nibble of byte3 = 0xF -> 0xFFF -> -1
      expect(s.rawFrom(bytes([0, 0, 0xFF, 0xF0])), -1);
    });

    test('does not read past a short payload', () {
      final s = DbcSignal(
          name: 'x', startBit: 7, length: 16, byteOrder: ByteOrder.motorola,
          signed: false, factor: 1, offset: 0, min: 0, max: 0, unit: '',
          receivers: []);
      expect(() => s.rawFrom(bytes([0x12])), returnsNormally);
    });
  });

  group('scaling and formatting', () {
    late DbcDatabase db;
    setUpAll(() => db = parseDbc(sampleDbc));

    test('factor and offset applied', () {
      final m = db.lookup(291, false)!;
      // EngineSpeed raw 0x1000 = 4096 * 0.25 = 1024 rpm
      // CoolantTemp raw 90 * 1 + (-40) = 50 degC
      final d = bytes([0x00, 0x10, 90, 0, 0, 0, 0, 0]);
      expect(m.signals[0].decode(d), 1024.0);
      expect(m.signals[1].decode(d), 50.0);
    });

    test('signed signal with factor', () {
      final m = db.lookup(291, false)!;
      final d = bytes([0, 0, 0, 0, 0xFF, 0xFF, 0, 0]);
      expect(m.signals[3].decode(d), closeTo(-0.1, 1e-9));
    });

    test('value table names win over numbers', () {
      final m = db.lookup(256, false)!;
      expect(m.signals[0].format(bytes([3, 0])), 'Drive (3)');
      expect(m.signals[0].format(bytes([9, 0])), '9');
    });

    test('unit appended when present', () {
      final m = db.lookup(291, false)!;
      expect(m.signals[1].format(bytes([0, 0, 90, 0, 0, 0, 0, 0])), '50 degC');
    });
  });

  group('multiplexing', () {
    late DbcDatabase db;
    setUpAll(() => db = parseDbc(sampleDbc));

    test('selector recognised', () {
      final m = db.lookup(512, false)!;
      expect(m.multiplexor!.name, 'Selector');
    });

    test('only the active mux page is decoded', () {
      final m = db.lookup(512, false)!;
      final page0 = m.signalsFor(bytes([0, 0x10, 0x20, 0, 0, 0, 0, 0]));
      expect(page0.map((s) => s.name), containsAll(['Selector', 'SensorA']));
      expect(page0.map((s) => s.name), isNot(contains('SensorB')));

      final page1 = m.signalsFor(bytes([1, 0x10, 0x20, 0, 0, 0, 0, 0]));
      expect(page1.map((s) => s.name), containsAll(['Selector', 'SensorB']));
      expect(page1.map((s) => s.name), isNot(contains('SensorA')));
    });

    test('non-multiplexed message returns all signals', () {
      final m = db.lookup(291, false)!;
      expect(m.signalsFor(bytes([0, 0, 0, 0, 0, 0, 0, 0])).length, 4);
    });
  });

  group('encode round-trip', () {
    for (final order in ByteOrder.values) {
      for (final start in [0, 3, 7, 12, 23]) {
        test('${order.name} start=$start survives write then read', () {
          final s = DbcSignal(
              name: 'x',
              startBit: order == ByteOrder.intel ? start : (start | 7),
              length: 10, byteOrder: order, signed: false,
              factor: 1, offset: 0, min: 0, max: 0, unit: '', receivers: []);
          final buf = Uint8List(8);
          s.rawInto(buf, 0x2A5);
          expect(s.rawFrom(buf), 0x2A5);
        });
      }
    }

    test('writing one signal leaves its neighbour intact', () {
      final a = DbcSignal(
          name: 'a', startBit: 0, length: 8, byteOrder: ByteOrder.intel,
          signed: false, factor: 1, offset: 0, min: 0, max: 0, unit: '', receivers: []);
      final b = DbcSignal(
          name: 'b', startBit: 8, length: 8, byteOrder: ByteOrder.intel,
          signed: false, factor: 1, offset: 0, min: 0, max: 0, unit: '', receivers: []);
      final buf = Uint8List(8);
      a.rawInto(buf, 0xAB);
      b.rawInto(buf, 0xCD);
      expect(a.rawFrom(buf), 0xAB);
      expect(b.rawFrom(buf), 0xCD);
    });

    test('physical encode inverts decode', () {
      final s = DbcSignal(
          name: 'x', startBit: 0, length: 16, byteOrder: ByteOrder.intel,
          signed: false, factor: 0.25, offset: -40, min: 0, max: 0, unit: '',
          receivers: []);
      final buf = Uint8List(8);
      s.rawInto(buf, s.encodeRaw(123.5));
      expect(s.decode(buf), closeTo(123.5, 1e-9));
    });
  });
}
