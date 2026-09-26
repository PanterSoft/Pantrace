// CAN FD end to end below the UI: the frame model, every backend's codec and
// open/send/receive path against a fake driver, bus load and the log formats.
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pantrace/src/backends/pcan.dart';
import 'package:pantrace/src/backends/slcan.dart';
import 'package:pantrace/src/backends/socketcan.dart';
import 'package:pantrace/src/backends/vector.dart';
import 'package:pantrace/src/backends/virtual.dart';
import 'package:pantrace/src/can.dart';
import 'package:pantrace/src/dbc.dart';
import 'package:pantrace/src/log/log.dart';
import 'package:pantrace/src/share.dart';
import 'package:pantrace/src/trace.dart';

Uint8List b(List<int> x) => Uint8List.fromList(x);
Uint8List seq(int n, [int from = 0]) => Uint8List.fromList(List.generate(n, (i) => (from + i) & 0xFF));

CanFrame fdFrame(int id, Uint8List data, {bool ext = false, bool brs = true, bool esi = false}) =>
    CanFrame(id: id, data: data, extended: ext, fd: true, brs: brs, esi: esi);

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  group('frame model', () {
    test('DLC codes map to FD lengths and back', () {
      expect(fdLengths.length, 16);
      expect([for (var d = 0; d < 16; d++) dlcToLength(d)],
          [0, 1, 2, 3, 4, 5, 6, 7, 8, 12, 16, 20, 24, 32, 48, 64]);
      expect(dlcToLength(12, fd: false), 8); // classic caps codes 9-15 at 8
      expect(lengthToDlc(8), 8);
      expect(lengthToDlc(9), 9);
      expect(lengthToDlc(33), 14);
      expect(lengthToDlc(64), 15);
      expect(lengthToDlc(100), 15);
      expect(fdPaddedLength(10), 12);
      expect(fdPaddedLength(49), 64);
    });

    test('flags survive withChannel and show in labels', () {
      final f = fdFrame(0x10, seq(12), esi: true).withChannel(1);
      expect((f.fd, f.brs, f.esi, f.channel), (true, true, true, 1));
      expect(f.dlc, 9);
      expect(f.fdLabel, 'FD BRS ESI');
      expect('$f', startsWith('010 [12] FD BRS ESI 00 01'));
      expect(CanFrame(id: 1, data: seq(3)).fdLabel, '');
      expect(CanFrame(id: 1, data: seq(3)).dlc, 3);
      expect(CanFrame.error('x').fd, isFalse);
    });

    test('checkSendable guards modes, lengths and remote frames', () {
      expect(() => checkSendable(fdFrame(1, seq(8)), fdMode: false),
          throwsA(predicate((e) => '$e'.contains('not in CAN FD mode'))));
      expect(() => checkSendable(CanFrame(id: 1, data: seq(12)), fdMode: true),
          throwsA(predicate((e) => '$e'.contains('send it as CAN FD'))));
      expect(() => checkSendable(CanFrame(id: 1, data: b([]), rtr: true, fd: true), fdMode: true),
          throwsA(predicate((e) => '$e'.contains('no remote frames'))));
      expect(() => checkSendable(fdFrame(1, seq(65)), fdMode: true),
          throwsA(predicate((e) => '$e'.contains('at most 64'))));
      checkSendable(fdFrame(1, seq(64)), fdMode: true);
      checkSendable(CanFrame(id: 1, data: seq(8)), fdMode: true); // classic on an FD bus
    });

    test('bit timing hits the rate exactly with an ~80 % sample point', () {
      final t = bitTiming(80000000, 500000, maxTseg1: 63, maxTseg2: 16, maxSjw: 16)!;
      expect(t, (brp: 2, tseg1: 63, tseg2: 16, sjw: 16));
      expect(80000000 ~/ (t.brp * (1 + t.tseg1 + t.tseg2)), 500000);
      final d = bitTiming(80000000, 8000000, maxTseg1: 15, maxTseg2: 4, maxSjw: 4)!;
      expect(d, (brp: 1, tseg1: 7, tseg2: 2, sjw: 2));
      // Long segments are capped at the maximum.
      expect(bitTiming(80000000, 1000000, maxTseg1: 100, maxTseg2: 4, maxSjw: 4),
          (brp: 1, tseg1: 75, tseg2: 4, sjw: 4));
      // 33.333 kbit/s does not divide an 80 MHz clock.
      expect(bitTiming(80000000, 33333, maxTseg1: 256, maxTseg2: 128, maxSjw: 128), isNull);
      // Too fast for the clock.
      expect(bitTiming(80000000, 40000000, maxTseg1: 15, maxTseg2: 4, maxSjw: 4), isNull);
    });
  });

  group('bus load', () {
    test('FD frames count their data phase at the data bitrate with BRS', () {
      final f = fdFrame(0x100, seq(64));
      expect(TraceModel.frameBits(f), 32 + 5 + 512 + 4 + 21);
      expect(TraceModel.fdDataBits(fdFrame(1, seq(10))), 5 + 96 + 4 + 17); // padded to 12
      expect(TraceModel.fdArbitrationBits(fdFrame(1, seq(1), ext: true)), 51);
      final atFour = TraceModel.busBits(f, 500000, 2000000);
      expect(atFour, closeTo(32 + 542 / 4, 0.001));
      // Without BRS, or without a data bitrate, everything is nominal.
      expect(TraceModel.busBits(fdFrame(1, seq(64), brs: false), 500000, 2000000),
          TraceModel.frameBits(f));
      expect(TraceModel.busBits(f, 500000, null), TraceModel.frameBits(f));
    });

    test('the model uses the channel data bitrate', () async {
      final m = TraceModel();
      m.bitrates[0] = 500000;
      m.dataBitrates[0] = 8000000;
      m.add(fdFrame(0x100, seq(64)));
      m.add(fdFrame(0x101, seq(64), brs: false).withChannel(1));
      await Future<void>.delayed(const Duration(milliseconds: 70));
      expect(m.busLoadPercent[0], lessThan(m.busLoadPercent[1]));
      final r = m.groupedRows.first;
      expect((r.fd, r.brs), (true, true));
      m.dispose();
    });
  });

  group('DBC', () {
    test('long messages and VFrameFormat mark FD messages', () {
      final db = parseDbc('''
BO_ 768 Big: 64 ECU
 SG_ First : 0|8@1+ (1,0) [0|255] "" X
BO_ 769 Small: 8 ECU
 SG_ A : 0|8@1+ (1,0) [0|255] "" X
BO_ 770 Classic: 8 ECU
BA_ "VFrameFormat" BO_ 769 14;
BA_ "VFrameFormat" BO_ 770 0;
''');
      expect(db.lookup(768, false)!.fd, isTrue);
      expect(db.lookup(769, false)!.fd, isTrue);
      expect(db.lookup(770, false)!.fd, isFalse);
      expect(db.lookup(768, false)!.signals.single.decode(seq(64, 7)), 7);
    });
  });

  group('SocketCAN', () {
    test('canfd_frame codec', () {
      final raw = encodeCanFdFrame(fdFrame(0x18DAF110, seq(10), ext: true, esi: true));
      expect(raw.length, canFdFrameSize);
      expect(raw[4], 12); // padded to the FD length
      expect(raw[5], canFdFdf | canFdBrs | canFdEsi);
      final back = decodeCanFrame(raw)!;
      expect('$back', 'x18DAF110 [12] FD BRS ESI 00 01 02 03 04 05 06 07 08 09 00 00');
      // A classic frame read through an FD socket is 16 bytes and stays classic.
      expect(decodeCanFrame(encodeCanFrame(CanFrame(id: 1, data: seq(2))))!.fd, isFalse);
    });

    test('an FD open enables FD frames on the socket and sends both sizes', () async {
      final rx = <Uint8List>[];
      final tx = <int>[];
      final opts = <(int, int)>[];
      var setsockoptResult = 0;
      SocketCanBus.ipCommand = '/nonexistent/ip'; // no iproute2: skip link setup
      libc = Libc(
        socket: (d, t, p) => 5,
        bind: (fd, addr, len) => 0,
        ioctl: (fd, req, arg) => 0,
        read: (fd, buf, n) {
          if (rx.isEmpty) return -1;
          final f = rx.removeAt(0);
          buf.asTypedList(n).setAll(0, f);
          return f.length;
        },
        write: (fd, buf, n) {
          tx.add(n);
          return n;
        },
        close: (fd) => 0,
        fcntl: (fd, cmd, arg) => 0,
        setsockopt: (fd, level, name, val, len) {
          opts.add((level, name));
          return setsockoptResult;
        },
      );
      try {
        final bus = SocketCanBus();
        final got = <CanFrame>[];
        bus.frames.listen(got.add);
        await bus.open('can0', 500000, dataBitrate: 2000000);
        expect(opts, [(101, 5)]); // SOL_CAN_RAW, CAN_RAW_FD_FRAMES
        rx.add(encodeCanFdFrame(fdFrame(0x300, seq(64))));
        rx.add(encodeCanFrame(CanFrame(id: 0x100, data: seq(1))));
        await settle();
        expect(got.map((f) => (f.id, f.fd, f.data.length)), [(0x300, true, 64), (0x100, false, 1)]);
        await bus.send(fdFrame(0x10, seq(20)));
        await bus.send(CanFrame(id: 0x11, data: seq(2)));
        expect(tx, [72, 16]);
        await bus.close();

        // A classic channel refuses FD frames; a kernel without FD refuses FD mode.
        final classic = SocketCanBus();
        await classic.open('can0', 500000);
        await expectLater(classic.send(fdFrame(1, seq(8))), throwsA(isA<CanBusException>()));
        await classic.close();
        setsockoptResult = -1;
        await expectLater(SocketCanBus().open('can0', 500000, dataBitrate: 2000000),
            throwsA(predicate((e) => '$e'.contains('does not support CAN FD'))));
      } finally {
        libc = null;
        SocketCanBus.ipCommand = 'ip';
      }
    });
  });

  group('PCAN', () {
    test('TPCANMsgFD codec', () {
      final raw = encodePcanMsgFd(fdFrame(0x1ABCDEF0, seq(48), ext: true, esi: true));
      expect(raw.length, pcanMsgFdSize);
      expect(raw[4], 0x02 | 0x04 | 0x08 | 0x10);
      expect(raw[5], 14);
      final back = decodePcanMsgFd(raw, timestamp: const Duration(microseconds: 9))!;
      expect((back.id, back.extended, back.fd, back.brs, back.esi, back.data.length),
          (0x1ABCDEF0, true, true, true, true, 48));
      expect(back.hwTimestamp, const Duration(microseconds: 9));
      final classic = decodePcanMsgFd(encodePcanMsgFd(CanFrame(id: 5, data: seq(3), rtr: true)))!;
      expect((classic.fd, classic.rtr, classic.data.length), (false, true, 3));
      final status = Uint8List(pcanMsgFdSize)..[4] = 0x80;
      expect(decodePcanMsgFd(status), isNull);
      expect(decodePcanMsgFd(Uint8List(10)), isNull);
    });

    test('bitrate strings', () {
      expect(pcanFdBitrate(500000, 2000000),
          'f_clock_mhz=80, nom_brp=1, nom_tseg1=127, nom_tseg2=32, nom_sjw=32, '
          'data_brp=1, data_tseg1=31, data_tseg2=8, data_sjw=8');
      expect(() => pcanFdBitrate(33333, 2000000), throwsA(isA<CanBusException>()));
    });

    test('an FD channel initialises with InitializeFD and reads / writes FD', () async {
      final rx = <Uint8List>[];
      final tx = <Uint8List>[];
      String? timing;
      pcanDriver = PcanDriver(
        init: (a, b, c, d, e) => 0,
        uninit: (a) => 0,
        read: (a, b, c) => 0x20,
        write: (a, b) => 0,
        getValue: (a, b, c, d) => 0,
        errText: (a, b, c) => 1,
        initFd: (ch, t) {
          timing = t.toDartString();
          return 0;
        },
        readFd: (ch, msg, ts) {
          if (rx.isEmpty) return 0x20;
          msg.asTypedList(pcanMsgFdSize).setAll(0, rx.removeAt(0));
          ts.value = 1234;
          return 0;
        },
        writeFd: (ch, msg) {
          tx.add(Uint8List.fromList(msg.asTypedList(pcanMsgFdSize)));
          return 0;
        },
      );
      try {
        expect(PcanBackend().supportsFd, isTrue);
        final bus = PcanBus();
        final got = <CanFrame>[];
        bus.frames.listen(got.add);
        await bus.open('81', 500000, dataBitrate: 2000000);
        expect(timing, startsWith('f_clock_mhz=80, nom_brp=1'));
        rx.add(encodePcanMsgFd(fdFrame(0x300, seq(64))));
        await settle();
        expect(got.single.data.length, 64);
        expect(got.single.hwTimestamp, const Duration(microseconds: 1234));
        await bus.send(fdFrame(0x301, seq(16)));
        expect(decodePcanMsgFd(tx.single)!.data.length, 16);
        await bus.close();
      } finally {
        pcanDriver = null;
      }
    });

    test('a PCANBasic without FD entry points says so', () async {
      pcanDriver = PcanDriver(
        init: (a, b, c, d, e) => 0,
        uninit: (a) => 0,
        read: (a, b, c) => 0x20,
        write: (a, b) => 0,
        getValue: (a, b, c, d) => 0,
        errText: (a, b, c) => 1,
      );
      try {
        expect(PcanBackend().supportsFd, isFalse);
        await expectLater(PcanBus().open('81', 500000, dataBitrate: 2000000),
            throwsA(predicate((e) => '$e'.contains('no CAN FD support'))));
      } finally {
        pcanDriver = null;
      }
    });
  });

  group('Vector XL', () {
    Uint8List rxEvent(CanFrame f, {int tag = 0x0400, int flags = -1}) {
      final raw = Uint8List(xlCanRxEventSize);
      final bd = ByteData.view(raw.buffer);
      bd.setUint32(0, xlCanRxEventSize, Endian.little);
      bd.setUint16(4, tag, Endian.little);
      bd.setUint16(6, 2, Endian.little);
      bd.setUint64(24, 7000, Endian.little);
      bd.setUint32(32, f.id | (f.extended ? 0x80000000 : 0), Endian.little);
      final fl = flags >= 0 ? flags : (f.fd ? 1 : 0) | (f.brs ? 2 : 0) | (f.esi ? 4 : 0);
      bd.setUint32(36, fl, Endian.little);
      raw[58] = f.fd ? lengthToDlc(f.data.length) : f.data.length;
      raw.setRange(64, 64 + f.data.length, f.data);
      return raw;
    }

    test('rx event, tx event and FD configuration codecs', () {
      final ok = decodeXlCanRxEvent(rxEvent(fdFrame(0x18DAF110, seq(32), ext: true, esi: true)));
      final f = ok.frame!;
      expect((f.id, f.extended, f.fd, f.brs, f.esi, f.data.length, f.channel),
          (0x18DAF110, true, true, true, true, 32, 2));
      expect(f.hwTimestamp, const Duration(microseconds: 7));
      expect(decodeXlCanRxEvent(rxEvent(CanFrame(id: 1, data: seq(3)))).frame!.fd, isFalse);
      expect(decodeXlCanRxEvent(rxEvent(fdFrame(1, seq(8)), flags: 0x200)).isError, isTrue);
      expect(decodeXlCanRxEvent(rxEvent(fdFrame(1, seq(8)), flags: 0x20)).status, contains('overrun'));
      expect(decodeXlCanRxEvent(rxEvent(fdFrame(1, seq(8)), tag: 0x0401)).isError, isTrue);
      expect(decodeXlCanRxEvent(rxEvent(fdFrame(1, seq(8)), tag: 0x0402)).status, 'transmit error');
      expect(decodeXlCanRxEvent(rxEvent(fdFrame(1, seq(8)), tag: 0x0404)).frame, isNull);
      expect(decodeXlCanRxEvent(rxEvent(fdFrame(1, seq(8)), tag: 0x0409)).status, 'chip state change');
      expect(decodeXlCanRxEvent(rxEvent(fdFrame(1, seq(8)), tag: 0x0999)).frame, isNull);
      expect(decodeXlCanRxEvent(Uint8List(10)).frame, isNull);

      final tx = encodeXlCanTxEvent(fdFrame(0x300, seq(20)));
      final bd = ByteData.view(tx.buffer);
      expect((tx.length, bd.getUint16(0, Endian.little), bd.getUint32(12, Endian.little), tx[16]),
          (xlCanTxEventSize, 0x0440, 0x3, 11));
      expect(tx.sublist(24, 44), seq(20));
      expect(ByteData.view(encodeXlCanTxEvent(CanFrame(id: 1, data: b([]), rtr: true)).buffer)
          .getUint32(12, Endian.little), 0x10);

      final conf = ByteData.view(encodeXlCanFdConf(500000, 2000000).buffer);
      expect([for (var i = 0; i < 8; i++) conf.getUint32(4 * i, Endian.little)],
          [500000, 16, 63, 16, 2000000, 4, 15, 4]);
      expect(() => encodeXlCanFdConf(33333, 2000000), throwsA(isA<CanBusException>()));
    });

    test('an FD channel opens with interface v4, configures, receives, transmits', () async {
      final rx = <Uint8List>[];
      final tx = <Uint8List>[];
      final calls = <String>[];
      final err = 'xl error'.toNativeUtf8();
      xlDriver = XlDriver(
        openDriver: () => 0,
        closeDriver: () => 0,
        openPort: (port, name, mask, perm, rxq, ver, bus) {
          calls.add('openPort v$ver');
          port.value = 3;
          return 0;
        },
        setBitrate: (port, mask, br) => 0,
        activate: (port, mask, bus, flags) => 0,
        deactivate: (port, mask) => 0,
        closePort: (port) => 0,
        receive: (port, count, buf) => 10,
        transmit: (port, mask, n, buf) => 0,
        errString: (s) => err,
        canFdSetConfiguration: (port, mask, conf) {
          calls.add('fdconf ${ByteData.view(conf.asTypedList(40).buffer).getUint32(16, Endian.little)}');
          return 0;
        },
        canReceive: (port, ev) {
          if (rx.isEmpty) return 10;
          ev.asTypedList(xlCanRxEventSize).setAll(0, rx.removeAt(0));
          return 0;
        },
        canTransmitEx: (port, mask, n, sent, ev) {
          tx.add(Uint8List.fromList(ev.asTypedList(xlCanTxEventSize)));
          sent.value = 1;
          return 0;
        },
      );
      try {
        expect(VectorBackend().supportsFd, isTrue);
        final bus = VectorBus();
        final got = <CanFrame>[];
        bus.frames.listen(got.add);
        await bus.open('0', 500000, dataBitrate: 2000000);
        expect(calls, ['openPort v4', 'fdconf 2000000']);
        rx.add(rxEvent(fdFrame(0x300, seq(64))));
        await settle();
        expect(got.single.data.length, 64);
        await bus.send(fdFrame(0x301, seq(12), brs: false));
        expect(ByteData.view(tx.single.buffer).getUint32(12, Endian.little), 0x1);
        await bus.close();

        xlDriver = XlDriver(
          openDriver: () => 0,
          closeDriver: () => 0,
          openPort: (port, name, mask, perm, rxq, ver, bus) => 0,
          setBitrate: (port, mask, br) => 0,
          activate: (port, mask, bus, flags) => 0,
          deactivate: (port, mask) => 0,
          closePort: (port) => 0,
          receive: (port, count, buf) => 10,
          transmit: (port, mask, n, buf) => 0,
          errString: (s) => err,
        );
        expect(VectorBackend().supportsFd, isFalse);
        await expectLater(VectorBus().open('0', 500000, dataBitrate: 2000000),
            throwsA(predicate((e) => '$e'.contains('no CAN FD support'))));
      } finally {
        xlDriver = null;
        calloc.free(err);
      }
    });
  });

  group('SLCAN', () {
    test('CANable 2.0 FD frames encode and parse', () {
      expect(encodeSlcan(fdFrame(0x123, seq(10))), 'b1239${'000102030405060708090000'}\r');
      expect(encodeSlcan(fdFrame(0x1, seq(1), brs: false, ext: true)), 'D00000001100\r');
      final f = parseSlcan('b123F${'AB' * 64}')!;
      expect((f.fd, f.brs, f.data.length, f.data.last), (true, true, 64, 0xAB));
      final g = parseSlcan('D18DAF1109${'01' * 12}')!;
      expect((g.fd, g.brs, g.extended, g.data.length), (true, false, true, 12));
      expect(parseSlcan('d1239${'00' * 5}'), isNull); // DLC 9 needs 12 bytes
      expect(parseSlcan('t1239${'00' * 12}'), isNull); // classic DLC stops at 8
    });

    test('the share accepts FD frames from clients', () {
      final sent = <CanFrame>[];
      expect(slcanReply('b1238${'11' * 8}', sent.add), 'z\r');
      expect(slcanReply('D000000019${'22' * 12}', sent.add), 'Z\r');
      expect(slcanReply('d12', sent.add), '\x07');
      expect(sent.map((f) => (f.fd, f.brs, f.data.length, f.direction)),
          [(true, true, 8, FrameDirection.tx), (true, false, 12, FrameDirection.tx)]);
    });

    test('data bitrates outside the firmware table are refused before opening', () async {
      await expectLater(SlcanBus().open('/nonexistent', 500000, dataBitrate: 3000000),
          throwsA(predicate((e) => '$e'.contains('data bitrates 1M, 2M, 4M, 5M, 8M'))));
    });
  });

  group('virtual bus', () {
    test('FD mode generates FD traffic and loops FD frames back, padded', () async {
      final bus = VirtualBus();
      final got = <CanFrame>[];
      bus.frames.listen(got.add);
      await bus.open('demo', 500000, dataBitrate: 2000000);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(got.where((f) => f.fd && f.brs && f.data.length == 64), isNotEmpty);
      expect(got.where((f) => f.fd && !f.brs && f.data.length == 12), isNotEmpty);
      await bus.send(fdFrame(0x7, seq(13)));
      final echo = got.last;
      expect((echo.fd, echo.brs, echo.data.length, echo.direction), (true, true, 16, FrameDirection.tx));
      await bus.close();

      final classic = VirtualBus();
      await classic.open('loopback', 500000);
      await expectLater(classic.send(fdFrame(1, seq(8))), throwsA(isA<CanBusException>()));
      expect(VirtualBackend().supportsFd, isTrue);
    });
  });

  group('log files', () {
    final t0 = DateTime(2026, 9, 26, 14, 30);
    final frames = [
      CanFrame(id: 0x123, data: b([1, 2, 3]), timestamp: t0),
      CanFrame(id: 0x300, fd: true, brs: true, data: seq(64), timestamp: t0.add(const Duration(milliseconds: 1)), channel: 1),
      CanFrame(id: 0x18DAF110, extended: true, fd: true, esi: true, data: seq(12, 0xA0),
          timestamp: t0.add(const Duration(milliseconds: 2)), direction: FrameDirection.tx),
      CanFrame(id: 0x7, fd: true, data: b([]), timestamp: t0.add(const Duration(milliseconds: 3))),
    ];
    String d(CanFrame f) =>
        'ch${f.channel} ${f.direction.name} ${f.extended ? 'x' : ''}${f.idHex} ${f.fdLabel} [${f.dataHex}]';

    for (final format in LogFormat.values) {
      test('${format.label} round-trips FD frames with their flags', () async {
        final back = decodeLog(format, await encodeLog(format, frames, start: t0));
        expect(back.skipped, 0);
        expect(back.frames.map(d), frames.map(d));
      });
    }

    // python-can 4.6 wrote these: a classic frame, a 64-byte BRS frame on
    // channel 2 and a 12-byte ESI frame sent on channel 1. Its BLF writer uses
    // CAN_FD_MESSAGE, its MF4 writer 0-based bus channels.
    for (final name in ['pyfd.blf', 'pyfd.asc', 'pyfd.log', 'pyfd.mf4']) {
      test('reads $name', () async {
        final log = await readLogFile('test/fixtures/$name');
        expect(log.frames.map(d), [
          'ch0 rx 123  [01 02]',
          'ch1 rx 300 FD BRS [${seq(64).map((x) => x.toRadixString(16).toUpperCase().padLeft(2, '0')).join(' ')}]',
          'ch0 tx x18DAF110 FD ESI [00 01 02 03 04 05 06 07 08 09 0A 0B]',
        ]);
      });
    }

    test('TRC follows PEAK: FE is ESI only, BI is BRS and ESI', () {
      // python-can reads FE as BRS + ESI; PEAK's format document does not.
      const text = ''';\$FILEVERSION=2.1
;\$STARTTIME=46291.5
;\$COLUMNS=N,O,T,B,I,d,R,L,D
      1         0.000 FD  1     0100 Rx -  9    00 00 00 00 00 00 00 00 00 00 00 00
      2         0.000 FB  1     0100 Rx -  1    00
      3         0.000 FE  1     0100 Rx -  1    00
      4         0.000 BI  1     0100 Rx -  1    00
      5         0.000 FD  1     0100 Rx -  15   00
''';
      final log = decodeLog(LogFormat.trc, Uint8List.fromList(text.codeUnits));
      expect(log.frames.map((f) => (f.fdLabel, f.data.length)),
          [('FD', 12), ('FD BRS', 1), ('FD ESI', 1), ('FD BRS ESI', 1)]);
      expect(log.skipped, 1); // DLC 15 promises 64 bytes, the line has 1
    });

    test('an ASC CANFD line without the FD flag is a classic frame', () {
      const text = '''date Sat Sep 26 14:30:00.000 2026
base hex  timestamps absolute
   0.100000 CANFD   1 Rx 123 Engine 0 0 2  2 AA BB        0    0        0        0 0 0 0 0
   0.200000 CANFD   1 Rx 123 0 0 0  0        0    0       10        0 0 0 0 0
   0.300000 CANFD   1 Rx 123 1 0 z  2 AA BB
''';
      final log = decodeLog(LogFormat.asc, Uint8List.fromList(text.codeUnits));
      expect(log.frames.map((f) => (f.fd, f.rtr, f.data.length)), [(false, false, 2), (false, true, 0)]);
      expect(log.skipped, 1);
    });
  });
}
