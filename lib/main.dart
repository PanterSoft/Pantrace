import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'src/backends/slcan.dart';
import 'src/can.dart';
import 'src/dbc.dart';
import 'src/log/log.dart';
import 'src/registry.dart';
import 'src/share.dart';
import 'src/trace.dart';
import 'src/transmit.dart';
import 'src/update.dart';

part 'ui/logging.dart';
part 'ui/send.dart';

void main() => runApp(const PantraceApp()); // coverage:ignore-line

/// macOS wants app actions in the system menu bar; Flutter ships no native
/// menu delegate for Windows/Linux, so those keep the toolbar overflow menu.
bool get _nativeMenus => defaultTargetPlatform == TargetPlatform.macOS;

const _r = BorderRadius.all(Radius.circular(4));
const _btn = ButtonStyle(
  shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: _r)),
  padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 10, vertical: 4)),
  minimumSize: WidgetStatePropertyAll(Size(0, 28)),
  textStyle: WidgetStatePropertyAll(TextStyle(fontSize: 12)),
);

const _mono = TextStyle(fontFamily: 'monospace', fontFamilyFallback: ['Menlo', 'Consolas'], fontSize: 13);

class PantraceApp extends StatelessWidget {
  const PantraceApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Pantrace',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF3DDC84),
          brightness: Brightness.dark,
        ),
        visualDensity: VisualDensity.compact,
        // ponytail: M3 defaults are pill-shaped and tall; flatten to a 4px tool look.
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        filledButtonTheme: const FilledButtonThemeData(style: _btn),
        outlinedButtonTheme: const OutlinedButtonThemeData(style: _btn),
        textButtonTheme: const TextButtonThemeData(style: _btn),
        segmentedButtonTheme: const SegmentedButtonThemeData(style: _btn),
        iconButtonTheme: const IconButtonThemeData(
            style: ButtonStyle(iconSize: WidgetStatePropertyAll(18))),
        inputDecorationTheme: const InputDecorationTheme(
          isDense: true,
          border: OutlineInputBorder(borderRadius: _r),
          contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        ),
        chipTheme: const ChipThemeData(
            shape: RoundedRectangleBorder(borderRadius: _r),
            labelStyle: TextStyle(fontSize: 12),
            padding: EdgeInsets.symmetric(horizontal: 4)),
        dialogTheme: const DialogThemeData(
            shape: RoundedRectangleBorder(borderRadius: _r)),
        popupMenuTheme: const PopupMenuThemeData(
            shape: RoundedRectangleBorder(borderRadius: _r)),
        textTheme: Typography.englishLike2021.apply(fontSizeFactor: 0.9),
      ),
      home: const TracerPage(),
    );
  }
}

class TracerPage extends StatefulWidget {
  const TracerPage({super.key});
  @override
  State<TracerPage> createState() => _TracerPageState();
}

/// Everything that exists once per traced bus.
class _Channel {
  CanBus? bus;
  CanShare? share;
  CanDevice? device;
  int bitrate = 500000;
  bool connecting = false;
  bool get connected => bus != null;
}

class _TracerPageState extends State<TracerPage> {
  final model = TraceModel();
  final channels = List.generate(TraceModel.channels, (_) => _Channel());
  List<CanDevice> devices = [];
  bool scanning = false;
  final expanded = <int>{};
  late final tx = TxScheduler(sendFrame);
  LogReplay? replay;

  @override
  void initState() {
    super.initState();
    _refreshDevices();
    _checkUpdate();
  }

