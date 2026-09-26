// ASAM MDF 4.1 (.mf4) with the ASAM bus-logging layout: CAN_DataFrame,
// CAN_RemoteFrame and CAN_ErrorFrame channel groups, each record carrying a
// float64 time stamp plus the frame's composed fields. asammdf, CANape and
// CANoe read these as a CAN bus log and can decode them against a DBC.
//
// Writing streams: every block but the data block is laid out up front, the
// DT block is last and grows while recording. Until [close] the file is
// flagged unfinalised ("UnFinMF "), so a crash still leaves a file MDF tools
// know how to recover.
//
// Reading handles DT, DZ (deflate, optionally transposed), DL and HL data,
// sorted and unsorted groups, and data bytes stored inline, in SD blocks or
// in VLSD channel groups — which covers what the common loggers write.
import 'dart:convert';
import 'dart:io' show ZLibCodec;
import 'dart:typed_data';

import '../can.dart';
import 'log.dart';
import 'sink.dart';

// ---------------------------------------------------------------------------
// writing

class _Block {
  final String id;
  final List<_Block?> links;
  final Uint8List data;
  int at = 0;

  _Block(this.id, this.links, Uint8List data)
      : data = data.length % 8 == 0
            ? data
            : (Uint8List((data.length + 7) & ~7)..setRange(0, data.length, data));

  int get size => 24 + 8 * links.length + data.length;

  Uint8List encode() {
    final w = LeWriter()
      ..chars('##$id', 4)
      ..u32(0)
      ..u64(size)
      ..u64(links.length);
    for (final l in links) {
      w.u64(l?.at ?? 0);
    }
    w.bytes(data);
    return w.take();
  }
}

_Block _text(String id, String s) =>
    _Block(id, const [], Uint8List.fromList([...utf8.encode(s), 0]));

// cn_data_type
const _dtUint = 0;
const _dtUintBe = 1;
const _dtFloat = 4;
const _dtFloatBe = 5;
const _dtBytes = 10;

const _cnBusEvent = 0x400;
const _cgBusEvent = 0x02 | 0x04; // bus event, plain bus event

class _Field {
  final String name;
  final int byte, bits, bitOffset, dataType;
  const _Field(this.name, this.byte, this.bits,
      {this.bitOffset = 0, this.dataType = _dtUint});
}

/// Record layouts, byte offsets after the 1-byte record id. Offset 0 is the
/// float64 time stamp in seconds since the measurement start.
const _dataFields = [
  _Field('BusChannel', 8, 8),
  _Field('ID', 9, 29),
  _Field('IDE', 12, 1, bitOffset: 7),
  _Field('DLC', 13, 4),
  _Field('DataLength', 14, 7),
  _Field('DataBytes', 15, 64, dataType: _dtBytes),
  _Field('Dir', 23, 1),
];
const _remoteFields = [
  _Field('BusChannel', 8, 8),
  _Field('ID', 9, 29),
  _Field('IDE', 12, 1, bitOffset: 7),
  _Field('DLC', 13, 4),
  _Field('DataLength', 14, 7),
  _Field('Dir', 15, 1),
];
const _errorFields = [
  _Field('BusChannel', 8, 8),
  _Field('ErrorType', 9, 8),
  _Field('Dir', 10, 1),
];

class Mf4Writer extends LogWriter {
  late final _Block _dt;
  final _cgs = <_Block>[];
  final _cycles = [0, 0, 0];
  var _dataStart = 0;

