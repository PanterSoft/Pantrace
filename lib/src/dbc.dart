// DBC (Vector CANdb) parser and signal decoder. Pure Dart, fully unit-tested.
import 'dart:typed_data';

enum ByteOrder { motorola, intel } // @0 = motorola/big, @1 = intel/little

class DbcSignal {
  final String name;
  final int startBit;
  final int length;
  final ByteOrder byteOrder;
  final bool signed;
  final double factor;
  final double offset;
  final double min;
  final double max;
  final String unit;
  final List<String> receivers;

  /// null = not multiplexed, -1 = this signal IS the multiplexor ('M'),
  /// >=0 = only present when the multiplexor equals this value, e.g. 'm3').
  final int? multiplexValue;

  /// Value table from VAL_, e.g. {0: 'Off', 1: 'On'}.
  final Map<int, String> valueTable;

  String comment;

  DbcSignal({
    required this.name,
    required this.startBit,
    required this.length,
    required this.byteOrder,
    required this.signed,
    required this.factor,
    required this.offset,
    required this.min,
    required this.max,
    required this.unit,
    required this.receivers,
    this.multiplexValue,
    Map<int, String>? valueTable,
    this.comment = '',
  }) : valueTable = valueTable ?? {};

  bool get isMultiplexor => multiplexValue == -1;

  /// Pull this signal's raw integer out of [data].
  ///
  /// Bit numbering follows the DBC convention: bit i lives in byte i~/8 at
  /// position i%8, where position 0 is the byte's LSB.
  int rawFrom(Uint8List data) {
    var raw = 0;
    if (byteOrder == ByteOrder.intel) {
      for (var i = 0; i < length; i++) {
        final bit = startBit + i;
        final byte = bit >> 3;
        if (byte >= data.length) break;
        raw |= ((data[byte] >> (bit & 7)) & 1) << i;
      }
    } else {
      // Motorola: start at the MSB and walk down through the sawtooth layout,
      // hopping to bit 7 of the next byte each time we fall off a byte.
      var bit = startBit;
      for (var i = 0; i < length; i++) {
        final byte = bit >> 3;
        if (byte >= data.length) {
          raw <<= 1;
        } else {
          raw = (raw << 1) | ((data[byte] >> (bit & 7)) & 1);
        }
        if ((bit & 7) == 0) {
          bit += 15;
        } else {
          bit -= 1;
        }
      }
    }
    if (signed && length < 64 && (raw & (1 << (length - 1))) != 0) {
      raw -= 1 << length;
    }
    return raw;
  }

  /// Write [raw] into [data] at this signal's bit positions (mirror of [rawFrom]).
  void rawInto(Uint8List data, int raw) {
    if (byteOrder == ByteOrder.intel) {
      for (var i = 0; i < length; i++) {
        final bit = startBit + i;
        final byte = bit >> 3;
        if (byte >= data.length) break;
        final mask = 1 << (bit & 7);
        data[byte] = ((raw >> i) & 1) != 0 ? data[byte] | mask : data[byte] & ~mask;
      }
    } else {
      var bit = startBit;
      for (var i = 0; i < length; i++) {
        final byte = bit >> 3;
        if (byte < data.length) {
          final mask = 1 << (bit & 7);
          final v = (raw >> (length - 1 - i)) & 1;
          data[byte] = v != 0 ? data[byte] | mask : data[byte] & ~mask;
        }
        if ((bit & 7) == 0) {
          bit += 15;
        } else {
          bit -= 1;
        }
      }
    }
  }

  double decode(Uint8List data) => rawFrom(data) * factor + offset;

  int encodeRaw(double physical) => ((physical - offset) / factor).round();

  /// Human-readable value: value-table name if one matches, else scaled number.
  String format(Uint8List data) {
    final raw = rawFrom(data);
    final named = valueTable[raw];
    if (named != null) return '$named ($raw)';
    final phys = raw * factor + offset;
    final text = (factor == factor.roundToDouble() && offset == offset.roundToDouble())
        ? phys.toStringAsFixed(phys == phys.roundToDouble() ? 0 : 3)
        : phys.toStringAsFixed(3);
    return unit.isEmpty ? text : '$text $unit';
  }
}

