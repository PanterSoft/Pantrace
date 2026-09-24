// SlcanBus against a real serial device: the pseudo-terminal CanShare opens
// speaks SLCAN, so the bus talks to it through libserialport exactly as it
// would to a CANable. Needs LIBSERIALPORT_PATH (see Makefile `test`).
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_libserialport/flutter_libserialport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pantrace/src/backends/slcan.dart';
import 'package:pantrace/src/can.dart';
import 'package:pantrace/src/share.dart';

class _FakeBus implements CanBus {
  final sent = <CanFrame>[];
  final _frames = StreamController<CanFrame>.broadcast();
  void inject(CanFrame f) => _frames.add(f);
  @override
  Stream<CanFrame> get frames => _frames.stream;
  @override
  Stream<String> get status => const Stream.empty();
  @override
  bool get isOpen => true;
  @override
  Future<void> open(String address, int bitrate) async {}
  @override
  Future<void> close() async {}
  @override
  Future<void> send(CanFrame frame) async => sent.add(frame);
}

Future<void> until(bool Function() done) async {
  for (var i = 0; i < 200 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(done(), isTrue, reason: 'timed out');
}

/// Top level so the closure captures the path alone, not the test's share.
Future<(bool, String?)> probeApart(String path) =>
    Isolate.run(() => probeSlcanPort(path));

void main() {
  if (!Platform.isMacOS && !Platform.isLinux) return; // no pty on Windows

  late _FakeBus adapter;
  late CanShare share;
  late String pty;

  setUp(() async {
    adapter = _FakeBus();
    share = CanShare(adapter, onClientSent: (_) {});
    pty = (await share.start()).firstWhere((e) => e.startsWith('/dev/'));
  });
  tearDown(() => share.stop());

  test('probe recognises the adapter and reads its firmware version', () async {
    // The probe blocks; the adapter answers from this isolate, so run it apart.
    expect(await probeApart(pty), (true, '1013'));
    expect(probeSlcanPort('/nonexistent/port'), (false, null));
  });

  test('open, receive, send, close against the adapter', () async {
    final bus = SlcanBus();
    final got = <CanFrame>[];
    final status = <String>[];
    bus.frames.listen(got.add);
    bus.status.listen(status.add);
    expect(bus.isOpen, isFalse);

    await bus.open(pty, 500000);
    expect(bus.isOpen, isTrue);
    // The adapter refuses timestamps (Z1) with a BEL; we carry on without.
    await until(() => status.isNotEmpty);
    expect(status.single, contains('BEL'));

    adapter.inject(CanFrame(id: 0x123, data: Uint8List.fromList([0xAA, 0xBB])));
    adapter.inject(CanFrame(
        id: 0x18FE6FFE, extended: true, data: Uint8List.fromList([1])));
    await until(() => got.length == 2);
    expect(got.map((f) => f.toString()), ['123 [2] AA BB', 'x18FE6FFE [1] 01']);

    await bus.send(CanFrame(id: 0x7AB, data: Uint8List.fromList([1, 2, 3])));
    await until(() => adapter.sent.isNotEmpty);
    expect(adapter.sent.single.toString(), '7AB [3] 01 02 03');

    await bus.close();
    expect(bus.isOpen, isFalse);
    await bus.close(); // idempotent
    await expectLater(bus.send(CanFrame(id: 1, data: Uint8List(0))),
        throwsA(isA<CanBusException>()));
  });

  test('refuses what the protocol cannot express or the OS cannot open', () async {
    final bus = SlcanBus();
    await expectLater(bus.open(pty, 83333),
        throwsA(predicate((e) => '$e'.contains('standard bitrates'))));
    await expectLater(bus.open('/nonexistent/port', 500000),
        throwsA(predicate((e) => '$e'.contains('Cannot open'))));
    expect(bus.isOpen, isFalse);
  });

  test('discover probes the ports and names what answers', () async {
    final backend = SlcanBackend();
    SlcanBackend.listPorts = () => [pty, '/dev/cu.Bluetooth-Incoming-Port'];
    try {
      expect(backend.available, isTrue);
      expect(backend.unavailableReason, isEmpty);
      expect(backend.name, contains('SLCAN'));
      expect(backend.create(), isA<SlcanBus>());

      final found = await backend.discover();
      expect(found.single.address, pty);
      expect(found.single.label, 'SLCAN adapter v1013 — $pty');

      backend.probe = false;
      final all = await backend.discover();
      expect(all.map((d) => d.address), [pty, '/dev/cu.Bluetooth-Incoming-Port']);
      expect(all.first.label, startsWith(pty));
    } finally {
      SlcanBackend.listPorts = () => SerialPort.availablePorts;
    }
  });

  test('a /tmp/slcan* pty is listed, opened past libserialport, and hangs up',
      () async {
    final link = '/tmp/slcan_pantrace_test_$pid';
    Link(link).createSync(pty);
    final status = <String>[];
    final got = <CanFrame>[];
    final bus = SlcanBus();
    try {
      expect(isPtyPath(link), isTrue);
      expect(isPtyPath('/dev/cu.Bluetooth-Incoming-Port'), isFalse);

      bus.frames.listen(got.add);
      bus.status.listen(status.add);
      await bus.open(link, 1000000);
      adapter.inject(CanFrame(id: 0x456, data: Uint8List.fromList([0x33])));
      await until(() => got.isNotEmpty);
      expect(got.single.toString(), '456 [1] 33');

      await share.stop(); // the bridge behind the port quits
      await until(() => !bus.isOpen);
      expect(status.last, contains('closed'));
    } finally {
      Link(link).deleteSync();
      await bus.close();
    }
  });
}
