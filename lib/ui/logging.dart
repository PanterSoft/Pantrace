part of '../main.dart';

/// Record while idle (pick a format, then a file), Stop while recording.
/// Fixed width, so swapping the label never re-wraps the toolbar.
class _RecordButton extends StatelessWidget {
  final _TracerPageState state;
  const _RecordButton({required this.state});

  @override
  Widget build(BuildContext context) {
    final rec = state.model.recorder;
    return SizedBox(
      width: 110,
      child: rec != null
          ? FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
              onPressed: state._stopRecording,
              icon: const Icon(Icons.stop),
              label: const Text('Stop'),
            )
          : MenuAnchor(
              menuChildren: [
                for (final f in LogFormat.values)
                  MenuItemButton(
                    onPressed: () => state._startRecording(f),
                    child: Text('${f.label} (.${f.extension})'),
                  ),
              ],
              builder: (context, menu, _) => Tooltip(
                message: 'Record every frame to a log file',
                child: OutlinedButton.icon(
                  onPressed: () => menu.isOpen ? menu.close() : menu.open(),
                  icon: const Icon(Icons.fiber_manual_record, color: Colors.redAccent),
                  label: const Text('Record'),
                ),
              ),
            ),
    );
  }
}

/// Open a log into the trace, replay one onto the bus, or export the buffer.
class _LogMenu extends StatelessWidget {
  final _TracerPageState state;
  const _LogMenu({required this.state});

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      menuChildren: [
        MenuItemButton(
          leadingIcon: const Icon(Icons.folder_open, size: 18),
          onPressed: state._openLog,
          child: const Text('Open log file…'),
        ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.replay, size: 18),
          onPressed: state.anyConnected ? state._replayLog : null,
          child: const Text('Replay log file…'),
        ),
        const Divider(height: 1),
        SubmenuButton(
          leadingIcon: const Icon(Icons.save_alt, size: 18),
          menuChildren: [
            for (final f in LogFormat.values)
              MenuItemButton(
                onPressed: () => state._export(f),
                child: Text('${f.label} (.${f.extension})'),
              ),
          ],
          child: const Text('Export trace as'),
        ),
      ],
      builder: (context, menu, _) => OutlinedButton.icon(
        onPressed: () => menu.isOpen ? menu.close() : menu.open(),
        icon: const Icon(Icons.folder_open),
        label: const Text('Log files'),
      ),
    );
  }
}

/// Where each channel of the log goes, how fast, and whether to loop.
class _ReplayDialog extends StatefulWidget {
  final _TracerPageState state;
  final String name;
  final DecodedLog log;
  const _ReplayDialog({required this.state, required this.name, required this.log});

  @override
  State<_ReplayDialog> createState() => _ReplayDialogState();
}

class _ReplayDialogState extends State<_ReplayDialog> {
  /// Log channel -> app channel, null = not replayed.
  late final Map<int, int?> route = {
    for (final ch in widget.log.frames.where((f) => !f.isError).map((f) => f.channel).toSet().toList()..sort())
      ch: ch < TraceModel.channels && widget.state.channels[ch].connected ? ch : null,
  };
  double speed = 1;
  bool loop = false;

  Duration get _length {
    final f = widget.log.frames;
    return f.isEmpty ? Duration.zero : f.last.timestamp.difference(f.first.timestamp);
  }

  void _start() {
    final frames = [
      for (final f in widget.log.frames)
        if (!f.isError && route[f.channel] != null) f.withChannel(route[f.channel]!),
    ];
    Navigator.pop(
        context,
        LogReplay(frames, widget.state.sendFrame,
            name: widget.name, speed: speed, loop: loop));
  }

  @override
  Widget build(BuildContext context) {
    final channels = widget.state.channels;
    return AlertDialog(
      title: Text('Replay ${widget.name}'),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${widget.log.frames.length} frames, '
                  '${_seconds(_length)} s'),
              const SizedBox(height: 12),
              for (final ch in route.keys)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: DropdownButtonFormField<int?>(
                    key: ValueKey('route$ch'),
                    initialValue: route[ch],
                    decoration: InputDecoration(labelText: 'Log channel ${ch + 1} to'),
                    items: [
                      const DropdownMenuItem(value: null, child: Text('Not replayed')),
                      for (final (i, c) in channels.indexed)
                        DropdownMenuItem(
                            value: i,
                            enabled: c.connected,
                            child: Text('CAN${i + 1}${c.connected ? '' : ' (not connected)'}')),
                    ],
                    onChanged: (v) => setState(() => route[ch] = v),
                  ),
                ),
              DropdownButtonFormField<double>(
                key: const ValueKey('speed'),
                initialValue: speed,
                decoration: const InputDecoration(labelText: 'Speed'),
                items: [
                  for (final s in const [0.25, 0.5, 1.0, 2.0, 5.0, 10.0])
                    DropdownMenuItem(value: s, child: Text('${s}x')),
                ],
                onChanged: (v) => setState(() => speed = v!),
              ),
              CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('Loop', style: TextStyle(fontSize: 13)),
                value: loop,
                onChanged: (v) => setState(() => loop = v!),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: route.values.any((v) => v != null) ? _start : null,
          child: const Text('Start'),
        ),
      ],
    );
  }
}