class DbcMessage {
  final int id;
  final bool extended;
  final String name;
  final int length;
  final String sender;
  final List<DbcSignal> signals;
  String comment;

  /// Sent as CAN FD: the VFrameFormat attribute says so, or it is longer than
  /// a classic frame can carry.
  bool get fd => fdFormat || length > 8;
  bool fdFormat = false;

  DbcMessage({
    required this.id,
    required this.extended,
    required this.name,
    required this.length,
    required this.sender,
    required this.signals,
    this.comment = '',
  });

  DbcSignal? get multiplexor =>
      signals.where((s) => s.isMultiplexor).firstOrNull;

  /// Signals actually present in this particular frame, resolving multiplexing.
  List<DbcSignal> signalsFor(Uint8List data) {
    final mux = multiplexor;
    if (mux == null) return signals;
    final sel = mux.rawFrom(data);
    return signals
        .where((s) => s.multiplexValue == null || s.multiplexValue == -1 || s.multiplexValue == sel)
        .toList();
  }
}

class DbcDatabase {
  final Map<int, DbcMessage> messages; // keyed by the composite key below
  final List<String> nodes;

  DbcDatabase(this.messages, this.nodes);

  /// DBC stores the extended flag in bit 31 of the message id; we keep the two
  /// apart in [DbcMessage] but still need one lookup key.
  static int key(int id, bool extended) => extended ? (id | 0x80000000) : id;

  DbcMessage? lookup(int id, bool extended) {
    return messages[key(id, extended)] ??
        // Some tools emit standard ids without the flag even for 29-bit frames.
        messages[key(id, !extended)];
  }

  int get messageCount => messages.length;
  int get signalCount =>
      messages.values.fold(0, (sum, m) => sum + m.signals.length);
}

class DbcParseException implements Exception {
  final String message;
  final int line;
  DbcParseException(this.message, this.line);
  @override
  String toString() => 'DBC parse error on line $line: $message';
}

final _boRe = RegExp(r'^BO_\s+(\d+)\s+([A-Za-z0-9_]+)\s*:\s*(\d+)\s+([A-Za-z0-9_]+)');
final _sgRe = RegExp(
  r'^SG_\s+([A-Za-z0-9_]+)\s*(M|m\d+)?\s*:\s*'
  r'(\d+)\|(\d+)@([01])([+-])\s*'
  r'\(([^,]+),([^)]+)\)\s*'
  r'\[([^|]*)\|([^\]]*)\]\s*'
  r'"([^"]*)"\s*(.*)$',
);
final _frameFormatRe = RegExp(r'^BA_\s+"VFrameFormat"\s+BO_\s+(\d+)\s+(\d+)\s*;');
final _valRe = RegExp(r'^VAL_\s+(\d+)\s+([A-Za-z0-9_]+)\s+(.*);');
final _valPairRe = RegExp(r'(-?\d+)\s+"([^"]*)"');
final _cmMsgRe = RegExp(r'^CM_\s+BO_\s+(\d+)\s+"(.*)"\s*;', dotAll: true);
final _cmSigRe = RegExp(r'^CM_\s+SG_\s+(\d+)\s+([A-Za-z0-9_]+)\s+"(.*)"\s*;', dotAll: true);
final _buRe = RegExp(r'^BU_\s*:\s*(.*)$');

