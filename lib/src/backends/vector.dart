// Vector hardware (VN1610, VN1630, CANcaseXL, VN8900 ...) via the XL Driver
// Library. Windows only — Vector ships vxlapi64.dll with the XL driver.
import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../can.dart';

// ---------------------------------------------------------------------------
// XLevent codec. 8-byte header, 8-byte timestamp, 32-byte tagData union.
// s_xl_can_msg inside tagData: id u32 | flags u16 | dlc u16 | res1 u64 |
// data[8] | res2 u64.
// ---------------------------------------------------------------------------

const xlEventSize = 48;
const _tagReceiveMsg = 1, _tagChipState = 4, _tagTransmitMsg = 10;
const _flagErrorFrame = 0x01, _flagOverrun = 0x02;
const _flagRemoteFrame = 0x10, _flagTxCompleted = 0x40;
const _extMsgId = 0x80000000;

class XlDecoded {
  final CanFrame? frame;
  final String? status;

  /// True when [status] describes a bus error rather than a plain notice —
  /// those also surface as error frames in the trace.
  final bool isError;
  const XlDecoded({this.frame, this.status, this.isError = false});
}

XlDecoded decodeXlEvent(Uint8List raw) {
  if (raw.length < xlEventSize) return const XlDecoded();
  final bd = ByteData.view(raw.buffer, raw.offsetInBytes, xlEventSize);
  final tag = raw[0];
  final chan = raw[1];

  if (tag == _tagChipState) return const XlDecoded(status: 'chip state change');
  if (tag != _tagReceiveMsg && tag != _tagTransmitMsg) return const XlDecoded();

  final timeNs = bd.getUint64(8, Endian.little);
  final rawId = bd.getUint32(16, Endian.little);
  final flags = bd.getUint16(20, Endian.little);
  final dlc = bd.getUint16(22, Endian.little).clamp(0, 8);

  if (flags & _flagErrorFrame != 0) {
    return const XlDecoded(status: 'error frame on bus', isError: true);
  }
  if (flags & _flagOverrun != 0) {
    return const XlDecoded(
        status: 'receive queue overrun — frames were lost', isError: true);
  }

  final extended = rawId & _extMsgId != 0;
  return XlDecoded(
    frame: CanFrame(
      id: rawId & 0x1FFFFFFF,
      data: Uint8List.fromList(raw.sublist(32, 32 + dlc)),
      extended: extended,
      rtr: flags & _flagRemoteFrame != 0,
      hwTimestamp: Duration(microseconds: timeNs ~/ 1000),
      channel: chan,
      direction: (tag == _tagTransmitMsg || flags & _flagTxCompleted != 0)
          ? FrameDirection.tx
          : FrameDirection.rx,
    ),
  );
}

/// Build an s_xl_can_msg for xlCanTransmit (same 32-byte layout, no header).
Uint8List encodeXlCanMsg(CanFrame f) {
  final out = Uint8List(32);
  final bd = ByteData.view(out.buffer);
  var id = f.id;
  if (f.extended) id |= _extMsgId;
  bd.setUint32(0, id, Endian.little);
  bd.setUint16(4, f.rtr ? _flagRemoteFrame : 0, Endian.little);
  final len = f.data.length.clamp(0, 8);
  bd.setUint16(6, len, Endian.little);
  out.setRange(16, 16 + len, f.data);
  return out;
}

// ---------------------------------------------------------------------------
// vxlapi bindings
// ---------------------------------------------------------------------------

const _xlSuccess = 0, _xlErrQueueEmpty = 10;
const _busTypeCan = 0x01, _interfaceVersion = 3, _activateResetClock = 8;

typedef _NoArgC = Int16 Function();
typedef _NoArgD = int Function();
typedef _OpenPortC = Int16 Function(
    Pointer<Int32>, Pointer<Utf8>, Uint64, Pointer<Uint64>, Uint32, Uint32, Uint32);
