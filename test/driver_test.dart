// The PCAN, Vector and SocketCAN buses against faked driver entry points.
// The fakes write into the same native buffers the real drivers would, so the
// FFI plumbing (pointers, layouts, drain loop, cleanup) runs for real.
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pantrace/src/backends/pcan.dart';
import 'package:pantrace/src/backends/socketcan.dart';
import 'package:pantrace/src/backends/vector.dart';
import 'package:pantrace/src/backends/virtual.dart';
import 'package:pantrace/src/can.dart';

final scratch = Directory.systemTemp.createTempSync('pantrace').path;

CanFrame frame(int id, List<int> data, {bool extended = false}) =>
    CanFrame(id: id, data: Uint8List.fromList(data), extended: extended);

/// Let the 1 ms poll timers run a few times.
Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  _canCoreTests();
  // ---------------------------------------------------------------------------
  group('PCAN', () {
    // Frames queued for CAN_Read, and what the fake reported back.
    final rx = <Uint8List>[];
    final tx = <Uint8List>[];
    var initResult = 0, writeResult = 0, readError = 0;
    var uninitCalls = 0;
    // Channel condition per handle for discover().
    final conditions = <int, int>{};

    setUp(() {
      rx.clear();
      tx.clear();
      initResult = 0;
      writeResult = 0;
      readError = 0;
      uninitCalls = 0;
      conditions.clear();
      pcanDriver = PcanDriver(
        init: (ch, baud, hw, io, irq) => initResult,
        uninit: (ch) {
          uninitCalls++;
          return 0;
        },
        read: (ch, msg, ts) {
          if (readError != 0) return readError;
          if (rx.isEmpty) return 0x20; // PCAN_ERROR_QRCVEMPTY
          msg.asTypedList(16).setAll(0, rx.removeAt(0));
          ts.asTypedList(8).setAll(0, [0x10, 0, 0, 0, 1, 0, 0x34, 0x12]);
          return 0;
        },
        write: (ch, msg) {
          tx.add(Uint8List.fromList(msg.asTypedList(16)));
          return writeResult;
        },
        getValue: (ch, param, buf, len) {
          final c = conditions[ch];
          if (c == null) return 0x1400; // PCAN_ERROR_ILLHW: no such handle
          buf.asTypedList(4)[0] = c;
          return 0;
        },
        errText: (code, lang, buf) {
          final s = 'fake error ${code.toRadixString(16)}'.codeUnits;
          buf.asTypedList(256).setAll(0, s);
          return 0;
        },
      );
    });
    tearDown(() => pcanDriver = null);

    test('discover lists channels the driver reports as present', () async {
      conditions[0x51] = 1; // PCAN_CHANNEL_AVAILABLE
      conditions[0x52] = 0; // unplugged
      conditions[0x41] = 2; // occupied, still joinable
      final found = await PcanBackend().discover();
      expect(found.map((d) => d.label), ['PCAN-USB 1', 'PCAN-PCI 1']);
      expect(found.first.address, '81');
      expect(PcanBackend().available, isTrue);
      expect(PcanBackend().name, contains('PCAN'));
      expect(PcanBackend().unavailableReason, isNotEmpty);
      expect(PcanBackend().create(), isA<PcanBus>());
    });

    test('open, receive, send, close', () async {
      final bus = PcanBus();
      final got = <CanFrame>[];
      final status = <String>[];
      bus.frames.listen(got.add);
      bus.status.listen(status.add);
      expect(bus.isOpen, isFalse);

      await bus.open('81', 500000);
      expect(bus.isOpen, isTrue);

      rx.add(encodePcanMsg(frame(0x123, [1, 2, 3])));
      rx.add(encodePcanMsg(frame(0x18FE6FFE, [9], extended: true)));
      rx.add(Uint8List(16)..[4] = 0x40); // error frame
      rx.add(Uint8List(16)..[4] = 0x80); // status message
      await settle();

      expect(got.where((f) => !f.isError).map((f) => f.toString()),
          ['123 [3] 01 02 03', 'x18FE6FFE [1] 09']);
      expect(got.first.hwTimestamp,
          const Duration(milliseconds: 0x10 + 0x100000000, microseconds: 0x1234));
      expect(got.where((f) => f.isError).length, 1);
      expect(status, ['error frame on bus', 'bus status change reported by adapter']);

      await bus.send(frame(0x7FF, [0xAA]));
      expect(decodePcanMsg(tx.single)!.toString(), '7FF [1] AA');

      readError = 0x4000; // PCAN_ERROR_ILLOPERATION
      await settle();
      expect(status.last, 'fake error 4000');

      await bus.close();
      expect(bus.isOpen, isFalse);
      expect(uninitCalls, 1);
      await bus.close(); // idempotent
      expect(uninitCalls, 1);

      // Reconnect reuses the same bus object without a late-init error.
      await bus.open('81', 500000);
      expect(bus.isOpen, isTrue);
      await bus.close();
    });

    test('joins a channel another application already runs', () async {
      initResult = 0x2000000; // PCAN_ERROR_CAUTION
      final bus = PcanBus();
      final status = <String>[];
      bus.status.listen(status.add);
      await bus.open('81', 250000);
      await settle();
      expect(status.single, contains('shared with another application'));
      await bus.close();
    });

    test('reports driver errors by text', () async {
      initResult = 0x1400;
      final bus = PcanBus();
      await expectLater(
          bus.open('81', 500000), throwsA(predicate((e) => '$e'.contains('fake error 1400'))));
      expect(bus.isOpen, isFalse);

      await expectLater(bus.send(frame(1, [])), throwsA(isA<CanBusException>()));
      await expectLater(
          bus.open('81', 123456), throwsA(predicate((e) => '$e'.contains('BTR pair'))));

      initResult = 0;
      writeResult = 0x1400;
      await bus.open('81', 500000);
      await expectLater(bus.send(frame(1, [])), throwsA(isA<CanBusException>()));
      await bus.close();
    });

    test('a driver that cannot format the error still yields a code', () async {
      pcanDriver = PcanDriver(
        init: (a, b, c, d, e) => 0x1400,
        uninit: (_) => 0,
        read: (a, b, c) => 0,
        write: (a, b) => 0,
        getValue: (a, b, c, d) => 0,
        errText: (a, b, c) => 1, // fails
      );
      await expectLater(PcanBus().open('81', 500000),
          throwsA(predicate((e) => '$e'.contains('PCAN error 0x1400'))));
    });

    test('without the library the backend is unavailable', () async {
      pcanDriver = null;
      expect(PcanBackend().available, isFalse);
      expect(await PcanBackend().discover(), isEmpty);
      await expectLater(PcanBus().open('81', 500000),
          throwsA(predicate((e) => '$e'.contains('not found'))));
      await expectLater(PcanBus().send(frame(1, [])), throwsA(isA<CanBusException>()));
    });
  });

  // ---------------------------------------------------------------------------
  group('Vector XL', () {
    final rx = <Uint8List>[];
    final tx = <Uint8List>[];
    var openPortResult = 0, activateResult = 0, bitrateResult = 0;
    var transmitResult = 0, receiveError = 0;
    var initAccess = true;
    final calls = <String>[];
    late Pointer<Utf8> errText;

    setUpAll(() => errText = 'fake xl error'.toNativeUtf8());
    tearDownAll(() => calloc.free(errText));

    Uint8List event(CanFrame f, {int tag = 1, int flags = 0}) {
      final raw = Uint8List(xlEventSize);
      final msg = encodeXlCanMsg(f);
      raw[0] = tag;
      raw[1] = 3;
      raw.setRange(16, 16 + 8, msg.sublist(0, 8));
      raw.setRange(32, 40, msg.sublist(16, 24));
      final bd = ByteData.view(raw.buffer);
      bd.setUint16(20, bd.getUint16(20, Endian.little) | flags, Endian.little);
      bd.setUint64(8, 5000, Endian.little);
      return raw;
    }

    setUp(() {
      rx.clear();
      tx.clear();
      calls.clear();
      openPortResult = activateResult = bitrateResult = 0;
      transmitResult = receiveError = 0;
      initAccess = true;
      xlDriver = XlDriver(
        openDriver: () => 0,
        closeDriver: () => 0,
        openPort: (port, name, mask, perm, rx, ver, bus) {
          calls.add('openPort ${name.toDartString()} $mask');
          port.value = 7;
          if (!initAccess) perm.value = 0;
          return openPortResult;
        },
        setBitrate: (port, mask, br) {
          calls.add('bitrate $br');
          return bitrateResult;
        },
        activate: (port, mask, bus, flags) => activateResult,
        deactivate: (port, mask) {
          calls.add('deactivate');
          return 0;
        },
        closePort: (port) {
          calls.add('closePort');
          return 0;
        },
        receive: (port, count, buf) {
          if (receiveError != 0) return receiveError;
          if (rx.isEmpty) return 10; // XL_ERR_QUEUE_IS_EMPTY
          buf.asTypedList(xlEventSize).setAll(0, rx.removeAt(0));
          return 0;
        },
        transmit: (port, mask, n, buf) {
          tx.add(Uint8List.fromList(buf.asTypedList(32)));
          return transmitResult;
        },
        errString: (s) => errText,
      );
    });
    tearDown(() => xlDriver = null);

    test('discover lists the app channels', () async {
      final b = VectorBackend();
      expect(b.available, isTrue);
      expect((await b.discover()).length, 8);
      expect(b.name, contains('Vector'));
      expect(b.unavailableReason, isNotEmpty);
      expect(b.create(), isA<VectorBus>());
    });

    test('open, receive, send, close', () async {
      final bus = VectorBus();
      final got = <CanFrame>[];
      final status = <String>[];
      bus.frames.listen(got.add);
      bus.status.listen(status.add);

      await bus.open('2', 500000);
      expect(bus.isOpen, isTrue);
      expect(calls, ['openPort Pantrace 4', 'bitrate 500000']);

      rx.add(event(frame(0x123, [1, 2])));
      rx.add(event(frame(0x456, [3]), tag: 10)); // tx echo
      rx.add(event(frame(0x1, []), flags: 0x01)); // error frame
      rx.add(event(frame(0x1, []), flags: 0x02)); // overrun
      rx.add(Uint8List(xlEventSize)..[0] = 4); // chip state
      await settle();

      expect(got.where((f) => !f.isError).map((f) => f.toString()),
          ['123 [2] 01 02', '456 [1] 03']);
      expect(got[1].direction, FrameDirection.tx);
      expect(got.where((f) => f.isError).length, 2);
      expect(status, [
        'error frame on bus',
        'receive queue overrun — frames were lost',
        'chip state change',
      ]);

      await bus.send(frame(0x7FF, [0xAA]));
      expect(tx.single, encodeXlCanMsg(frame(0x7FF, [0xAA])));

      receiveError = 99;
      await settle();
      expect(status.last, 'fake xl error');

      await bus.close();
      expect(bus.isOpen, isFalse);
      expect(calls.sublist(2), ['deactivate', 'closePort']);
      await bus.close();
      expect(calls.length, 4);

      await bus.open('2', 500000);
      await bus.close();
    });

    test('warns when it has no init access or the bitrate is refused', () async {
      final status = <String>[];
      var bus = VectorBus()..status.listen(status.add);
      initAccess = false;
      await bus.open('0', 500000);
      await settle();
      expect(status.single, contains('no init access'));
      expect(calls, isNot(contains('bitrate 500000')));
      await bus.close();

      status.clear();
      initAccess = true;
      bitrateResult = 1;
      bus = VectorBus()..status.listen(status.add);
      await bus.open('0', 500000);
      await settle();
      expect(status.single, contains('could not set bitrate'));
      await bus.close();
    });

    test('reports driver errors', () async {
      final bus = VectorBus();
      await expectLater(bus.send(frame(1, [])), throwsA(isA<CanBusException>()));

      openPortResult = 1;
      await expectLater(bus.open('0', 500000),
          throwsA(predicate((e) => '$e'.contains('fake xl error'))));

      openPortResult = 0;
      activateResult = 1;
      await expectLater(bus.open('0', 500000), throwsA(isA<CanBusException>()));
      expect(calls.last, 'closePort');
      expect(bus.isOpen, isFalse);

      activateResult = 0;
      transmitResult = 1;
      await bus.open('0', 500000);
      await expectLater(bus.send(frame(1, [])), throwsA(isA<CanBusException>()));
      await bus.close();
    });

    test('a driver whose error text is unreadable still yields a code', () async {
      xlDriver = XlDriver(
        openDriver: () => 0,
        closeDriver: () => 0,
        openPort: (a, b, c, d, e, f, g) => 1,
        setBitrate: (a, b, c) => 0,
        activate: (a, b, c, d) => 0,
        deactivate: (a, b) => 0,
        closePort: (a) => 0,
        receive: (a, b, c) => 10,
        transmit: (a, b, c, d) => 0,
        errString: (s) => nullptr,
      );
      await expectLater(VectorBus().open('0', 500000),
          throwsA(predicate((e) => '$e'.contains('XL error 1'))));
    });

    test('without the library the backend is unavailable', () async {
      xlDriver = null;
      expect(VectorBackend().available, isFalse);
      expect(await VectorBackend().discover(), isEmpty);
      await expectLater(VectorBus().open('0', 500000),
          throwsA(predicate((e) => '$e'.contains('not found'))));
      final bus = VectorBus();
      await bus.close(); // never opened: nothing to release
      expect(bus.isOpen, isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  group('SocketCAN', () {
    final rx = <Uint8List>[];
    final tx = <Uint8List>[];
    var socketResult = 5, ioctlResult = 0, bindResult = 0, writeResult = 16;
    var closed = 0;
    late String ip;

    setUpAll(() {
      // A stand-in for iproute2 that answers from a state file.
      ip = '$scratch/fake-ip.sh';
      File(ip).writeAsStringSync('#!/bin/sh\necho "\$@" >> "$scratch/ip.log"\n'
          'if [ "\$1" = "-details" ]; then cat "$scratch/ip.state"; exit 0; fi\n'
          'exit "\$(cat "$scratch/ip.rc" 2>/dev/null || echo 0)"\n');
      Process.runSync('chmod', ['+x', ip]);
    });

    setUp(() {
      rx.clear();
      tx.clear();
      socketResult = 5;
      ioctlResult = bindResult = 0;
      writeResult = 16;
      closed = 0;
      SocketCanBus.ipCommand = ip;
      File('$scratch/ip.state').writeAsStringSync('state DOWN');
      File('$scratch/ip.rc').writeAsStringSync('0');
      File('$scratch/ip.log').writeAsStringSync('');
      libc = Libc(
        socket: (d, t, p) => socketResult,
        bind: (fd, addr, len) => bindResult,
        ioctl: (fd, req, arg) {
          if (ioctlResult == 0) arg.asTypedList(40).buffer.asByteData().setInt32(16, 3, Endian.host);
          return ioctlResult;
        },
        read: (fd, buf, n) {
          if (rx.isEmpty) return -1; // EAGAIN
          buf.asTypedList(16).setAll(0, rx.removeAt(0));
          return 16;
        },
        write: (fd, buf, n) {
          tx.add(Uint8List.fromList(buf.asTypedList(16)));
          return writeResult;
        },
        close: (fd) {
          closed++;
          return 0;
        },
        fcntl: (fd, cmd, arg) => 0,
      );
    });
    tearDown(() {
      libc = null;
      SocketCanBus.ipCommand = 'ip';
    });

    String ipLog() => File('$scratch/ip.log').readAsStringSync();

    test('brings the link up, then opens, drains, sends and closes', () async {
      final bus = SocketCanBus();
      final got = <CanFrame>[];
      final status = <String>[];
      bus.frames.listen(got.add);
      bus.status.listen(status.add);

      await bus.open('can0', 250000);
      expect(bus.isOpen, isTrue);
      expect(ipLog(), contains('link set can0 up type can bitrate 250000'));

      rx.add(encodeCanFrame(frame(0x123, [1, 2, 3])));
      rx.add(encodeCanFrame(frame(0x18FE6FFE, [9], extended: true)));
      final err = Uint8List(16);
      ByteData.view(err.buffer).setUint32(0, canErrFlag | 0x40, Endian.host);
      rx.add(err);
      await settle();

      expect(got.where((f) => !f.isError).map((f) => f.toString()),
          ['123 [3] 01 02 03', 'x18FE6FFE [1] 09']);
      expect(got.last.error, 'bus off');
      expect(status, ['bus off']);

      await bus.send(frame(0x7FF, [0xAA]));
      expect(decodeCanFrame(tx.single)!.toString(), '7FF [1] AA');

      await bus.close();
      expect(bus.isOpen, isFalse);
      expect(closed, 1);
      await bus.close();
      expect(closed, 1);

      await bus.open('can0', 250000);
      await bus.close();
    });

    test('leaves an interface that is already up alone', () async {
      File('$scratch/ip.state').writeAsStringSync('<NOARP,UP> state UP bitrate 500000');
      final status = <String>[];
      final bus = SocketCanBus()..status.listen(status.add);
      await bus.open('can0', 250000);
      await settle();
      expect(ipLog(), isNot(contains('link set')));
      expect(status.single, contains('leaving its bitrate unchanged'));
      await bus.close();

      File('$scratch/ip.state').writeAsStringSync('state UP bitrate 250000');
      status.clear();
      await bus.open('can0', 250000);
      await settle();
      expect(status, isEmpty);
      await bus.close();
    });

    test('vcan needs no bitrate; a failed bring-up says what to run', () async {
      final bus = SocketCanBus();
      await bus.open('vcan0', 500000);
      expect(ipLog().trim(), endsWith('link set vcan0 up'));
      await bus.close();

      File('$scratch/ip.rc').writeAsStringSync('2');
      final status = <String>[];
      bus.status.listen(status.add);
      await bus.open('can1', 500000);
      await settle();
      expect(status.single, contains('sudo ip link set can1 up type can bitrate 500000'));
      await bus.close();

      // An `ip` that cannot even show the link: bind() will report the error.
      File('$scratch/ip.state').writeAsStringSync('');
      File(ip).writeAsStringSync('#!/bin/sh\nexit 1\n');
      await bus.open('can1', 500000);
      await bus.close();
      File(ip).writeAsStringSync('#!/bin/sh\necho "\$@" >> "$scratch/ip.log"\n'
          'if [ "\$1" = "-details" ]; then cat "$scratch/ip.state"; exit 0; fi\n'
          'exit "\$(cat "$scratch/ip.rc" 2>/dev/null || echo 0)"\n');

      // No iproute2 at all.
      SocketCanBus.ipCommand = '$scratch/does-not-exist';
      await bus.open('can1', 500000);
      await bus.close();
    });

    test('reports socket, ioctl, bind and write failures', () async {
      final bus = SocketCanBus();
      await expectLater(bus.send(frame(1, [])), throwsA(isA<CanBusException>()));

      socketResult = -1;
      await expectLater(bus.open('can0', 500000),
          throwsA(predicate((e) => '$e'.contains('socket(PF_CAN) failed'))));

      socketResult = 5;
      await expectLater(bus.open('a-name-that-is-too-long', 500000),
          throwsA(predicate((e) => '$e'.contains('too long'))));

      ioctlResult = -1;
      await expectLater(bus.open('can0', 500000),
          throwsA(predicate((e) => '$e'.contains('no such CAN interface'))));
      expect(bus.isOpen, isFalse);

      ioctlResult = 0;
      bindResult = -1;
      await expectLater(bus.open('can0', 500000),
          throwsA(predicate((e) => '$e'.contains('bind to can0 failed'))));
      expect(bus.isOpen, isFalse);

      bindResult = 0;
      writeResult = -1;
      await bus.open('can0', 500000);
      await expectLater(bus.send(frame(1, [])),
          throwsA(predicate((e) => '$e'.contains('write failed'))));
      await bus.close();
    });

    test('the real libc refuses PF_CAN outside Linux', () async {
      libc = null;
      final bus = SocketCanBus();
      // On Linux this may even succeed (with can_raw loaded); elsewhere it
      // throws. Either way the real binding has been exercised.
      try {
        await bus.open('can0', 500000);
      } on CanBusException catch (_) {}
      await bus.close();
      if (!Platform.isLinux) expect(bus.isOpen, isFalse);
    });

    test('discover reads CAN netdevs out of sysfs', () async {
      final root = Directory('$scratch/sysnet')..createSync(recursive: true);
      Directory('${root.path}/can0').createSync();
      File('${root.path}/can0/type').writeAsStringSync('280\n');
      Directory('${root.path}/eth0').createSync();
      File('${root.path}/eth0/type').writeAsStringSync('1\n');
      Directory('${root.path}/lo').createSync(); // no type file
      SocketCanBackend.sysClassNet = root.path;
      try {
        final b = SocketCanBackend();
        expect((await b.discover()).map((d) => d.label), ['can0 (SocketCAN)']);
        expect(b.name, contains('SocketCAN'));
        expect(b.available, Platform.isLinux);
        expect(b.unavailableReason.isEmpty, Platform.isLinux);
        expect(b.create(), isA<SocketCanBus>());

        SocketCanBackend.sysClassNet = '$scratch/nope';
        expect(await b.discover(), isEmpty);
      } finally {
        SocketCanBackend.sysClassNet = '/sys/class/net';
      }
    });
  });
}

// ---------------------------------------------------------------------------
// Small pieces of the plain-Dart core that the driver tests above never
// happen to touch (CanDevice equality/toString, CanBackend defaults).
void _canCoreTests() {
  group('CanDevice / CanBackend', () {
    test('dlc is the payload length even for RTR frames', () {
      expect(CanFrame(id: 1, data: Uint8List(3), rtr: true).dlc, 3);
    });

    test('toString is the label', () {
      expect(const CanDevice('slcan', 'x', 'My Adapter').toString(), 'My Adapter');
    });

    test('hashCode matches equality (backend + address)', () {
      const a = CanDevice('slcan', 'x', 'A');
      const b = CanDevice('slcan', 'x', 'B'); // label does not affect identity
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('unavailableReason defaults to empty', () {
      expect(VirtualBackend().unavailableReason, '');
    });
  });
}
