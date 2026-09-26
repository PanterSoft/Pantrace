// SLCAN / Lawicel ASCII protocol over a serial port.
// Covers CANable, CANtact, USBtin, Lawicel CAN232 and the many clones.
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_libserialport/flutter_libserialport.dart';

import '../can.dart';
import '../pty.dart';

// ---------------------------------------------------------------------------
// Protocol codec — pure string<->frame, no I/O, so it is unit-tested directly.
// ---------------------------------------------------------------------------

/// SLCAN offers a fixed bitrate table (S0..S8). Anything else needs the raw
/// BTR registers, which are chip-specific, so we expose only the standard set.
const slcanBitrateCodes = {
  10000: 'S0', 20000: 'S1', 50000: 'S2', 100000: 'S3', 125000: 'S4',
  250000: 'S5', 500000: 'S6', 800000: 'S7', 1000000: 'S8',
};

/// CAN FD data bitrates of the CANable 2.0 firmware's SLCAN extension (`Y`).
const slcanDataBitrateCodes = {
  1000000: 'Y1', 2000000: 'Y2', 4000000: 'Y4', 5000000: 'Y5', 8000000: 'Y8',
};

/// Encodes a frame. CAN FD uses the CANable 2.0 extension: `d`/`D` for FD,
/// `b`/`B` for FD with bit rate switch, and the DLC as one hex digit (0-F).
String encodeSlcan(CanFrame f) {
  final id = f.extended
      ? f.id.toRadixString(16).toUpperCase().padLeft(8, '0')
      : f.id.toRadixString(16).toUpperCase().padLeft(3, '0');
  if (f.fd) {
    final cmd = f.brs ? (f.extended ? 'B' : 'b') : (f.extended ? 'D' : 'd');
    final dlc = lengthToDlc(f.data.length.clamp(0, 64));
    final data = Uint8List(fdLengths[dlc])..setAll(0, f.data.take(64));
    final payload =
        data.map((b) => b.toRadixString(16).toUpperCase().padLeft(2, '0')).join();
    return '$cmd$id${dlc.toRadixString(16).toUpperCase()}$payload\r';
  }
  final len = f.data.length.clamp(0, 8);
  final cmd = f.rtr
      ? (f.extended ? 'R' : 'r')
      : (f.extended ? 'T' : 't');
  final payload = f.rtr
      ? ''
      : f.data
          .take(len)
          .map((b) => b.toRadixString(16).toUpperCase().padLeft(2, '0'))
          .join();
  return '$cmd$id$len$payload\r';
}

/// Decode one SLCAN line (without the trailing CR).
///
/// Returns null for anything that is not a frame: version strings, status
/// replies, bare ACKs, and garbage from a half-open port.
CanFrame? parseSlcan(String line, {bool timestamps = false}) {
  if (line.isEmpty) return null;
  final kind = line[0];
  if (!'tTrRdDbB'.contains(kind)) return null;
  final extended = 'TRDB'.contains(kind);
  final rtr = kind == 'r' || kind == 'R';
  final fd = 'dDbB'.contains(kind);

  final idLen = extended ? 8 : 3;
  if (line.length < 1 + idLen + 1) return null;

  final id = int.tryParse(line.substring(1, 1 + idLen), radix: 16);
  final dlc = int.tryParse(line.substring(1 + idLen, 2 + idLen), radix: 16);
  if (id == null || dlc == null || (!fd && dlc > 8)) return null;
  final len = dlcToLength(dlc, fd: fd);

  var pos = 2 + idLen;
  final data = Uint8List(rtr ? 0 : len);
  if (!rtr) {
    if (line.length < pos + len * 2) return null;
    for (var i = 0; i < len; i++) {
      final b = int.tryParse(line.substring(pos, pos + 2), radix: 16);
      if (b == null) return null;
      data[i] = b;
      pos += 2;
    }
  }

  Duration? hw;
  if (timestamps && line.length >= pos + 4) {
    final ms = int.tryParse(line.substring(pos, pos + 4), radix: 16);
    if (ms != null) hw = Duration(milliseconds: ms);
  }

  return CanFrame(
    id: id,
    data: data,
    extended: extended,
    rtr: rtr,
    fd: fd,
    brs: kind == 'b' || kind == 'B',
    hwTimestamp: hw,
  );
}

/// Split a raw serial chunk into complete CR-terminated lines, returning the
/// leftover partial line so the caller can prepend it to the next chunk.
(List<String>, String) splitSlcanLines(String buffer) {
  final parts = buffer.split('\r');
  final remainder = parts.removeLast();
  return (parts.where((p) => p.isNotEmpty).toList(), remainder);
}

