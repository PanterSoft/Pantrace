// PEAK-System PCAN via the PCANBasic driver library, bound with dart:ffi.
// Windows: PCANBasic.dll · Linux: libpcanbasic.so · macOS: libPCBUSB.dylib
import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../can.dart';

// ---------------------------------------------------------------------------
// TPCANMsg codec. Layout is DWORD ID | BYTE type | BYTE len | BYTE data[8],
// naturally aligned, so data starts at offset 6 and the struct is 16 bytes.
// ---------------------------------------------------------------------------

const pcanMsgSize = 16;
const _msgStandard = 0x00, _msgRtr = 0x01, _msgExtended = 0x02;
const _msgErrFrame = 0x40, _msgStatus = 0x80;

Uint8List encodePcanMsg(CanFrame f) {
  final out = Uint8List(pcanMsgSize);
  ByteData.view(out.buffer).setUint32(0, f.id, Endian.little);
  var type = f.extended ? _msgExtended : _msgStandard;
  if (f.rtr) type |= _msgRtr;
  out[4] = type;
  final len = f.data.length.clamp(0, 8);
  out[5] = len;
  out.setRange(6, 6 + len, f.data);
  return out;
}

/// Returns null for status and error frames — those are driver notices, not bus
/// traffic, and belong on the status stream instead.
CanFrame? decodePcanMsg(Uint8List raw, {Duration? timestamp}) {
  if (raw.length < pcanMsgSize) return null;
  final type = raw[4];
  if (type & (_msgErrFrame | _msgStatus) != 0) return null;
  final id = ByteData.view(raw.buffer, raw.offsetInBytes, pcanMsgSize)
      .getUint32(0, Endian.little);
  final len = raw[5].clamp(0, 8);
  return CanFrame(
    id: id,
    data: Uint8List.fromList(raw.sublist(6, 6 + len)),
    extended: type & _msgExtended != 0,
    rtr: type & _msgRtr != 0,
    hwTimestamp: timestamp,
  );
}

/// TPCANTimestamp is millis | millis_overflow | micros = 8 bytes.
Duration decodePcanTimestamp(Uint8List raw) {
  final bd = ByteData.view(raw.buffer, raw.offsetInBytes, 8);
  final millis = bd.getUint32(0, Endian.little);
  final overflow = bd.getUint16(4, Endian.little);
  final micros = bd.getUint16(6, Endian.little);
  return Duration(
    milliseconds: millis + overflow * 0x100000000,
    microseconds: micros,
  );
}

/// PCANBasic takes BTR0/BTR1 register pairs, not plain bitrates.
const pcanBaudCodes = {
  1000000: 0x0014, 800000: 0x0016, 500000: 0x001C, 250000: 0x011C,
  125000: 0x031C, 100000: 0x432F, 83333: 0x852B, 50000: 0x472F,
  33333: 0x8B2F, 20000: 0x532F, 10000: 0x672F,
};

/// Channel handles worth probing: USB 1-16, PCI 1-8, LAN 1-8.
Map<int, String> pcanCandidateChannels() {
  final out = <int, String>{};
  for (var i = 0; i < 8; i++) {
    out[0x51 + i] = 'PCAN-USB ${i + 1}';
  }
  for (var i = 0; i < 8; i++) {
    out[0x509 + i] = 'PCAN-USB ${i + 9}';
  }
  for (var i = 0; i < 8; i++) {
    out[0x41 + i] = 'PCAN-PCI ${i + 1}';
  }
  for (var i = 0; i < 8; i++) {
    out[0x801 + i] = 'PCAN-LAN ${i + 1}';
  }
  return out;
}

// ---------------------------------------------------------------------------
// Driver bindings
// ---------------------------------------------------------------------------

const _errOk = 0x00000, _errQrcvEmpty = 0x00020, _errCaution = 0x2000000;
const _paramChannelCondition = 0x07;
// PCAN_CHANNEL_AVAILABLE 1, _OCCUPIED 2, _PCANVIEW 3. Occupied channels are
// still joinable: the PCAN driver shares a channel between client applications.
const _channelUnavailable = 0x00;

