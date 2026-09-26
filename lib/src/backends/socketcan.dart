// SocketCAN (Linux) via dart:ffi against libc. No native plugin, no build glue.
import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../can.dart';

// ---------------------------------------------------------------------------
// struct can_frame codec — pure bytes<->frame, unit-tested without a socket.
// ---------------------------------------------------------------------------

const canEffFlag = 0x80000000;
const canRtrFlag = 0x40000000;
const canErrFlag = 0x20000000;
const canFrameSize = 16;

/// struct canfd_frame: id | len | flags | res0 | res1 | data[64].
const canFdFrameSize = 72;
const canFdBrs = 0x01, canFdEsi = 0x02, canFdFdf = 0x04;

Uint8List encodeCanFdFrame(CanFrame f) {
  final out = Uint8List(canFdFrameSize);
  var canId = f.id & (f.extended ? 0x1FFFFFFF : 0x7FF);
  if (f.extended) canId |= canEffFlag;
  ByteData.view(out.buffer).setUint32(0, canId, Endian.host);
  final n = f.data.length.clamp(0, 64);
  out[4] = fdPaddedLength(n);
  out[5] = canFdFdf | (f.brs ? canFdBrs : 0) | (f.esi ? canFdEsi : 0);
  out.setRange(8, 8 + n, f.data);
  return out;
}

Uint8List encodeCanFrame(CanFrame f) {
  final out = Uint8List(canFrameSize);
  final bd = ByteData.view(out.buffer);
  var canId = f.id & (f.extended ? 0x1FFFFFFF : 0x7FF);
  if (f.extended) canId |= canEffFlag;
  if (f.rtr) canId |= canRtrFlag;
  bd.setUint32(0, canId, Endian.host);
  final len = f.data.length.clamp(0, 8);
  out[4] = len;
  out.setRange(8, 8 + len, f.data);
  return out;
}

/// Decodes a can_frame (16 bytes) or, for 72 bytes, a canfd_frame.
/// Returns null for error frames, which carry diagnostics rather than data.
CanFrame? decodeCanFrame(Uint8List raw) {
  if (raw.length < canFrameSize) return null;
  final fd = raw.length >= canFdFrameSize;
  final bd = ByteData.view(raw.buffer, raw.offsetInBytes, canFrameSize);
  final canId = bd.getUint32(0, Endian.host);
  if (canId & canErrFlag != 0) return null;
  final extended = canId & canEffFlag != 0;
  final rtr = !fd && canId & canRtrFlag != 0;
  final len = raw[4].clamp(0, fd ? 64 : 8);
  return CanFrame(
    id: canId & (extended ? 0x1FFFFFFF : 0x7FF),
    data: Uint8List.fromList(raw.sublist(8, 8 + len)),
    extended: extended,
    rtr: rtr,
    fd: fd,
    brs: fd && raw[5] & canFdBrs != 0,
    esi: fd && raw[5] & canFdEsi != 0,
  );
}

/// Human-readable summary of a SocketCAN error frame (class bits in the id).
String describeErrorFrame(Uint8List raw) {
  final id = ByteData.view(raw.buffer, raw.offsetInBytes, canFrameSize)
      .getUint32(0, Endian.host);
  final causes = <String>[];
  if (id & 0x001 != 0) causes.add('TX timeout');
  if (id & 0x002 != 0) causes.add('lost arbitration');
  if (id & 0x004 != 0) causes.add('controller problem');
  if (id & 0x008 != 0) causes.add('protocol violation');
  if (id & 0x010 != 0) causes.add('transceiver status');
  if (id & 0x020 != 0) causes.add('no ACK');
  if (id & 0x040 != 0) causes.add('bus off');
  if (id & 0x080 != 0) causes.add('bus error');
  if (id & 0x100 != 0) causes.add('controller restarted');
  return causes.isEmpty ? 'bus error' : causes.join(', ');
}

// ---------------------------------------------------------------------------
// libc bindings
// ---------------------------------------------------------------------------

const _afCan = 29, _sockRaw = 3, _canRaw = 1;
const _solCanRaw = 101, _canRawFdFrames = 5;
const _siocgifindex = 0x8933;
const _fSetfl = 4, _oNonblock = 0x800;

typedef _SocketC = Int32 Function(Int32, Int32, Int32);
typedef LibcSocket = int Function(int, int, int);
typedef _BindC = Int32 Function(Int32, Pointer<Uint8>, Uint32);
typedef LibcBind = int Function(int, Pointer<Uint8>, int);
typedef _IoctlC = Int32 Function(Int32, UnsignedLong, Pointer<Uint8>);
typedef LibcIoctl = int Function(int, int, Pointer<Uint8>);
typedef _RwC = IntPtr Function(Int32, Pointer<Uint8>, IntPtr);
typedef LibcRw = int Function(int, Pointer<Uint8>, int);
typedef _CloseC = Int32 Function(Int32);
typedef LibcClose = int Function(int);
typedef _FcntlC = Int32 Function(Int32, Int32, Int32);
typedef LibcFcntl = int Function(int, int, int);
typedef _SetsockoptC = Int32 Function(Int32, Int32, Int32, Pointer<Uint8>, Uint32);
typedef LibcSetsockopt = int Function(int, int, int, Pointer<Uint8>, int);

