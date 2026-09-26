import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pantrace/src/can.dart';
import 'package:pantrace/src/log/asc.dart';
import 'package:pantrace/src/log/log.dart';
import 'package:pantrace/src/log/trc.dart';

Uint8List b(List<int> x) => Uint8List.fromList(x);

final t0 = DateTime(2026, 9, 26, 14, 30, 0, 123);

/// One of everything a trace holds: both channels, both id widths, both
/// directions, an empty payload, a remote frame and an error frame.
final sample = <CanFrame>[
  CanFrame(id: 0x123, data: b([1, 2, 3, 4, 5, 6, 7, 8]), timestamp: t0),
  CanFrame(
      id: 0x18FE6FFE,
      extended: true,
      data: b([0xAA]),
      timestamp: t0.add(const Duration(microseconds: 1500)),
      channel: 1,
      direction: FrameDirection.tx),
  CanFrame(id: 0x7FF, rtr: true, data: b([]), timestamp: t0.add(const Duration(milliseconds: 3))),
  CanFrame.error('bus off', timestamp: t0.add(const Duration(milliseconds: 4)), channel: 1),
  CanFrame(id: 0x001, data: b([]), timestamp: t0.add(const Duration(seconds: 2, microseconds: 7))),
];

/// What survives a round trip: everything but the error text, which only
/// CSV keeps, and (for CSV) the RTR flag.
String describe(CanFrame f, {bool keepRtr = true}) => f.isError
    ? 'ch${f.channel} error'
    : 'ch${f.channel} ${f.direction.name} ${f.extended ? 'x' : ''}${f.idHex}'
        '${keepRtr && f.rtr ? ' rtr' : ''}${f.fd ? ' ${f.fdLabel.toLowerCase()}' : ''} [${f.dataHex}]';