typedef _OpenPortD = int Function(
    Pointer<Int32>, Pointer<Utf8>, int, Pointer<Uint64>, int, int, int);
typedef _BitrateC = Int16 Function(Int32, Uint64, Uint32);
typedef _BitrateD = int Function(int, int, int);
typedef _ActivateC = Int16 Function(Int32, Uint64, Uint32, Uint32);
typedef _ActivateD = int Function(int, int, int, int);
typedef _DeactivateC = Int16 Function(Int32, Uint64);
typedef _DeactivateD = int Function(int, int);
typedef _ClosePortC = Int16 Function(Int32);
typedef _ClosePortD = int Function(int);
typedef _ReceiveC = Int16 Function(Int32, Pointer<Uint32>, Pointer<Uint8>);
typedef _ReceiveD = int Function(int, Pointer<Uint32>, Pointer<Uint8>);
typedef _TransmitC = Int16 Function(Int32, Uint64, Pointer<Uint32>, Pointer<Uint8>);
typedef _TransmitD = int Function(int, int, Pointer<Uint32>, Pointer<Uint8>);
typedef _ErrStrC = Pointer<Utf8> Function(Int16);
typedef _ErrStrD = Pointer<Utf8> Function(int);

class _Xl {
  final DynamicLibrary lib;
  late final openDriver = lib.lookupFunction<_NoArgC, _NoArgD>('xlOpenDriver');
  late final closeDriver = lib.lookupFunction<_NoArgC, _NoArgD>('xlCloseDriver');
  late final openPort = lib.lookupFunction<_OpenPortC, _OpenPortD>('xlOpenPort');
  late final setBitrate =
      lib.lookupFunction<_BitrateC, _BitrateD>('xlCanSetChannelBitrate');
  late final activate =
      lib.lookupFunction<_ActivateC, _ActivateD>('xlActivateChannel');
  late final deactivate =
      lib.lookupFunction<_DeactivateC, _DeactivateD>('xlDeactivateChannel');
  late final closePort = lib.lookupFunction<_ClosePortC, _ClosePortD>('xlClosePort');
  late final receive = lib.lookupFunction<_ReceiveC, _ReceiveD>('xlReceive');
  late final transmit = lib.lookupFunction<_TransmitC, _TransmitD>('xlCanTransmit');
  late final errString = lib.lookupFunction<_ErrStrC, _ErrStrD>('xlGetErrorString');
  _Xl(this.lib);
}

_Xl? _xl;
bool _xlTried = false;

_Xl? get _x {
  if (_xlTried) return _xl;
  _xlTried = true;
  if (!Platform.isWindows) return null;
  for (final n in ['vxlapi64.dll', 'vxlapi.dll']) {
    try {
      final lib = _Xl(DynamicLibrary.open(n));
      if (lib.openDriver() == _xlSuccess) {
        _xl = lib;
        return _xl;
      }
    } catch (_) {
      // Try the 32-bit name next.
    }
  }
  return null;
}

String _xlError(int status) {
  final x = _x;
  if (x == null) return 'XL error $status';
  try {
    return x.errString(status).toDartString();
  } catch (_) {
    return 'XL error $status';
  }
}

class VectorBus implements CanBus {
  int _port = -1;
  int _mask = 0;
  Timer? _poll;
  final _frames = StreamController<CanFrame>.broadcast();
  final _status = StreamController<String>.broadcast();
  late final Pointer<Uint8> _evBuf;
  late final Pointer<Uint32> _count;

  @override
  Stream<CanFrame> get frames => _frames.stream;
  @override
  Stream<String> get status => _status.stream;
  @override
  bool get isOpen => _port >= 0;