  /// The startup check only speaks up when there is something new; the menu
  /// entry (`manual`) always reports, so the user sees that it actually ran.
  Future<void> _checkUpdate({bool manual = false}) async {
    String? tag;
    try {
      tag = await checkForUpdate();
    } catch (e) {
      if (manual && mounted) _snack('Update check failed: $e');
      return; // ponytail: silent at startup; the next launch tries again
    }
    if (!mounted) return;
    if (tag == null) {
      if (manual) _snack('Pantrace $appVersion is the latest version');
      return;
    }
    final newTag = tag;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Pantrace $newTag is available (installed: $appVersion)'),
      duration: const Duration(seconds: 15),
      action: canSelfInstall
          ? SnackBarAction(label: 'Install', onPressed: () => _install(newTag))
          : SnackBarAction(label: 'Download', onPressed: openReleasePage),
    ));
  }

  /// Downloads and runs the installer; on success the app exits and the
  /// installer brings it back, so nothing after the await runs.
  Future<void> _install(String tag) async {
    final progress = ValueNotifier<double>(0);
    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: Text('Installing Pantrace $tag'),
        content: ValueListenableBuilder<double>(
          valueListenable: progress,
          builder: (_, v, _) => LinearProgressIndicator(value: v == 0 ? null : v),
        ),
      ),
    ));
    try {
      await downloadAndInstall(tag, onProgress: (v) => progress.value = v);
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop();
      _snack('Install failed: $e — opening the download page');
      openReleasePage();
    }
  }

  void _snack(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  bool get anyConnected => channels.any((c) => c.connected);

  @override
  void dispose() {
    tx.dispose();
    replay?.dispose();
    // Unawaited: finishing the log only patches its header and closes it.
    model.stopRecording();
    for (final c in channels) {
      c.share?.stop();
      c.bus?.close();
    }
    model.dispose();
    super.dispose();
  }

  /// Transmits [template] on channel [ch] as a fresh, now-stamped Tx frame.
  /// The one path every sender (dialog, cyclic list, replay) goes through.
  Future<void> sendFrame(int ch, CanFrame template) async {
    final c = channels[ch];
    final bus = c.bus;
    if (bus == null) throw CanBusException('CAN${ch + 1} is not connected');
    final frame = CanFrame(
        id: template.id,
        data: template.data,
        extended: template.extended,
        rtr: template.rtr,
        direction: FrameDirection.tx);
    await bus.send(frame);
    // Drivers that do not echo transmissions still need the frame traced.
    if (c.device?.backend != 'virtual') {
      model.add(frame.withChannel(ch));
      c.share?.relay(frame);
    }
  }

  Future<void> _refreshDevices() async {
    setState(() => scanning = true);
    final found = await discoverAll();
    if (!mounted) return;
    final hw = found.where((d) => d.backend != 'virtual').length;
    model.addStatus(hw == 0
        ? 'scan: no CAN interfaces found (virtual bus only)'
        : 'scan: $hw CAN interface${hw == 1 ? '' : 's'} found');
    setState(() {
      scanning = false;
      devices = found;
      for (final (i, c) in channels.indexed) {
        if (c.device != null && !found.contains(c.device)) c.device = null;
        // CAN1 defaults to the first interface, CAN2 to the second if any.
        c.device ??= i < found.length ? found[i] : null;
      }
    });
  }

  Future<void> _connect(int ch) async {
    final c = channels[ch];
    final d = c.device;
    if (d == null) return;
    // One physical interface cannot be two buses; the virtual one can.
    if (d.backend != 'virtual' &&
        channels.any((o) => o != c && o.connected && o.device == d)) {
      _toast('${d.label} is already in use by another channel');
      return;
    }
    setState(() => c.connecting = true);
    try {
      final b = backendById(d.backend).create();
      b.frames.listen((f) => model.add(f.withChannel(ch)));
      b.status.listen((s) {
        model.addStatus('CAN${ch + 1}: $s');
        // The backend closes itself when the device goes away.
        if (!b.isOpen && c.bus == b && mounted) setState(() => c.bus = null);
      });
      await b.open(d.address, c.bitrate);
      model.bitrates[ch] = c.bitrate;
      model.addStatus('CAN${ch + 1}: connected to ${d.label} at ${c.bitrate} bit/s');
      setState(() => c.bus = b);
    } catch (e) {
      model.addStatus('CAN${ch + 1}: $e');
      if (mounted) _toast('$e');
    } finally {
      if (mounted) setState(() => c.connecting = false);
    }
  }

  Future<void> _disconnect(int ch) async {
    final c = channels[ch];
    tx.stopAll(channel: ch);
    await _setShared(ch, false);
    await c.bus?.close();
    model.addStatus('CAN${ch + 1}: disconnected');
    setState(() => c.bus = null);
  }

  Future<void> _loadDbc(int ch) async {
    final file = await FilePicker.pickFile(dialogTitle: 'Open DBC database');
    if (file == null) return;
    try {
      // DBCs from older tools are latin-1; allowMalformed keeps those readable.
      final text = utf8.decode(await file.readAsBytes(), allowMalformed: true);
      final db = parseDbc(text);
      model.loadDbc(ch, db, file.name);
      model.addStatus('CAN${ch + 1}: loaded ${file.name}: '
          '${db.messageCount} messages, ${db.signalCount} signals');
    } catch (e) {
      _toast('$e');
    }
  }

  /// Writes the trace buffer as [format]. A different known extension typed
  /// into the save dialog wins over the menu choice.
  Future<void> _export(LogFormat format) async {
    final frames = model.bufferedFrames;
    final uri = await FilePicker.saveFile(
      dialogTitle: 'Export trace as ${format.label}',
      fileName: 'cantrace.${format.extension}',
      bytes: await encodeLog(format, frames),
    );
    if (uri == null) return;
    final path = uri.toFilePath();
    final typed = LogFormat.fromPath(path);
    try {
      if (typed != null && typed != format) {
        File(path).writeAsBytesSync(await encodeLog(typed, frames));
      }
      _toast('Exported ${frames.length} frames to $path');
    } catch (e) {
      _toast('Export failed: $e');
    }
  }

  static String _fileStamp(DateTime t) => t
      .toIso8601String()
      .substring(0, 19)
      .replaceAll(RegExp('[-:]'), '')
      .replaceAll('T', '-');

  /// Asks for a file and streams every frame from now on into it.
  Future<void> _startRecording(LogFormat format) async {
    final uri = await FilePicker.saveFile(
      dialogTitle: 'Record trace as ${format.label}',
      fileName: 'trace-${_fileStamp(DateTime.now())}.${format.extension}',
      bytes: Uint8List(0),
    );
    if (uri == null) return;
    try {
      model.startRecording(uri.toFilePath(), format: format);
    } catch (e) {
      _toast('Could not start recording: $e');
    }
  }

  Future<void> _stopRecording() async {
    final r = await model.stopRecording();
    if (r != null) _toast('Recorded ${r.frames} frames to ${r.path}');
  }

  /// Picks and decodes a log file; null when cancelled or unreadable.
  Future<(String, DecodedLog)?> _pickLog(String title) async {
    final file = await FilePicker.pickFile(dialogTitle: title);
    if (file == null) return null;
    final format = LogFormat.fromPath(file.name);
    if (format == null) {
      _toast('${file.name}: unknown log format — open '
          '${LogFormat.allExtensions.map((e) => '.$e').join(', ')}');
      return null;
    }
    try {
      return (file.name, await decodeLogAsync(format, await file.readAsBytes()));
    } catch (e) {
      _toast('Could not read ${file.name}: $e');
      return null;
    }
  }

  /// CANoe's offline mode: a recorded log goes into the trace views.
  Future<void> _openLog() async {
    final picked = await _pickLog('Open log file');
    if (picked == null) return;
    final (name, log) = picked;
    final dropped = model.addOffline(log.frames);
    final notes = [
      if (log.skipped > 0) '${log.skipped} unsupported records skipped',
      if (dropped > 0) '$dropped frames on channels beyond CAN${TraceModel.channels}',
    ];
    model.addStatus('loaded ${log.frames.length - dropped} frames from $name'
        '${notes.isEmpty ? '' : ' (${notes.join(', ')})'}');
    _toast('Loaded ${log.frames.length - dropped} frames from $name');
  }

  /// CANoe's replay block: a recorded log played back onto the buses.
  Future<void> _replayLog() async {
    final picked = await _pickLog('Replay log file');
    if (picked == null || !mounted) return;
    final (name, log) = picked;
    final r = await showDialog<LogReplay>(
        context: context,
        builder: (_) => _ReplayDialog(state: this, name: name, log: log));
    if (r == null || !mounted) return;
    replay?.dispose();
    r.addListener(() {
      if (mounted) setState(() {});
    });
    setState(() => replay = r);
    model.addStatus('replaying $name: ${r.frames.length} frames at ${r.speed}x'
        '${r.loop ? ', looped' : ''}');
    r.start();
  }

  void _stopReplay() {
    replay?.stop();
    setState(() {});
  }

  // The toolbar and tables live in separate widgets; these are the only
  // pieces of page state they mutate.
  void toggleExpanded(int key) =>
      setState(() => expanded.contains(key) ? expanded.remove(key) : expanded.add(key));
  void expandAll(bool expand) => setState(() {
        expanded.clear();
        if (expand) {
          expanded.addAll(model.groupedRows
              .where((r) => model.messageFor(r.channel, r.id, r.extended) != null)
              .map((r) => r.key));
        }
      });
  Future<void> _setShared(int ch, bool on) async {
    final c = channels[ch];
    await c.share?.stop();
    c.share = null;
    final b = c.bus;
    if (on && b != null) {
      final s = CanShare(b,
          onClientSent: (f) => model.add(f.withChannel(ch)),
          busEchoes: c.device?.backend == 'virtual');
      try {
        final endpoints = await s.start();
        c.share = s;
        model.addStatus(
            'CAN${ch + 1}: sharing bus as SLCAN on ${endpoints.join(' and ')}');
      } catch (e) {
        _toast('Could not share the bus: $e');
      }
    }
    if (mounted) setState(() {});
  }

  void setDevice(int ch, CanDevice? d) => setState(() => channels[ch].device = d);
  void setBitrate(int ch, int b) => setState(() => channels[ch].bitrate = b);
  void setProbeSerial(bool v) {
    (backendById('slcan') as SlcanBackend).probe = v;
    _refreshDevices();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg), showCloseIcon: true));
  }

  /// macOS keeps app-level actions in the system menu bar. PlatformMenuBar
  /// replaces the whole Runner menu, so the standard menus are re-declared
  /// here from platform-provided items.
  List<PlatformMenuItem> _menus() => [
        PlatformMenu(label: 'Pantrace', menus: [
          const PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.about),
          PlatformMenuItemGroup(members: [
            PlatformMenuItem(
              label: 'Check for Updates…',
              onSelected: () => _checkUpdate(manual: true),
            ),
          ]),
          const PlatformMenuItemGroup(members: [
            PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.servicesSubmenu),
          ]),
          const PlatformMenuItemGroup(members: [
            PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.hide),
            PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.hideOtherApplications),
            PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.showAllApplications),
          ]),
          const PlatformMenuItemGroup(members: [
            PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.quit),
          ]),
        ]),
        PlatformMenu(label: 'File', menus: [
          PlatformMenuItem(
            label: 'Open DBC for CAN1…',
            shortcut: const SingleActivator(LogicalKeyboardKey.keyO, meta: true),
            onSelected: () => _loadDbc(0),
          ),
          PlatformMenuItem(label: 'Close DBC for CAN1',
              onSelected: () => model.clearDbc(0)),
          PlatformMenuItem(
            label: 'Open DBC for CAN2…',
            onSelected: () => _loadDbc(1),
          ),
          PlatformMenuItem(label: 'Close DBC for CAN2',
              onSelected: () => model.clearDbc(1)),
          PlatformMenuItemGroup(members: [
            PlatformMenuItem(
              label: 'Open Log File…',
              shortcut: const SingleActivator(LogicalKeyboardKey.keyO,
                  meta: true, shift: true),
              onSelected: _openLog,
            ),
            PlatformMenuItem(label: 'Replay Log File…', onSelected: _replayLog),
          ]),
          PlatformMenuItemGroup(members: [
            PlatformMenu(label: 'Record As', menus: [
              for (final f in LogFormat.values)
                PlatformMenuItem(
                    label: '${f.label} (.${f.extension})…',
                    onSelected: () => _startRecording(f)),
            ]),
            PlatformMenuItem(
              label: 'Stop Recording',
              shortcut: const SingleActivator(LogicalKeyboardKey.keyR,
                  meta: true, shift: true),
              onSelected: _stopRecording,
            ),
            PlatformMenu(label: 'Export As', menus: [
              for (final f in LogFormat.values)
                PlatformMenuItem(
                  label: '${f.label} (.${f.extension})…',
                  shortcut: f == LogFormat.csv
                      ? const SingleActivator(LogicalKeyboardKey.keyS, meta: true)
                      : null,
                  onSelected: () => _export(f),
                ),
            ]),
          ]),
        ]),
        const PlatformMenu(label: 'Edit', menus: [
          PlatformMenuItem(
            label: 'Cut',
            shortcut: SingleActivator(LogicalKeyboardKey.keyX, meta: true),
            onSelectedIntent: CopySelectionTextIntent.cut(SelectionChangedCause.keyboard),
          ),
          PlatformMenuItem(
            label: 'Copy',
            shortcut: SingleActivator(LogicalKeyboardKey.keyC, meta: true),
            onSelectedIntent: CopySelectionTextIntent.copy,
          ),
          PlatformMenuItem(
            label: 'Paste',
            shortcut: SingleActivator(LogicalKeyboardKey.keyV, meta: true),
            onSelectedIntent: PasteTextIntent(SelectionChangedCause.keyboard),
          ),
          PlatformMenuItem(
            label: 'Select All',
            shortcut: SingleActivator(LogicalKeyboardKey.keyA, meta: true),
            onSelectedIntent: SelectAllTextIntent(SelectionChangedCause.keyboard),
          ),
        ]),
        const PlatformMenu(label: 'Window', menus: [
          PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.minimizeWindow),
          PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.zoomWindow),
          PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.toggleFullScreen),
        ]),
        PlatformMenu(label: 'Help', menus: [
          PlatformMenuItem(label: 'Release Notes', onSelected: openReleasePage),
        ]),
      ];

  @override
  Widget build(BuildContext context) {
    final page = Scaffold(
      body: Column(
        children: [
          // The toolbar shows model state too (pause, view, DBC), so it must
          // follow the model, not only setState.
          ListenableBuilder(
            listenable: model,
            builder: (context, _) => _Toolbar(state: this),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListenableBuilder(
              listenable: model,
              builder: (context, _) => model.view == TraceView.grouped
                  ? _GroupedTable(state: this)
                  : _LiveTable(state: this),
            ),
          ),
          const Divider(height: 1),
          ListenableBuilder(
            listenable: model,
            builder: (context, _) => _StatusBar(state: this),
          ),
        ],
      ),
    );
    return _nativeMenus ? PlatformMenuBar(menus: _menus(), child: page) : page;
  }
}

