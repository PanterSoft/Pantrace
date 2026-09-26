// The parts of the UI the virtual-bus walkthrough in app_test.dart does not
// reach: a hardware-style backend (no echo, errors, devices vanishing), file
// dialogs, sharing, the update flow, the macOS menu bar, and every toolbar
// control.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pantrace/main.dart';
import 'package:pantrace/src/backends/slcan.dart';
import 'package:pantrace/src/can.dart';
import 'package:pantrace/src/dbc.dart';
import 'package:pantrace/src/log/log.dart';
import 'package:pantrace/src/registry.dart';
import 'package:pantrace/src/trace.dart';
import 'package:pantrace/src/update.dart';

// --- a hardware-like backend -------------------------------------------------

class _FakeBus implements CanBus {
  final _frames = StreamController<CanFrame>.broadcast();
  final _status = StreamController<String>.broadcast();
  final sent = <CanFrame>[];
  bool _open = false;
  bool failOpen = false, failSend = false, breakFrames = false;

  @override
  Stream<CanFrame> get frames =>
      breakFrames ? throw StateError('adapter gone') : _frames.stream;
  @override
  Stream<String> get status => _status.stream;
  @override
  bool get isOpen => _open;
  @override
  Future<void> open(String address, int bitrate) async {
    if (failOpen) throw CanBusException('device unplugged');
    _open = true;
  }

  @override
  Future<void> close() async => _open = false;
  @override
  Future<void> send(CanFrame frame) async {
    if (failSend) throw CanBusException('tx queue full');
    sent.add(frame);
  }

  void inject(CanFrame f) => _frames.add(f);
  void report(String s) => _status.add(s);

  /// What a yanked USB adapter looks like: closed, then a status notice.
  void vanish() {
    _open = false;
    _status.add('device removed');
  }
}

class _FakeBackend implements CanBackend {
  final buses = <_FakeBus>[];
  bool failOpen = false;
  @override
  String get id => 'fake';
  @override
  String get name => 'Fake adapter';
  @override
  bool get available => true;
  @override
  String get unavailableReason => '';
  @override
  Future<List<CanDevice>> discover() async => const [
        CanDevice('fake', 'a', 'Fake adapter A'),
        CanDevice('fake', 'b', 'Fake adapter B'),
      ];
  @override
  CanBus create() {
    final b = _FakeBus()..failOpen = failOpen;
    buses.add(b);
    return b;
  }
}

// --- file dialogs ------------------------------------------------------------

final class _MemFile extends PlatformFile {
  final Uint8List bytes;
  @override
  final String name;
  _MemFile(this.name, this.bytes);
  @override
  Uri get uri => Uri.file('/tmp/$name');
  @override
  get xFile => throw UnimplementedError(); // type inherited: cross_file is not ours
  @override
  int? lengthSync() => bytes.length;
  @override
  Future<int> length() async => bytes.length;
  @override
  Future<Uint8List> readAsBytes() async => bytes;
  @override
  Stream<Uint8List> readAsByteStream() => Stream.value(bytes);
}