  @override
  Future<void> open(String address, int bitrate) async {
    final x = _x;
    if (x == null) throw CanBusException('Vector XL driver library not found');

    final channelIndex = int.parse(address);
    _mask = 1 << channelIndex;

    final portPtr = calloc<Int32>();
    final permPtr = calloc<Uint64>()..value = _mask;
    final name = 'Pantrace'.toNativeUtf8();
    try {
      final r = x.openPort(
          portPtr, name, _mask, permPtr, 16384, _interfaceVersion, _busTypeCan);
      if (r != _xlSuccess) throw CanBusException(_xlError(r));
      _port = portPtr.value;

      // Without init access the device is already owned by another application
      // (typically CANoe); we can still listen, but not set the bitrate.
      if (permPtr.value & _mask != 0) {
        final br = x.setBitrate(_port, _mask, bitrate);
        if (br != _xlSuccess) {
          _status.add('could not set bitrate: ${_xlError(br)}');
        }
      } else {
        _status.add(
            'no init access on channel $channelIndex — another application owns '
            'it, so the configured bitrate is used');
      }

      final a = x.activate(_port, _mask, _busTypeCan, _activateResetClock);
      if (a != _xlSuccess) {
        x.closePort(_port);
        _port = -1;
        throw CanBusException(_xlError(a));
      }
    } finally {
      calloc.free(portPtr);
      calloc.free(permPtr);
      calloc.free(name);
    }

    _evBuf = calloc<Uint8>(xlEventSize);
    _count = calloc<Uint32>();
    // ponytail: polled drain. xlSetNotification gives an event handle if the
    // 1 ms tick ever becomes the bottleneck.
    _poll = Timer.periodic(const Duration(milliseconds: 1), (_) => _drain());
  }

  void _drain() {
    final x = _x;
    if (x == null || _port < 0) return;
    for (var i = 0; i < 512; i++) {
      _count.value = 1;
      final r = x.receive(_port, _count, _evBuf);
      if (r == _xlErrQueueEmpty) return;
      if (r != _xlSuccess) {
        _status.add(_xlError(r));
        return;
      }
      final decoded =
          decodeXlEvent(Uint8List.fromList(_evBuf.asTypedList(xlEventSize)));
      if (decoded.frame != null) _frames.add(decoded.frame!);
      if (decoded.status != null) {
        _status.add(decoded.status!);
        if (decoded.isError) _frames.add(CanFrame.error(decoded.status!));
      }
    }
  }

  @override
  Future<void> send(CanFrame frame) async {
    final x = _x;
    if (x == null || _port < 0) throw CanBusException('bus is not open');
    final buf = calloc<Uint8>(32);
    final n = calloc<Uint32>()..value = 1;
    try {
      buf.asTypedList(32).setAll(0, encodeXlCanMsg(frame));
      final r = x.transmit(_port, _mask, n, buf);
      if (r != _xlSuccess) throw CanBusException(_xlError(r));
    } finally {
      calloc.free(buf);
      calloc.free(n);
    }
  }

  @override
  Future<void> close() async {
    _poll?.cancel();
    _poll = null;
    final x = _x;
    if (x != null && _port >= 0) {
      x.deactivate(_port, _mask);
      x.closePort(_port);
      calloc.free(_evBuf);
      calloc.free(_count);
    }
    _port = -1;
  }
}

class VectorBackend implements CanBackend {
  @override
  String get id => 'vector';
  @override
  String get name => 'Vector XL (VN1610, CANcaseXL, VN8900 ...)';
  @override
  bool get available => _x != null;
  @override
  String get unavailableReason => Platform.isWindows
      ? 'install the Vector XL Driver Library (vxlapi64.dll)'
      : 'the Vector XL driver is Windows-only';

  /// ponytail: we list the 8 channel slots rather than parsing XLdriverConfig,
  /// which is a large `#pragma pack(1)` struct that changes between driver
  /// versions. Assign the channel in Vector Hardware Config, then pick its
  /// index here. Swap in xlGetDriverConfig if you want real device names.
  @override
  Future<List<CanDevice>> discover() async {
    if (!available) return [];
    return List.generate(
        8, (i) => CanDevice(id, '$i', 'Vector channel ${i + 1} (app channel $i)'));
  }

  @override
  CanBus create() => VectorBus();
}