// ---------------------------------------------------------------------------

class _Toolbar extends StatelessWidget {
  final _TracerPageState state;
  const _Toolbar({required this.state});

  /// Interface, bitrate, connect and share for one bus. Flat children rather
  /// than a nested Row so the outer Wrap can break between them on a narrow
  /// window.
  List<Widget> _channel(int ch, double Function(double) cap) {
    final c = state.channels[ch];
    final connected = c.connected;
    return [
      Text('CAN${ch + 1}',
          style: TextStyle(
              fontWeight: FontWeight.bold,
              color: connected ? const Color(0xFF3DDC84) : Colors.grey)),
      SizedBox(
        width: cap(260),
        child: DropdownButtonFormField<CanDevice>(
          key: ValueKey('device$ch'),
          initialValue: c.device,
          isExpanded: true,
          decoration: const InputDecoration(
              labelText: 'Interface', border: OutlineInputBorder(), isDense: true),
          items: state.devices
              .map((d) => DropdownMenuItem(
                  value: d,
                  child: Text(d.label, overflow: TextOverflow.ellipsis)))
              .toList(),
          onChanged: connected ? null : (d) => state.setDevice(ch, d),
        ),
      ),
      SizedBox(
        width: cap(130),
        child: DropdownButtonFormField<int>(
          key: ValueKey('bitrate$ch'),
          initialValue: c.bitrate,
          isExpanded: true,
          decoration: const InputDecoration(
              labelText: 'Bitrate', border: OutlineInputBorder(), isDense: true),
          items: kStandardBitrates
              .map((b) => DropdownMenuItem(
                  value: b,
                  child: Text('${b ~/ 1000} kbit/s', overflow: TextOverflow.ellipsis)))
              .toList(),
          onChanged: connected ? null : (b) => state.setBitrate(ch, b!),
        ),
      ),
      // Fixed width: 'Disconnect' is wider than 'Connect', and letting the
      // button resize re-wraps the whole toolbar on every connect.
      SizedBox(
        width: 150,
        child: FilledButton.icon(
          onPressed: c.connecting || (!connected && c.device == null)
              ? null
              : connected
                  ? () => state._disconnect(ch)
                  : () => state._connect(ch),
          icon: Icon(connected ? Icons.stop : Icons.play_arrow),
          label: Text(connected ? 'Disconnect' : 'Connect'),
        ),
      ),
      FilterChip(
        tooltip: 'Let other tools use this bus as an SLCAN device '
            '(TCP on localhost, plus a virtual serial port on macOS/Linux)',
        label: const Text('Share'),
        selected: c.share != null,
        onSelected: connected ? (v) => state._setShared(ch, v) : null,
      ),
      OutlinedButton.icon(
        onPressed: () => state._loadDbc(ch),
        icon: const Icon(Icons.description),
        label: const Text('Load DBC'),
      ),
      IconButton(
        tooltip: state.model.dbcs[ch] == null
            ? 'No DBC loaded'
            : 'Unload ${state.model.dbcPaths[ch]}',
        onPressed: state.model.dbcs[ch] == null ? null : () => state.model.clearDbc(ch),
        icon: const Icon(Icons.close),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final connected = state.anyConnected;
    return LayoutBuilder(builder: (context, c) {
    // Fields keep their preferred width until the window is narrower than they are.
    double cap(double want) => math.min(want, c.maxWidth - 24);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          const Text('Pantrace',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(width: 8),
          for (var ch = 0; ch < state.channels.length; ch++) ..._channel(ch, cap),
          IconButton(
            tooltip: 'Rescan for devices',
            onPressed: connected || state.scanning ? null : state._refreshDevices,
            icon: state.scanning
                ? const SizedBox(
                    width: 24, height: 24,
                    child: Padding(
                        padding: EdgeInsets.all(3),
                        child: CircularProgressIndicator(strokeWidth: 2)))
                : const Icon(Icons.refresh),
          ),
          FilterChip(
            tooltip: 'List every serial port instead of only detected CAN adapters',
            label: const Text('All ports'),
            selected: !(backendById('slcan') as SlcanBackend).probe,
            onSelected: connected ? null : (v) => state.setProbeSerial(!v),
          ),
          const SizedBox(width: 12),
          SegmentedButton<TraceView>(
            segments: const [
              ButtonSegment(
                  value: TraceView.grouped,
                  icon: Icon(Icons.view_list),
                  label: Text('Grouped')),
              ButtonSegment(
                  value: TraceView.live,
                  icon: Icon(Icons.stream),
                  label: Text('Live')),
            ],
            selected: {state.model.view},
            onSelectionChanged: (s) => state.model.setView(s.first),
          ),
          IconButton.filledTonal(
            tooltip: state.model.paused ? 'Resume' : 'Pause',
            onPressed: () => state.model.setPaused(!state.model.paused),
            icon: Icon(state.model.paused ? Icons.play_arrow : Icons.pause),
          ),
          IconButton.filledTonal(
            tooltip: 'Clear trace',
            onPressed: state.model.clear,
            icon: const Icon(Icons.delete_sweep),
          ),
          const SizedBox(width: 12),
          _RecordButton(state: state),
          _LogMenu(state: state),
          OutlinedButton.icon(
            onPressed: connected
                ? () => showDialog(
                    context: context,
                    builder: (_) => _SendDialog(state: state))
                : null,
            icon: const Icon(Icons.send),
            label: const Text('Send'),
          ),
          IconButton(
            tooltip: 'Cyclic transmit list',
            onPressed: () => showDialog(
                context: context, builder: (_) => _TxListDialog(state: state)),
            icon: Badge(
              isLabelVisible: state.tx.running > 0,
              label: Text('${state.tx.running}'),
              child: const Icon(Icons.repeat),
            ),
          ),
          SizedBox(
            width: cap(180),
            child: TextField(
              decoration: const InputDecoration(
                labelText: 'ID filter (hex)',
                hintText: '100, 200-2FF',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: state.model.setFilter,
            ),
          ),
          if (!_nativeMenus)
            PopupMenuButton<void Function()>(
              tooltip: 'More',
              icon: const Icon(Icons.more_vert),
              onSelected: (action) => action(),
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: () => state._checkUpdate(manual: true),
                  child: const ListTile(
                      dense: true,
                      leading: Icon(Icons.system_update),
                      title: Text('Check for updates')),
                ),
                PopupMenuItem(
                  value: openReleasePage,
                  child: const ListTile(
                      dense: true,
                      leading: Icon(Icons.info_outline),
                      title: Text('Releases')),
                ),
              ],
            ),
          Text('v$appVersion',
              style: const TextStyle(fontSize: 11, color: Color(0xFF9E9E9E))),
        ],
      ),
    );
    });
  }
}

