// Trace log files: recording, exporting and reading back the formats other
// CAN tools speak. Pure Dart, no Flutter — every format is round-trip tested.
//
//   .blf  Vector binary logging format (CANoe/CANalyzer's native log)
//   .asc  Vector ASCII log
//   .mf4  ASAM MDF 4.1 with the standard CAN bus-logging channel layout
//   .log  Linux can-utils candump -l
//   .trc  PEAK PCAN-View trace (version 1.1)
//   .csv  Pantrace's own flat table
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import '../can.dart';
import 'asc.dart';
import 'blf.dart';
import 'candump.dart';
import 'csv.dart';
import 'mf4.dart';
import 'sink.dart';
import 'trc.dart';

export 'sink.dart' show ByteSink, FileSink, MemorySink, LogFormatException;

enum LogFormat {
  blf('blf', 'Vector BLF', ['blf']),
  asc('asc', 'Vector ASC', ['asc']),
  mf4('mf4', 'ASAM MDF4', ['mf4', 'mdf']),
  candump('log', 'candump log', ['log']),
  trc('trc', 'PCAN trace', ['trc']),
  csv('csv', 'CSV', ['csv']);

  /// Extension a new file of this format gets.
  final String extension;
  final String label;

  /// Extensions recognised when reading.
  final List<String> extensions;

  const LogFormat(this.extension, this.label, this.extensions);

  /// The format a file name implies, or null if it implies none.
  static LogFormat? fromPath(String path) {
    final dot = path.lastIndexOf('.');
    if (dot < 0 || dot < path.lastIndexOf(RegExp(r'[/\\]'))) return null;
    final ext = path.substring(dot + 1).toLowerCase();
    for (final f in values) {
      if (f.extensions.contains(ext)) return f;
    }
    return null;
  }

  /// Every extension any format reads, for file dialogs.
  static List<String> get allExtensions =>
      [for (final f in values) ...f.extensions];
}

/// Streams frames into a log. Timestamps are written relative to [start]
/// (the measurement start), which the header records as wall-clock time.
abstract class LogWriter {
  final ByteSink sink;
  final DateTime start;
  int frames = 0;

  LogWriter(this.sink, this.start);

  void write(CanFrame f) {
    frames++;
    writeFrame(f);
  }

  void writeFrame(CanFrame f);

  /// Finishes the file (trailer, header patches) and closes the sink.
  Future<void> close() => sink.close();

  /// Microseconds since [start]; frames stamped marginally before the
  /// measurement started are clamped rather than written as negative times.
  int micros(CanFrame f) {
    final us = f.timestamp.difference(start).inMicroseconds;
    return us < 0 ? 0 : us;
  }
}

LogWriter createWriter(LogFormat format, ByteSink sink, DateTime start) =>
    switch (format) {
      LogFormat.blf => BlfWriter(sink, start),
      LogFormat.asc => AscWriter(sink, start),
      LogFormat.mf4 => Mf4Writer(sink, start),
      LogFormat.candump => CandumpWriter(sink, start),
      LogFormat.trc => TrcWriter(sink, start),
      LogFormat.csv => CsvWriter(sink, start),
    };

/// Result of reading a log: the frames, oldest first, and how many records
/// were recognised but not representable (CAN FD, other bus types).
class DecodedLog {
  final List<CanFrame> frames;
  final int skipped;
  const DecodedLog(this.frames, [this.skipped = 0]);
}

DecodedLog decodeLog(LogFormat format, Uint8List bytes) => switch (format) {
      LogFormat.blf => readBlf(bytes),
      LogFormat.asc => readAsc(bytes),
      LogFormat.mf4 => readMf4(bytes),
      LogFormat.candump => readCandump(bytes),
      LogFormat.trc => readTrc(bytes),
      LogFormat.csv => readCsv(bytes),
    };

/// [decodeLog] off the UI isolate for anything big enough to stall a frame;
/// a multi-megabyte BLF takes a while to inflate and parse.
Future<DecodedLog> decodeLogAsync(LogFormat format, Uint8List bytes) =>
    bytes.length < 256 * 1024
        ? Future.sync(() => decodeLog(format, bytes))
        : Isolate.run(() => decodeLog(format, bytes));

/// Encodes a finished list of frames, e.g. the trace buffer for an export.
/// The measurement start defaults to the first frame.
Future<Uint8List> encodeLog(LogFormat format, List<CanFrame> frames,
    {DateTime? start}) async {
  final sink = MemorySink();
  final w = createWriter(format, sink,
      start ?? (frames.isEmpty ? DateTime.now() : frames.first.timestamp));
  frames.forEach(w.write);
  await w.close();
  return sink.bytes;
}

/// Reads a log file, picking the format from its extension.
Future<DecodedLog> readLogFile(String path) async {
  final format = LogFormat.fromPath(path);
  if (format == null) {
    throw LogFormatException('Unknown log format: $path '
        '(expected ${LogFormat.allExtensions.map((e) => '.$e').join(', ')})');
  }
  return decodeLog(format, await File(path).readAsBytes());
}

/// A recording in progress: frames stream straight to disk, independent of the
/// trace view's ring buffer, pause state or filters — CANoe's logging block.
class LogRecorder {
  final String path;
  final LogFormat format;
  final LogWriter _writer;

  LogRecorder._(this.path, this.format, this._writer);

  /// Opens [path] for recording; the format follows the extension, falling
  /// back to [format] when the extension names none.
  static LogRecorder start(String path,
      {LogFormat format = LogFormat.blf, DateTime? start}) {
    final f = LogFormat.fromPath(path) ?? format;
    final sink = FileSink.create(path);
    final w = createWriter(f, sink, start ?? DateTime.now());
    sink.flush(); // the header is on disk before the first frame
    return LogRecorder._(path, f, w);
  }

  DateTime get started => _writer.start;
  int get frames => _writer.frames;
  int get bytes => _writer.sink.length;

  void write(CanFrame f) => _writer.write(f);
  Future<void> stop() => _writer.close();
}