// ---------------------------------------------------------------------------
// Device detection — pure helpers, unit-tested; the probe itself needs a port.
// ---------------------------------------------------------------------------

/// USB ids of adapters known to speak SLCAN out of the box.
const knownSlcanUsbIds = <(int, int), String>{
  (0xAD50, 0x60C4): 'CANable',
  (0x04D8, 0x000A): 'USBtin',
  (0x1D50, 0x606F): 'CANable', // candleLight boards reflashed with slcan
};

/// Best-effort product name from USB descriptors, or null if it looks generic
/// (FTDI/CH340 bridges are used by everything, so no guess for those).
String? slcanNameHint(int? vid, int? pid, String? product, String? manufacturer) {
  if (vid != null && pid != null) {
    final known = knownSlcanUsbIds[(vid, pid)];
    if (known != null) return known;
  }
  final text = '${product ?? ''} ${manufacturer ?? ''}'.toLowerCase();
  for (final needle in ['canable', 'cantact', 'usbtin', 'slcan', 'canusb', 'candapter']) {
    if (text.contains(needle)) {
      // CANable reports "CANable2 b158aa7 github.com/..." — keep the model only.
      final full = (product ?? manufacturer)!.trim();
      return full.split(RegExp(r'\s+')).first;
    }
  }
  return null;
}

/// Ports that are certainly not CAN adapters and would only waste probe time
/// (or, for Bluetooth, hang for seconds trying to pair).
bool slcanWorthProbing(String path, int transport) {
  if (transport == SerialPortTransport.bluetooth) return false;
  final p = path.toLowerCase();
  return !p.contains('bluetooth') && !p.contains('debug-console') && !p.contains('wlan');
}

/// Extract the firmware version from a reply to `V\r`, e.g. "V1013" -> "1013".
/// Accepts lowercase `v` (CANable) and tolerates surrounding ACK/BEL noise.
String? slcanVersionFrom(String reply) =>
    RegExp(r'[Vv]([0-9A-Fa-f]{4})').firstMatch(reply)?.group(1);

/// Does this look like something an SLCAN adapter said? The protocol is the
/// only common one that terminates with a bare CR (modems, Arduino sketches
/// and shells all use CRLF) or answers with a lone BEL.
///
/// CANable2 replies to `V` with a git hash, so a classic version string is
/// sufficient but not necessary.
bool slcanLooksLikeReply(String reply) {
  if (reply.isEmpty) return false;
  if (slcanVersionFrom(reply) != null) return true;
  if (reply.contains('\x07')) return true;
  return reply.contains('\r') && !reply.contains('\n');
}

/// Open [path], send the version query, and return (detected, version) after
/// listening for ~300 ms. Blocking; run off the UI isolate.
(bool, String?) probeSlcanPort(String path) {
  final SerialPort port;
  try {
    port = SerialPort(path); // a path that is no port at all throws here
  } catch (_) {
    return (false, null);
  }
  if (!port.openReadWrite()) {
    port.dispose();
    return (false, null);
  }
  try {
    port.config = SerialPortConfig()
      ..baudRate = 115200
      ..bits = 8
      ..parity = SerialPortParity.none
      ..stopBits = 1
      ..setFlowControl(SerialPortFlowControl.none);
    port.flush();
    // No 'C' here: it would close the CAN channel of another application
    // using the adapter. An already-open adapter answers V with BELL, which
    // slcanLooksLikeReply accepts.
    port.write(Uint8List.fromList('V\r'.codeUnits), timeout: 100);
    final buf = StringBuffer();
    final deadline = DateTime.now().add(const Duration(milliseconds: 300));
    while (DateTime.now().isBefore(deadline)) {
      final chunk = port.read(64, timeout: 100);
      if (chunk.isNotEmpty) buf.write(String.fromCharCodes(chunk));
      final v = slcanVersionFrom(buf.toString());
      if (v != null) return (true, v);
    }
    return (slcanLooksLikeReply(buf.toString()), null);
  } catch (_) {
    return (false, null);
  } finally {
    port.close();
    port.dispose();
  }
}

class _PortInfo {
  final String path;
  final int transport;
  final int? vid, pid;
  final String? product, manufacturer, description;
  const _PortInfo(this.path, this.transport, this.vid, this.pid, this.product,
      this.manufacturer, this.description);
}

_PortInfo _inspect(String path) {
  SerialPort? sp;
  try {
    sp = SerialPort(path);
    return _PortInfo(path, sp.transport, sp.vendorId, sp.productId,
        sp.productName, sp.manufacturer, sp.description);
  } catch (_) {
    return _PortInfo(path, SerialPortTransport.native, null, null, null, null, null);
  } finally {
    sp?.dispose();
  }
}