/// The libc calls SocketCAN needs, as plain Dart functions so a test can stand
/// in for the kernel without a CAN netdev.
class Libc {
  final LibcSocket socket;
  final LibcBind bind;
  final LibcIoctl ioctl;
  final LibcRw read;
  final LibcRw write;
  final LibcClose close;
  final LibcFcntl fcntl;

  /// Only needed for CAN FD; a test that does not do FD may leave it out.
  final LibcSetsockopt? setsockopt;

  Libc({
    this.setsockopt,
    required this.socket,
    required this.bind,
    required this.ioctl,
    required this.read,
    required this.write,
    required this.close,
    required this.fcntl,
  });

  Libc.fromLibrary(DynamicLibrary lib)
      : socket = lib.lookupFunction<_SocketC, LibcSocket>('socket'),
        bind = lib.lookupFunction<_BindC, LibcBind>('bind'),
        ioctl = lib.lookupFunction<_IoctlC, LibcIoctl>('ioctl'),
        read = lib.lookupFunction<_RwC, LibcRw>('read'),
        write = lib.lookupFunction<_RwC, LibcRw>('write'),
        close = lib.lookupFunction<_CloseC, LibcClose>('close'),
        fcntl = lib.lookupFunction<_FcntlC, LibcFcntl>('fcntl'),
        setsockopt =
            lib.lookupFunction<_SetsockoptC, LibcSetsockopt>('setsockopt');
}

Libc? _libc;
Libc get _c => _libc ??= Libc.fromLibrary(DynamicLibrary.process());

/// Replace (or, with null, restore) the libc bindings. Tests only.
@visibleForTesting
set libc(Libc? l) => _libc = l;

class SocketCanBus implements CanBus {
  int _fd = -1;
  bool _canFd = false;
  Timer? _poll;
  final _frames = StreamController<CanFrame>.broadcast();
  final _status = StreamController<String>.broadcast();
  late Pointer<Uint8> _rxBuf;

  @override
  Stream<CanFrame> get frames => _frames.stream;
  @override
  Stream<String> get status => _status.stream;
  @override
  bool get isOpen => _fd >= 0;

  @override
  Future<void> open(String address, int bitrate, {int? dataBitrate}) async {
    await _ensureInterfaceUp(address, bitrate, dataBitrate);

    _fd = _c.socket(_afCan, _sockRaw, _canRaw);
    if (_fd < 0) throw CanBusException('socket(PF_CAN) failed (errno $_fd)');
    _canFd = dataBitrate != null;
    if (_canFd) _enableFd(address);

    // Resolve ifname -> ifindex through SIOCGIFINDEX on a struct ifreq.
    final ifreq = calloc<Uint8>(40);
    try {
      final name = address.codeUnits;
      if (name.length > 15) throw CanBusException('interface name too long');
      for (var i = 0; i < name.length; i++) {
        ifreq[i] = name[i];
      }
      if (_c.ioctl(_fd, _siocgifindex, ifreq) < 0) {
        _c.close(_fd);
        _fd = -1;
        throw CanBusException('no such CAN interface: $address');
      }
      final ifindex =
          ByteData.view(ifreq.asTypedList(40).buffer).getInt32(16, Endian.host);

      final addr = calloc<Uint8>(16);
      try {
        final bd = ByteData.view(addr.asTypedList(16).buffer);
        bd.setUint16(0, _afCan, Endian.host);
        bd.setInt32(4, ifindex, Endian.host);
        if (_c.bind(_fd, addr, 16) < 0) {
          _c.close(_fd);
          _fd = -1;
          throw CanBusException('bind to $address failed');
        }
      } finally {
        calloc.free(addr);
      }
    } finally {
      calloc.free(ifreq);
    }

    _c.fcntl(_fd, _fSetfl, _oNonblock);
    _rxBuf = calloc<Uint8>(canFdFrameSize);

    // ponytail: non-blocking socket drained on a 1 ms timer. Simple and good
    // for a few thousand frames/s; move the read loop into an Isolate with a
    // blocking recv if you need to keep up with a saturated 1 Mbit bus.
    _poll = Timer.periodic(const Duration(milliseconds: 1), (_) => _drain());
  }