class _FakePicker extends MethodChannelFilePicker {
  PlatformFile? next;
  Uri? saveTo;
  Uint8List? saved;
  @override
  Future<PlatformFile?> pickFile({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async =>
      next;
  @override
  Future<Uri?> saveFile({
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
    String? dialogTitle,
    String? initialDirectory,
    Function(FilePickerStatus)? onFileSaving,
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    saved = bytes;
    return saveTo;
  }
}

// --- the macOS menu bar --------------------------------------------------------

class _FakeMenus extends PlatformMenuDelegate {
  List<PlatformMenuItem> menus = [];
  @override
  void setMenus(List<PlatformMenuItem> topLevelMenus) => menus = topLevelMenus;
  @override
  void clearMenus() => menus = [];
  @override
  bool debugLockDelegate(BuildContext context) => true;
  @override
  bool debugUnlockDelegate(BuildContext context) => true;

  /// [label] may be a path, 'Export As/CSV (.csv)…', where submenus repeat
  /// item labels.
  void select(String label) {
    PlatformMenuItem? find(Iterable<PlatformMenuItem> items, String label) {
      for (final i in items) {
        if (i.label == label) return i;
        final hit = find(i is PlatformMenuItemGroup ? i.members : i.descendants, label);
        if (hit != null) return hit;
      }
      return null;
    }

    PlatformMenuItem? item;
    Iterable<PlatformMenuItem> scope = menus;
    for (final part in label.split('/')) {
      item = find(scope, part);
      if (item == null) break;
      scope = item is PlatformMenu ? item.menus : const [];
    }
    expect(item, isNotNull, reason: 'no menu item "$label"');
    item!.onSelected!();
  }
}

// --- helpers -------------------------------------------------------------------

final fake = _FakeBackend();
final picker = _FakePicker();

Future<dynamic> pumpApp(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(1400, 800));
  await tester.pumpWidget(const PantraceApp());
  await tester.pumpAndSettle();
  return tester.state(find.byType(TracerPage));
}

Future<void> pick(WidgetTester tester, String dropdownKey, String item) async {
  await tester.tap(find.byKey(ValueKey(dropdownKey)));
  await tester.pumpAndSettle();
  await tester.tap(find.text(item).last);
  await tester.pumpAndSettle();
}

/// The overflow menu's update check, start to finish. Everything the check
/// touches — the closing menu, the HTTP round trip, the snack bar — has to
/// run in the real zone, or the request never completes.
Future<void> checkForUpdatesFromMenu(WidgetTester tester) async {
  await tester.runAsync(() async {
    await tester.tap(find.byIcon(Icons.more_vert));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.tap(find.text('Check for updates'));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
  });
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

/// The HTTP round trip runs on the real event loop while the widget code
/// waiting on it runs on the test's fake clock: alternate between the two
/// until the result has been rendered.
Future<void> settleNetwork(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }
}

/// Toasts raised under real async keep real timers, so fake time never
/// expires them; drop them so the next one is not queued behind.
void clearToasts(WidgetTester tester) =>
    tester.state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger)).clearSnackBars();

Finder inDialog(Finder f) => find.descendant(of: find.byType(AlertDialog), matching: f);