typedef _InitC = Uint32 Function(Uint16, Uint16, Uint8, Uint32, Uint16);
typedef PcanInit = int Function(int, int, int, int, int);
typedef _UninitC = Uint32 Function(Uint16);
typedef PcanUninit = int Function(int);
typedef _ReadC = Uint32 Function(Uint16, Pointer<Uint8>, Pointer<Uint8>);
typedef PcanRead = int Function(int, Pointer<Uint8>, Pointer<Uint8>);
typedef _WriteC = Uint32 Function(Uint16, Pointer<Uint8>);
typedef PcanWrite = int Function(int, Pointer<Uint8>);
typedef _GetValueC = Uint32 Function(Uint16, Uint8, Pointer<Uint8>, Uint32);
typedef PcanGetValue = int Function(int, int, Pointer<Uint8>, int);
typedef _ErrTextC = Uint32 Function(Uint32, Uint16, Pointer<Uint8>);
typedef PcanErrText = int Function(int, int, Pointer<Uint8>);

/// The PCANBasic entry points as plain Dart functions, so a test can stand in
/// for the driver without hardware.
class PcanDriver {
  final PcanInit init;
  final PcanUninit uninit;
  final PcanRead read;
  final PcanWrite write;
  final PcanGetValue getValue;
  final PcanErrText errText;

  PcanDriver({
    required this.init,
    required this.uninit,
    required this.read,
    required this.write,
    required this.getValue,
    required this.errText,
  });

  PcanDriver.fromLibrary(DynamicLibrary lib)
      : init = lib.lookupFunction<_InitC, PcanInit>('CAN_Initialize'),
        uninit = lib.lookupFunction<_UninitC, PcanUninit>('CAN_Uninitialize'),
        read = lib.lookupFunction<_ReadC, PcanRead>('CAN_Read'),
        write = lib.lookupFunction<_WriteC, PcanWrite>('CAN_Write'),
        getValue = lib.lookupFunction<_GetValueC, PcanGetValue>('CAN_GetValue'),
        errText = lib.lookupFunction<_ErrTextC, PcanErrText>('CAN_GetErrorText');
}

PcanDriver? _pcan;
bool _pcanTried = false;

/// Replace (or, with null, remove) the driver. Tests only.
@visibleForTesting
set pcanDriver(PcanDriver? d) {
  _pcan = d;
  _pcanTried = true;
}

PcanDriver? get _p {
  if (_pcanTried) return _pcan;
  _pcanTried = true;
  final names = Platform.isWindows
      ? ['PCANBasic.dll']
      : Platform.isMacOS
          ? ['libPCBUSB.dylib', '/usr/local/lib/libPCBUSB.dylib']
          : ['libpcanbasic.so', 'libpcanbasic.so.4'];
  for (final n in names) {
    try {
      _pcan = PcanDriver.fromLibrary(DynamicLibrary.open(n));
      return _pcan; // coverage:ignore-line
    } catch (_) {
      // Try the next candidate path.
    }
  }
  return null;
}

String _errorText(int code) {
  final p = _p;
  if (p == null) return 'PCAN error 0x${code.toRadixString(16)}';
  final buf = calloc<Uint8>(256);
  try {
    if (p.errText(code, 0x09, buf) == _errOk) {
      final bytes = buf.asTypedList(256);
      final end = bytes.indexOf(0);
      return String.fromCharCodes(bytes.sublist(0, end < 0 ? 256 : end));
    }
  } finally {
    calloc.free(buf);
  }
  return 'PCAN error 0x${code.toRadixString(16)}';
}

class PcanBus implements CanBus {
  int _channel = 0;
  Timer? _poll;
  final _frames = StreamController<CanFrame>.broadcast();
  final _status = StreamController<String>.broadcast();
  late Pointer<Uint8> _msgBuf;
  late Pointer<Uint8> _tsBuf;

