// Vector ASC: the line-per-event text log CANoe and CANalyzer write.
//
//   date Sat Sep 26 09:30:00.123 am 2026
//   base hex  timestamps absolute
//   internal events logged
//   Begin Triggerblock Sat Sep 26 09:30:00.123 am 2026
//      0.000000 Start of measurement
//      0.001234 1  123             Rx   d 8 00 11 22 33 44 55 66 77
//      0.002000 2  18FE6FFEx       Tx   r 8
//      0.003000 1  ErrorFrame
//   End TriggerBlock
//
// Channels are 1-based in the file, 0-based in [CanFrame].
import 'dart:convert';
import 'dart:typed_data';

import '../can.dart';
import 'log.dart';

const _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// ASC's header date, e.g. `Sat Sep 26 09:30:00.123 am 2026`.
String ascDate(DateTime t) {
  final h12 = t.hour % 12 == 0 ? 12 : t.hour % 12;
  String two(int v) => v.toString().padLeft(2, '0');
  return '${_days[t.weekday - 1]} ${_months[t.month - 1]} ${two(t.day)} '
      '${two(h12)}:${two(t.minute)}:${two(t.second)}.'
      '${t.millisecond.toString().padLeft(3, '0')} '
      '${t.hour < 12 ? 'am' : 'pm'} ${t.year}';
}

final _dateRe = RegExp(
    r'([A-Za-z]{3})\w*\s+(\d{1,2})\s+(\d{1,2}):(\d{2}):(\d{2})(?:[.,](\d+))?\s*(am|pm|AM|PM)?\s+(\d{4})');

/// Parses the date after `date` / `Begin Triggerblock`; null if unreadable
/// (e.g. localised month names from a German CANoe).
DateTime? parseAscDate(String s) {
  final m = _dateRe.firstMatch(s);
  if (m == null) return null;
  final month = _months.indexWhere(
      (x) => x.toLowerCase() == m.group(1)!.toLowerCase());
  if (month < 0) return null;
  var hour = int.parse(m.group(3)!);
  final ampm = m.group(7)?.toLowerCase();
  if (ampm == 'pm' && hour < 12) hour += 12;
  if (ampm == 'am' && hour == 12) hour = 0;
  final frac = m.group(6) ?? '0';
  final ms = int.parse(frac.padRight(3, '0').substring(0, 3));
  return DateTime(int.parse(m.group(8)!), month + 1, int.parse(m.group(2)!),
      hour, int.parse(m.group(4)!), int.parse(m.group(5)!), ms);
}

class AscWriter extends LogWriter {
  AscWriter(super.sink, super.start) {
    final d = ascDate(start);
    _line('date $d');
    _line('base hex  timestamps absolute');
    _line('internal events logged');
    _line('// version 13.0.0');
    _line('Begin Triggerblock $d');
    _line('   0.000000 Start of measurement');
  }

  void _line(String s) => sink.add(utf8.encode('$s\n'));

  static String time(int us) =>
      '${us ~/ 1000000}.${(us % 1000000).toString().padLeft(6, '0')}'
          .padLeft(11);

  @override
  void writeFrame(CanFrame f) {
    final ts = time(micros(f));
    final ch = f.channel + 1;
    if (f.isError) {
      _line('$ts $ch  ErrorFrame');
      return;
    }
    final id = '${f.id.toRadixString(16).toUpperCase()}${f.extended ? 'x' : ''}';
    final dir = f.direction == FrameDirection.tx ? 'Tx' : 'Rx';
    if (f.fd) {
      // Vector's CAN FD line: channel, dir, id, (symbolic name), BRS, ESI,
      // DLC (hex), data length (dec), data, then duration, bit count, flags,
      // CRC and four bit-timing words we do not know and leave at 0.
      final n = f.data.length.clamp(0, 64);
      final flags = 0x1000 | (f.brs ? 0x2000 : 0) | (f.esi ? 0x4000 : 0);
      _line('$ts CANFD ${'$ch'.padLeft(3)} ${dir.padRight(4)} ${id.padLeft(8)}  '
          '${''.padLeft(32)} ${f.brs ? 1 : 0} ${f.esi ? 1 : 0} '
          '${lengthToDlc(n).toRadixString(16)} ${'$n'.padLeft(2)}'
          '${n == 0 ? '' : ' ${f.dataHex}'} '
          '${'0'.padLeft(8)} ${'0'.padLeft(4)} ${flags.toRadixString(16).toUpperCase().padLeft(8)} '
          '${'0'.padLeft(8)} ${'0'.padLeft(8)} ${'0'.padLeft(8)} ${'0'.padLeft(8)} ${'0'.padLeft(8)}');
      return;
    }
    final len = f.data.length.toRadixString(16).toUpperCase();
    final body = f.rtr ? 'r $len' : 'd $len ${f.dataHex}';
    _line('$ts $ch  ${id.padRight(15)} ${dir.padRight(4)} $body'.trimRight());
  }

  @override
  Future<void> close() async {
    _line('End TriggerBlock');
    await sink.close();
  }
}

final _frameRe = RegExp(
    r'^\s*(\d+(?:\.\d+)?)\s+(\d+)\s+([0-9A-Fa-f]+)(x?)\s+(Rx|Tx|TxRq)\s+([dDrR])\s*([0-9A-Fa-f]+)?(.*)$');