  Mf4Writer(super.sink, super.start) {
    final si = _Block('SI', [_text('TX', 'CAN'), null, null],
        Uint8List.fromList([2, 2, 0, 0, 0, 0, 0, 0])); // bus source, CAN
    final unit = _text('TX', 's');

    _Block cn(String name,
            {int type = 0,
            int sync = 0,
            required int dataType,
            int bitOffset = 0,
            required int byte,
            required int bits,
            int flags = 0,
            _Block? composition,
            _Block? next,
            _Block? source,
            _Block? unitBlock}) =>
        _Block('CN', [next, composition, _text('TX', name), source, null, null, unitBlock, null],
            (LeWriter()
                  ..u8(type)
                  ..u8(sync)
                  ..u8(dataType)
                  ..u8(bitOffset)
                  ..u32(byte)
                  ..u32(bits)
                  ..u32(flags)
                  ..u32(0) // invalidation bit
                  ..u8(0) // precision
                  ..u8(0)
                  ..u16(0) // attachments
                  ..zeros(48)) // ranges and limits
                .take());

    _Block group(String frame, int recordId, int recordBytes, List<_Field> fields,
        _Block? next) {
      _Block? child;
      for (final f in fields.reversed) {
        child = cn('$frame.${f.name}',
            dataType: f.dataType, bitOffset: f.bitOffset, byte: f.byte, bits: f.bits, next: child);
      }
      final composed = cn(frame,
          dataType: _dtBytes,
          byte: 8,
          bits: (recordBytes - 8) * 8,
          flags: _cnBusEvent,
          composition: child,
          source: si);
      final time = cn('Timestamp',
          type: 2, sync: 1, dataType: _dtFloat, byte: 0, bits: 64,
          next: composed, unitBlock: unit);
      return _Block('CG', [next, time, _text('TX', 'CAN'), si, null, null],
          (LeWriter()
                ..u64(recordId)
                ..u64(0) // cycle count, patched on close
                ..u16(_cgBusEvent)
                ..u16(0x2E) // path separator '.'
                ..zeros(4)
                ..u32(recordBytes)
                ..u32(0))
              .take());
    }

    final error = group('CAN_ErrorFrame', 3, 16, _errorFields, null);
    final remote = group('CAN_RemoteFrame', 2, 16, _remoteFields, error);
    final data = group('CAN_DataFrame', 1, 24, _dataFields, remote);
    _cgs.addAll([data, remote, error]);

    _dt = _Block('DT', const [], Uint8List(0));
    final dg = _Block('DG', [null, data, _dt, null],
        Uint8List.fromList([1, 0, 0, 0, 0, 0, 0, 0])); // 1-byte record ids
    final fhComment = _text(
        'MD',
        '<FHcomment><TX>Recorded by Pantrace</TX><tool_id>Pantrace</tool_id>'
            '<tool_vendor>PanterSoft</tool_vendor><tool_version>1</tool_version></FHcomment>');
    final now = DateTime.now();
    final fh = _Block('FH', [null, fhComment],
        (LeWriter()
              ..u64(now.microsecondsSinceEpoch * 1000)
              ..i16(0)
              ..i16(0)
              ..u8(0)
              ..zeros(3))
            .take());
    final hd = _Block('HD', [dg, fh, null, null, null, null],
        (LeWriter()
              ..u64(start.microsecondsSinceEpoch * 1000) // UTC
              ..i16(0)
              ..i16(0)
              ..u8(0)
              ..u8(0)
              ..u8(0)
              ..u8(0)
              ..f64(0)
              ..f64(0))
            .take());

    // Every block collected in file order; DT last so its data can grow.
    final all = <_Block>[];
    void visit(_Block? b) {
      if (b == null || all.contains(b) || b == _dt) return;
      all.add(b);
      b.links.forEach(visit);
    }

    visit(hd);
    all.add(_dt);
    var at = 64;
    for (final b in all) {
      b.at = at;
      at += b.size;
    }
    sink.add(_idBlock(finished: false));
    for (final b in all) {
      sink.add(b.encode());
    }
    _dataStart = sink.length;
  }

  static Uint8List _idBlock({required bool finished}) => (LeWriter()
        ..chars(finished ? 'MDF     ' : 'UnFinMF ', 8)
        ..chars('4.10    ', 8)
        ..chars('Pantrace', 8)
        ..zeros(4)
        ..u16(410)
        ..zeros(30)
        // unfinalised: cycle counters (0x1) and last DT length (0x4) stale
        ..u16(finished ? 0 : 0x05)
        ..u16(0))
      .take();

