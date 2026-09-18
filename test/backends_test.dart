import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:pantrace/src/can.dart';
import 'package:pantrace/src/backends/slcan.dart';
import 'package:pantrace/src/backends/socketcan.dart';
import 'package:pantrace/src/backends/pcan.dart';
import 'package:pantrace/src/backends/vector.dart';
import 'package:pantrace/src/backends/virtual.dart';

Uint8List b(List<int> x) => Uint8List.fromList(x);

void main() {
  slcanDetectionTests();
  group('SLCAN protocol', () {
    test('encodes a standard frame', () {
      final f = CanFrame(id: 0x123, data: b([0xDE, 0xAD, 0xBE, 0xEF]));
      expect(encodeSlcan(f), 't1234DEADBEEF\r');
    });

    test('encodes an extended frame', () {
      final f = CanFrame(id: 0x18FF1234, data: b([0x01]), extended: true);
      expect(encodeSlcan(f), 'T18FF1234101\r');
    });

    test('encodes an RTR frame with no payload', () {
      final f = CanFrame(id: 0x7FF, data: b([]), rtr: true);
      expect(encodeSlcan(f), 'r7FF0\r');
    });

    test('pads short ids to the full width', () {
      expect(encodeSlcan(CanFrame(id: 0x1, data: b([]))), 't0010\r');
    });

    test('parses a standard frame', () {
      final f = parseSlcan('t1234DEADBEEF')!;
      expect(f.id, 0x123);
      expect(f.extended, isFalse);
      expect(f.data, b([0xDE, 0xAD, 0xBE, 0xEF]));
    });

    test('parses an extended frame', () {
      final f = parseSlcan('T18FF1234201AB')!;
      expect(f.id, 0x18FF1234);
      expect(f.extended, isTrue);
      expect(f.data, b([0x01, 0xAB]));
    });

    test('parses an RTR frame', () {
      final f = parseSlcan('r1238')!;
      expect(f.rtr, isTrue);
      expect(f.id, 0x123);
      expect(f.data, isEmpty);
    });

    test('parses the optional timestamp suffix', () {
      final f = parseSlcan('t12310401F4', timestamps: true)!;
      expect(f.data, b([0x04]));
      expect(f.hwTimestamp, const Duration(milliseconds: 0x01F4));
    });

    test('ignores non-frame replies', () {
      for (final line in ['', 'V1013', 'N1234', 'Z', '\x07', 'garbage']) {
        expect(parseSlcan(line), isNull, reason: line);
      }
    });

    test('rejects a truncated payload instead of inventing bytes', () {
      expect(parseSlcan('t1238DEAD'), isNull);
    });

    test('rejects a bad DLC', () {
      expect(parseSlcan('t123F'), isNull);
    });

    test('round-trips every payload length', () {
      for (var len = 0; len <= 8; len++) {
        final data = b(List.generate(len, (i) => i * 17 & 0xFF));
        final f = CanFrame(id: 0x7AB, data: data);
        final line = encodeSlcan(f).replaceAll('\r', '');
        final back = parseSlcan(line)!;
        expect(back.id, 0x7AB);
        expect(back.data, data, reason: 'len $len');
      }
    });

    test('splits a stream into lines and keeps the partial tail', () {
      var (lines, rest) = splitSlcanLines('t1231AA\rt1231BB\rt12');
      expect(lines, ['t1231AA', 't1231BB']);
      expect(rest, 't12');

      (lines, rest) = splitSlcanLines('${rest}31CC\r');
      expect(lines, ['t1231CC']);
      expect(rest, '');
    });

    test('bitrate table covers the standard set', () {
      expect(slcanBitrateCodes[500000], 'S6');
      expect(slcanBitrateCodes[1000000], 'S8');
      expect(slcanBitrateCodes[250000], 'S5');
    });
  });

  group('SocketCAN struct can_frame', () {
    test('encodes a standard frame', () {
      final raw = encodeCanFrame(CanFrame(id: 0x123, data: b([1, 2, 3])));
      expect(raw.length, canFrameSize);
      expect(raw[4], 3);
      expect(raw.sublist(8, 11), b([1, 2, 3]));
    });

    test('sets the EFF flag for extended ids', () {
      final raw = encodeCanFrame(
          CanFrame(id: 0x18FF1234, data: b([]), extended: true));
      final id = ByteData.view(raw.buffer).getUint32(0, Endian.host);
      expect(id & canEffFlag, canEffFlag);
      expect(id & 0x1FFFFFFF, 0x18FF1234);
    });

    test('sets the RTR flag', () {
      final raw = encodeCanFrame(CanFrame(id: 0x100, data: b([]), rtr: true));
      final id = ByteData.view(raw.buffer).getUint32(0, Endian.host);
      expect(id & canRtrFlag, canRtrFlag);
    });

    test('round-trips through decode', () {
      for (final orig in [
        CanFrame(id: 0x7FF, data: b([0xAA, 0xBB])),
        CanFrame(id: 0x1FFFFFFF, data: b([1, 2, 3, 4, 5, 6, 7, 8]), extended: true),
        CanFrame(id: 0x001, data: b([]), rtr: true),
      ]) {
        final back = decodeCanFrame(encodeCanFrame(orig))!;
        expect(back.id, orig.id);
        expect(back.extended, orig.extended);
        expect(back.rtr, orig.rtr);
        expect(back.data, orig.data);
      }
    });

    test('error frames decode to null, not to a bogus frame', () {
      final raw = Uint8List(canFrameSize);
      ByteData.view(raw.buffer).setUint32(0, canErrFlag | 0x40, Endian.host);
      expect(decodeCanFrame(raw), isNull);
      expect(describeErrorFrame(raw), contains('bus off'));
    });

    test('describes multiple error causes', () {
      final raw = Uint8List(canFrameSize);
      ByteData.view(raw.buffer)
          .setUint32(0, canErrFlag | 0x020 | 0x080, Endian.host);
      final text = describeErrorFrame(raw);
      expect(text, contains('no ACK'));
      expect(text, contains('bus error'));
    });

    test('clamps an out-of-range dlc from a malformed driver read', () {
      final raw = Uint8List(canFrameSize)..[4] = 200;
      expect(decodeCanFrame(raw)!.data.length, 8);
    });
  });

  group('PCAN TPCANMsg', () {
    test('payload sits at offset 6, struct is 16 bytes', () {
      final raw = encodePcanMsg(CanFrame(id: 0x123, data: b([9, 8, 7])));
      expect(raw.length, pcanMsgSize);
      expect(raw[5], 3);
      expect(raw.sublist(6, 9), b([9, 8, 7]));
    });

    test('marks extended and RTR in MSGTYPE', () {
      final ext = encodePcanMsg(
          CanFrame(id: 0x18FF1234, data: b([]), extended: true));
      expect(ext[4] & 0x02, 0x02);
      final rtr = encodePcanMsg(CanFrame(id: 0x100, data: b([]), rtr: true));
      expect(rtr[4] & 0x01, 0x01);
    });

    test('round-trips', () {
      final orig =
          CanFrame(id: 0x1ABCDEF, data: b([1, 2, 3, 4, 5, 6, 7, 8]), extended: true);
      final back = decodePcanMsg(encodePcanMsg(orig))!;
      expect(back.id, orig.id);
      expect(back.extended, isTrue);
      expect(back.data, orig.data);
    });

    test('status and error frames are not traffic', () {
      final status = Uint8List(pcanMsgSize)..[4] = 0x80;
      expect(decodePcanMsg(status), isNull);
      final err = Uint8List(pcanMsgSize)..[4] = 0x40;
      expect(decodePcanMsg(err), isNull);
    });

    test('decodes the timestamp triplet', () {
      final ts = Uint8List(8);
      ByteData.view(ts.buffer)
        ..setUint32(0, 1500, Endian.little)
        ..setUint16(4, 0, Endian.little)
        ..setUint16(6, 250, Endian.little);
      expect(decodePcanTimestamp(ts),
          const Duration(milliseconds: 1500, microseconds: 250));
    });

    test('channel probe list covers USB, PCI and LAN', () {
      final c = pcanCandidateChannels();
      expect(c[0x51], 'PCAN-USB 1');
      expect(c[0x509], 'PCAN-USB 9');
      expect(c[0x41], 'PCAN-PCI 1');
      expect(c.length, 32);
    });

    test('baud table maps the common rates', () {
      expect(pcanBaudCodes[500000], 0x001C);
      expect(pcanBaudCodes[1000000], 0x0014);
      expect(pcanBaudCodes[125000], 0x031C);
    });
  });

  group('Vector XLevent', () {
    Uint8List event({
      int tag = 1,
      int id = 0x123,
      int flags = 0,
      int dlc = 2,
      int timeNs = 1000000,
      List<int> data = const [0xAA, 0xBB],
      int chan = 0,
    }) {
      final raw = Uint8List(xlEventSize);
      final bd = ByteData.view(raw.buffer);
      raw[0] = tag;
      raw[1] = chan;
      bd.setUint64(8, timeNs, Endian.little);
      bd.setUint32(16, id, Endian.little);
      bd.setUint16(20, flags, Endian.little);
      bd.setUint16(22, dlc, Endian.little);
      raw.setRange(32, 32 + data.length, data);
      return raw;
    }

    test('decodes a received message', () {
      final d = decodeXlEvent(event());
      expect(d.frame!.id, 0x123);
      expect(d.frame!.data, b([0xAA, 0xBB]));
      expect(d.frame!.hwTimestamp, const Duration(milliseconds: 1));
      expect(d.frame!.direction, FrameDirection.rx);
    });

    test('strips the extended id flag', () {
      final d = decodeXlEvent(event(id: 0x80000000 | 0x18FF1234));
      expect(d.frame!.extended, isTrue);
      expect(d.frame!.id, 0x18FF1234);
    });

    test('reports error frames as status, not traffic', () {
      final d = decodeXlEvent(event(flags: 0x01));
      expect(d.frame, isNull);
      expect(d.status, contains('error frame'));
    });

    test('reports a receive overrun so lost frames are visible', () {
      final d = decodeXlEvent(event(flags: 0x02));
      expect(d.status, contains('overrun'));
    });

    test('tags tx-completed events as tx', () {
      expect(decodeXlEvent(event(flags: 0x40)).frame!.direction, FrameDirection.tx);
      expect(decodeXlEvent(event(tag: 10)).frame!.direction, FrameDirection.tx);
    });

    test('carries the channel index through', () {
      expect(decodeXlEvent(event(chan: 3)).frame!.channel, 3);
    });

    test('ignores unrelated event tags', () {
      expect(decodeXlEvent(event(tag: 7)).frame, isNull);
    });

    test('transmit struct places data at offset 16', () {
      final msg = encodeXlCanMsg(CanFrame(id: 0x321, data: b([1, 2, 3])));
      expect(msg.length, 32);
      expect(ByteData.view(msg.buffer).getUint16(6, Endian.little), 3);
      expect(msg.sublist(16, 19), b([1, 2, 3]));
    });

    test('transmit sets the extended flag on the id', () {
      final msg =
          encodeXlCanMsg(CanFrame(id: 0x18FF1234, data: b([]), extended: true));
      expect(ByteData.view(msg.buffer).getUint32(0, Endian.little) & 0x80000000,
          0x80000000);
    });
  });

  group('virtual bus', () {
    test('loopback echoes sent frames as TX', () async {
      final bus = VirtualBus(generateTraffic: false);
      await bus.open('loopback', 500000);
      final got = bus.frames.first;
      await bus.send(CanFrame(id: 0x555, data: b([1, 2])));
      final f = await got;
      expect(f.id, 0x555);
      expect(f.direction, FrameDirection.tx);
      await bus.close();
    });

    test('refuses to send on a closed bus', () async {
      final bus = VirtualBus(generateTraffic: false);
      expect(() => bus.send(CanFrame(id: 1, data: b([]))),
          throwsA(isA<CanBusException>()));
    });

    test('demo mode produces traffic', () async {
      final bus = VirtualBus();
      expect(bus.isOpen, isFalse);
      await bus.open('demo', 500000);
      expect(bus.isOpen, isTrue);
      final frames = await bus.frames.take(5).toList();
      expect(frames.length, 5);
      expect(frames.every((f) => f.data.isNotEmpty), isTrue);
      await bus.close();
      expect(bus.isOpen, isFalse);
    });

    test('backend advertises itself as always available', () {
      final b = VirtualBackend();
      expect(b.name, contains('Virtual'));
      expect(b.available, isTrue);
      expect(b.unavailableReason, isEmpty);
      expect(b.create(), isA<VirtualBus>());
    });
  });
}