void main() {
  group('LogFormat', () {
    test('comes from the file extension', () {
      expect(LogFormat.fromPath('/a/b/trace.BLF'), LogFormat.blf);
      expect(LogFormat.fromPath(r'C:\logs\x.asc'), LogFormat.asc);
      expect(LogFormat.fromPath('x.mdf'), LogFormat.mf4);
      expect(LogFormat.fromPath('x.mf4'), LogFormat.mf4);
      expect(LogFormat.fromPath('candump-2026.log'), LogFormat.candump);
      expect(LogFormat.fromPath('x.trc'), LogFormat.trc);
      expect(LogFormat.fromPath('x.csv'), LogFormat.csv);
      expect(LogFormat.fromPath('x.txt'), isNull);
      expect(LogFormat.fromPath('dir.blf/noext'), isNull);
      expect(LogFormat.allExtensions, containsAll(['blf', 'asc', 'mf4', 'log', 'trc', 'csv']));
    });
  });

  group('round trip', () {
    for (final format in LogFormat.values) {
      test('${format.label} reads back what it wrote', () async {
        final bytes = await encodeLog(format, sample, start: t0);
        final back = decodeLog(format, bytes);
        expect(back.skipped, 0);
        final keepRtr = format != LogFormat.csv;
        expect(back.frames.map((f) => describe(f, keepRtr: keepRtr)),
            sample.map((f) => describe(f, keepRtr: keepRtr)));
        // TRC stamps its start as fractional days, good to ~10 µs.
        final tolerance = format == LogFormat.trc ? 20 : 1;
        for (var i = 0; i < sample.length; i++) {
          expect(
              back.frames[i].timestamp.difference(sample[i].timestamp).inMicroseconds.abs(),
              lessThanOrEqualTo(tolerance),
              reason: 'frame $i timestamp');
        }
      });
    }

    test('an empty trace is still a valid file in every format', () async {
      for (final format in LogFormat.values) {
        final bytes = await encodeLog(format, const []);
        expect(decodeLog(format, bytes).frames, isEmpty, reason: format.label);
      }
    });

    test('BLF spreads a long capture over several compressed containers', () async {
      final many = [
        for (var i = 0; i < 20000; i++)
          CanFrame(
              id: i & 0x7FF,
              data: b([i & 0xFF, i >> 8]),
              timestamp: t0.add(Duration(microseconds: i * 100))),
      ];
      final bytes = await encodeLog(LogFormat.blf, many);
      // 20000 frames of 48 bytes is ~7 containers; compression keeps it small.
      expect(bytes.length, lessThan(20000 * 48 ~/ 2));
      final back = decodeLog(LogFormat.blf, bytes).frames;
      expect(back.length, many.length);
      expect(back.map((f) => f.data[0] | f.data[1] << 8), List.generate(20000, (i) => i));
    });

    test('MF4 keeps a long capture in order', () async {
      final many = [
        for (var i = 0; i < 5000; i++)
          CanFrame(
              id: 0x100 + (i % 3),
              rtr: i % 7 == 0,
              data: i % 7 == 0 ? b([]) : b([i & 0xFF]),
              timestamp: t0.add(Duration(microseconds: i * 250))),
      ];
      final back = decodeLog(LogFormat.mf4, await encodeLog(LogFormat.mf4, many)).frames;
      expect(back.map(describe), many.map(describe));
    });
  });

  group('recording to disk', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('pantrace_log'));
    tearDown(() => dir.deleteSync(recursive: true));

    for (final format in LogFormat.values) {
      test('${format.label} streams and finishes a readable file', () async {
        final path = '${dir.path}/rec.${format.extension}';
        final r = LogRecorder.start(path, start: t0);
        expect(r.format, format);
        for (var i = 0; i < 3000; i++) {
          r.write(CanFrame(
              id: 0x200, data: b([i & 0xFF, i >> 8]), timestamp: t0.add(Duration(milliseconds: i))));
        }
        expect(r.frames, 3000);
        expect(r.bytes, greaterThan(0));
        await r.stop();
        final back = await readLogFile(path);
        expect(back.frames.length, 3000);
        expect(back.frames.last.data, [2999 & 0xFF, 2999 >> 8]);
      });
    }

    test('an extension that names no format records the fallback', () async {
      final r = LogRecorder.start('${dir.path}/rec.dat', format: LogFormat.asc);
      expect(r.format, LogFormat.asc);
      await r.stop();
      expect(File('${dir.path}/rec.dat').readAsStringSync(), startsWith('date '));
    });

    test('an MF4 is flagged unfinished until the recording stops', () async {
      final path = '${dir.path}/rec.mf4';
      final r = LogRecorder.start(path, start: t0);
      r.write(sample.first);
      // What a crash now would leave behind: the header is on disk already.
      final raf = File(path).openSync();
      final head = raf.readSync(8);
      raf.closeSync();
      expect(ascii.decode(head), 'UnFinMF ');
      await r.stop();
      expect(ascii.decode(File(path).readAsBytesSync().sublist(0, 8)), 'MDF     ');
    });

    test('readLogFile refuses an unknown extension', () {
      expect(readLogFile('${dir.path}/x.txt'), throwsA(isA<LogFormatException>()));
    });
  });

  group('files written by other tools (python-can 4.6 / asammdf 8.8)', () {
    // py.* hold 33 frames: 30 alternating between channels, a 29-bit frame, a
    // remote frame on channel 2 and an error frame. python-can defaults to
    // 29-bit ids, so even 0x100 is extended.
    for (final name in ['py.blf', 'py.asc', 'py.log', 'py.mf4', 'py_deflate.mf4', 'py_transposed.mf4']) {
      test(name, () async {
        final log = await readLogFile('test/fixtures/$name');
        expect(log.frames.length, 33);
        final f = log.frames;
        expect(describe(f[0]), 'ch0 tx x00000100 []');
        expect(describe(f[1]), 'ch1 rx x00000101 [01]');
        expect(describe(f[8]), 'ch0 rx x00000108 [08 08 08 08 08 08 08 08]');
        expect(describe(f[30]), 'ch0 rx x1ABCDEF0 [01 02]');
        expect(describe(f[31]), 'ch1 rx x00000055 rtr []');
        expect(f[32].isError, isTrue);
        expect(f[32].timestamp.difference(f[0].timestamp).inMilliseconds, 700);
      });
    }

    test('py.trc (python-can writes no remote or error frames to TRC)', () async {
      final log = await readLogFile('test/fixtures/py.trc');
      expect(log.frames.length, 31);
      expect(describe(log.frames[1]), 'ch1 rx x00000101 [01]');
      expect(describe(log.frames.last), 'ch0 rx x1ABCDEF0 [01 02]');
    });
  });

  group('ASC details', () {
    test('dates read in both 12 h and 24 h spelling', () {
      expect(parseAscDate('date Sat Sep 26 02:30:00.123 pm 2026'),
          DateTime(2026, 9, 26, 14, 30, 0, 123));
      expect(parseAscDate('Begin Triggerblock Sat Sep 26 12:05:01.5 am 2026'),
          DateTime(2026, 9, 26, 0, 5, 1, 500));
      expect(parseAscDate('date Sat Sep 26 14:30:00 2026'), DateTime(2026, 9, 26, 14, 30));
      expect(parseAscDate('date Sa Mär 26 14:30:00 2026'), isNull); // localised
      expect(ascDate(DateTime(2026, 1, 5, 0, 7, 9, 3)), 'Mon Jan 05 12:07:09.003 am 2026');
    });

    test('relative timestamps, decimal base, FD lines and noise', () {
      final text = '''
date Sat Sep 26 14:30:00.000 2026
base dec  timestamps relative
Begin Triggerblock
   0.500000 1  291             Rx   d 2 1 255
   0.250000 2  291             Tx   d 1 16
   0.100000 CANFD   1 Rx 123 1 0 8 8 11 22 33 44 55 66 77 88
   0.100000 1  291             Rx   d 2 1 XYZ
   1.000000 Start of measurement
End TriggerBlock
''';
      final log = decodeLog(LogFormat.asc, b(utf8.encode(text)));
      expect(log.frames.map(describe), [
        'ch0 rx 123 [01 FF]',
        'ch1 tx 123 [10]',
        'ch0 rx 07B fd brs [0B 16 21 2C 37 42 4D 58]', // decimal base applies to FD too
      ]);
      expect(log.frames[1].timestamp, DateTime(2026, 9, 26, 14, 30, 0, 750));
      expect(log.frames[2].timestamp, DateTime(2026, 9, 26, 14, 30, 0, 850));
      expect(log.skipped, 1); // the unreadable payload
    });
  });

  group('TRC details', () {
    test('OLE dates round-trip', () {
      final t = DateTime(2026, 9, 26, 14, 30, 0, 123);
      expect(fromOleDate(oleDate(t)).difference(t).inMicroseconds.abs(), lessThan(5));
      expect(oleDate(DateTime(1899, 12, 31)), 1.0);
    });

    test('version 1.1 files from PCAN-View', () {
      const text = ''';\$FILEVERSION=1.1
;\$STARTTIME=46291.5
;   Message Number
     1)      1841.8  Rx         0123  8  00 11 22 33 44 55 66 77
     2)      1842.0  Tx     18FE6FFE  2  AA BB
     3)      1843.5  Rx         0100  4  RTR
     4)      1844.0  Error      0000  0
     5)      1845.0  Rx         zzzz  2  00 00
''';
      final log = decodeLog(LogFormat.trc, b(utf8.encode(text)));
      expect(log.frames.map(describe), [
        'ch0 rx 123 [00 11 22 33 44 55 66 77]',
        'ch0 tx x18FE6FFE [AA BB]',
        'ch0 rx 100 rtr []',
        'ch0 error',
      ]);
      expect(log.frames.first.timestamp,
          DateTime(2026, 9, 26, 12).add(const Duration(microseconds: 1841800)));
      expect(log.skipped, 1);
    });

    test('version 2.0 default columns and non-CAN rows', () {
      const text = ''';\$FILEVERSION=2.0
;\$STARTTIME=46291.5
      1        10.000 DT     0123 Rx 2  AA BB
      2        11.000 ST          Rx    00 00 00 04
''';
      final log = decodeLog(LogFormat.trc, b(utf8.encode(text)));
      expect(log.frames.map(describe), ['ch0 rx 123 [AA BB]']);
      expect(log.skipped, 1);
    });
  });

  group('candump details', () {
    test('interfaces, FD, dotted payloads and garbage', () {
      const text = '''(1700000000.5) vcan3 123#11.22 T
(1700000000.600000) mybus 7FF#R4
(1700000000.700000) other 100##1AABB
(1700000000.800000) can0 20000004#0000000000000000
(1700000000.900000) can0 123#ABC
not a frame
''';
      final log = decodeLog(LogFormat.candump, b(utf8.encode(text)));
      expect(log.frames.map(describe),
          ['ch3 tx 123 [11 22]', 'ch0 rx 7FF rtr []', 'ch1 rx 100 fd brs [AA BB]', 'ch0 error']);
      expect(log.frames.first.timestamp.microsecondsSinceEpoch, 1700000000500000);
      expect(log.skipped, 1);
    });
  });

  group('CSV details', () {
    test('quoted error text and broken rows', () {
      const text = '''timestamp,channel,direction,id,extended,dlc,data
2026-09-26T14:30:00.000,1,error,,,,"said ""no"", twice"
2026-09-26T14:30:00.100,2,tx,1ABCDEF0,true,1,0g
2026-09-26T14:30:00.100,x,tx,1,false,0,
short,row
''';
      final log = decodeLog(LogFormat.csv, b(utf8.encode(text)));
      expect(log.frames.single.error, 'said "no", twice');
      expect(log.skipped, 3);
    });
  });

  group('broken files', () {
    test('BLF and MF4 without their signature are refused', () {
      expect(() => decodeLog(LogFormat.blf, b(List.filled(200, 0))),
          throwsA(isA<LogFormatException>()));
      expect(() => decodeLog(LogFormat.mf4, b(List.filled(200, 0))),
          throwsA(isA<LogFormatException>()));
    });

    test('MDF 3 is named as unsupported', () {
      final bytes = Uint8List(200)..setAll(0, ascii.encode('MDF     3.30    '));
      ByteData.sublistView(bytes).setUint16(28, 330, Endian.little);
      expect(() => decodeLog(LogFormat.mf4, bytes),
          throwsA(predicate((e) => '$e'.contains('MDF 330'))));
    });

    test('a truncated BLF yields the frames before the cut', () async {
      final bytes = await encodeLog(LogFormat.blf, sample);
      expect(decodeLog(LogFormat.blf, bytes.sublist(0, bytes.length - 10)).frames, isEmpty);
    });

    test('a corrupt BLF container is reported', () async {
      final bytes = await encodeLog(LogFormat.blf, sample);
      bytes.fillRange(144 + 32, 144 + 40, 0xFF); // inside the deflate stream
      expect(() => decodeLog(LogFormat.blf, bytes), throwsA(isA<LogFormatException>()));
    });
  });

  test('big logs decode off the UI isolate with the same result', () async {
    final many = [
      for (var i = 0; i < 30000; i++)
        CanFrame(id: 0x300, data: b([i & 0xFF]), timestamp: t0.add(Duration(microseconds: i))),
    ];
    final bytes = await encodeLog(LogFormat.asc, many);
    expect(bytes.length, greaterThan(256 * 1024));
    final log = await decodeLogAsync(LogFormat.asc, bytes);
    expect(log.frames.length, 30000);
    final small = await decodeLogAsync(LogFormat.asc, await encodeLog(LogFormat.asc, sample));
    expect(small.frames.length, sample.length);
  });
}
