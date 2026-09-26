// Vector hardware (VN1610, VN1630, CANcaseXL, VN8900 ...) via the XL Driver
// Library. Windows only — Vector ships vxlapi64.dll with the XL driver.
import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

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
// CAN FD events (XL API v4). XLcanTxEvent: tag u16 | transId u16 | channel u8
// | 3 reserved | XL_CAN_TX_MSG { canId u32 | msgFlags u32 | dlc u8 | 7 reserved
// | data[64] } = 88 bytes. XLcanRxEvent: size u32 | tag u16 | channel u16 |
// userHandle u32 | flagsChip u16 | 2 reserved | 8 reserved | timeStampSync
// u64 | union at 32; the rx message there is canId u32 | msgFlags u32 | crc
// u32 | 12 reserved | totalBitCnt u16 | dlc u8 | 5 reserved | data[64] = 128.
// ---------------------------------------------------------------------------

const xlCanTxEventSize = 88, xlCanRxEventSize = 128, xlCanFdConfSize = 40;
const _tagTxMsg = 0x0440;
const _evRxOk = 0x0400, _evRxError = 0x0401, _evTxError = 0x0402;
const _evTxOk = 0x0404, _evChipState = 0x0409;
const _fdEdl = 0x0001, _fdBrs = 0x0002, _fdEsi = 0x0004, _fdRtr = 0x0010;
const _fdErrorFrame = 0x0200, _fdOverrun = 0x0020;

Uint8List encodeXlCanTxEvent(CanFrame f) {
  final out = Uint8List(xlCanTxEventSize);
  final bd = ByteData.view(out.buffer);
  bd.setUint16(0, _tagTxMsg, Endian.little);
  bd.setUint32(8, f.id | (f.extended ? _extMsgId : 0), Endian.little);
  var flags = f.rtr ? _fdRtr : 0;
  if (f.fd) flags |= _fdEdl | (f.brs ? _fdBrs : 0);
  bd.setUint32(12, flags, Endian.little);
  final n = f.data.length.clamp(0, f.fd ? 64 : 8);
  out[16] = f.fd ? lengthToDlc(n) : n;
  out.setRange(24, 24 + n, f.data);
  return out;
}

XlDecoded decodeXlCanRxEvent(Uint8List raw) {
  if (raw.length < xlCanRxEventSize) return const XlDecoded();
  final bd = ByteData.view(raw.buffer, raw.offsetInBytes, xlCanRxEventSize);
  final tag = bd.getUint16(4, Endian.little);
  final chan = bd.getUint16(6, Endian.little);
  switch (tag) {
    case _evChipState:
      return const XlDecoded(status: 'chip state change');
    case _evRxError:
      return const XlDecoded(status: 'error frame on bus', isError: true);
    case _evTxError:
      return const XlDecoded(status: 'transmit error', isError: true);
    case _evTxOk:
      // Our own transmission confirmed; the page already traced it.
      return const XlDecoded();
    case _evRxOk:
      break;
    default:
      return const XlDecoded();
  }
  final flags = bd.getUint32(36, Endian.little);
  if (flags & _fdErrorFrame != 0) {
    return const XlDecoded(status: 'error frame on bus', isError: true);
  }
  if (flags & _fdOverrun != 0) {
    return const XlDecoded(
        status: 'receive queue overrun — frames were lost', isError: true);
  }
  final fd = flags & _fdEdl != 0;
  final rawId = bd.getUint32(32, Endian.little);
  final len = dlcToLength(raw[58], fd: fd);
  return XlDecoded(
    frame: CanFrame(
      id: rawId & 0x1FFFFFFF,
      extended: rawId & _extMsgId != 0,
      rtr: flags & _fdRtr != 0,
      fd: fd,
      brs: flags & _fdBrs != 0,
      esi: flags & _fdEsi != 0,
      data: Uint8List.fromList(raw.sublist(64, 64 + len)),
      hwTimestamp: Duration(microseconds: bd.getUint64(24, Endian.little) ~/ 1000),
      channel: chan,
    ),
  );
}

/// XLcanFdConf for [bitrate] / [dataBitrate]. Segment lengths are in time
/// quanta of the 80 MHz FD controllers; the driver derives the prescaler.
Uint8List encodeXlCanFdConf(int bitrate, int dataBitrate) {
  const clock = 80000000;
  final a = bitTiming(clock, bitrate, maxTseg1: 63, maxTseg2: 16, maxSjw: 16);
  final d = bitTiming(clock, dataBitrate, maxTseg1: 15, maxTseg2: 4, maxSjw: 4);
  if (a == null || d == null) {
    throw CanBusException('Vector CAN FD cannot run $bitrate / $dataBitrate bit/s');
  }
  final out = Uint8List(xlCanFdConfSize);
  final bd = ByteData.view(out.buffer);
  for (final (i, v) in [bitrate, a.sjw, a.tseg1, a.tseg2, dataBitrate, d.sjw, d.tseg1, d.tseg2].indexed) {
    bd.setUint32(4 * i, v, Endian.little);
  }
  return out;
}