  @override
  void writeFrame(CanFrame f) {
    final t = micros(f) / 1e6;
    final w = LeWriter();
    final dir = f.direction == FrameDirection.tx ? 1 : 0;
    final ch = (f.channel + 1) & 0xFF;
    if (f.isError) {
      w
        ..u8(3)
        ..f64(t)
        ..u8(ch)
        ..u8(0) // error type unknown
        ..u8(dir)
        ..zeros(5);
      _cycles[2]++;
    } else {
      final idField = (f.id & 0x1FFFFFFF) | (f.extended ? 0x80000000 : 0);
      final n = f.data.length.clamp(0, 8);
      w
        ..u8(f.rtr ? 2 : 1)
        ..f64(t)
        ..u8(ch)
        ..u32(idField)
        ..u8(n)
        ..u8(f.rtr ? 0 : n);
      if (f.rtr) {
        w.u8(dir);
        _cycles[1]++;
      } else {
        w
          ..bytes(Uint8List(8)..setRange(0, n, f.data))
          ..u8(dir);
        _cycles[0]++;
      }
    }
    sink.add(w.take());
  }

  @override
  Future<void> close() async {
    final dataLen = sink.length - _dataStart;
    sink.patch(_dt.at + 8, (LeWriter()..u64(24 + dataLen)).take());
    for (var i = 0; i < _cgs.length; i++) {
      sink.patch(_cgs[i].at + 24 + 6 * 8 + 8, (LeWriter()..u64(_cycles[i])).take());
    }
    sink.patch(0, _idBlock(finished: true));
    await sink.close();
  }
}

// ---------------------------------------------------------------------------
// reading

class _Blk {
  final String id;
  final int at, length;
  final List<int> links;
  final int dataAt;
  _Blk(this.id, this.at, this.length, this.links, this.dataAt);
}

class _Cn {
  final String name;
  final int type, sync, dataType, bitOffset, byteOffset, bits;
  final int cc, data;
  _Cn(this.name, this.type, this.sync, this.dataType, this.bitOffset,
      this.byteOffset, this.bits, this.cc, this.data);
}

class _Cg {
  final int at, recordId, dataBytes, invalBytes, flags;
  final List<_Cn> channels;
  _Cg(this.at, this.recordId, this.dataBytes, this.invalBytes, this.flags, this.channels);
  bool get vlsd => flags & 1 != 0;

  /// VLSD payloads by stream offset, for a VLSD group.
  final vlsdData = <int, Uint8List>{};
  var vlsdOffset = 0;
}

class _Mdf {
  final Uint8List bytes;
  final ByteData d;
  final zlib = ZLibCodec();
  _Mdf(this.bytes) : d = ByteData.sublistView(bytes);

  int u64(int at) => d.getUint64(at, Endian.little);

  _Blk block(int at) {
    if (at <= 0 || at + 24 > bytes.length) {
      throw LogFormatException('MF4 link to offset $at is outside the file');
    }
    final id = String.fromCharCodes(bytes.sublist(at, at + 4));
    if (!id.startsWith('##')) {
      throw LogFormatException('MF4 has no block at offset $at');
    }
    final len = u64(at + 8);
    final n = u64(at + 16);
    return _Blk(id.substring(2), at, len,
        [for (var i = 0; i < n; i++) u64(at + 24 + 8 * i)], at + 24 + 8 * n);
  }

  String text(int at) {
    if (at == 0) return '';
    final b = block(at);
    var end = b.dataAt;
    while (end < b.at + b.length && end < bytes.length && bytes[end] != 0) {
      end++;
    }
    return utf8.decode(bytes.sublist(b.dataAt, end), allowMalformed: true);
  }