final _errorRe = RegExp(r'^\s*(\d+(?:\.\d+)?)\s+(\d+)\s+ErrorFrame', caseSensitive: false);
final _eventRe = RegExp(r'^\s*\d+(?:\.\d+)?\s+(\S+)');
final _fdRe = RegExp(r'^\s*(\d+(?:\.\d+)?)\s+CANFD\s+(\d+)\s+(Rx|Tx)\s+(\S+)\s+(.*)$');

/// One CANFD line's fields after the id, or null when they do not parse.
({bool brs, bool esi, bool fd, bool rtr, Uint8List data})? _fdFields(String rest, int radix) {
  var t = rest.trim().split(RegExp(r'\s+'));
  // The symbolic name is optional; BRS is always 0 or 1.
  if (t.isNotEmpty && t[0] != '0' && t[0] != '1') t = t.sublist(1);
  if (t.length < 4) return null;
  final dlc = int.tryParse(t[2], radix: 16);
  final len = int.tryParse(t[3]);
  if (dlc == null || len == null || len > 64 || t.length < 4 + len) return null;
  final data = Uint8List(len);
  for (var i = 0; i < len; i++) {
    final v = int.tryParse(t[4 + i], radix: radix);
    if (v == null || v > 0xFF) return null;
    data[i] = v;
  }
  // Flags follow duration and bit count; without them it is an FD frame.
  final flags = t.length > 6 + len ? int.tryParse(t[6 + len], radix: 16) : null;
  return (
    brs: t[0] == '1',
    esi: t[1] == '1',
    fd: flags == null || flags & 0x1000 != 0,
    rtr: flags != null && flags & 0x10 != 0,
    data: data,
  );
}

DecodedLog readAsc(Uint8List bytes) {
  final text = latin1.decode(bytes, allowInvalid: true);
  var start = DateTime.fromMillisecondsSinceEpoch(0);
  var radix = 16;
  var relative = false;
  var last = 0.0;
  var skipped = 0;
  final frames = <CanFrame>[];

  DateTime at(double t) {
    final abs = relative ? last + t : t;
    last = abs;
    return start.add(Duration(microseconds: (abs * 1e6).round()));
  }

  for (final raw in const LineSplitter().convert(text)) {
    final line = raw.trimRight();
    final lower = line.trimLeft().toLowerCase();
    if (lower.startsWith('date ')) {
      start = parseAscDate(line) ?? start;
      continue;
    }
    if (lower.startsWith('base ')) {
      radix = lower.contains('base dec') ? 10 : 16;
      relative = lower.contains('timestamps relative');
      continue;
    }
    if (lower.startsWith('begin triggerblock')) {
      // A later trigger block restarts the time base.
      start = parseAscDate(line) ?? start;
      last = 0;
      continue;
    }
    final m = _frameRe.firstMatch(line);
    if (m != null) {
      final id = int.tryParse(m.group(3)!, radix: radix);
      if (id == null) continue;
      final rtr = m.group(6)!.toLowerCase() == 'r';
      final dlc = int.tryParse(m.group(7) ?? '0', radix: radix) ?? 0;
      final n = rtr ? 0 : (dlc > 8 ? 8 : dlc);
      final tokens = m.group(8)!.trim().split(RegExp(r'\s+'));
      final data = Uint8List(n);
      var ok = true;
      for (var i = 0; i < n; i++) {
        final v = i < tokens.length ? int.tryParse(tokens[i], radix: radix) : null;
        if (v == null || v > 0xFF) {
          ok = false;
          break;
        }
        data[i] = v;
      }
      if (!ok) {
        skipped++;
        continue;
      }
      frames.add(CanFrame(
        id: id,
        extended: m.group(4) == 'x' || id > 0x7FF,
        rtr: rtr,
        data: rtr ? Uint8List(0) : data,
        timestamp: at(double.parse(m.group(1)!)),
        direction: m.group(5) == 'Rx' ? FrameDirection.rx : FrameDirection.tx,
        channel: int.parse(m.group(2)!) - 1,
      ));
      continue;
    }
    final fdm = _fdRe.firstMatch(line);
    if (fdm != null) {
      final idText = fdm.group(4)!;
      final ext = idText.toLowerCase().endsWith('x');
      final id = int.tryParse(ext ? idText.substring(0, idText.length - 1) : idText, radix: radix);
      final f = _fdFields(fdm.group(5)!, radix);
      if (id == null || f == null) {
        skipped++;
        continue;
      }
      frames.add(CanFrame(
        id: id,
        extended: ext || id > 0x7FF,
        fd: f.fd,
        brs: f.fd && f.brs,
        esi: f.fd && f.esi,
        rtr: f.rtr,
        data: f.rtr ? Uint8List(0) : f.data,
        timestamp: at(double.parse(fdm.group(1)!)),
        direction: fdm.group(3) == 'Tx' ? FrameDirection.tx : FrameDirection.rx,
        channel: int.parse(fdm.group(2)!) - 1,
      ));
      continue;
    }
    final e = _errorRe.firstMatch(line);
    if (e != null) {
      frames.add(CanFrame.error('error frame',
          timestamp: at(double.parse(e.group(1)!)),
          channel: int.parse(e.group(2)!) - 1));
      continue;
    }
    // A CANFD line we could not read is a skipped record; LIN, statistics,
    // `Start of measurement` and friends are not frames at all.
    final ev = _eventRe.firstMatch(line);
    if (ev != null && ev.group(1)!.toUpperCase().startsWith('CANFD')) skipped++;
  }
  return DecodedLog(frames, skipped);
}