// ---------------------------------------------------------------------------

/// Narrower than this the columns stop being readable, so the whole table
/// scrolls sideways instead of crushing every cell into an ellipsis.
const _minTableWidth = 880.0;

Widget _scrollableTable(Widget table) => LayoutBuilder(
      builder: (context, c) => c.maxWidth >= _minTableWidth
          ? table
          : SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                  width: _minTableWidth, height: c.maxHeight, child: table),
            ),
    );

const _headerStyle = TextStyle(
    fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF9E9E9E));

/// Clickable column header of the grouped table: picks the sort column, and
/// clicking the active one flips the direction.
Widget _sortHeader(TraceModel model, String label, int flex, TraceSort column) {
  final active = model.sort == column;
  return Expanded(
    flex: flex,
    child: InkWell(
      onTap: () => model.setSort(column),
      child: Row(
        children: [
          Flexible(
              child: Text(label,
                  overflow: TextOverflow.ellipsis,
                  style: active
                      ? _headerStyle.copyWith(color: const Color(0xFFE0E0E0))
                      : _headerStyle)),
          if (active)
            Icon(model.sortAscending ? Icons.arrow_upward : Icons.arrow_downward,
                size: 12, color: const Color(0xFFE0E0E0)),
        ],
      ),
    ),
  );
}

