import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
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

/// Collects everything a stream says, readable as one string.
class _Rx {
  final buf = StringBuffer();
  _Rx(Stream<List<int>> s) {
    s.listen((d) => buf.write(latin1.decode(d)));
  }
  Future<String> waitFor(String needle) async {
    for (var i = 0; i < 100 && !buf.toString().contains(needle); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    return buf.toString();
  }
}

void main() {
  test('slcanReply forwards frames and acks commands', () {
    final sent = <CanFrame>[];
    expect(slcanReply('S6', sent.add), '\r');
    expect(slcanReply('O', sent.add), '\r');
    expect(slcanReply('V', sent.add), 'V1013\r');
    expect(slcanReply('Z1', sent.add), '\x07');
    expect(slcanReply('t1232AABB', sent.add), 'z\r');
    expect(slcanReply('T18FE6FFE101', sent.add), 'Z\r');
    expect(slcanReply('tzzz', sent.add), '\x07');
    expect(sent.map((f) => f.toString()), ['123 [2] AA BB', 'x18FE6FFE [1] 01']);
    expect(sent.first.direction, FrameDirection.tx);
  });

  test('clients see bus traffic and each other, bus gets client frames', () async {
    final bus = _FakeBus();
    final traced = <CanFrame>[];
    final share = CanShare(bus, onClientSent: traced.add);
    final endpoints = await share.start();
    final port = int.parse(endpoints.first.split(':').last);

    final a = await Socket.connect(InternetAddress.loopbackIPv4, port);
    final b = await Socket.connect(InternetAddress.loopbackIPv4, port);
    final rxA = _Rx(a), rxB = _Rx(b);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    bus.inject(CanFrame(id: 0x100, data: Uint8List.fromList([1])));
    expect(await rxA.waitFor('t100101\r'), contains('t100101\r'));
    expect(await rxB.waitFor('t100101\r'), contains('t100101\r'));

    b.write('S6\rO\rt2000\r');
    expect(await rxB.waitFor('z\r'), endsWith('\r\rz\r'));
    expect(await rxA.waitFor('t2000\r'), contains('t2000\r'));
    expect(rxB.buf.toString(), isNot(contains('t2000')));
    expect(bus.sent.single.id, 0x200);
    expect(traced.single.id, 0x200);

    if (endpoints.length > 1) {
      // Virtual serial port: open it the way a client tool would.
      final cat = await Process.start('cat', [endpoints[1]]);
      final rxTty = _Rx(cat.stdout);
      await Process.run('sh', ['-c', "printf 't3001FF\\r' > ${endpoints[1]}"]);
      expect(await rxA.waitFor('t3001FF\r'), contains('t3001FF\r'));
      expect(bus.sent.last.id, 0x300);
      bus.inject(CanFrame(id: 0x7FF, data: Uint8List(0)));
      expect(await rxTty.waitFor('t7FF0\r'), contains('t7FF0\r'));
      cat.kill();
    }

    a.destroy();
    b.destroy();
    await share.stop();
  });
}
