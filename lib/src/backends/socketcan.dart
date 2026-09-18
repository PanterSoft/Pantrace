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

/// Returns null for error frames, which carry diagnostics rather than data.
CanFrame? decodeCanFrame(Uint8List raw) {
  if (raw.length < canFrameSize) return null;
  final bd = ByteData.view(raw.buffer, raw.offsetInBytes, canFrameSize);
  final canId = bd.getUint32(0, Endian.host);
  if (canId & canErrFlag != 0) return null;
  final extended = canId & canEffFlag != 0;
  final rtr = canId & canRtrFlag != 0;
  final len = raw[4].clamp(0, 8);
  return CanFrame(
    id: canId & (extended ? 0x1FFFFFFF : 0x7FF),
    data: Uint8List.fromList(raw.sublist(8, 8 + len)),
    extended: extended,
    rtr: rtr,
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

  Libc({
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
        fcntl = lib.lookupFunction<_FcntlC, LibcFcntl>('fcntl');
}

Libc? _libc;
Libc get _c => _libc ??= Libc.fromLibrary(DynamicLibrary.process());

/// Replace (or, with null, restore) the libc bindings. Tests only.
@visibleForTesting
set libc(Libc? l) => _libc = l;

class SocketCanBus implements CanBus {
  int _fd = -1;
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
  Future<void> open(String address, int bitrate) async {
    await _ensureInterfaceUp(address, bitrate);

    _fd = _c.socket(_afCan, _sockRaw, _canRaw);
    if (_fd < 0) throw CanBusException('socket(PF_CAN) failed (errno $_fd)');

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
    _rxBuf = calloc<Uint8>(canFrameSize);

    // ponytail: non-blocking socket drained on a 1 ms timer. Simple and good
    // for a few thousand frames/s; move the read loop into an Isolate with a
    // blocking recv if you need to keep up with a saturated 1 Mbit bus.
    _poll = Timer.periodic(const Duration(milliseconds: 1), (_) => _drain());
  }

  void _drain() {
    if (_fd < 0) return;
    for (var i = 0; i < 512; i++) {
      final n = _c.read(_fd, _rxBuf, canFrameSize);
      if (n < canFrameSize) return; // EAGAIN or partial: nothing more to take
      final raw = Uint8List.fromList(_rxBuf.asTypedList(canFrameSize));
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
  Future<void> _ensureInterfaceUp(String ifname, int bitrate) async {
    try {
      final state = await Process.run(ipCommand, ['-details', 'link', 'show', ifname]);
      if (state.exitCode != 0) return; // let bind() produce the real error
      final out = state.stdout.toString();
      if (out.contains('state UP') || out.contains('<NOARP,UP')) {
        if (!out.contains('bitrate $bitrate')) {
          _status.add('$ifname is already up; leaving its bitrate unchanged');
        }
        return;
      }
      if (ifname.startsWith('vcan')) {
        await Process.run(ipCommand, ['link', 'set', ifname, 'up']);
        return;
      }
      final r = await Process.run(
          ipCommand, ['link', 'set', ifname, 'up', 'type', 'can', 'bitrate', '$bitrate']);
      if (r.exitCode != 0) {
        _status.add(
            'could not bring up $ifname (needs root). Run: sudo ip link set '
            '$ifname up type can bitrate $bitrate');
      }
    } on ProcessException {
      // No iproute2 available; assume the interface was configured externally.
    }
  }

  @override
  Future<void> send(CanFrame frame) async {
    if (_fd < 0) throw CanBusException('bus is not open');
    final bytes = encodeCanFrame(frame);
    final buf = calloc<Uint8>(canFrameSize);
    try {
      buf.asTypedList(canFrameSize).setAll(0, bytes);
      if (_c.write(_fd, buf, canFrameSize) < 0) {
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