// ---------------------------------------------------------------------------
// vxlapi bindings
// ---------------------------------------------------------------------------

const _xlSuccess = 0, _xlErrQueueEmpty = 10;
const _busTypeCan = 0x01, _interfaceVersion = 3, _activateResetClock = 8;
const _interfaceVersionV4 = 4; // CAN FD event API

typedef _NoArgC = Int16 Function();
typedef XlNoArg = int Function();
typedef _OpenPortC = Int16 Function(
    Pointer<Int32>, Pointer<Utf8>, Uint64, Pointer<Uint64>, Uint32, Uint32, Uint32);
typedef XlOpenPort = int Function(
    Pointer<Int32>, Pointer<Utf8>, int, Pointer<Uint64>, int, int, int);
typedef _BitrateC = Int16 Function(Int32, Uint64, Uint32);
typedef XlBitrate = int Function(int, int, int);
typedef _ActivateC = Int16 Function(Int32, Uint64, Uint32, Uint32);
typedef XlActivate = int Function(int, int, int, int);
typedef _DeactivateC = Int16 Function(Int32, Uint64);
typedef XlDeactivate = int Function(int, int);
typedef _ClosePortC = Int16 Function(Int32);
typedef XlClosePort = int Function(int);
typedef _ReceiveC = Int16 Function(Int32, Pointer<Uint32>, Pointer<Uint8>);
typedef XlReceive = int Function(int, Pointer<Uint32>, Pointer<Uint8>);
typedef _TransmitC = Int16 Function(Int32, Uint64, Pointer<Uint32>, Pointer<Uint8>);
typedef XlTransmit = int Function(int, int, Pointer<Uint32>, Pointer<Uint8>);
typedef _ErrStrC = Pointer<Utf8> Function(Int16);
typedef XlErrStr = Pointer<Utf8> Function(int);
typedef _FdConfC = Int16 Function(Int32, Uint64, Pointer<Uint8>);
typedef XlFdConf = int Function(int, int, Pointer<Uint8>);
typedef _TransmitExC = Int16 Function(Int32, Uint64, Uint32, Pointer<Uint32>, Pointer<Uint8>);
typedef XlTransmitEx = int Function(int, int, int, Pointer<Uint32>, Pointer<Uint8>);
typedef _CanReceiveC = Int16 Function(Int32, Pointer<Uint8>);
typedef XlCanReceive = int Function(int, Pointer<Uint8>);

/// The XL Driver Library entry points as plain Dart functions, so a test can
/// stand in for the driver without hardware.
class XlDriver {
  final XlNoArg openDriver;
  final XlNoArg closeDriver;
  final XlOpenPort openPort;
  final XlBitrate setBitrate;
  final XlActivate activate;
  final XlDeactivate deactivate;
  final XlClosePort closePort;
  final XlReceive receive;
  final XlTransmit transmit;
  final XlErrStr errString;

  /// The CAN FD entry points; null on a driver too old to have them.
  final XlFdConf? canFdSetConfiguration;
  final XlTransmitEx? canTransmitEx;
  final XlCanReceive? canReceive;

  XlDriver({
    this.canFdSetConfiguration,
    this.canTransmitEx,
    this.canReceive,
    required this.openDriver,
    required this.closeDriver,
    required this.openPort,
    required this.setBitrate,
    required this.activate,
    required this.deactivate,
    required this.closePort,
    required this.receive,
    required this.transmit,
    required this.errString,
  });

  XlDriver.fromLibrary(DynamicLibrary lib)
      : openDriver = lib.lookupFunction<_NoArgC, XlNoArg>('xlOpenDriver'),
        closeDriver = lib.lookupFunction<_NoArgC, XlNoArg>('xlCloseDriver'),
        openPort = lib.lookupFunction<_OpenPortC, XlOpenPort>('xlOpenPort'),
        setBitrate =
            lib.lookupFunction<_BitrateC, XlBitrate>('xlCanSetChannelBitrate'),
        activate = lib.lookupFunction<_ActivateC, XlActivate>('xlActivateChannel'),
        deactivate =
            lib.lookupFunction<_DeactivateC, XlDeactivate>('xlDeactivateChannel'),
        closePort = lib.lookupFunction<_ClosePortC, XlClosePort>('xlClosePort'),
        receive = lib.lookupFunction<_ReceiveC, XlReceive>('xlReceive'),
        transmit = lib.lookupFunction<_TransmitC, XlTransmit>('xlCanTransmit'),
        errString = lib.lookupFunction<_ErrStrC, XlErrStr>('xlGetErrorString'),
        // coverage:ignore-start needs the Windows only vxlapi DLL
        canFdSetConfiguration = _optional(() =>
            lib.lookupFunction<_FdConfC, XlFdConf>('xlCanFdSetConfiguration')),
        canTransmitEx = _optional(
            () => lib.lookupFunction<_TransmitExC, XlTransmitEx>('xlCanTransmitEx')),
        canReceive = _optional(
            () => lib.lookupFunction<_CanReceiveC, XlCanReceive>('xlCanReceive'));