/// True for a pseudo-terminal (directly or via a symlink such as /tmp/slcan0):
/// a program emulating an SLCAN adapter, which libserialport cannot open.
bool isPtyPath(String path) {
  try {
    final real = File(path).resolveSymbolicLinksSync();
    return real.startsWith('/dev/ttys') || real.startsWith('/dev/pts/');
  } on FileSystemException {
    return false;
  }
}

// ---------------------------------------------------------------------------
// Transport
// ---------------------------------------------------------------------------

class SlcanBus implements CanBus {
  SerialPort? _port;
  Pty? _pty;
  StreamSubscription<Uint8List>? _sub;
  final _frames = StreamController<CanFrame>.broadcast();
  final _status = StreamController<String>.broadcast();
  String _buffer = '';
  bool _timestamps = false;
  bool _canFd = false;

  @override
  Stream<CanFrame> get frames => _frames.stream;
  @override
  Stream<String> get status => _status.stream;
  @override
  bool get isOpen => _pty != null || (_port?.isOpen ?? false);

  @override
  Future<void> open(String address, int bitrate, {int? dataBitrate}) async {
    final code = slcanBitrateCodes[bitrate];
    if (code == null) {
      throw CanBusException(
          'SLCAN adapters support only the standard bitrates '
          '${slcanBitrateCodes.keys.join(", ")}');
    }
    final dataCode = dataBitrate == null ? null : slcanDataBitrateCodes[dataBitrate];
    if (dataBitrate != null && dataCode == null) {
      throw CanBusException('SLCAN FD adapters support the data bitrates '
          '${slcanDataBitrateCodes.keys.map((b) => '${b ~/ 1000000}M').join(', ')}');
    }
    _canFd = dataBitrate != null;

    if (Platform.isWindows || !isPtyPath(address)) {
      _openSerial(address);
    } else {
      try {
        _pty = Pty.connect(address);
      } on OSError catch (e) {
        throw CanBusException('Cannot open $address: ${e.message}');
      }
    }

    // Close first: an adapter left open by a crashed session ignores S/O.
    _write('C\r');
    await Future.delayed(const Duration(milliseconds: 50));
    _write('$code\r');
    await Future.delayed(const Duration(milliseconds: 20));
    // FD firmware (CANable 2.0) takes the data bitrate; classic firmware
    // answers BEL and the channel stays classic.
    if (dataCode != null) {
      _write('$dataCode\r');
      await Future.delayed(const Duration(milliseconds: 20));
    }
    _write('Z1\r'); // request timestamps; harmless if unsupported
    _timestamps = true;
    await Future.delayed(const Duration(milliseconds: 20));
    _write('O\r');

    final pty = _pty;
    if (pty != null) {
      pty.start((b) => _onData(Uint8List.fromList(b)), onHangup: () {
        _status.add('$address closed by the program behind it');
        // No 'C': output nobody reads can make close() on a tty wait forever.
        _pty = null;
        pty.close();
      });
      return;
    }
    _sub = SerialPortReader(_port!).stream.listen(
      _onData,
      onError: (Object e) {
        // Usually the adapter was unplugged; the port is dead from here on.
        _status.add('serial error: $e');
        close();
      },
    );
  }

  void _openSerial(String address) {
    final SerialPort port;
    try {
      port = SerialPort(address); // a path that is no port at all throws here
    } catch (e) {
      throw CanBusException('Cannot open $address: $e');
    }
    if (!port.openReadWrite()) {
      final error = SerialPort.lastError;
      port.dispose();
      throw CanBusException('Cannot open $address: $error');
    }
    // Most SLCAN adapters are USB CDC, where these settings are ignored, but
    // real RS-232 bridges (CAN232) need them.
    port.config = SerialPortConfig()
      ..baudRate = 115200
      ..bits = 8
      ..parity = SerialPortParity.none
      ..stopBits = 1
      ..setFlowControl(SerialPortFlowControl.none);
    _port = port;
  }

  /// Longest legit line is a timestamped 29-bit/8-byte frame (30 chars);
  /// leave headroom. Guards against a buffer that grows without bound if a
  /// noisy line (or a misidentified device) never sends the \r terminator.
  static const _maxLineLength = 256;

  /// Feeds bytes through the exact path a real read would. Tests only — it
  /// lets the receive-buffer bound be exercised without a live serial port.
  @visibleForTesting
  void feedForTest(Uint8List chunk) => _onData(chunk);

