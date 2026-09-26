// Where log writers put their bytes. Pure Dart plus dart:io, no Flutter.
//
// The binary formats (BLF, MF4) only know their object counts and block
// lengths once the capture is over, so a sink is random access: append while
// recording, [patch] the header on close.
import 'dart:io';
import 'dart:typed_data';

abstract class ByteSink {
  /// Bytes written so far, i.e. the offset the next [add] lands at.
  int get length;
  void add(List<int> bytes);

  /// Overwrite already-written bytes at [offset].
  void patch(int offset, List<int> bytes);
  Future<void> close();
}

/// An in-memory sink, for exporting the trace buffer and for tests.
class MemorySink implements ByteSink {
  var _buf = Uint8List(4096);
  var _len = 0;

  @override
  int get length => _len;

  @override
  void add(List<int> bytes) {
    if (_len + bytes.length > _buf.length) {
      var cap = _buf.length * 2;
      while (cap < _len + bytes.length) {
        cap *= 2;
      }
      _buf = Uint8List(cap)..setRange(0, _len, _buf);
    }
    _buf.setRange(_len, _len + bytes.length, bytes);
    _len += bytes.length;
  }

  @override
  void patch(int offset, List<int> bytes) {
    if (offset < 0 || offset + bytes.length > _len) {
      throw RangeError('patch outside written data');
    }
    _buf.setRange(offset, offset + bytes.length, bytes);
  }

  Uint8List get bytes => Uint8List.sublistView(_buf, 0, _len);

  @override
  Future<void> close() async {}
}

/// A file sink with a write-behind buffer: a busy bus is thousands of small
/// frames a second, and a syscall per frame is what makes loggers drop data.
class FileSink implements ByteSink {
  final RandomAccessFile _file;
  final _pending = BytesBuilder(copy: true);
  var _flushed = 0;

  /// Flushed at 64 KiB or after a second, whichever comes first, so a crash
  /// loses at most that much — even on a quiet bus.
  static const flushAt = 64 * 1024;
  static const flushAfter = Duration(seconds: 1);
  final _sinceFlush = Stopwatch()..start();

  FileSink._(this._file);

  /// Creates (or truncates) [path] for writing.
  static FileSink create(String path) =>
      FileSink._(File(path).openSync(mode: FileMode.write));

  @override
  int get length => _flushed + _pending.length;

  @override
  void add(List<int> bytes) {
    _pending.add(bytes);
    if (_pending.length >= flushAt || _sinceFlush.elapsed >= flushAfter) flush();
  }

  void flush() {
    _sinceFlush.reset();
    if (_pending.isEmpty) return;
    final chunk = _pending.takeBytes();
    _file.writeFromSync(chunk);
    _flushed += chunk.length;
  }

  @override
  void patch(int offset, List<int> bytes) {
    flush();
    _file
      ..setPositionSync(offset)
      ..writeFromSync(bytes)
      ..setPositionSync(_flushed);
  }

  /// Synchronous underneath: closing is quick, and it lets a recording be
  /// finished from dispose, where nothing waits for a future.
  @override
  Future<void> close() async {
    flush();
    _file.closeSync();
  }
}

/// Little-endian field builder for the binary formats.
class LeWriter {
  final _b = BytesBuilder(copy: false);
  final _scratch = ByteData(8);

  int get length => _b.length;

  void u8(int v) => _b.addByte(v & 0xFF);
  void u16(int v) {
    _scratch.setUint16(0, v, Endian.little);
    _b.add(Uint8List.fromList(_scratch.buffer.asUint8List(0, 2)));
  }

  void u32(int v) {
    _scratch.setUint32(0, v, Endian.little);
    _b.add(Uint8List.fromList(_scratch.buffer.asUint8List(0, 4)));
  }

  void i16(int v) => u16(v & 0xFFFF);

  void u64(int v) {
    _scratch.setUint64(0, v, Endian.little);
    _b.add(Uint8List.fromList(_scratch.buffer.asUint8List(0, 8)));
  }

  void f64(double v) {
    _scratch.setFloat64(0, v, Endian.little);
    _b.add(Uint8List.fromList(_scratch.buffer.asUint8List(0, 8)));
  }

  /// ASCII text in a fixed-size field, zero-padded (or cut).
  void chars(String s, int size) {
    final out = Uint8List(size);
    for (var i = 0; i < s.length && i < size; i++) {
      out[i] = s.codeUnitAt(i) & 0x7F;
    }
    _b.add(out);
  }

  void bytes(List<int> v) => _b.add(v);
  void zeros(int n) => _b.add(Uint8List(n));

  /// Pads with zeros to a multiple of [align].
  void align(int align) {
    final r = _b.length % align;
    if (r != 0) zeros(align - r);
  }

  Uint8List take() => _b.takeBytes();
}

/// Error thrown for a log file that cannot be read.
class LogFormatException implements Exception {
  final String message;
  LogFormatException(this.message);
  @override
  String toString() => message;
}