/// Log files → Export trace as → [format].
Future<void> exportAs(WidgetTester tester, String format) async {
  await tester.tap(find.text('Log files'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Export trace as'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(format));
  await tester.pumpAndSettle();
}

CanFrame frame(int id, List<int> data) => CanFrame(id: id, data: Uint8List.fromList(data));

void main() {
  setUpAll(() {
    backends.insert(0, fake);
    FilePickerPlatform.instance = picker;
  });
  tearDownAll(() => backends.remove(fake));
  setUp(() {
    fake.buses.clear();
    fake.failOpen = false;
    picker.next = null;
    picker.saveTo = null;
  });

  testWidgets('hardware backend: connect, trace, send, lose the device', (tester) async {
    final state = await pumpApp(tester);
    final TraceModel model = state.model;
    expect(model.statusLog.last, contains('scan: 2 CAN interfaces found'));

    // Both channels defaulted to the two adapters found; CAN1 connects.
    await tester.tap(find.text('Connect').first);
    await tester.pumpAndSettle();
    expect(find.text('Disconnect'), findsOneWidget);
    final bus = fake.buses.single;

    // The same physical interface cannot be traced twice.
    await pick(tester, 'device1', 'Fake adapter A');
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();
    expect(find.textContaining('already in use'), findsOneWidget);
    expect(fake.buses.length, 1);

    // Traffic and driver notices.
    bus.inject(frame(0x321, [1, 2]));
    bus.inject(frame(0x321, [1, 3]));
    bus.report('bus off');
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('321'), findsOneWidget);
    expect(model.statusLog.last, contains('CAN1: bus off'));

    // A driver that does not echo: the sent frame is traced and relayed here.
    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Identifier (hex)'), '7AB');
    await tester.tap(find.widgetWithText(FilledButton, 'Send'));
    await tester.pumpAndSettle();
    expect(bus.sent.single.idHex, '7AB');
    expect(find.text('7AB'), findsOneWidget);

    // Sending can fail; the dialog stays open and says why.
    bus.failSend = true;
    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Send'));
    await tester.pumpAndSettle();
    expect(find.textContaining('tx queue full'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    // The adapter goes away: the channel drops back to Connect on its own.
    bus.vanish();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Connect'), findsNWidgets(2));
    expect(model.statusLog.last, contains('device removed'));
  });

  testWidgets('a driver that refuses to open is reported, not fatal', (tester) async {
    fake.failOpen = true;
    final state = await pumpApp(tester);
    await tester.tap(find.text('Connect').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('device unplugged'), findsWidgets); // toast and status bar
    expect(find.text('Connect'), findsNWidgets(2));
    expect(state.model.statusLog.last, contains('CAN1: CanBusException: device unplugged'));
  });

  testWidgets('sharing a hardware bus, and failing to', (tester) async {
    final state = await pumpApp(tester);
    await tester.tap(find.text('Connect').first);
    await tester.pumpAndSettle();
    final bus = fake.buses.single;

    // Sockets and the pty are real I/O: run them for real.
    await tester.runAsync(() async {
      await tester.tap(find.text('Share').first);
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await tester.pump();
      expect(state.model.statusLog.last, contains('sharing bus as SLCAN on socket://'));
      expect(state.channels[0].share, isNotNull);

      // A frame sent from the UI is relayed to share clients too.
      await tester.tap(find.text('Send'));
      await tester.pump();
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Send'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
      expect(bus.sent, hasLength(1));

      // A frame from a share client is traced too (onClientSent).
      final port = int.parse(
          state.model.statusLog.last.split('socket://127.0.0.1:').last.split(' ').first);
      final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
      socket.write('t4560AB\r');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();
      expect(bus.sent, hasLength(2));
      expect(bus.sent.last.id, 0x456);
      socket.destroy();

      await tester.tap(find.text('Share').first);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();
      expect(state.channels[0].share, isNull);

      bus.breakFrames = true;
      await tester.tap(find.text('Share').first);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();
      expect(find.textContaining('Could not share the bus'), findsOneWidget);
      bus.breakFrames = false;

      await tester.tap(find.text('Disconnect'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();
    });
    expect(find.text('Connect'), findsNWidgets(2));
  });

  testWidgets('DBC and CSV go through the file dialogs', (tester) async {
    final state = await pumpApp(tester);
    final TraceModel model = state.model;

    // Cancelled dialog: nothing happens.
    await tester.tap(find.text('Load DBC').first);
    await tester.pumpAndSettle();
    expect(model.dbcs[0], isNull);

    picker.next = _MemFile('demo.dbc', File('example/demo.dbc').readAsBytesSync());
    await tester.tap(find.text('Load DBC').first);
    await tester.pumpAndSettle();
    expect(model.dbcPaths[0], 'demo.dbc');
    expect(model.statusLog.last, contains('loaded demo.dbc'));
    expect(find.text('DBC 1 '), findsOneWidget);

    picker.next = _MemFile('bad.dbc', utf8.encode('BO_ 291 X: 8 ECU\n SG_ broken\n'));
    await tester.tap(find.text('Load DBC').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('DBC parse error'), findsOneWidget);
    expect(model.dbcPaths[0], 'demo.dbc'); // the good one stays loaded

    await tester.tap(find.byTooltip('Unload demo.dbc'));
    await tester.pumpAndSettle();
    expect(model.dbcs[0], isNull);

    await tester.pump(const Duration(seconds: 5)); // let queued toasts expire
    model.add(frame(0x123, [1, 2, 3]));
    await exportAs(tester, 'CSV (.csv)');
    expect(picker.saved, isNotNull);
    expect(utf8.decode(picker.saved!), contains('123,false,3,010203'));
    expect(find.textContaining('Exported'), findsNothing); // cancelled

    picker.saveTo = Uri.file('/tmp/cantrace.csv');
    await exportAs(tester, 'CSV (.csv)');
    expect(find.textContaining('frames to /tmp/cantrace.csv'), findsOneWidget);
  });

  testWidgets('toolbar controls: bitrate, port probing, pause, clear, sort, filter',
      (tester) async {
    final state = await pumpApp(tester);
    final TraceModel model = state.model;

    await pick(tester, 'bitrate0', '250 kbit/s');
    expect(state.channels[0].bitrate, 250000);

    final slcan = backendById('slcan') as SlcanBackend;
    await tester.tap(find.text('All ports'));
    await tester.pumpAndSettle();
    expect(slcan.probe, isFalse);
    await tester.tap(find.text('All ports'));
    await tester.pumpAndSettle();
    expect(slcan.probe, isTrue);

    await tester.tap(find.byTooltip('Pause'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('PAUSED'), findsOneWidget);
    expect(model.paused, isTrue);
    await tester.tap(find.byTooltip('Resume'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('PAUSED'), findsNothing);

    model.add(frame(0x100, [1]));
    model.add(frame(0x200, [2, 2]));
    await tester.pump(const Duration(milliseconds: 100));
    for (final col in ['CH', 'MESSAGE / SIGNAL', 'LEN', 'DATA / VALUE', 'COUNT / RAW', 'CYCLE', 'ID', 'ID']) {
      await tester.tap(find.text(col));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(model.sort, TraceSort.id);
    expect(model.sortAscending, isFalse);
    expect(find.byIcon(Icons.arrow_downward), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, 'ID filter (hex)'), '200');
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('100'), findsNothing);
    expect(find.text('200'), findsNWidgets(2)); // the row and the filter field

    await tester.tap(find.byTooltip('Clear trace'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(model.totalFrames, 0);
    expect(find.textContaining('No frames yet'), findsOneWidget);
  });

  testWidgets('error frames stand out in the live view', (tester) async {
    final state = await pumpApp(tester);
    final TraceModel model = state.model;
    model.add(frame(0x100, [1]));
    model.add(CanFrame.error('bus off'));
    await tester.tap(find.text('Live'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('ERROR FRAME — bus off'), findsOneWidget);
    expect(find.text('Errors '), findsOneWidget);
  });

  testWidgets('send dialog validates the frame before it goes out', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.text('Connect').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();

    final id = find.widgetWithText(TextField, 'Identifier (hex)');
    final data = find.widgetWithText(TextField, 'Data (hex bytes)');
    final send = find.widgetWithText(FilledButton, 'Send');

    Future<void> expectError(String text) async {
      await tester.tap(send);
      await tester.pumpAndSettle();
      expect(find.text(text), findsOneWidget);
    }

    await tester.enterText(id, '');
    await expectError('ID must be hex');
    await tester.enterText(id, '800');
    await expectError('ID does not fit in an 11-bit identifier');
    await tester.tap(find.text('29-bit'));
    await tester.enterText(id, '20000000');
    await expectError('ID does not fit in an 29-bit identifier');
    await tester.enterText(id, '123');
    await tester.enterText(data, 'ABC');
    await expectError('Data needs whole bytes');
    await tester.enterText(data, '00 11 22 33 44 55 66 77 88');
    await expectError('Max 8 data bytes');

    // CAN2 is not connected, so its segment is disabled; CAN1 stays selected.
    await tester.tap(find.text('CAN2').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('RTR'));
    await tester.enterText(data, '');
    await tester.tap(send);
    await tester.pumpAndSettle();
    final f = fake.buses.single.sent.single;
    expect(f.extended, isTrue);
    expect(f.rtr, isTrue);
    expect(f.id, 0x123);
  });

  testWidgets('update flow: notice, install failure, download fallback', (tester) async {
    final launched = <String>[];
    final realLaunch = launch;
    launch = (cmd, args) async {
      launched.add(cmd);
      return ProcessResult(0, 0, '', '');
    };
    final mock = HttpOverrides.current;
    HttpOverrides.global = null;
    var tag = 'v99.0.0';
    late HttpServer server;
    await tester.runAsync(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        if (req.uri.path.endsWith('/releases/latest')) {
          req.response.write(jsonEncode({'tag_name': tag}));
        } else {
          req.response.statusCode = 404;
        }
        await req.response.close();
      });
    });
    apiBase = downloadBase = 'http://127.0.0.1:${server.port}';
    os = 'macos';
    try {
      await tester.runAsync(() async {
        await tester.pumpWidget(const PantraceApp());
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pump();
      expect(find.textContaining('v99.0.0 is available'), findsOneWidget);

      // Install: the download 404s, so we fall back to the browser. Taps run
      // under fake async (so animations finish); only the HTTP round trip
      // needs real time.
      await tester.pump(const Duration(seconds: 1));
      await tester.runAsync(() async {
        await tester.tap(find.text('Install'));
        await tester.pump();
        expect(find.text('Installing Pantrace v99.0.0'), findsOneWidget);
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.textContaining('Install failed'), findsOneWidget);
      expect(launched, ['open']);

      // Up to date: the manual check says so.
      tag = appVersion;
      clearToasts(tester);
      await checkForUpdatesFromMenu(tester);
      expect(find.textContaining('is the latest version'), findsOneWidget);

      // No self-install on this platform: offer the download page instead.
      tag = 'v99.0.1';
      os = 'linux';
      clearToasts(tester);
      await checkForUpdatesFromMenu(tester);
      await tester.tap(find.text('Download'));
      expect(launched, ['open', 'xdg-open']);
    } finally {
      os = Platform.operatingSystem;
      launch = realLaunch;
      apiBase = 'https://api.github.com';
      downloadBase = 'https://github.com';
      HttpOverrides.global = mock;
      await tester.runAsync(() => server.close(force: true));
    }
  });

  group('logging', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('pantrace_ui'));
    tearDown(() => dir.deleteSync(recursive: true));

    Future<void> menu(WidgetTester tester, String item) async {
      await tester.tap(find.text('Log files'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(item));
      await tester.pumpAndSettle();
    }

    testWidgets('record, stop, and the file holds what was on the bus', (tester) async {
      final state = await pumpApp(tester);
      final TraceModel model = state.model;
      await tester.tap(find.text('Connect').first);
      await tester.pumpAndSettle();
      final bus = fake.buses.single;

      // Cancelling the file dialog records nothing.
      await tester.tap(find.text('Record'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Vector BLF (.blf)'));
      await tester.pumpAndSettle();
      expect(model.recorder, isNull);

      final path = '${dir.path}/rec.blf';
      picker.saveTo = Uri.file(path);
      await tester.tap(find.text('Record'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Vector BLF (.blf)'));
      await tester.pumpAndSettle();
      expect(model.recorder, isNotNull);
      expect(find.text('Stop'), findsOneWidget);

      bus.inject(frame(0x321, [1, 2]));
      bus.inject(frame(0x322, [3]));
      model.setPaused(true);
      bus.inject(frame(0x323, [4]));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.textContaining('● REC'), findsOneWidget);
      expect(find.textContaining('rec.blf  3 frames'), findsOneWidget);

      await tester.tap(find.text('Stop'));
      await tester.pumpAndSettle();
      expect(model.recorder, isNull);
      expect(find.text('Recorded 3 frames to $path'), findsOneWidget);
      final log = decodeLog(LogFormat.blf, File(path).readAsBytesSync());
      expect(log.frames.map((f) => f.idHex), ['321', '322', '323']);
    });

    testWidgets('open a log into the trace, and the ways that fails', (tester) async {
      final state = await pumpApp(tester);
      final TraceModel model = state.model;

      picker.next = _MemFile('py.asc', File('test/fixtures/py.asc').readAsBytesSync());
      await menu(tester, 'Open log file…');
      expect(model.totalFrames, 32);
      expect(model.errorFrames, 1);
      expect(model.statusLog.last, endsWith('loaded 33 frames from py.asc'));
      clearToasts(tester);

      picker.next = _MemFile('notes.txt', Uint8List(3));
      await menu(tester, 'Open log file…');
      expect(find.textContaining('notes.txt: unknown log format'), findsOneWidget);
      clearToasts(tester);

      picker.next = _MemFile('bad.blf', Uint8List(64));
      await menu(tester, 'Open log file…');
      expect(find.textContaining('Could not read bad.blf'), findsOneWidget);
      clearToasts(tester);

      // Channels this trace does not have are dropped, and said so.
      picker.next = _MemFile('x.log', Uint8List.fromList(
          '(1.0) can0 100#01\n(1.1) can7 100#02\n(1.2) can0 100##1AA\n'.codeUnits));
      await menu(tester, 'Open log file…');
      expect(model.statusLog.last,
          endsWith('1 frames from x.log (1 unsupported records skipped, 1 frames on channels beyond CAN2)'));
    });

    testWidgets('export in any format; a typed extension wins', (tester) async {
      final state = await pumpApp(tester);
      final TraceModel model = state.model;
      model.add(frame(0x123, [1, 2, 3]));

      picker.saveTo = Uri.file('${dir.path}/out.blf');
      await exportAs(tester, 'Vector BLF (.blf)');
      expect(decodeLog(LogFormat.blf, picker.saved!).frames.single.idHex, '123');
      expect(find.text('Exported 1 frames to ${dir.path}/out.blf'), findsOneWidget);
      clearToasts(tester);

      // Picked MF4 in the menu, but typed .asc into the dialog.
      picker.saveTo = Uri.file('${dir.path}/typed.asc');
      await exportAs(tester, 'ASAM MDF4 (.mf4)');
      expect(File('${dir.path}/typed.asc').readAsStringSync(), contains('123'));
      clearToasts(tester);

      picker.saveTo = Uri.file('${dir.path}/missing/dir/x.asc');
      await exportAs(tester, 'CSV (.csv)');
      expect(find.textContaining('Export failed'), findsOneWidget);
    });

    testWidgets('replay a log onto the connected bus', (tester) async {
      final state = await pumpApp(tester);
      await tester.tap(find.text('Log files'));
      await tester.pumpAndSettle();
      // Nothing connected: nothing to replay onto.
      expect(tester.widget<MenuItemButton>(find.widgetWithText(MenuItemButton, 'Replay log file…')).onPressed,
          isNull);
      await tester.tapAt(const Offset(700, 600)); // close the menu
      await tester.pumpAndSettle();

      await tester.tap(find.text('Connect').first);
      await tester.pumpAndSettle();
      final bus = fake.buses.single;
      const log = '(5.0) can0 101#01\n(5.0) can1 102#02\n(5.0) can0 103#03\n(5.0) can0 20000080#0000000000000000\n';

      picker.next = _MemFile('r.log', Uint8List.fromList(log.codeUnits));
      await menu(tester, 'Replay log file…');
      expect(find.text('Replay r.log'), findsOneWidget);
      expect(find.text('4 frames, 0.000000 s'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(state.replay, isNull);

      picker.next = _MemFile('r.log', Uint8List.fromList(log.codeUnits));
      await menu(tester, 'Replay log file…');
      // Log channel 2 has nowhere to go: CAN2 is not connected.
      expect(find.text('Not replayed'), findsOneWidget);
      await pick(tester, 'speed', '2.0x');
      await tester.tap(find.text('Start'));
      await tester.pumpAndSettle();
      expect(bus.sent.map((f) => f.idHex), ['101', '103']);
      expect(find.text('done  2 sent'), findsOneWidget);

      // Looped, it runs until stopped from the status bar.
      picker.next = _MemFile('r.log', Uint8List.fromList(log.codeUnits));
      await menu(tester, 'Replay log file…');
      await tester.tap(find.text('Loop'));
      await tester.tap(find.text('Start'));
      await tester.pump();
      await tester.pump();
      expect(state.replay.running, isTrue);
      await tester.tap(find.byTooltip('Stop replay'));
      await tester.pumpAndSettle();
      expect(state.replay.running, isFalse);
    });
  });

  testWidgets('cyclic transmit from the send dialog, managed in the list', (tester) async {
    final state = await pumpApp(tester);
    await tester.tap(find.text('Connect').first);
    await tester.pumpAndSettle();
    final bus = fake.buses.single;

    await tester.tap(find.byTooltip('Cyclic transmit list'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Nothing is sent cyclically'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Cycle time (ms)'), '100');
    await tester.tap(find.widgetWithText(FilledButton, 'Send'));
    await tester.pump();
    expect(bus.sent.length, 1); // first one right away, not after a period
    await tester.pumpAndSettle();
    final n = bus.sent.length;
    await tester.pump(const Duration(milliseconds: 250));
    expect(bus.sent.length, n + 2);
    expect(find.text('1'), findsWidgets); // the badge

    await tester.tap(find.byTooltip('Cyclic transmit list'));
    await tester.pumpAndSettle();
    expect(find.textContaining('100 ms · ${bus.sent.length} sent'), findsOneWidget);
    await tester.tap(inDialog(find.byTooltip('Pause')));
    await tester.pump();
    expect(find.textContaining('stopped'), findsOneWidget);
    await tester.tap(inDialog(find.byTooltip('Resume')));
    await tester.pump();
    await tester.tap(find.text('Stop all'));
    await tester.pump();
    expect(state.tx.running, 0);
    await tester.tap(inDialog(find.byTooltip('Remove')));
    await tester.pumpAndSettle();
    expect(state.tx.jobs, isEmpty);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    // Disconnecting stops what that channel was sending.
    state.tx.add(0, frame(0x10, [1]), const Duration(milliseconds: 50));
    await tester.tap(find.text('Disconnect'));
    await tester.pumpAndSettle();
    expect(state.tx.running, 0);
    state.tx.jobs.clear();
  });

  testWidgets('send dialog composes a frame from DBC signal values', (tester) async {
    final state = await pumpApp(tester);
    final TraceModel model = state.model;
    await tester.tap(find.text('Connect').first);
    await tester.pumpAndSettle();
    final bus = fake.buses.single;
    model.loadDbc(0, parseDbc(File('example/demo.dbc').readAsStringSync()), 'demo.dbc');

    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();
    await pick(tester, 'msg0', 'EngineData  (123)');
    expect(find.widgetWithText(TextField, 'EngineSpeed [rpm]'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'EngineSpeed [rpm]'), '1000');
    await tester.enterText(find.widgetWithText(TextField, 'CoolantTemp [degC]'), '20');
    await tester.enterText(find.widgetWithText(TextField, 'ThrottlePos [%]'), 'abc'); // ignored
    await tester.pump();
    expect(find.text('A0 0F 3C 00 00 00 00 00'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Send'));
    await tester.pumpAndSettle();
    expect(bus.sent.last.idHex, '123');
    expect(bus.sent.last.data, [0xA0, 0x0F, 0x3C, 0, 0, 0, 0, 0]);

    // Value-table names work, and typed bytes show up as signal values.
    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();
    await pick(tester, 'msg0', 'GearStatus  (100)');
    await tester.enterText(find.widgetWithText(TextField, 'GearState'), 'drive');
    await tester.pump();
    expect(find.text('03 00'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Data (hex bytes)'), '02 00');
    await tester.pump();
    expect(find.widgetWithText(TextField, '2'), findsOneWidget);
    await pick(tester, 'msg0', 'Raw frame');
    expect(find.widgetWithText(TextField, 'GearState'), findsNothing);
    await tester.enterText(find.widgetWithText(TextField, 'Cycle time (ms)'), '');
    await tester.tap(find.widgetWithText(FilledButton, 'Send'));
    await tester.pumpAndSettle();
    expect(bus.sent.last.data, [2, 0]);
  });

  testWidgets('live view switches between absolute, relative and delta time', (tester) async {
    final state = await pumpApp(tester);
    final TraceModel model = state.model;
    final t = DateTime(2026, 1, 1, 12);
    model.add(CanFrame(id: 1, data: Uint8List(0), timestamp: t));
    model.add(CanFrame(id: 2, data: Uint8List(0), timestamp: t.add(const Duration(milliseconds: 10))));
    model.add(CanFrame.error('x', timestamp: t.add(const Duration(milliseconds: 25))));
    await tester.tap(find.text('Live'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('12:00:00.010'), findsOneWidget);

    await tester.tap(find.text('TIME ▾'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('0.010000'), findsOneWidget);
    expect(find.text('0.025000'), findsOneWidget);

    await tester.tap(find.text('TIME (s) ▾'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('+0.015000'), findsOneWidget);
    expect(find.text('+0.000000'), findsOneWidget);

    await tester.tap(find.text('Δ TIME (s) ▾'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(model.timeMode, TimeMode.absolute);
  });

  testWidgets('macOS gets the menu bar instead of the overflow menu', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final menus = _FakeMenus();
    final original = WidgetsBinding.instance.platformMenuDelegate;
    WidgetsBinding.instance.platformMenuDelegate = menus;
    final launched = <String>[];
    final realLaunch = launch;
    launch = (cmd, args) async {
      launched.add(cmd);
      return ProcessResult(0, 0, '', '');
    };
    os = 'macos'; // the browser command follows the OS, not the target platform
    try {
      final state = await pumpApp(tester);
      final TraceModel model = state.model;
      expect(find.byIcon(Icons.more_vert), findsNothing);
      expect(menus.menus.map((m) => m.label), ['Pantrace', 'File', 'Edit', 'Window', 'Help']);

      picker.next = _MemFile('demo.dbc', File('example/demo.dbc').readAsBytesSync());
      menus.select('Open DBC for CAN1…');
      await tester.pumpAndSettle();
      expect(model.dbcPaths[0], 'demo.dbc');
      menus.select('Close DBC for CAN1');
      await tester.pumpAndSettle();
      expect(model.dbcs[0], isNull);

      picker.saveTo = Uri.file('/tmp/x.csv');
      menus.select('Export As/CSV (.csv)…');
      await tester.pumpAndSettle();
      expect(find.text('Exported 0 frames to /tmp/x.csv'), findsOneWidget);

      menus.select('Release Notes');
      expect(launched, ['open']);

      await tester.pump(const Duration(seconds: 5)); // export toast gone

      final tmp = Directory.systemTemp.createTempSync('pantrace_menu');
      picker.saveTo = Uri.file('${tmp.path}/m.asc');
      menus.select('Record As/Vector ASC (.asc)…');
      await tester.pumpAndSettle();
      expect(model.recorder?.format, LogFormat.asc);
      menus.select('Stop Recording');
      await tester.pumpAndSettle();
      expect(model.recorder, isNull);
      expect(File('${tmp.path}/m.asc').readAsStringSync(), contains('End TriggerBlock'));
      tmp.deleteSync(recursive: true);
      picker.next = _MemFile('py.log', File('test/fixtures/py.log').readAsBytesSync());
      menus.select('Open Log File…');
      await tester.pumpAndSettle();
      expect(model.totalFrames, 32);
      menus.select('Replay Log File…'); // cancelled in the file dialog
      await tester.pumpAndSettle();
      clearToasts(tester);
      await tester.pumpAndSettle();

      menus.select('Check for Updates…');
      await tester.pumpAndSettle();
      expect(find.textContaining('Update check failed'), findsOneWidget);
    } finally {
      WidgetsBinding.instance.platformMenuDelegate = original;
      debugDefaultTargetPlatformOverride = null;
      os = Platform.operatingSystem;
      launch = realLaunch;
    }
  });
}