  /// With CAN_RAW_FD_FRAMES the socket hands out both frame sizes; each read
  /// returns exactly one frame and its size says which kind it is.
  void _enableFd(String address) {
    final set = _c.setsockopt;
    final one = calloc<Uint8>(4);
    try {
      ByteData.view(one.asTypedList(4).buffer).setInt32(0, 1, Endian.host);
      if (set == null || set(_fd, _solCanRaw, _canRawFdFrames, one, 4) < 0) {
        _c.close(_fd);
        _fd = -1;
        throw CanBusException('$address does not support CAN FD');
      }
    } finally {
      calloc.free(one);
    }
  }

  void _drain() {
    if (_fd < 0) return;
    final size = _canFd ? canFdFrameSize : canFrameSize;
    for (var i = 0; i < 512; i++) {
      final n = _c.read(_fd, _rxBuf, size);
      // EAGAIN or partial: nothing more to take
      if (n != canFrameSize && n != canFdFrameSize) return;
      final raw = Uint8List.fromList(_rxBuf.asTypedList(n));
      final frame = decodeCanFrame(raw);
      if (frame != null) {
        _frames.add(frame);
      } else {
        final what = describeErrorFrame(raw);
        _status.add(what);
        _frames.add(CanFrame.error(what));
      }
    }
  }

  /// The iproute2 binary; a test points it at a script.
  @visibleForTesting
  static String ipCommand = 'ip';

  /// SocketCAN bitrate lives on the netdev, not the socket, so it needs
  /// CAP_NET_ADMIN. If the link is already up we leave it alone.
  Future<void> _ensureInterfaceUp(String ifname, int bitrate, int? dataBitrate) async {
    try {
      final state = await Process.run(ipCommand, ['-details', 'link', 'show', ifname]);
      if (state.exitCode != 0) return; // let bind() produce the real error
      final out = state.stdout.toString();
      if (out.contains('state UP') || out.contains('<NOARP,UP')) {
        if (!out.contains('bitrate $bitrate') ||
            (dataBitrate != null && !out.contains('dbitrate $dataBitrate'))) {
          _status.add('$ifname is already up; leaving its bitrate unchanged');
        }
        return;
      }
      if (ifname.startsWith('vcan')) {
        await Process.run(ipCommand, ['link', 'set', ifname, 'up']);
        return;
      }
      final args = [
        'link', 'set', ifname, 'up', 'type', 'can', 'bitrate', '$bitrate',
        if (dataBitrate != null) ...['dbitrate', '$dataBitrate', 'fd', 'on'],
      ];
      final r = await Process.run(ipCommand, args);
      if (r.exitCode != 0) {
        _status.add('could not bring up $ifname (needs root). Run: sudo ip '
            '${args.join(' ')}');
      }
    } on ProcessException {
      // No iproute2 available; assume the interface was configured externally.
    }
  }

  @override
  Future<void> send(CanFrame frame) async {
    if (_fd < 0) throw CanBusException('bus is not open');
    checkSendable(frame, fdMode: _canFd);
    final bytes = frame.fd ? encodeCanFdFrame(frame) : encodeCanFrame(frame);
    final buf = calloc<Uint8>(bytes.length);
    try {
      buf.asTypedList(bytes.length).setAll(0, bytes);
      if (_c.write(_fd, buf, bytes.length) < 0) {
        throw CanBusException('write failed (bus off or tx queue full)');
      }
    } finally {
      calloc.free(buf);
    }
  }

  @override
  Future<void> close() async {
    _poll?.cancel();
    _poll = null;
    if (_fd >= 0) {
      _c.close(_fd);
      _fd = -1;
      calloc.free(_rxBuf);
    }
  }
}

class SocketCanBackend implements CanBackend {
  @override
  String get id => 'socketcan';
  @override
  String get name => 'SocketCAN (Linux kernel drivers)';
  @override
  bool get available => Platform.isLinux;
  @override
  bool get supportsFd => true;
  @override
  String get unavailableReason =>
      Platform.isLinux ? '' : 'SocketCAN is a Linux kernel subsystem';

  /// Where the kernel lists netdevs; a test points it at a fixture directory.
  @visibleForTesting
  static String sysClassNet = '/sys/class/net';

  @override
  Future<List<CanDevice>> discover() async {
    // Every CAN netdev shows up here, physical and virtual alike. The
    // directory only exists on Linux, so this doubles as the platform check.
    final dir = Directory(sysClassNet);
    if (!dir.existsSync()) return [];
    final devices = <CanDevice>[];
    for (final e in dir.listSync()) {
      final name = e.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
      if (File('${e.path}/type').existsSync()) {
        // ARPHRD_CAN == 280
        final type = File('${e.path}/type').readAsStringSync().trim();
        if (type == '280') {
          devices.add(CanDevice(id, name, '$name (SocketCAN)'));
        }
      }
    }
    return devices;
  }

  @override
  CanBus create() => SocketCanBus();
}
