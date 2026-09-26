// Vector Binary Logging Format (.blf), CANoe/CANalyzer's native log.
//
// A 144-byte file header, then LOBJ objects. Frames are CAN_MESSAGE objects
// batched into zlib-compressed LOG_CONTAINER objects, the way Vector's own
// tools write them. Layouts follow python-can's reader/writer, which is what
// the open-source CAN tools interoperate against.
import 'dart:io' show ZLibCodec;
import 'dart:typed_data';

import '../can.dart';
import 'log.dart';
import 'sink.dart';

const _fileHeaderSize = 144;
const _objBaseSize = 16;
const _objV1Size = 16;
const _containerHeaderSize = 16;

const _canMessage = 1;
const _canError = 2;
const _logContainer = 10;
const _canErrorExt = 73;
const _canMessage2 = 86;
const _canFdMessage = 100;
const _canFdMessage64 = 101;

const _extFlag = 0x80000000;
const _txFlag = 0x01;
const _remoteFlag = 0x80;
const _timeTenMics = 1;
const _timeOneNanos = 2;

/// Windows SYSTEMTIME, which BLF uses for the measurement start and stop.
void _systemTime(LeWriter w, DateTime t) {
  w
    ..u16(t.year)
    ..u16(t.month)
    ..u16(t.weekday % 7) // Sunday = 0
    ..u16(t.day)
    ..u16(t.hour)
    ..u16(t.minute)
    ..u16(t.second)
    ..u16(t.millisecond);
}

DateTime? _readSystemTime(ByteData d, int at) {
  int u(int i) => d.getUint16(at + 2 * i, Endian.little);
  if (u(0) == 0) return null;
  return DateTime(u(0), u(1), u(3), u(4), u(5), u(6), u(7));
}

class BlfWriter extends LogWriter {
  /// ponytail: 128 KiB of objects per container, like CANoe and python-can.
  static const containerSize = 128 * 1024;

  final _objects = BytesBuilder(copy: false);
  var _objectCount = 0;
  var _uncompressed = _fileHeaderSize;
  late DateTime _stop = start;
  final _zlib = ZLibCodec(level: 6);

  BlfWriter(super.sink, super.start) {
    sink.add(_header(0));
  }

  Uint8List _header(int fileSize) {
    final w = LeWriter()
      ..chars('LOGG', 4)
      ..u32(_fileHeaderSize)
      // application id (5 = CANoe, what readers expect of a CAN log),
      // application version, BL API version 2.6.8.1
      ..bytes([5, 0, 0, 0, 2, 6, 8, 1])
      ..u64(fileSize)
      ..u64(_uncompressed)
      ..u32(_objectCount)
      ..u32(0);
    _systemTime(w, start);
    _systemTime(w, _stop);
    w.zeros(_fileHeaderSize - w.length);
    return w.take();
  }

  void _object(int type, Uint8List payload, int ns) {
    final size = _objBaseSize + _objV1Size + payload.length;
    final w = LeWriter()
      ..chars('LOBJ', 4)
      ..u16(_objBaseSize + _objV1Size)
      ..u16(1) // header version
      ..u32(size)
      ..u32(type)
      ..u32(_timeOneNanos)
      ..u16(0) // client index
      ..u16(0) // object version
      ..u64(ns)
      ..bytes(payload)
      ..align(4);
    _objects.add(w.take());
    _objectCount++;
    if (_objects.length >= containerSize) _flush();
  }

  @override
  void writeFrame(CanFrame f) {
    if (f.timestamp.isAfter(_stop)) _stop = f.timestamp;
    final ns = micros(f) * 1000;
    final ch = f.channel + 1;
    if (f.isError) {
      // CAN_ERROR_EXT: channel, length, flags, ecc, position, dlc, frame
      // length, id, extended flags, data.
      final w = LeWriter()
        ..u16(ch)
        ..u16(0)
        ..u32(0)
        ..zeros(4)
        ..u32(0)
        ..u32(0)
        ..u16(0)
        ..zeros(2)
        ..zeros(8);
      _object(_canErrorExt, w.take(), ns);
      return;
    }
    final data = Uint8List(8)..setRange(0, f.data.length.clamp(0, 8), f.data);
    final w = LeWriter()
      ..u16(ch)
      ..u8((f.direction == FrameDirection.tx ? _txFlag : 0) | (f.rtr ? _remoteFlag : 0))
      ..u8(f.data.length.clamp(0, 8))
      ..u32(f.id | (f.extended ? _extFlag : 0))
      ..bytes(data);
    _object(_canMessage, w.take(), ns);
  }

  /// Compresses the pending objects into one LOG_CONTAINER.
  void _flush() {
    if (_objects.isEmpty) return;
    final raw = _objects.takeBytes();
    final packed = _zlib.encode(raw);
    final size = _objBaseSize + _containerHeaderSize + packed.length;
    final w = LeWriter()
      ..chars('LOBJ', 4)
      ..u16(_objBaseSize)
      ..u16(1)
      ..u32(size)
      ..u32(_logContainer)
      ..u16(2) // zlib deflate
      ..zeros(6)
      ..u32(raw.length)
      ..zeros(4)
      ..bytes(packed)
      // python-can pads containers by size % 4 and its reader expects it.
      ..zeros(size % 4);
    sink.add(w.take());
    _uncompressed += _objBaseSize + _containerHeaderSize + raw.length;
  }