/// Hex payload with per-byte highlighting of what just changed.
class _HexData extends StatelessWidget {
  final Uint8List data;
  final int changedMask;
  const _HexData(this.data, {this.changedMask = 0});

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Row(
      children: [
        for (var i = 0; i < data.length; i++)
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Text(
              data[i].toRadixString(16).toUpperCase().padLeft(2, '0'),
              style: _mono.copyWith(
                color: (changedMask >> i) & 1 == 1 ? accent : null,
                fontWeight:
                    (changedMask >> i) & 1 == 1 ? FontWeight.bold : null,
              ),
            ),
          ),
      ],
    );
  }
}

/// A line in the grouped trace: either a message or, when that message is
/// expanded and decodable, one of its signals — CANoe's trace window layout.
sealed class _Line {}

class _MsgLine extends _Line {
  final TraceRow row;
  final DbcMessage? msg;
  _MsgLine(this.row, this.msg);
}

class _SigLine extends _Line {
  final TraceRow row;
  final DbcSignal sig;
  _SigLine(this.row, this.sig);
}

class _GroupedTable extends StatelessWidget {
  final _TracerPageState state;
  const _GroupedTable({required this.state});

  @override
  Widget build(BuildContext context) {
    final model = state.model;
    final lines = <_Line>[];
    for (final r in model.groupedRows) {
      final msg = model.messageFor(r.channel, r.id, r.extended);
      lines.add(_MsgLine(r, msg));
      if (msg != null && state.expanded.contains(r.key)) {
        for (final sig in msg.signalsFor(r.data)) {
          lines.add(_SigLine(r, sig));
        }
      }
    }
    final anyExpanded = state.expanded.isNotEmpty;

    return _scrollableTable(Column(
      children: [
        Container(
          color: const Color(0x22FFFFFF),
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
          child: Row(
            children: [
              IconButton(
                tooltip: anyExpanded ? 'Collapse all' : 'Expand all',
                visualDensity: VisualDensity.compact,
                iconSize: 18,
                onPressed: model.dbcs.every((d) => d == null)
                    ? null
                    : () => state.expandAll(!anyExpanded),
                icon: Icon(anyExpanded ? Icons.unfold_less : Icons.unfold_more),
              ),
              _sortHeader(model, 'CH', 1, TraceSort.channel),
              _sortHeader(model, 'ID', 2, TraceSort.id),
              _sortHeader(model, 'MESSAGE / SIGNAL', 4, TraceSort.name),
              _sortHeader(model, 'LEN', 1, TraceSort.length),
              _sortHeader(model, 'DATA / VALUE', 6, TraceSort.data),
              _sortHeader(model, 'COUNT / RAW', 2, TraceSort.count),
              _sortHeader(model, 'CYCLE', 2, TraceSort.cycle),
            ],
          ),
        ),
        Expanded(
          child: lines.isEmpty
              ? const _Empty('No frames yet — connect an interface.')
              : ListView.builder(
                  itemCount: lines.length,
                  itemExtent: 28,
                  itemBuilder: (context, i) => switch (lines[i]) {
                    _MsgLine l => _messageRow(context, l),
                    _SigLine l => _signalRow(context, l),
                  },
                ),
        ),
      ],
    ));
  }

