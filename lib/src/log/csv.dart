// Pantrace's flat CSV: one row per frame, spreadsheet-friendly.
//
//   timestamp,channel,direction,id,extended,dlc,data,flags
//   2026-09-26T09:30:00.123456,1,rx,123,false,3,010203,
//   2026-09-26T09:30:00.150000,1,rx,300,false,12,00112233445566778899AABB,FD BRS
//   2026-09-26T09:30:00.200000,1,error,,,,"bus off"
//
// dlc is the payload length in bytes. flags lists RTR, FD, BRS and ESI.
import 'dart:convert';
import 'dart:typed_data';

import '../can.dart';
import 'log.dart';

const csvHeader = 'timestamp,channel,direction,id,extended,dlc,data,flags';

class CsvWriter extends LogWriter {
  CsvWriter(super.sink, super.start) {
    sink.add(utf8.encode('$csvHeader\n'));
  }

  @override
  void writeFrame(CanFrame f) {
    final t = f.timestamp.toIso8601String();
    final line = f.isError
        ? '$t,${f.channel + 1},error,,,,"${f.error!.replaceAll('"', '""')}"'
        : '$t,${f.channel + 1},${f.direction.name},${f.idHex},${f.extended},'
            '${f.data.length},${f.dataHex.replaceAll(' ', '')},'
            '${[if (f.rtr) 'RTR', if (f.fd) f.fdLabel].join(' ')}';
    sink.add(utf8.encode('$line\n'));
  }
}

DecodedLog readCsv(Uint8List bytes) {
  final frames = <CanFrame>[];
  var skipped = 0;
  for (final line in const LineSplitter().convert(utf8.decode(bytes, allowMalformed: true))) {
    if (line.isEmpty || line.startsWith('timestamp,')) continue;
    final c = line.split(',');
    if (c.length < 7) {
      skipped++;
      continue;
    }
    final t = DateTime.tryParse(c[0]);
    final ch = int.tryParse(c[1]);
    if (t == null || ch == null) {
      skipped++;
      continue;
    }
    if (c[2] == 'error') {
      var msg = c.sublist(6).join(',');
      if (msg.startsWith('"') && msg.endsWith('"') && msg.length >= 2) {
        msg = msg.substring(1, msg.length - 1).replaceAll('""', '"');
      }
      frames.add(CanFrame.error(msg, timestamp: t, channel: ch - 1));
      continue;
    }
    final id = int.tryParse(c[3], radix: 16);
    final flags = c.length > 7 ? c[7].trim().split(' ') : const <String>[];
    final fd = flags.contains('FD');
    final hex = c[6].trim();
    if (id == null || hex.length.isOdd || hex.length > (fd ? 128 : 16) ||
        !RegExp(r'^[0-9A-Fa-f]*$').hasMatch(hex)) {
      skipped++;
      continue;
    }
    final data = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < data.length; i++) {
      data[i] = int.parse(hex.substring(2 * i, 2 * i + 2), radix: 16);
    }
    frames.add(CanFrame(
      id: id,
      extended: c[4] == 'true',
      rtr: flags.contains('RTR'),
      fd: fd,
      brs: flags.contains('BRS'),
      esi: flags.contains('ESI'),
      data: data,
      timestamp: t,
      direction: c[2] == 'tx' ? FrameDirection.tx : FrameDirection.rx,
      channel: ch - 1,
    ));
  }
  return DecodedLog(frames, skipped);
}