  /// Concatenated payload of a data block or list of data blocks.
  Uint8List data(int at) {
    if (at == 0) return Uint8List(0);
    final b = block(at);
    switch (b.id) {
      case 'DT' || 'SD' || 'RD':
        return Uint8List.sublistView(bytes, b.dataAt, b.at + b.length);
      case 'DZ':
        final zipType = bytes[b.dataAt + 2];
        final param = d.getUint32(b.dataAt + 4, Endian.little);
        final orgLen = u64(b.dataAt + 8);
        final zLen = u64(b.dataAt + 16);
        final raw = Uint8List.fromList(
            zlib.decode(Uint8List.sublistView(bytes, b.dataAt + 24, b.dataAt + 24 + zLen)));
        if (zipType == 1 && param > 0) {
          // Transposed: columns of each record's bytes; the tail that does
          // not fill a whole row is stored as is.
          final rows = orgLen ~/ param;
          final out = Uint8List(raw.length);
          for (var c = 0; c < param; c++) {
            for (var r = 0; r < rows; r++) {
              out[r * param + c] = raw[c * rows + r];
            }
          }
          out.setRange(rows * param, raw.length, raw, rows * param);
          return out;
        }
        return raw;
      case 'DL':
        final out = BytesBuilder(copy: false);
        for (var dl = b; ;) {
          for (final l in dl.links.skip(1)) {
            if (l != 0) out.add(data(l));
          }
          if (dl.links.isEmpty || dl.links[0] == 0) break;
          dl = block(dl.links[0]);
        }
        return out.takeBytes();
      case 'HL':
        return data(b.links[0]);
      default:
        throw LogFormatException('Unsupported MF4 data block ##${b.id}');
    }
  }

  List<_Cn> channels(int at) {
    final out = <_Cn>[];
    while (at != 0) {
      final b = block(at);
      if (b.id != 'CN') break;
      final p = b.dataAt;
      out.add(_Cn(
        text(b.links[2]),
        bytes[p],
        bytes[p + 1],
        bytes[p + 2],
        bytes[p + 3],
        d.getUint32(p + 4, Endian.little),
        d.getUint32(p + 8, Endian.little),
        b.links[4],
        b.links[5],
      ));
      final comp = b.links[1];
      if (comp != 0 && block(comp).id == 'CN') out.addAll(channels(comp));
      at = b.links[0];
    }
    return out;
  }

  /// Unsigned value of a little- or big-endian integer field.
  int uint(Uint8List rec, int byteOffset, int bitOffset, int bits, bool bigEndian) {
    final nBytes = (bitOffset + bits + 7) >> 3;
    if (byteOffset + nBytes > rec.length) return 0;
    if (nBytes > 7) {
      final v = ByteData.sublistView(rec, byteOffset, byteOffset + 8)
          .getUint64(0, bigEndian ? Endian.big : Endian.little);
      return bits >= 64 ? v : (v >> bitOffset) & ((1 << bits) - 1);
    }
    var v = 0;
    for (var i = 0; i < nBytes; i++) {
      v |= rec[byteOffset + (bigEndian ? nBytes - 1 - i : i)] << (8 * i);
    }
    return (v >> bitOffset) & ((1 << bits) - 1);
  }

  double number(_Cn c, Uint8List rec) {
    double raw;
    if (c.dataType == _dtFloat || c.dataType == _dtFloatBe) {
      final e = c.dataType == _dtFloat ? Endian.little : Endian.big;
      if (c.byteOffset + c.bits ~/ 8 > rec.length) return 0;
      final bd = ByteData.sublistView(rec, c.byteOffset);
      raw = c.bits == 32 ? bd.getFloat32(0, e) : bd.getFloat64(0, e);
    } else {
      raw = uint(rec, c.byteOffset, c.bitOffset, c.bits, c.dataType == _dtUintBe)
          .toDouble();
    }
    if (c.cc == 0) return raw;
    final cc = block(c.cc);
    final type = bytes[cc.dataAt];
    final valCount = d.getUint16(cc.dataAt + 6, Endian.little);
    if (type == 1 && valCount >= 2) {
      final a = d.getFloat64(cc.dataAt + 24, Endian.little);
      final b = d.getFloat64(cc.dataAt + 32, Endian.little);
      return a + b * raw;
    }
    return raw;
  }
}

