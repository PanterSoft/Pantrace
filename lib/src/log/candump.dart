// can-utils `candump -l` log: `(1695720600.123456) can0 123#DEADBEEF R`.
// canplayer, python-can and SavvyCAN read it. The trailing R/T direction is
// python-can's extension; can-utils ignores it.
import 'dart:convert';
import 'dart:typed_data';

import '../can.dart';
import 'log.dart';

/// Linux's CAN_ERR_FLAG: an 8-digit id with this bit set is an error frame.
const _errFlag = 0x20000000;
const _errBusError = 0x80;

class CandumpWriter extends LogWriter {
  CandumpWriter(super.sink, super.start);

  @override
  void writeFrame(CanFrame f) {
    final us = f.timestamp.microsecondsSinceEpoch;
    final ts = '${us ~/ 1000000}.${(us % 1000000).toString().padLeft(6, '0')}';
    final String frame;
    if (f.isError) {
      // Class CAN_ERR_BUSERROR: the controller saw an error frame on the bus.
      frame = '${(_errFlag | _errBusError).toRadixString(16).toUpperCase().padLeft(8, '0')}'
          '#0000000000000000';
    } else if (f.fd) {
      // `##` then one hex digit of flags: 1 = BRS, 2 = ESI.
      final flags = (f.brs ? 1 : 0) | (f.esi ? 2 : 0);
      frame = '${f.idHex}##${flags.toRadixString(16)}${f.dataHex.replaceAll(' ', '')}';
    } else if (f.rtr) {
      frame = '${f.idHex}#R${f.data.isEmpty ? '' : f.data.length}';
    } else {
      frame = '${f.idHex}#${f.dataHex.replaceAll(' ', '')}';
    }
    final dir = f.direction == FrameDirection.tx ? 'T' : 'R';
    sink.add(utf8.encode('($ts) can${f.channel} $frame $dir\n'));
  }
}

final _lineRe = RegExp(
    r'^\s*\((\d+)\.(\d+)\)\s+(\S+)\s+([0-9A-Fa-f]+)#(#?)([0-9A-Fa-fR.]*)\s*([RrTt])?\s*$');

DecodedLog readCandump(Uint8List bytes) {
  final frames = <CanFrame>[];
  final names = <String, int>{};
  var skipped = 0;
  for (final line in const LineSplitter().convert(latin1.decode(bytes))) {
    final m = _lineRe.firstMatch(line);
    if (m == null) continue;
    final frac = m.group(2)!.padRight(6, '0').substring(0, 6);
    final t = DateTime.fromMicrosecondsSinceEpoch(
        int.parse(m.group(1)!) * 1000000 + int.parse(frac));
    // canX / vcanX / slcanX number their channel; anything else is numbered
    // in order of first appearance.
    final iface = m.group(3)!;
    final digits = RegExp(r'(\d+)$').firstMatch(iface);
    final ch = digits != null
        ? int.parse(digits.group(1)!)
        : names.putIfAbsent(iface, () => names.length);
    final idText = m.group(4)!;
    final id = int.parse(idText, radix: 16);
    final extended = idText.length > 3;
    final dir = (m.group(7) ?? 'R').toUpperCase() == 'T'
        ? FrameDirection.tx
        : FrameDirection.rx;
    if (extended && id & _errFlag != 0) {
      frames.add(CanFrame.error('error frame (class 0x${(id & 0x1FFFFFFF).toRadixString(16)})',
          timestamp: t, channel: ch));
      continue;
    }
    var payload = m.group(6)!.replaceAll('.', '');
    final fd = m.group(5)!.isNotEmpty;
    var flags = 0;
    if (fd) {
      if (payload.isEmpty || payload.toUpperCase().startsWith('R')) {
        skipped++;
        continue;
      }
      flags = int.parse(payload[0], radix: 16);
      payload = payload.substring(1);
    }
    if (!fd && payload.toUpperCase().startsWith('R')) {
      frames.add(CanFrame(
          id: id & 0x1FFFFFFF, extended: extended, rtr: true, data: Uint8List(0),
          timestamp: t, direction: dir, channel: ch));
      continue;
    }
    if (payload.length.isOdd || payload.length > (fd ? 128 : 16)) {
      skipped++;
      continue;
    }
    final data = Uint8List(payload.length ~/ 2);
    for (var i = 0; i < data.length; i++) {
      data[i] = int.parse(payload.substring(2 * i, 2 * i + 2), radix: 16);
    }
    frames.add(CanFrame(
        id: id & 0x1FFFFFFF, extended: extended, data: data,
        fd: fd, brs: flags & 1 != 0, esi: flags & 2 != 0,
        timestamp: t, direction: dir, channel: ch));
  }
  return DecodedLog(frames, skipped);
}
