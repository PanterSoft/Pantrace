// A software bus: loops back everything you send and, optionally, generates
// synthetic traffic. Lets the app be exercised (and tested) without hardware.
import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import '../can.dart';

class VirtualBus implements CanBus {
  final _frames = StreamController<CanFrame>.broadcast();
  final _status = StreamController<String>.broadcast();
  final bool generateTraffic;
  Timer? _gen;
  bool _open = false;
  bool _fd = false;
  var _tick = 0;
  final _rng = Random(42); // fixed seed: reproducible in tests

  VirtualBus({this.generateTraffic = true});

  @override
  Stream<CanFrame> get frames => _frames.stream;
  @override
  Stream<String> get status => _status.stream;
  @override
  bool get isOpen => _open;

  @override
  Future<void> open(String address, int bitrate, {int? dataBitrate}) async {
    _open = true;
    _fd = dataBitrate != null;
    if (address == 'loopback' || !generateTraffic) return;
    _gen = Timer.periodic(const Duration(milliseconds: 10), (_) => _emit());
  }

  /// Mirrors the sample DBC shipped in example/demo.dbc so the decode pane has
  /// something meaningful to show.
  void _emit() {
    _tick++;
    final rpm = (800 + 3000 * (0.5 + 0.5 * sin(_tick / 50))).round();
    final raw = (rpm / 0.25).round();
    _frames.add(CanFrame(
      id: 0x123,
      data: Uint8List.fromList([
        raw & 0xFF, (raw >> 8) & 0xFF,
        (70 + _rng.nextInt(15) + 40), // coolant, offset -40
        (_tick % 250), 0, 0, 0, 0,
      ]),
    ));

    if (_tick % 5 == 0) {
      _frames.add(CanFrame(
        id: 0x100,
        data: Uint8List.fromList([(_tick ~/ 50) % 4, 0]),
      ));
    }
    if (_tick % 10 == 0) {
      _frames.add(CanFrame(
        id: 0x200,
        data: Uint8List.fromList([
          _tick % 2, _rng.nextInt(256), _rng.nextInt(256), 0, 0, 0, 0, 0,
        ]),
      ));
    }
    // In FD mode, a 64-byte BRS frame and a 12-byte one without BRS.
    if (_fd && _tick % 20 == 0) {
      _frames.add(CanFrame(
        id: 0x300,
        fd: true,
        brs: true,
        data: Uint8List.fromList(List.generate(64, (i) => (i + _tick ~/ 20) & 0xFF)),
      ));
    }
    if (_fd && _tick % 50 == 0) {
      _frames.add(CanFrame(
        id: 0x18DAF110,
        extended: true,
        fd: true,
        data: Uint8List.fromList(List.generate(12, (i) => i == 0 ? _tick ~/ 50 : 0)),
      ));
    }
    if (_tick % 100 == 0) {
      _frames.add(CanFrame(
        id: 0x18FE6FFE,
        extended: true,
        data: Uint8List.fromList([_tick ~/ 100, 0, 0, 0, 0, 0, 0, 0]),
      ));
    }
  }

  @override
  Future<void> send(CanFrame frame) async {
    if (!_open) throw CanBusException('bus is not open');
    checkSendable(frame, fdMode: _fd);
    _frames.add(CanFrame(
      id: frame.id,
      data: frame.fd
          ? (Uint8List(fdPaddedLength(frame.data.length))..setAll(0, frame.data))
          : frame.data,
      extended: frame.extended,
      rtr: frame.rtr,
      fd: frame.fd,
      brs: frame.brs,
      direction: FrameDirection.tx,
    ));
  }

  @override
  Future<void> close() async {
    _gen?.cancel();
    _gen = null;
    _open = false;
  }
}

class VirtualBackend implements CanBackend {
  @override
  String get id => 'virtual';
  @override
  String get name => 'Virtual bus (no hardware)';
  @override
  bool get available => true;
  @override
  bool get supportsFd => true;
  @override
  String get unavailableReason => '';

  @override
  Future<List<CanDevice>> discover() async => [
        const CanDevice('virtual', 'demo', 'Demo traffic generator'),
        const CanDevice('virtual', 'loopback', 'Loopback only (echoes TX)'),
      ];

  @override
  CanBus create() => VirtualBus();
}