  @override
  Future<void> close() async {
    _flush();
    sink.patch(0, _header(sink.length));
    await sink.close();
  }
}

/// Reads a BLF. Supports compressed and uncompressed containers and bare
/// top-level objects; CAN FD frames are counted as skipped.
DecodedLog readBlf(Uint8List bytes) {
  if (bytes.length < 48 || String.fromCharCodes(bytes.sublist(0, 4)) != 'LOGG') {
    throw LogFormatException('Not a BLF file (no LOGG signature)');
  }
  final d = ByteData.sublistView(bytes);
  final headerSize = d.getUint32(4, Endian.little);
  final start = _readSystemTime(d, 40) ?? DateTime.fromMillisecondsSinceEpoch(0);
  final frames = <CanFrame>[];
  var skipped = 0;
  final zlib = ZLibCodec();

  void parseObject(ByteData o, int pos) {
    final headerLen = o.getUint16(pos + 4, Endian.little);
    final version = o.getUint16(pos + 6, Endian.little);
    final type = o.getUint32(pos + 12, Endian.little);
    if (version != 1 && version != 2) return;
    final flags = o.getUint32(pos + 16, Endian.little);
    final ts = o.getUint64(pos + 24, Endian.little);
    final us = flags == _timeTenMics ? ts * 10 : ts ~/ 1000;
    final t = start.add(Duration(microseconds: us));
    final p = pos + headerLen;
    switch (type) {
      case _canMessage || _canMessage2:
        final ch = o.getUint16(p, Endian.little) - 1;
        final fl = o.getUint8(p + 2);
        final dlc = o.getUint8(p + 3).clamp(0, 8);
        final id = o.getUint32(p + 4, Endian.little);
        final rtr = fl & _remoteFlag != 0;
        frames.add(CanFrame(
          id: id & 0x1FFFFFFF,
          extended: id & _extFlag != 0,
          rtr: rtr,
          data: rtr
              ? Uint8List(0)
              : Uint8List.fromList(
                  o.buffer.asUint8List(o.offsetInBytes + p + 8, dlc)),
          timestamp: t,
          direction: fl & _txFlag != 0 ? FrameDirection.tx : FrameDirection.rx,
          channel: ch < 0 ? 0 : ch,
        ));
      case _canError || _canErrorExt:
        final ch = o.getUint16(p, Endian.little) - 1;
        frames.add(CanFrame.error('error frame', timestamp: t, channel: ch < 0 ? 0 : ch));
      case _canFdMessage || _canFdMessage64:
        skipped++;
    }
  }

  /// Walks the objects in [data]; returns the offset of the first incomplete
  /// one, which the next container continues.
  int walk(ByteData data, int pos, int end) {
    while (pos + _objBaseSize <= end) {
      // Objects are padded; find the next signature within a few bytes.
      var found = -1;
      for (var i = pos; i < pos + 8 && i + 4 <= end; i++) {
        if (data.getUint32(i, Endian.little) == 0x4A424F4C) {
          // 'LOBJ'
          found = i;
          break;
        }
      }
      // Nothing yet, but the signature may straddle into the next container.
      if (found < 0) return pos + 8 > end ? pos : end;
      pos = found;
      if (pos + _objBaseSize > end) return pos;
      final size = data.getUint32(pos + 8, Endian.little);
      if (size < _objBaseSize) return end; // corrupt
      if (pos + size > end) return pos;
      final type = data.getUint32(pos + 12, Endian.little);
      if (type != _logContainer) parseObject(data, pos);
      pos += size;
    }
    return pos;
  }

  var carry = Uint8List(0);
  var pos = headerSize;
  while (pos + _objBaseSize <= bytes.length) {
    if (d.getUint32(pos, Endian.little) != 0x4A424F4C) {
      pos++; // padding between top-level objects
      continue;
    }
    final size = d.getUint32(pos + 8, Endian.little);
    final type = d.getUint32(pos + 12, Endian.little);
    if (size < _objBaseSize || pos + size > bytes.length) break; // truncated
    if (type == _logContainer) {
      final method = d.getUint16(pos + 16, Endian.little);
      final payload = bytes.sublist(pos + 32, pos + size);
      final List<int> inner;
      try {
        inner = method == 0 ? payload : zlib.decode(payload);
      } on FormatException {
        throw LogFormatException('BLF container at offset $pos is corrupt');
      }
      final merged = Uint8List(carry.length + inner.length)
        ..setRange(0, carry.length, carry)
        ..setRange(carry.length, carry.length + inner.length, inner);
      final md = ByteData.sublistView(merged);
      final rest = walk(md, 0, merged.length);
      carry = Uint8List.sublistView(merged, rest);
    } else {
      parseObject(d, pos);
    }
    pos += size;
  }
  return DecodedLog(frames, skipped);
}
