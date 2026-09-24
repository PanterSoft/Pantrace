import 'dart:async';

import 'package:pantrace/src/backends/slcan.dart';

/// Runs around every test file. Widget tests must not probe the machine's
/// real serial ports: that happens in an isolate, which fake async never
/// drains, and it would poke at whatever adapter is plugged in.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  SlcanBackend.listPorts = () => [];
  SlcanBackend.listVirtualPorts = () => [];
  await testMain();
}