  @override
  Stream<CanFrame> get frames => _frames.stream;
  @override
  Stream<String> get status => _status.stream;
  @override
  bool get isOpen => _channel != 0;

  @override
  Future<void> open(String address, int bitrate) async {
    final p = _p;
    if (p == null) throw CanBusException('PCANBasic driver library not found');
    final channel = int.parse(address);
    final baud = pcanBaudCodes[bitrate];
    if (baud == null) {
      throw CanBusException('PCAN does not define a BTR pair for $bitrate bit/s');
    }
    final r = p.init(channel, baud, 0, 0, 0);
    if (r == _errCaution) {
      // Another application already runs this channel; we join at its bitrate.
      _status.add('channel is shared with another application — '
          'using its bitrate instead of $bitrate bit/s');
    } else if (r != _errOk) {
      throw CanBusException(_errorText(r));
    }

    _channel = channel;
    _msgBuf = calloc<Uint8>(pcanMsgSize);
    _tsBuf = calloc<Uint8>(8);
    // ponytail: polled drain, same tradeoff as SocketCAN. PCANBasic can signal
    // an event handle instead — swap to that if you saturate a 1 Mbit bus.
    _poll = Timer.periodic(const Duration(milliseconds: 1), (_) => _drain());
  }

  void _drain() {
    final p = _p;
    if (p == null || _channel == 0) return;
    for (var i = 0; i < 512; i++) {
      final r = p.read(_channel, _msgBuf, _tsBuf);
      if (r == _errQrcvEmpty) return;
      if (r != _errOk) {
        _status.add(_errorText(r));
        return;
      }
      final raw = Uint8List.fromList(_msgBuf.asTypedList(pcanMsgSize));
      final ts = decodePcanTimestamp(Uint8List.fromList(_tsBuf.asTypedList(8)));
      final frame = decodePcanMsg(raw, timestamp: ts);
      if (frame != null) {
        _frames.add(frame);
      } else if (raw[4] & _msgErrFrame != 0) {
        const what = 'error frame on bus';
        _status.add(what);
        _frames.add(CanFrame.error(what));
      } else if (raw[4] & _msgStatus != 0) {
        _status.add('bus status change reported by adapter');
      }
    }
  }

  @override
  Future<void> send(CanFrame frame) async {
    final p = _p;
    if (p == null || _channel == 0) throw CanBusException('bus is not open');
    _msgBuf.asTypedList(pcanMsgSize).setAll(0, encodePcanMsg(frame));
    final r = p.write(_channel, _msgBuf);
    if (r != _errOk) throw CanBusException(_errorText(r));
  }

  @override
  Future<void> close() async {
    _poll?.cancel();
    _poll = null;
    if (_channel != 0) {
      _p?.uninit(_channel);
      _channel = 0;
      calloc.free(_msgBuf);
      calloc.free(_tsBuf);
    }
  }
}

class PcanBackend implements CanBackend {
  @override
  String get id => 'pcan';
  @override
  String get name => 'PEAK PCAN (USB / PCI / LAN)';
  @override
  bool get available => _p != null;
  @override
  String get unavailableReason => Platform.isMacOS
      ? 'install the MacCAN PCBUSB driver (libPCBUSB.dylib)'
      : Platform.isWindows
          ? 'install the PEAK PCANBasic driver (PCANBasic.dll)'
          : 'install libpcanbasic.so from the PEAK Linux driver package';

  @override
  Future<List<CanDevice>> discover() async {
    final p = _p;
    if (p == null) return [];
    final out = <CanDevice>[];
    final buf = calloc<Uint8>(4);
    try {
      for (final entry in pcanCandidateChannels().entries) {
        final r = p.getValue(entry.key, _paramChannelCondition, buf, 4);
        if (r != _errOk) continue;
        final cond = buf.asTypedList(4)[0];
        if (cond != _channelUnavailable) {
          out.add(CanDevice(id, '${entry.key}', entry.value));
        }
      }
    } finally {
      calloc.free(buf);
    }
    return out;
  }

  @override
  CanBus create() => PcanBus();
}