  Widget _messageRow(BuildContext context, _MsgLine l) {
    final r = l.row;
    final msg = l.msg;
    final theme = Theme.of(context);
    final open = state.expanded.contains(r.key);
    final period = r.periodMs;
    return InkWell(
      onTap: msg == null ? null : () => state.toggleExpanded(r.key),
      child: Container(
        color: open ? theme.colorScheme.primary.withValues(alpha: 0.08) : null,
        padding: const EdgeInsets.only(left: 4, right: 12),
        child: Row(
          children: [
            SizedBox(
              width: 40,
              child: msg == null
                  ? null
                  : Icon(open ? Icons.arrow_drop_down : Icons.arrow_right,
                      size: 20, color: theme.colorScheme.primary),
            ),
            Expanded(flex: 1, child: Text('${r.channel + 1}', style: _mono)),
            Expanded(
                flex: 2,
                child: Text('${r.extended ? "x" : ""}${_hexId(r.id, r.extended)}',
                    style: _mono)),
            Expanded(
                flex: 4,
                child: Text(msg?.name ?? '—',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 13,
                        color: msg == null ? Colors.grey : theme.colorScheme.primary))),
            Expanded(flex: 1, child: Text('${r.data.length}', style: _mono)),
            Expanded(flex: 6, child: _HexData(r.data, changedMask: r.changedMask)),
            Expanded(flex: 2, child: Text('${r.count}', style: _mono)),
            Expanded(
                flex: 2,
                child: Text(period == null ? '—' : '${period.toStringAsFixed(1)} ms',
                    style: _mono)),
          ],
        ),
      ),
    );
  }

  Widget _signalRow(BuildContext context, _SigLine l) {
    final s = l.sig;
    final data = l.row.data;
    return Padding(
      padding: const EdgeInsets.only(left: 4, right: 12),
      child: Row(
        children: [
          const SizedBox(width: 40),
          const Expanded(flex: 3, child: SizedBox()),
          Expanded(
              flex: 4,
              child: Padding(
                padding: const EdgeInsets.only(left: 16),
                child: Text('└ ${s.name}',
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13)),
              )),
          const Expanded(flex: 1, child: SizedBox()),
          Expanded(
              flex: 6,
              child: Text(s.format(data),
                  style: _mono.copyWith(fontWeight: FontWeight.bold))),
          Expanded(
              flex: 2,
              child: Text('${s.rawFrom(data)}',
                  style: _mono.copyWith(color: Colors.grey))),
          Expanded(
              flex: 2,
              child: Text(
                  '${s.startBit}|${s.length}@${s.byteOrder == ByteOrder.intel ? 1 : 0}${s.signed ? "-" : "+"}',
                  style: _mono.copyWith(color: Colors.grey, fontSize: 11))),
        ],
      ),
    );
  }
}

