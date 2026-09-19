// Bus sharing: Pantrace owns the adapter and re-exposes it as SLCAN, so tools
// that speak SLCAN (python-can, SavvyCAN, cangaroo, Linux slcand) can use any
// backend at the same time as Pantrace — including ones whose driver can only
// be opened once, like a serial SLCAN stick or PCBUSB on macOS.
import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import 'backends/slcan.dart';
import 'can.dart';

const shareTcpPort = 20100;

/// Answer one SLCAN command line from a client. Frames go to [send]; every
/// other command gets a canned OK, because the bitrate and open state belong
/// to Pantrace's own connection, not to the client.
String slcanReply(String line, void Function(CanFrame) send) {
  if (line.isEmpty) return '\r';
  switch (line[0]) {
    case 't' || 'T' || 'r' || 'R':
      final f = parseSlcan(line);
      if (f == null) return '\x07';
      send(CanFrame(
          id: f.id, data: f.data, extended: f.extended, rtr: f.rtr,
          direction: FrameDirection.tx));
      return f.extended ? 'Z\r' : 'z\r';
    case 'V' || 'v':
      return 'V1013\r';
    case 'N':
      return 'NPANT\r';
    case 'F':
      return 'F00\r';
    case 'Z':
      return line == 'Z1' ? '\x07' : '\r'; // we forward frames without timestamps
    default:
      return '\r'; // O, C, S, s, M, m, X ... accepted and ignored
  }
}

class _Client {
  final void Function(List<int>) write;
  String buffer = '';
  _Client(this.write);
}

class CanShare {
  final CanBus bus;

  /// Called for every frame a client transmits, so the trace shows it too.
  final void Function(CanFrame) onClientSent;

  /// Buses that echo transmissions (the virtual one) already put client frames
  /// on the frames stream, so relaying them again would duplicate them.
  final bool busEchoes;

  final _clients = <_Client>{};
  ServerSocket? _server;
  StreamSubscription<CanFrame>? _busSub;
  _Pty? _pty;

  CanShare(this.bus, {required this.onClientSent, this.busEchoes = false});

  /// Starts the endpoints and returns a human-readable list of them.
  Future<List<String>> start() async {
    _busSub = bus.frames.listen(relay);
    final endpoints = <String>[];

    // Loopback only: anyone reaching this port can put frames on the bus.
    try {
      _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, shareTcpPort);
    } on SocketException {
      _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    }
    _server!.listen(_accept);
    endpoints.add('socket://127.0.0.1:${_server!.port}');

    if (Platform.isMacOS || Platform.isLinux) {
      try {
        _pty = _Pty.open();
        final c = _Client(_pty!.write);
        _clients.add(c);
        _pty!.start((bytes) => _onBytes(c, bytes));
        endpoints.add(_pty!.path);
      } catch (_) {
        // ponytail: TCP still works; the virtual serial port is a convenience.
      }
    }
    return endpoints;
  }

  void _accept(Socket s) {
    s.setOption(SocketOption.tcpNoDelay, true);
    // ponytail: a client that stops reading grows its socket buffer without
    // bound. Drop slow clients if that ever shows up on a saturated bus.
    final c = _Client(s.add);
    _clients.add(c);
    void drop() {
      _clients.remove(c);
      s.destroy();
    }
    s.done.ignore(); // a client vanishing mid-write is normal, not an error
    s.listen((d) => _onBytes(c, d), onDone: drop, onError: (_) => drop());
  }

  void _onBytes(_Client from, List<int> bytes) {
    from.buffer += String.fromCharCodes(bytes);
    final (lines, rest) = splitSlcanLines(from.buffer);
    from.buffer = rest;
    for (final line in lines) {
      from.write(slcanReply(line.trim(), (f) {
        bus.send(f).catchError((Object _) {});
        if (busEchoes) return;
        relay(f, except: from);
        onClientSent(f);
      }).codeUnits);
    }
  }

  /// Adds a client whose write always throws, to test that relay() drops a
  /// client that misbehaves instead of propagating the error. Tests only.
  @visibleForTesting
  void injectBrokenClientForTest(void Function() onWrite) =>
      _clients.add(_Client((_) => onWrite()));

  /// Forward a frame to every client except [except]. Pantrace's own Send
  /// calls this for backends that don't echo transmissions.
  void relay(CanFrame f, {Object? except}) {
    final line = encodeSlcan(f).codeUnits;
    for (final c in _clients.toList()) {
      if (identical(c, except)) continue;
      try {
        c.write(line);
      } catch (_) {
        _clients.remove(c);
      }
    }
  }

  Future<void> stop() async {
    await _busSub?.cancel();
    await _server?.close();
    _pty?.close();
    _clients.clear();
  }
}

// ---------------------------------------------------------------------------
// Pseudo-terminal: a /dev/tty… path other programs open like a serial port.
// ---------------------------------------------------------------------------