/// Parse DBC source text. Unknown sections are skipped rather than fatal —
/// real-world DBCs carry plenty of tool-specific noise we don't need.
DbcDatabase parseDbc(String source) {
  final messages = <int, DbcMessage>{};
  var nodes = <String>[];
  // Signal lookup by (rawId, signalName) so VAL_/CM_ can attach afterwards.
  final byRawId = <int, DbcMessage>{};

  final lines = source.split(RegExp(r'\r?\n'));
  DbcMessage? current;

  for (var i = 0; i < lines.length; i++) {
    final line = lines[i].trim();
    if (line.isEmpty) continue;

    if (line.startsWith('BO_ ')) {
      final m = _boRe.firstMatch(line);
      if (m == null) throw DbcParseException('malformed BO_: $line', i + 1);
      final rawId = int.parse(m.group(1)!);
      final extended = (rawId & 0x80000000) != 0;
      final msg = DbcMessage(
        id: rawId & 0x1FFFFFFF,
        extended: extended,
        name: m.group(2)!,
        length: int.parse(m.group(3)!),
        sender: m.group(4)!,
        signals: [],
      );
      messages[DbcDatabase.key(msg.id, extended)] = msg;
      byRawId[rawId] = msg;
      current = msg;
      continue;
    }

    if (line.startsWith('SG_ ')) {
      if (current == null) continue; // orphan signal, ignore
      final m = _sgRe.firstMatch(line);
      if (m == null) throw DbcParseException('malformed SG_: $line', i + 1);
      final muxTag = m.group(2);
      int? mux;
      if (muxTag == 'M') {
        mux = -1;
      } else if (muxTag != null && muxTag.startsWith('m')) {
        mux = int.parse(muxTag.substring(1));
      }
      current.signals.add(DbcSignal(
        name: m.group(1)!,
        startBit: int.parse(m.group(3)!),
        length: int.parse(m.group(4)!),
        byteOrder: m.group(5) == '1' ? ByteOrder.intel : ByteOrder.motorola,
        signed: m.group(6) == '-',
        factor: double.parse(m.group(7)!.trim()),
        offset: double.parse(m.group(8)!.trim()),
        min: double.tryParse(m.group(9)!.trim()) ?? 0,
        max: double.tryParse(m.group(10)!.trim()) ?? 0,
        unit: m.group(11)!,
        receivers: m.group(12)!.trim().split(RegExp(r'[,\s]+')).where((s) => s.isNotEmpty).toList(),
        multiplexValue: mux,
      ));
      continue;
    }

    if (line.startsWith('BU_')) {
      final m = _buRe.firstMatch(line);
      if (m != null) {
        nodes = m.group(1)!.trim().split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
      }
      current = null;
      continue;
    }

    if (line.startsWith('VAL_ ')) {
      final m = _valRe.firstMatch(line);
      if (m == null) continue;
      final msg = byRawId[int.parse(m.group(1)!)];
      final sig = msg?.signals.where((s) => s.name == m.group(2)).firstOrNull;
      if (sig == null) continue;
      for (final p in _valPairRe.allMatches(m.group(3)!)) {
        sig.valueTable[int.parse(p.group(1)!)] = p.group(2)!;
      }
      continue;
    }

    if (line.startsWith('CM_ ')) {
      // Comments may wrap across lines; gather until the terminating semicolon.
      var block = line;
      var j = i;
      while (!block.trimRight().endsWith(';') && j + 1 < lines.length) {
        j++;
        block += '\n${lines[j]}';
      }
      i = j;
      final ms = _cmSigRe.firstMatch(block);
      if (ms != null) {
        final msg = byRawId[int.parse(ms.group(1)!)];
        final sig = msg?.signals.where((s) => s.name == ms.group(2)).firstOrNull;
        if (sig != null) sig.comment = ms.group(3)!;
        continue;
      }
      final mm = _cmMsgRe.firstMatch(block);
      if (mm != null) {
        byRawId[int.parse(mm.group(1)!)]?.comment = mm.group(2)!;
      }
      continue;
    }

    // VFrameFormat 14 / 15 is StandardCAN_FD / ExtendedCAN_FD.
    final fdm = _frameFormatRe.firstMatch(line);
    if (fdm != null) {
      final v = int.parse(fdm.group(2)!);
      byRawId[int.parse(fdm.group(1)!)]?.fdFormat = v == 14 || v == 15;
      continue;
    }

    // BO_TX_BU_, other BA_, SIG_VALTYPE_, NS_, etc. — not needed for tracing.
    if (line.startsWith('BO_') || line.startsWith('SG_')) continue;
  }

  return DbcDatabase(messages, nodes);
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