/// An error frame: no id or payload to show, so the description takes over the
/// row and the red makes it findable while scrolling past traffic.
Widget _errorRow(CanFrame f, String time) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Expanded(
              flex: 3,
              child: Text(time,
                  style: _mono.copyWith(color: Colors.redAccent))),
          Expanded(
              flex: 1,
              child: Text('${f.channel + 1}',
                  style: _mono.copyWith(color: Colors.redAccent))),
          const Expanded(
              flex: 1,
              child: Icon(Icons.error_outline, size: 14, color: Colors.redAccent)),
          Expanded(
              flex: 13,
              child: Text('ERROR FRAME — ${f.error}',
                  overflow: TextOverflow.ellipsis,
                  style: _mono.copyWith(color: Colors.redAccent))),
        ],
      ),
    );

class _LiveTable extends StatelessWidget {
  final _TracerPageState state;
  const _LiveTable({required this.state});

  @override
  Widget build(BuildContext context) {
    final model = state.model;
    final frames = model.liveFrames;
    final start = model.measurementStart;
    String time(int i) {
      final t = frames[i].timestamp;
      return switch (model.timeMode) {
        TimeMode.absolute => t.toIso8601String().substring(11, 23),
        TimeMode.relative => start == null ? '' : _seconds(t.difference(start)),
        // Newest first: the previous frame is the next row down.
        TimeMode.delta => i + 1 < frames.length
            ? '+${_seconds(t.difference(frames[i + 1].timestamp))}'
            : '+0.000000',
      };
    }

    return _scrollableTable(Column(
      children: [
        Container(
          color: const Color(0x22FFFFFF),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(children: [
            Expanded(
              flex: 3,
              child: Tooltip(
                message: 'Switch between absolute, relative and delta time',
                child: InkWell(
                  onTap: () => model.setTimeMode(
                      TimeMode.values[(model.timeMode.index + 1) % TimeMode.values.length]),
                  child: Text(
                      switch (model.timeMode) {
                        TimeMode.absolute => 'TIME ▾',
                        TimeMode.relative => 'TIME (s) ▾',
                        TimeMode.delta => 'Δ TIME (s) ▾',
                      },
                      style: _headerStyle.copyWith(color: const Color(0xFFE0E0E0))),
                ),
              ),
            ),
            for (final (label, flex) in const [
              ('CH', 1), ('DIR', 1), ('ID', 2), ('MESSAGE', 4), ('LEN', 1), ('DATA', 6),
            ])
              Expanded(flex: flex, child: Text(label, style: _headerStyle)),
          ]),
        ),
        Expanded(
          child: frames.isEmpty
              ? const _Empty('No frames yet — connect an interface.')
              : ListView.builder(
                  itemCount: frames.length,
                  itemExtent: 26,
                  itemBuilder: (context, i) {
                    final f = frames[i];
                    if (f.isError) return _errorRow(f, time(i));
                    final msg = state.model.messageFor(f.channel, f.id, f.extended);
                    final tx = f.direction == FrameDirection.tx;
                    return InkWell(
                      onTap: null,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Row(
                          children: [
                            Expanded(
                                flex: 3,
                                child: Text(time(i),
                                    style: _mono.copyWith(color: Colors.grey))),
                            Expanded(
                                flex: 1,
                                child: Text('${f.channel + 1}', style: _mono)),
                            Expanded(
                                flex: 1,
                                child: Text(tx ? 'Tx' : 'Rx',
                                    style: _mono.copyWith(
                                        color: tx ? Colors.orangeAccent : null))),
                            Expanded(
                                flex: 2,
                                child: Text(
                                    '${f.extended ? "x" : ""}${_hexId(f.id, f.extended)}',
                                    style: _mono)),
                            Expanded(
                                flex: 4,
                                child: Text(msg?.name ?? '—',
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        fontSize: 13,
                                        color: msg == null
                                            ? Colors.grey
                                            : Theme.of(context).colorScheme.primary))),
                            Expanded(
                                flex: 1,
                                child: Text('${f.data.length}', style: _mono)),
                            Expanded(flex: 6, child: _HexData(f.data)),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    ));
  }
}

String _seconds(Duration d) =>
    (d.inMicroseconds / 1e6).toStringAsFixed(6);

String _basename(String path) => path.split(RegExp(r'[/\\]')).last;

String _size(int bytes) => bytes < 1024
    ? '$bytes B'
    : bytes < 1024 * 1024
        ? '${(bytes / 1024).toStringAsFixed(1)} KB'
        : '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';

String _hexId(int id, bool extended) => id
    .toRadixString(16)
    .toUpperCase()
    .padLeft(extended ? 8 : 3, '0');

class _Empty extends StatelessWidget {
  final String text;
  const _Empty(this.text);
  @override
  Widget build(BuildContext context) => Center(
      child: Text(text, style: const TextStyle(color: Colors.grey)));
}

// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------

class _StatusBar extends StatelessWidget {
  final _TracerPageState state;
  const _StatusBar({required this.state});

  @override
  Widget build(BuildContext context) {
    final model = state.model;
    final rec = model.recorder;
    final replay = state.replay;
    final last = model.statusLog.isEmpty ? '' : model.statusLog.last;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          // The stats scroll sideways rather than overflow once the window is
          // too narrow for them, like the trace table.
          Flexible(
            flex: 3,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: [
                // What is running in the background comes first, so it is
                // never scrolled out of sight on a narrow window.
                if (rec != null)
                  _stat('● REC',
                      '${_basename(rec.path)}  ${rec.frames} frames  ${_size(rec.bytes)}',
                      color: Colors.redAccent),
                if (replay != null) ...[
                  _stat(
                      'Replay',
                      replay.running
                          ? '${(replay.progress * 100).floor()} %  ${replay.sent} sent'
                          : 'done  ${replay.sent} sent'
                              '${replay.failed > 0 ? ', ${replay.failed} not sent' : ''}',
                      color: replay.running ? Colors.lightBlueAccent : null),
                  if (replay.running)
                    IconButton(
                      tooltip: 'Stop replay',
                      visualDensity: VisualDensity.compact,
                      iconSize: 16,
                      onPressed: state._stopReplay,
                      icon: const Icon(Icons.stop),
                    ),
                ],
                _stat('Frames', '${model.totalFrames}'),
                _stat('Rate', '${model.framesPerSecond.round()} /s'),
                for (var ch = 0; ch < TraceModel.channels; ch++)
                  _stat('Load ${ch + 1}',
                      '${model.busLoadPercent[ch].toStringAsFixed(1)} %'),
                _stat('IDs', '${model.groupedRows.length}'),
                _stat('Errors', '${model.errorFrames}',
                    color: model.errorFrames > 0 ? Colors.redAccent : null),
                for (var ch = 0; ch < TraceModel.channels; ch++)
                  if (model.dbcPaths[ch] != null)
                    _stat('DBC ${ch + 1}', model.dbcPaths[ch]!),
                if (model.paused)
                  const Padding(
                    padding: EdgeInsets.only(right: 16),
                    child: Text('PAUSED',
                        style: TextStyle(
                            color: Colors.orangeAccent,
                            fontWeight: FontWeight.bold)),
                  ),
              ]),
            ),
          ),
          Flexible(
            flex: 2,
            child: Text(last,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: const TextStyle(fontSize: 11, color: Colors.grey)),
          ),
        ],
      ),
    );
  }

  Widget _stat(String label, String value, {Color? color}) => Padding(
        padding: const EdgeInsets.only(right: 20),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text('$label ',
              style: TextStyle(fontSize: 11, color: color ?? Colors.grey)),
          Text(value,
              softWrap: false,
              style: _mono.copyWith(fontSize: 12, color: color)),
        ]),
      );
}