const _kinds = ['CAN_DataFrame', 'CAN_RemoteFrame', 'CAN_ErrorFrame'];

DecodedLog readMf4(Uint8List bytes) {
  if (bytes.length < 64 ||
      !(String.fromCharCodes(bytes.sublist(0, 3)) == 'MDF' ||
          String.fromCharCodes(bytes.sublist(0, 8)) == 'UnFinMF ')) {
    throw LogFormatException('Not an MDF file');
  }
  final m = _Mdf(bytes);
  final version = m.d.getUint16(28, Endian.little);
  if (version < 400) {
    throw LogFormatException('MDF $version is not supported, only MDF 4.x');
  }
  final hd = m.block(64);
  final startNs = m.u64(hd.dataAt);
  final localTime = bytes[hd.dataAt + 12] & 1 != 0;
  var start = DateTime.fromMicrosecondsSinceEpoch(startNs ~/ 1000, isUtc: localTime);
  if (localTime) {
    // The stamp is wall-clock time with no zone: keep the fields.
    start = DateTime(start.year, start.month, start.day, start.hour, start.minute,
        start.second, start.millisecond, start.microsecond);
  } else {
    start = start.toLocal();
  }

  final frames = <(double, int, CanFrame)>[];
  var skipped = 0;
  // ASAM counts bus channels from 1, but some writers (python-can) from 0.
  var zeroBased = false;

  for (var dgAt = hd.links[0]; dgAt != 0;) {
    final dg = m.block(dgAt);
    final ridSize = bytes[dg.dataAt];
    final cgs = <int, _Cg>{};
    final byAddr = <int, _Cg>{};
    for (var cgAt = dg.links[1]; cgAt != 0;) {
      final cg = m.block(cgAt);
      final p = cg.dataAt;
      final g = _Cg(
        cg.at,
        m.u64(p),
        m.d.getUint32(p + 24, Endian.little),
        m.d.getUint32(p + 28, Endian.little),
        m.d.getUint16(p + 16, Endian.little),
        m.channels(cg.links[1]),
      );
      cgs[g.recordId] = g;
      byAddr[g.at] = g;
      cgAt = cg.links[0];
    }

    final data = m.data(dg.links[2]);
    // Pass 1 splits the stream into records (and collects VLSD payloads);
    // pass 2 decodes them, so a record can reference VLSD data in any order.
    final records = <(_Cg, Uint8List)>[];
    var pos = 0;
    while (pos < data.length) {
      _Cg? g;
      if (ridSize == 0) {
        g = cgs.values.length == 1 ? cgs.values.first : null;
      } else {
        if (pos + ridSize > data.length) break;
        g = cgs[m.uint(data, pos, 0, ridSize * 8, false)];
        pos += ridSize;
      }
      if (g == null) break; // unknown record id: the rest is unreadable
      if (g.vlsd) {
        if (pos + 4 > data.length) break;
        final n = ByteData.sublistView(data).getUint32(pos, Endian.little);
        g.vlsdData[g.vlsdOffset] = Uint8List.sublistView(data, pos + 4, pos + 4 + n);
        g.vlsdOffset += 4 + n;
        pos += 4 + n;
        continue;
      }
      final len = g.dataBytes + g.invalBytes;
      if (pos + len > data.length) break;
      records.add((g, Uint8List.sublistView(data, pos, pos + len)));
      pos += len;
    }

    final sdCache = <int, Uint8List>{};
    Uint8List? vlsdBytes(_Cn c, Uint8List rec) {
      final offset = m.uint(rec, c.byteOffset, c.bitOffset, c.bits, false);
      final vg = byAddr[c.data];
      if (vg != null) return vg.vlsdData[offset];
      final sd = sdCache.putIfAbsent(c.data, () => m.data(c.data));
      if (offset + 4 > sd.length) return null;
      final n = ByteData.sublistView(sd, offset, offset + 4).getUint32(0, Endian.little);
      if (offset + 4 + n > sd.length) return null;
      return Uint8List.sublistView(sd, offset + 4, offset + 4 + n);
    }

    for (final (g, rec) in records) {
      final kind = _kinds.indexWhere(
          (k) => g.channels.any((c) => c.name == k || c.name.startsWith('$k.')));
      if (kind < 0) continue; // not a CAN group
      _Cn? field(String suffix) {
        for (final c in g.channels) {
          if (c.name.startsWith(_kinds[kind]) && c.name.endsWith('.$suffix')) return c;
        }
        return null;
      }

      final master = g.channels.where((c) => c.type == 2 || c.type == 3).firstOrNull;
      final seconds = master == null || master.type == 3 ? 0.0 : m.number(master, rec);
      final t = start.add(Duration(microseconds: (seconds * 1e6).round()));
      int? val(String name) {
        final c = field(name);
        return c == null ? null : m.uint(rec, c.byteOffset, c.bitOffset, c.bits, c.dataType == _dtUintBe);
      }

      // Raw bus channel for now; whether it counts from 0 or 1 is decided
      // for the whole file below.
      final channel = val('BusChannel') ?? 1;
      if (channel == 0) zeroBased = true;
      final dir = val('Dir') == 1 ? FrameDirection.tx : FrameDirection.rx;
      if (kind == 2) {
        frames.add((seconds, frames.length, CanFrame.error('error frame', timestamp: t, channel: channel)));
        continue;
      }
      final idField = field('ID');
      if (idField == null) {
        skipped++;
        continue;
      }
      final rawId = m.uint(rec, idField.byteOffset, idField.bitOffset, idField.bits, false);
      final id = rawId & 0x1FFFFFFF;
      final ide = field('IDE');
      final extended = ide != null
          ? val('IDE') == 1
          : (rawId & 0x80000000 != 0 || id > 0x7FF);
      final dlc = val('DLC') ?? 0;
      if (kind == 1) {
        frames.add((seconds, frames.length,
            CanFrame(id: id, extended: extended, rtr: true, data: Uint8List(0),
                timestamp: t, direction: dir, channel: channel)));
        continue;
      }
      if ((val('EDL') ?? 0) == 1) {
        skipped++; // CAN FD
        continue;
      }
      final length = val('DataLength') ?? (dlc > 8 ? 8 : dlc);
      if (length > 8) {
        skipped++;
        continue;
      }
      final db = field('DataBytes');
      Uint8List? payload;
      if (db == null) {
        payload = Uint8List(0);
      } else if (db.type == 1) {
        payload = vlsdBytes(db, rec);
      } else if (db.byteOffset + length <= rec.length) {
        payload = Uint8List.sublistView(rec, db.byteOffset, db.byteOffset + length);
      }
      if (payload == null || payload.length < length) {
        skipped++;
        continue;
      }
      frames.add((seconds, frames.length,
          CanFrame(id: id, extended: extended, data: Uint8List.fromList(payload.sublist(0, length)),
              timestamp: t, direction: dir, channel: channel)));
    }
    dgAt = dg.links[0];
  }
  // Sorted files keep each frame type in its own group; merge them back into
  // one timeline, keeping file order among equal stamps.
  frames.sort((a, b) {
    final c = a.$1.compareTo(b.$1);
    return c != 0 ? c : a.$2.compareTo(b.$2);
  });
  return DecodedLog([
    for (final (_, _, f) in frames)
      zeroBased || f.channel == 0 ? f : f.withChannel(f.channel - 1)
  ], skipped);
}
