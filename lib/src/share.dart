// Bus sharing: Pantrace owns the adapter and re-exposes it as SLCAN, so tools
// that speak SLCAN (python-can, SavvyCAN, cangaroo, Linux slcand) can use any
// backend at the same time as Pantrace — including ones whose driver can only
// be opened once, like a serial SLCAN stick or PCBUSB on macOS.
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'backends/slcan.dart';
import 'can.dart';
import 'pty.dart';

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
  Pty? _pty;

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
        _pty = Pty.create();
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
