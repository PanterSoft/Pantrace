part of '../main.dart';

String _hexBytes(Uint8List data) =>
    data.map((b) => b.toRadixString(16).toUpperCase().padLeft(2, '0')).join(' ');

/// A physical value without float noise: 12.5, not 12.500000000001.
String _number(double v) {
  if (v == v.roundToDouble() && v.abs() < 1e15) return v.toInt().toString();
  return double.parse(v.toStringAsPrecision(10)).toString();
}

/// Compose and send a frame once or cyclically — raw, or by signal values
/// when the channel has a DBC (CANoe's Interactive Generator).
class _SendDialog extends StatefulWidget {
  final _TracerPageState state;
  const _SendDialog({required this.state});
  @override
  State<_SendDialog> createState() => _SendDialogState();
}

class _SendDialogState extends State<_SendDialog> {
  late int channel =
      widget.state.channels.indexWhere((c) => c.connected).clamp(0, 99);
  final idCtrl = TextEditingController(text: '123');
  final dataCtrl = TextEditingController(text: '00 11 22 33');
  final cycleCtrl = TextEditingController();
  bool extended = false;
  bool rtr = false;
  String? error;
  DbcMessage? message;
  final signalCtrls = <String, TextEditingController>{};

  DbcDatabase? get db => widget.state.model.dbcs[channel];

  @override
  void dispose() {
    for (final c in [idCtrl, dataCtrl, cycleCtrl, ...signalCtrls.values]) {
      c.dispose();
    }
    super.dispose();
  }

  /// The data field as bytes, or null with [error] set.
  Uint8List? _data() {
    final hex = dataCtrl.text.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
    if (hex.length.isOdd) {
      setState(() => error = 'Data needs whole bytes');
      return null;
    }
    if (hex.length > 16) {
      setState(() => error = 'Max 8 data bytes');
      return null;
    }
    final data = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < data.length; i++) {
      data[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return data;
  }

  void _pickMessage(DbcMessage? m) {
    setState(() {
      message = m;
      error = null;
      if (m == null) return;
      idCtrl.text = m.id.toRadixString(16).toUpperCase();
      extended = m.extended;
      rtr = false;
      final data = Uint8List(m.length.clamp(0, 8));
      dataCtrl.text = _hexBytes(data);
      _showSignals(data);
    });
  }

  /// Fills the signal fields from [data].
  void _showSignals(Uint8List data) {
    for (final s in message?.signals ?? const <DbcSignal>[]) {
      signalCtrls.putIfAbsent(s.name, TextEditingController.new).text =
          _number(s.decode(data));
    }
  }

  /// A signal field changed: encode it into the data bytes. Accepts a number
  /// or a value-table name.
  void _setSignal(DbcSignal s, String text) {
    final m = message;
    if (m == null) return;
    final named = s.valueTable.entries
        .where((e) => e.value.toLowerCase() == text.trim().toLowerCase())
        .map((e) => e.key)
        .firstOrNull;
    final phys = double.tryParse(text.trim());
    if (named == null && phys == null) return;
    final current = _data() ?? Uint8List(0);
    final data = Uint8List(m.length.clamp(0, 8))
      ..setRange(0, math.min(current.length, m.length.clamp(0, 8)), current);
    s.rawInto(data, named ?? s.encodeRaw(phys!));
    setState(() {
      error = null;
      dataCtrl.text = _hexBytes(data);
    });
  }

  Future<void> _send() async {
    final id = int.tryParse(idCtrl.text.trim(), radix: 16);
    if (id == null) return setState(() => error = 'ID must be hex');
    if (id > (extended ? 0x1FFFFFFF : 0x7FF)) {
      return setState(() => error = 'ID does not fit in an ${extended ? 29 : 11}-bit identifier');
    }
    final data = _data();
    if (data == null) return;
    final cycleText = cycleCtrl.text.trim();
    final cycle = cycleText.isEmpty ? 0 : int.tryParse(cycleText);
    if (cycle == null || cycle < 0) {
      return setState(() => error = 'Cycle time must be whole milliseconds');
    }
    final frame = CanFrame(
        id: id, data: data, extended: extended, rtr: rtr, direction: FrameDirection.tx);
    try {
      if (cycle > 0) {
        widget.state.tx.add(channel, frame, Duration(milliseconds: cycle));
      } else {
        await widget.state.sendFrame(channel, frame);
      }
      if (mounted) Navigator.pop(context);
    } catch (e) {
      setState(() => error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final messages = (db?.messages.values.toList() ?? <DbcMessage>[])
      ..sort((a, b) => a.name.compareTo(b.name));
    if (message != null && !messages.contains(message)) message = null;
    return AlertDialog(
      title: const Text('Send CAN frame'),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SegmentedButton<int>(
                segments: [
                  for (final (i, c) in widget.state.channels.indexed)
                    ButtonSegment(
                        value: i, enabled: c.connected, label: Text('CAN${i + 1}')),
                ],
                selected: {channel},
                onSelectionChanged: (s) => setState(() => channel = s.first),
              ),
              if (messages.isNotEmpty) ...[
                const SizedBox(height: 12),
                DropdownButtonFormField<DbcMessage?>(
                  key: ValueKey('msg$channel'),
                  initialValue: message,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'DBC message'),
                  items: [
                    const DropdownMenuItem(value: null, child: Text('Raw frame')),
                    for (final m in messages)
                      DropdownMenuItem(
                          value: m,
                          child: Text(
                              '${m.name}  (${m.extended ? 'x' : ''}${_hexId(m.id, m.extended)})',
                              overflow: TextOverflow.ellipsis)),
                  ],
                  onChanged: _pickMessage,
                ),
              ],
              const SizedBox(height: 12),
              TextField(
                controller: idCtrl,
                style: _mono,
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9a-fA-F]'))],
                decoration: const InputDecoration(
                    labelText: 'Identifier (hex)', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: dataCtrl,
                style: _mono,
                onChanged: (_) {
                  final d = _data();
                  if (d != null) _showSignals(d);
                },
                decoration: const InputDecoration(
                    labelText: 'Data (hex bytes)',
                    hintText: 'DE AD BE EF',
                    border: OutlineInputBorder()),
              ),
              if (message != null)
                for (final s in message!.signals)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: TextField(
                      key: ValueKey('sig-${s.name}'),
                      controller:
                          signalCtrls.putIfAbsent(s.name, TextEditingController.new),
                      style: _mono,
                      onChanged: (v) => _setSignal(s, v),
                      decoration: InputDecoration(
                        labelText: '${s.name}${s.unit.isEmpty ? '' : ' [${s.unit}]'}',
                        helperText: s.valueTable.isEmpty
                            ? null
                            : s.valueTable.entries.map((e) => '${e.key}=${e.value}').join('  '),
                        border: const OutlineInputBorder(),
                      ),
                    ),
                  ),
              const SizedBox(height: 12),
              TextField(
                controller: cycleCtrl,
                style: _mono,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(
                    labelText: 'Cycle time (ms)',
                    hintText: 'empty = send once',
                    border: OutlineInputBorder()),
              ),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: CheckboxListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('29-bit', style: TextStyle(fontSize: 13)),
                    value: extended,
                    onChanged: (v) => setState(() => extended = v!),
                  ),
                ),
                Expanded(
                  child: CheckboxListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('RTR', style: TextStyle(fontSize: 13)),
                    value: rtr,
                    onChanged: (v) => setState(() => rtr = v!),
                  ),
                ),
              ]),
              if (error != null)
                Text(error!, style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _send, child: const Text('Send')),
      ],
    );
  }
}