  void _onData(Uint8List chunk) {
    _buffer += String.fromCharCodes(chunk);
    final (lines, rest) = splitSlcanLines(_buffer);
    _buffer = rest;
    // Bound only the unterminated tail: a big chunk of complete lines (what
    // arrives after the OS buffered serial input while we were napping) is
    // legitimate traffic, not garbage.
    if (_buffer.length > _maxLineLength) {
      _status.add('discarding $_maxLineLength+ bytes with no line terminator');
      _buffer = '';
    }
    for (var line in lines) {
      // BEL: adapter rejected the previous command or saw a bus error. It
      // comes without a CR, so it can prefix the next frame on the same line.
      while (line.isNotEmpty && line.codeUnitAt(0) == 7) {
        _status.add('adapter reported an error (BEL)');
        line = line.substring(1);
      }
      if (line.isEmpty) continue;
      final frame = parseSlcan(line, timestamps: _timestamps);
      if (frame != null) _frames.add(frame);
    }
  }

  void _write(String s) {
    final pty = _pty;
    if (pty != null) return pty.write(s.codeUnits);
    try {
      _port?.write(Uint8List.fromList(s.codeUnits));
    } on SerialPortError catch (e) {
      _status.add('serial error: $e');
    }
  }

  @override
  Future<void> send(CanFrame frame) async {
    if (!isOpen) throw CanBusException('bus is not open');
    checkSendable(frame, fdMode: _canFd);
    _write(encodeSlcan(frame));
  }

  @override
  Future<void> close() async {
    final pty = _pty;
    if (pty != null) {
      _write('C\r');
      _pty = null;
      pty.close();
      return;
    }
    final port = _port;
    if (port == null) return;
    _port = null;
    _write('C\r');
    await _sub?.cancel();
    _sub = null;
    // macOS blocks forever in close() on a yanked USB serial device, so close
    // off the UI isolate and give up after a while (the fd leaks, the OS
    // reclaims it on exit).
    final addr = port.address;
    await Isolate.run(() {
      final p = SerialPort.fromAddress(addr);
      p.close();
      p.dispose();
    }).timeout(const Duration(seconds: 2), onTimeout: () {});
  }
}

class SlcanBackend implements CanBackend {
  @override
  String get id => 'slcan';
  @override
  String get name => 'SLCAN (CANable, CANtact, USBtin, Lawicel)';
  @override
  bool get available => true; // libserialport ships with the app on all three OSes
  /// With CANable 2.0 (or compatible) FD firmware.
  @override
  bool get supportsFd => true;
  @override
  String get unavailableReason => '';

  /// When true (default) only ports that answer the SLCAN version query are
  /// listed. Turn off to see every serial port — the escape hatch for an
  /// adapter whose firmware doesn't implement `V`.
  bool probe = true;

  /// Where the port list comes from; a test hands in a pty.
  @visibleForTesting
  static List<String> Function() listPorts = () => SerialPort.availablePorts;

  /// Emulated adapters (e.g. a network bridge) at /tmp/slcan*. They are ptys,
  /// which libserialport neither lists nor opens, so they are found by name.
  @visibleForTesting
  static List<String> Function() listVirtualPorts = () {
    if (Platform.isWindows) return [];
    try {
      return [
        for (final e in Directory('/tmp').listSync(followLinks: false))
          if (e.uri.pathSegments.last.startsWith('slcan') && isPtyPath(e.path))
            e.path
      ]..sort();
    } on FileSystemException {
      return [];
    }
  };

  @override
  Future<List<CanDevice>> discover() async {
    final infos = listPorts().map(_inspect).toList();
    final virtual = [
      for (final p in listVirtualPorts()) CanDevice(id, p, 'Virtual SLCAN — $p'),
    ];

    if (!probe) {
      return [
        ...virtual,
        for (final i in infos)
          CanDevice(id, i.path,
              i.description == null || i.description!.isEmpty
                  ? i.path
                  : '${i.path} — ${i.description}'),
      ];
    }

    final candidates =
        infos.where((i) => slcanWorthProbing(i.path, i.transport)).toList();
    if (candidates.isEmpty) return virtual;
    final paths = candidates.map((i) => i.path).toList();
    // Each probe blocks up to 300 ms; keep that off the UI isolate.
    final probes = await Isolate.run(() => paths.map(probeSlcanPort).toList());

    final out = <CanDevice>[...virtual];
    for (var k = 0; k < candidates.length; k++) {
      final i = candidates[k];
      final (detected, version) = probes[k];
      final hint = slcanNameHint(i.vid, i.pid, i.product, i.manufacturer);
      if (!detected && hint == null) continue;
      final name = hint ?? 'SLCAN adapter';
      final fw = version == null ? '' : ' v$version';
      out.add(CanDevice(id, i.path, '$name$fw — ${i.path}'));
    }
    return out;
  }

  @override
  CanBus create() => SlcanBus();
}