void slcanDetectionTests() {
  group('SLCAN detection', () {
    test('names adapters by known USB id', () {
      expect(slcanNameHint(0xAD50, 0x60C4, null, null), 'CANable');
      expect(slcanNameHint(0x04D8, 0x000A, 'Generic CDC', null), 'USBtin');
    });

    test('names adapters by product string', () {
      expect(slcanNameHint(0x0483, 0x5740, 'CANable2 b158aa7 github.com/x', null), 'CANable2');
      expect(slcanNameHint(null, null, null, 'USBtin by fischl'), 'USBtin');
    });

    test('has no opinion about generic bridges', () {
      expect(slcanNameHint(0x0403, 0x6001, 'FT232R USB UART', 'FTDI'), isNull);
      expect(slcanNameHint(0x1A86, 0x7523, 'USB Serial', null), isNull);
    });

    test('skips ports that cannot be CAN adapters', () {
      expect(slcanWorthProbing('/dev/cu.Bluetooth-Incoming-Port', 0), isFalse);
      expect(slcanWorthProbing('/dev/cu.debug-console', 0), isFalse);
      expect(slcanWorthProbing('/dev/rfcomm0', 2), isFalse);
      expect(slcanWorthProbing('/dev/cu.usbmodem1234', 1), isTrue);
      expect(slcanWorthProbing('COM3', 1), isTrue);
      expect(slcanWorthProbing('/dev/ttyUSB0', 1), isTrue);
    });

    test('recognises SLCAN framing even without a version string', () {
      expect(slcanLooksLikeReply('V1013\r'), isTrue);
      expect(slcanLooksLikeReply('16e7497-dirty github.com/canable2.git\r'), isTrue);
      expect(slcanLooksLikeReply('\x07'), isTrue);
      expect(slcanLooksLikeReply('\r'), isTrue);
      expect(slcanLooksLikeReply(''), isFalse);
      expect(slcanLooksLikeReply('OK\r\n'), isFalse); // AT modem
      expect(slcanLooksLikeReply('Hello from Arduino\r\n'), isFalse);
      expect(slcanLooksLikeReply('\$ '), isFalse); // shell on a debug UART
    });

    test('reads the version out of a noisy reply', () {
      expect(slcanVersionFrom('V1013\r'), '1013');
      expect(slcanVersionFrom('\x07\rv0107\r'), '0107');
      expect(slcanVersionFrom('\r'), isNull);
      expect(slcanVersionFrom('hello\r'), isNull);
      expect(slcanVersionFrom('AT+GMR\r\nOK'), isNull);
    });
  });
}