  static T? _optional<T>(T Function() lookup) {
    try {
      return lookup();
    } on ArgumentError {
      return null;
    }
  }
  // coverage:ignore-end

  bool get hasFd =>
      canFdSetConfiguration != null && canTransmitEx != null && canReceive != null;
}

XlDriver? _xl;
bool _xlTried = false;

/// Replace (or, with null, remove) the driver. Tests only.
@visibleForTesting
set xlDriver(XlDriver? d) {
  _xl = d;
  _xlTried = true;
}

XlDriver? get _x {
  if (_xlTried) return _xl;
  _xlTried = true;
  if (!Platform.isWindows) return null;
  // coverage:ignore-start needs the Windows only vxlapi DLL
  for (final n in ['vxlapi64.dll', 'vxlapi.dll']) {
    try {
      final lib = XlDriver.fromLibrary(DynamicLibrary.open(n));
      if (lib.openDriver() == _xlSuccess) {
        _xl = lib;
        return _xl;
      }
    } catch (_) {
      // Try the 32-bit name next.
    }
  }
  return null;
  // coverage:ignore-end
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
  bool _canFd = false;
  int _mask = 0;
  Timer? _poll;
  final _frames = StreamController<CanFrame>.broadcast();
  final _status = StreamController<String>.broadcast();
  late Pointer<Uint8> _evBuf;
  late Pointer<Uint32> _count;

  @override
  Stream<CanFrame> get frames => _frames.stream;
  @override
  Stream<String> get status => _status.stream;
  @override
  bool get isOpen => _port >= 0;

  @override
  Future<void> open(String address, int bitrate, {int? dataBitrate}) async {
    final x = _x;
    if (x == null) throw CanBusException('Vector XL driver library not found');
    _canFd = dataBitrate != null;
    if (_canFd && !x.hasFd) {
      throw CanBusException('this XL Driver Library has no CAN FD support — update it');
    }
    final fdConf = _canFd ? encodeXlCanFdConf(bitrate, dataBitrate!) : null;

    final channelIndex = int.parse(address);
    _mask = 1 << channelIndex;

    final portPtr = calloc<Int32>();
    final permPtr = calloc<Uint64>()..value = _mask;
    final name = 'Pantrace'.toNativeUtf8();
    try {
      final r = x.openPort(portPtr, name, _mask, permPtr, 16384,
          _canFd ? _interfaceVersionV4 : _interfaceVersion, _busTypeCan);
      if (r != _xlSuccess) throw CanBusException(_xlError(r));
      _port = portPtr.value;

      // Without init access the device is already owned by another application
      // (typically CANoe); we can still listen, but not set the bitrate.
      if (permPtr.value & _mask != 0) {
        final int br;
        if (fdConf != null) {
          final conf = calloc<Uint8>(xlCanFdConfSize);
          conf.asTypedList(xlCanFdConfSize).setAll(0, fdConf);
          br = x.canFdSetConfiguration!(_port, _mask, conf);
          calloc.free(conf);
        } else {
          br = x.setBitrate(_port, _mask, bitrate);
        }
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

    _evBuf = calloc<Uint8>(xlCanRxEventSize);
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
      final r = _canFd
          ? x.canReceive!(_port, _evBuf)
          : x.receive(_port, _count, _evBuf);
      if (r == _xlErrQueueEmpty) return;
      if (r != _xlSuccess) {
        _status.add(_xlError(r));
        return;
      }
      final decoded = _canFd
          ? decodeXlCanRxEvent(Uint8List.fromList(_evBuf.asTypedList(xlCanRxEventSize)))
          : decodeXlEvent(Uint8List.fromList(_evBuf.asTypedList(xlEventSize)));
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
    checkSendable(frame, fdMode: _canFd);
    final bytes = _canFd ? encodeXlCanTxEvent(frame) : encodeXlCanMsg(frame);
    final buf = calloc<Uint8>(bytes.length);
    final n = calloc<Uint32>()..value = 1;
    try {
      buf.asTypedList(bytes.length).setAll(0, bytes);
      final r = _canFd
          ? x.canTransmitEx!(_port, _mask, 1, n, buf)
          : x.transmit(_port, _mask, n, buf);
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
  bool get supportsFd => _x?.hasFd ?? false;
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