typedef _IntIntC = Int32 Function(Int32);
typedef _IntIntD = int Function(int);
typedef _OpenC = Int32 Function(Pointer<Utf8>, Int32);
typedef _OpenD = int Function(Pointer<Utf8>, int);
typedef _PtsnameC = Pointer<Utf8> Function(Int32);
typedef _PtsnameD = Pointer<Utf8> Function(int);
typedef _TcgetC = Int32 Function(Int32, Pointer<Uint8>);
typedef _TcgetD = int Function(int, Pointer<Uint8>);
typedef _TcsetC = Int32 Function(Int32, Int32, Pointer<Uint8>);
typedef _TcsetD = int Function(int, int, Pointer<Uint8>);
typedef _MakeRawC = Void Function(Pointer<Uint8>);
typedef _MakeRawD = void Function(Pointer<Uint8>);
typedef _RwC = IntPtr Function(Int32, Pointer<Uint8>, IntPtr);
typedef _RwD = int Function(int, Pointer<Uint8>, int);
// fcntl is variadic; Apple arm64 passes variadic args on the stack.
typedef _FcntlC = Int32 Function(Int32, Int32, VarArgs<(Int32,)>);
typedef _FcntlD = int Function(int, int, int);

class _Pty {
  static final _lib = DynamicLibrary.process();
  static final _openpt = _lib.lookupFunction<_IntIntC, _IntIntD>('posix_openpt');
  static final _grantpt = _lib.lookupFunction<_IntIntC, _IntIntD>('grantpt');
  static final _unlockpt = _lib.lookupFunction<_IntIntC, _IntIntD>('unlockpt');
  static final _ptsname = _lib.lookupFunction<_PtsnameC, _PtsnameD>('ptsname');
  static final _open = _lib.lookupFunction<_OpenC, _OpenD>('open');
  static final _tcgetattr = _lib.lookupFunction<_TcgetC, _TcgetD>('tcgetattr');
  static final _tcsetattr = _lib.lookupFunction<_TcsetC, _TcsetD>('tcsetattr');
  static final _cfmakeraw = _lib.lookupFunction<_MakeRawC, _MakeRawD>('cfmakeraw');
  static final _read = _lib.lookupFunction<_RwC, _RwD>('read');
  static final _write = _lib.lookupFunction<_RwC, _RwD>('write');
  static final _close = _lib.lookupFunction<_IntIntC, _IntIntD>('close');
  static final _fcntl = _lib.lookupFunction<_FcntlC, _FcntlD>('fcntl');

  static const _oRdwr = 2, _fGetfl = 3, _fSetfl = 4;
  static final _oNoctty = Platform.isMacOS ? 0x20000 : 0x100;
  static final _oNonblock = Platform.isMacOS ? 0x4 : 0x800;

  final int master, slave;
  final String path;
  final Pointer<Uint8> _buf = calloc<Uint8>(4096);
  Timer? _poll;

  _Pty._(this.master, this.slave, this.path);

  factory _Pty.open() {
    final m = _openpt(_oRdwr | _oNoctty);
    if (m < 0 || _grantpt(m) != 0 || _unlockpt(m) != 0) {
      throw const OSError('posix_openpt failed');
    }
    final path = _ptsname(m).toDartString();
    // Holding the slave open keeps the pty from hanging up between clients,
    // and raw mode stops the line discipline from mangling the CRs.
    final nameC = path.toNativeUtf8();
    final s = _open(nameC, _oRdwr | _oNoctty);
    calloc.free(nameC);
    final tio = calloc<Uint8>(512); // larger than termios on either OS
    try {
      _tcgetattr(s, tio);
      _cfmakeraw(tio);
      _tcsetattr(s, 0, tio);
    } finally {
      calloc.free(tio);
    }
    _fcntl(m, _fSetfl, _fcntl(m, _fGetfl, 0) | _oNonblock);
    return _Pty._(m, s, path);
  }

  void start(void Function(List<int>) onBytes) {
    // ponytail: polled like the FFI backends. Frames written while no client
    // has the port open queue in the pty (a few KB) and arrive stale on open.
    _poll = Timer.periodic(const Duration(milliseconds: 2), (_) {
      for (;;) {
        final n = _read(master, _buf, 4096);
        if (n <= 0) return;
        onBytes(Uint8List.fromList(_buf.asTypedList(n)));
      }
    });
  }

  void write(List<int> bytes) {
    final p = calloc<Uint8>(bytes.length);
    p.asTypedList(bytes.length).setAll(0, bytes);
    _write(master, p, bytes.length); // full buffer: drop, like a real overrun
    calloc.free(p);
  }

  void close() {
    _poll?.cancel();
    _close(slave);
    _close(master);
    calloc.free(_buf);
  }
}