/// The running cyclic frames: pause, resume, delete.
class _TxListDialog extends StatelessWidget {
  final _TracerPageState state;
  const _TxListDialog({required this.state});

  @override
  Widget build(BuildContext context) {
    final tx = state.tx;
    // The model ticks at 20 Hz, which keeps the sent counters moving.
    return ListenableBuilder(
      listenable: Listenable.merge([tx, state.model]),
      builder: (context, _) => AlertDialog(
        title: const Text('Cyclic transmit list'),
        content: SizedBox(
          width: 560,
          child: tx.jobs.isEmpty
              ? const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Text('Nothing is sent cyclically. Use Send with a cycle '
                      'time to add a frame here.',
                      style: TextStyle(color: Colors.grey)),
                )
              : SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final j in tx.jobs)
                        ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: Text('CAN${j.channel + 1}', style: _mono),
                          title: Text(
                              '${j.frame.extended ? 'x' : ''}${j.frame.idHex}  '
                              '[${j.frame.data.length}] ${j.frame.dataHex}'
                              '${j.frame.rtr ? '  RTR' : ''}',
                              style: _mono),
                          subtitle: Text(
                              j.error ??
                                  '${j.period.inMilliseconds} ms · ${j.sent} sent'
                                      '${j.running ? '' : ' · stopped'}',
                              style: TextStyle(
                                  fontSize: 11,
                                  color: j.error != null ? Colors.redAccent : Colors.grey)),
                          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                            IconButton(
                              tooltip: j.running ? 'Pause' : 'Resume',
                              onPressed: () => j.running ? tx.stop(j) : tx.start(j),
                              icon: Icon(j.running ? Icons.pause : Icons.play_arrow),
                            ),
                            IconButton(
                              tooltip: 'Remove',
                              onPressed: () => tx.remove(j),
                              icon: const Icon(Icons.delete_outline),
                            ),
                          ]),
                        ),
                    ],
                  ),
                ),
        ),
        actions: [
          TextButton(
            onPressed: tx.running > 0 ? () => tx.stopAll() : null,
            child: const Text('Stop all'),
          ),
          FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
        ],
      ),
    );
  }
}
