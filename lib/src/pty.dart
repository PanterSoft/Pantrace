// Pseudo-terminal: a /dev/tty… path other programs open like a serial port.
// Share creates one; the SLCAN backend connects to ones other programs create.
import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';


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
typedef _ErrnoC = Pointer<Int32> Function();

class Pty {
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
  static final _errno = _lib.lookupFunction<_ErrnoC, _ErrnoC>(
      Platform.isMacOS ? '__error' : '__errno_location');

  static const _oRdwr = 2, _fGetfl = 3, _fSetfl = 4;
  static final _oNoctty = Platform.isMacOS ? 0x20000 : 0x100;
  static final _oNonblock = Platform.isMacOS ? 0x4 : 0x800;
  static final _eAgain = Platform.isMacOS ? 35 : 11;
  static const _eIntr = 4;

  /// [fd] is what we read and write; [_held] is the other end kept open (or -1).
  final int fd, _held;
  final String path;
  final Pointer<Uint8> _buf = calloc<Uint8>(4096);
  Timer? _poll;

  Pty._(this.fd, this._held, this.path);

  /// A new pty other programs open at [path]; we talk on the master side.
  factory Pty.create() {
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
    _makeRaw(s);
    _fcntl(m, _fSetfl, _fcntl(m, _fGetfl, 0) | _oNonblock);
    return Pty._(m, s, path);
  }

  /// Opens an existing pty someone else created, e.g. a bridge emulating an
  /// SLCAN adapter at /tmp/slcan0. libserialport can't: sp_open() fails with
  /// ENOTTY on the modem-line ioctls a pty doesn't have.
  factory Pty.connect(String path) {
    final nameC = path.toNativeUtf8();
    final fd = _open(nameC, _oRdwr | _oNoctty | _oNonblock);
    calloc.free(nameC);
    if (fd < 0) throw OSError('cannot open $path');
    _makeRaw(fd);
    return Pty._(fd, -1, path);
  }

  /// Raw mode stops the line discipline from mangling the CRs.
  static void _makeRaw(int fd) {
    final tio = calloc<Uint8>(512); // larger than termios on either OS
    try {
      _tcgetattr(fd, tio);
      _cfmakeraw(tio);
      _tcsetattr(fd, 0, tio);
    } finally {
      calloc.free(tio);
    }
  }

  /// [onHangup] fires once the other end is gone (EOF, or EIO on macOS), which
  /// only happens on a [Pty.connect] pty: [Pty.create] holds its slave open.
  void start(void Function(List<int>) onBytes, {void Function()? onHangup}) {
    // ponytail: polled like the FFI backends. Frames written while no client
    // has the port open queue in the pty (a few KB) and arrive stale on open.
    _poll = Timer.periodic(const Duration(milliseconds: 2), (_) {
      for (;;) {
        final n = _read(fd, _buf, 4096);
        if (n < 0 && [_eAgain, _eIntr].contains(_errno().value)) return;
        if (n <= 0) {
          if (onHangup != null) {
            _poll?.cancel();
            onHangup();
          }
          return;
        }
        onBytes(Uint8List.fromList(_buf.asTypedList(n)));
      }
    });
  }

  void write(List<int> bytes) {
    final p = calloc<Uint8>(bytes.length);
    p.asTypedList(bytes.length).setAll(0, bytes);
    _write(fd, p, bytes.length); // full buffer: drop, like a real overrun
    calloc.free(p);
  }

  bool _closed = false;

  void close() {
    if (_closed) return; // a second close would free _buf twice
    _closed = true;
    _poll?.cancel();
    if (_held >= 0) _close(_held);
    _close(fd);
    calloc.free(_buf);
  }
}
