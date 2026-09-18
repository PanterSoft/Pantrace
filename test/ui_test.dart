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

  void select(String label) {
    PlatformMenuItem? find(Iterable<PlatformMenuItem> items) {
      for (final i in items) {
        if (i.label == label) return i;
        final hit = find(i is PlatformMenuItemGroup ? i.members : i.descendants);
        if (hit != null) return hit;
      }
      return null;
    }

    final item = find(menus);
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
    await tester.tap(find.text('Load DBC'));
    await tester.pumpAndSettle();
    expect(model.dbc, isNull);

    picker.next = _MemFile('demo.dbc', File('example/demo.dbc').readAsBytesSync());
    await tester.tap(find.text('Load DBC'));
    await tester.pumpAndSettle();
    expect(model.dbcPath, 'demo.dbc');
    expect(model.statusLog.last, contains('loaded demo.dbc'));
    expect(find.text('DBC '), findsOneWidget);

    picker.next = _MemFile('bad.dbc', utf8.encode('BO_ 291 X: 8 ECU\n SG_ broken\n'));
    await tester.tap(find.text('Load DBC'));
    await tester.pumpAndSettle();
    expect(find.textContaining('DBC parse error'), findsOneWidget);
    expect(model.dbcPath, 'demo.dbc'); // the good one stays loaded

    await tester.tap(find.byTooltip('Unload demo.dbc'));
    await tester.pumpAndSettle();
    expect(model.dbc, isNull);

    await tester.pump(const Duration(seconds: 5)); // let queued toasts expire
    model.add(frame(0x123, [1, 2, 3]));
    await tester.tap(find.text('Export CSV'));
    await tester.pumpAndSettle();
    expect(picker.saved, isNotNull);
    expect(utf8.decode(picker.saved!), contains('123,false,3,010203'));
    expect(find.textContaining('Exported to'), findsNothing); // cancelled

    picker.saveTo = Uri.file('/tmp/cantrace.csv');
    await tester.tap(find.text('Export CSV'));
    await tester.pumpAndSettle();
    expect(find.text('Exported to /tmp/cantrace.csv'), findsOneWidget);
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
    try {
      final state = await pumpApp(tester);
      final TraceModel model = state.model;
      expect(find.byIcon(Icons.more_vert), findsNothing);
      expect(menus.menus.map((m) => m.label), ['Pantrace', 'File', 'Edit', 'Window', 'Help']);

      picker.next = _MemFile('demo.dbc', File('example/demo.dbc').readAsBytesSync());
      menus.select('Open DBC…');
      await tester.pumpAndSettle();
      expect(model.dbcPath, 'demo.dbc');
      menus.select('Close DBC');
      await tester.pumpAndSettle();
      expect(model.dbc, isNull);

      picker.saveTo = Uri.file('/tmp/x.csv');
      menus.select('Export CSV…');
      await tester.pumpAndSettle();
      expect(find.text('Exported to /tmp/x.csv'), findsOneWidget);

      menus.select('Release Notes');
      expect(launched, ['open']);

      await tester.pump(const Duration(seconds: 5)); // export toast gone
      menus.select('Check for Updates…');
      await tester.pumpAndSettle();
      expect(find.textContaining('Update check failed'), findsOneWidget);
    } finally {
      WidgetsBinding.instance.platformMenuDelegate = original;
      debugDefaultTargetPlatformOverride = null;
      launch = realLaunch;
    }
  });
}
