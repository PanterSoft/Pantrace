part of '../main.dart';

// The Graphics view: plotted DBC signals as small multiples — one strip per
// signal with its own y-scale, all on one shared time axis — so signals of
// different units never share (or fake) an axis.

/// Series colours: the dark steps of the reference categorical palette, in its
/// fixed order, validated on this app's #101510 surface (worst adjacent CVD
/// ΔE 8.4, all ≥ 3:1). A series keeps its slot for life.
const _seriesColors = [
  Color(0xFF3987E5), Color(0xFFD95926), Color(0xFF199E70), Color(0xFFC98500),
  Color(0xFFD55181), Color(0xFF008300), Color(0xFF9085E9), Color(0xFFE66767),
];

const _plotSurface = Color(0xFF101510);
const _gridColor = Color(0xFF2C2C2A);
const _axisColor = Color(0xFF383835);
const _mutedInk = Color(0xFF898781);
const _secondaryInk = Color(0xFFC3C2B7);
const _primaryInk = Color(0xFFFFFFFF);

/// Time windows offered for the plot; null shows everything recorded.
const _plotWindows = <double?>[1, 5, 10, 30, 60, null];

const _yGutter = 56.0;
const _rightPad = 16.0;
const _minStrip = 64.0;
const _timeAxisHeight = 24.0;

Color _seriesColor(SignalSeries s) => _seriesColors[s.slot % _seriesColors.length];

class _GraphicsView extends StatefulWidget {
  final _TracerPageState state;
  const _GraphicsView({required this.state});
  @override
  State<_GraphicsView> createState() => _GraphicsViewState();
}

class _GraphicsViewState extends State<_GraphicsView> {
  /// Time under the pointer, snapped to the nearest sample; null when the
  /// pointer is outside the plot.
  final hover = ValueNotifier<int?>(null);

  @override
  void dispose() {
    hover.dispose();
    super.dispose();
  }

  TraceModel get model => widget.state.model;

  /// Visible time range in microseconds since epoch.
  (int, int)? _range() {
    final plot = model.plot;
    final last = plot.lastTime;
    final first = plot.firstTime;
    if (last == null || first == null) return null;
    final window = widget.state.plotWindow;
    // Until a window's worth is recorded, show what there is edge to edge.
    final from = window == null ? first : math.max(first, last - (window * 1e6).round());
    // A single sample (or a burst at one instant) still gets a visible span.
    return from < last ? (from, last) : (last - 1000000, last);
  }

  /// Snaps [t] to the closest sample of any plotted series.
  int _snap(int t) {
    int? best;
    for (final s in model.plot.series) {
      final i = s.nearest(t);
      if (i == null) continue;
      final c = s.timeAt(i);
      if (best == null || (c - t).abs() < (best - t).abs()) best = c;
    }
    return best ?? t;
  }

  @override
  Widget build(BuildContext context) {
    final plot = model.plot;
    return LayoutBuilder(builder: (context, c) => Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // A narrow window keeps most of its width for the plot.
        SizedBox(width: math.min(240, c.maxWidth * 0.32), child: _sidebar(context)),
        const VerticalDivider(width: 1),
        Expanded(
          child: plot.series.isEmpty
              ? const _Empty('No signals plotted — add some with "Add signals", '
                  'or the chart button on a signal row in the Grouped view.')
              : _plots(),
        ),
      ],
    ));
  }

  Widget _sidebar(BuildContext context) {
    final state = widget.state;
    final plot = model.plot;
    final anyDbc = model.dbcs.any((d) => d != null);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 4),
          child: Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: anyDbc ? () => showDialog(
                    context: context, builder: (_) => _SignalPickerDialog(state: state)) : null,
                icon: const Icon(Icons.add),
                label: const Text('Add signals'),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 76,
              child: DropdownButtonFormField<double?>(
                key: const ValueKey('plotWindow'),
                initialValue: state.plotWindow,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Window', isDense: true),
                items: [
                  for (final w in _plotWindows)
                    DropdownMenuItem(value: w, child: Text(w == null ? 'All' : '${w.toInt()} s')),
                ],
                onChanged: (w) => state.setPlotWindow(w),
              ),
            ),
          ]),
        ),
        if (!anyDbc)
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text('Load a DBC to pick signals.',
                style: TextStyle(color: Colors.grey, fontSize: 12)),
          ),
        // The readout: every signal's value at the cursor (or its latest).
        ValueListenableBuilder<int?>(
          valueListenable: hover,
          builder: (context, t, _) => Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
            child: Text(
              t == null
                  ? 'Latest values'
                  : 'At ${_seconds(Duration(microseconds: t - _zero()))} s',
              style: const TextStyle(fontSize: 11, color: _mutedInk),
            ),
          ),
        ),
        Expanded(
          child: ListView(
            children: [
              for (final s in plot.series)
                ValueListenableBuilder<int?>(
                  valueListenable: hover,
                  builder: (context, t, _) {
                    final v = s.isEmpty ? null : (t == null ? s.lastValue : s.heldAt(t));
                    return ListTile(
                      dense: true,
                      key: ValueKey('series-${s.label}'),
                      contentPadding: const EdgeInsets.only(left: 12, right: 4),
                      minLeadingWidth: 16,
                      // The key beside the name carries identity; the text
                      // itself stays in text ink.
                      leading: Container(width: 16, height: 3, color: _seriesColor(s)),
                      title: Text(s.label,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12, color: _primaryInk)),
                      subtitle: Text(v == null ? '—' : s.format(v),
                          style: _mono.copyWith(fontSize: 12, color: _secondaryInk)),
                      trailing: IconButton(
                        tooltip: 'Remove ${s.signal.name}',
                        iconSize: 16,
                        onPressed: () => plot.remove(s.key),
                        icon: const Icon(Icons.close),
                      ),
                    );
                  },
                ),
            ],
          ),
        ),
      ],
    );
  }

  /// Time zero of the axis: the measurement start, else the first sample.
  int _zero() =>
      model.measurementStart?.microsecondsSinceEpoch ?? model.plot.firstTime ?? 0;

  Widget _plots() {
    final range = _range();
    final series = model.plot.series;
    return LayoutBuilder(builder: (context, c) {
      final avail = c.maxHeight - _timeAxisHeight;
      final strip = math.max(_minStrip, avail / series.length);
      final strips = Column(children: [
        for (final s in series)
          SizedBox(height: strip, child: _strip(s, range, c.maxWidth)),
      ]);
      void track(Offset p) {
        if (range == null) return;
        final w = c.maxWidth - _yGutter - _rightPad;
        final x = (p.dx - _yGutter).clamp(0.0, w);
        final t = range.$1 + ((range.$2 - range.$1) * x / w).round();
        hover.value = _snap(t);
      }

      return MouseRegion(
        onHover: (e) => track(e.localPosition),
        onExit: (_) => hover.value = null,
        child: GestureDetector(
          // Touch and click also place the cursor.
          onTapDown: (d) => track(d.localPosition),
          onHorizontalDragUpdate: (d) => track(d.localPosition),
          child: Column(children: [
            Expanded(
              child: strip * series.length > avail
                  ? SingleChildScrollView(child: strips)
                  : strips,
            ),
            SizedBox(
              height: _timeAxisHeight,
              child: range == null
                  ? null
                  : ValueListenableBuilder<int?>(
                      valueListenable: hover,
                      builder: (_, t, _) => CustomPaint(
                        size: Size.infinite,
                        painter: _TimeAxisPainter(range.$1, range.$2, _zero(), t),
                      ),
                    ),
            ),
          ]),
        ),
      );
    });
  }

  Widget _strip(SignalSeries s, (int, int)? range, double width) {
    return Stack(children: [
      Positioned.fill(
        child: range == null
            ? const SizedBox()
            : ValueListenableBuilder<int?>(
                valueListenable: hover,
                builder: (_, t, _) => CustomPaint(
                  painter: _StripPainter(s, _seriesColor(s), range.$1, range.$2, t),
                ),
              ),
      ),
      // Title: the strip names its signal, so a legend box is not needed.
      Positioned(
        left: _yGutter + 6,
        top: 2,
        right: _rightPad,
        child: Row(children: [
          Container(width: 12, height: 2, color: _seriesColor(s)),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              '${s.label}${s.unit.isEmpty ? '' : ' [${s.unit}]'}',
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: _secondaryInk),
            ),
          ),
          const SizedBox(width: 8),
          // The value at the cursor, like the readout; the latest without one.
          ValueListenableBuilder<int?>(
            valueListenable: hover,
            builder: (_, t, _) {
              final v = s.isEmpty ? null : (t == null ? s.lastValue : s.heldAt(t));
              return Text(v == null ? '' : s.format(v),
                  style: _mono.copyWith(fontSize: 11, color: _primaryInk));
            },
          ),
        ]),
      ),
    ]);
  }
}

/// One signal's strip: its own y-scale, hairline grid, 2px line (steps for
/// enumerations and flags), an end dot, and the cursor.
class _StripPainter extends CustomPainter {
  final SignalSeries s;
  final Color color;
  final int from, to;
  final int? hover;
  _StripPainter(this.s, this.color, this.from, this.to, this.hover);

  static const _top = 18.0, _bottom = 6.0;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width - _yGutter - _rightPad;
    final h = size.height - _top - _bottom;
    if (w <= 0 || h <= 0) return;

    // y-range from what is visible, padded; a flat signal gets a band around it.
    final r = s.range(from, to) ??
        (s.heldAt(from) != null ? (s.heldAt(from)!, s.heldAt(from)!) : null);
    var lo = r?.$1 ?? 0, hi = r?.$2 ?? 1;
    final held = s.heldAt(from);
    if (held != null) {
      lo = math.min(lo, held);
      hi = math.max(hi, held);
    }
    if (hi - lo < 1e-9) {
      final pad = lo.abs() > 1 ? lo.abs() * 0.1 : 1.0;
      lo -= pad;
      hi += pad;
    } else {
      final pad = (hi - lo) * 0.08;
      lo -= pad;
      hi += pad;
    }
    double x(int t) => _yGutter + (t - from) * w / (to - from);
    double y(double v) => _top + h - (v - lo) * h / (hi - lo);

    final grid = Paint()
      ..color = _gridColor
      ..strokeWidth = 1;
    for (final tick in niceTicks(lo, hi, count: math.max(1, (h / 28).floor()))) {
      final ty = y(tick).roundToDouble() + 0.5;
      canvas.drawLine(Offset(_yGutter, ty), Offset(_yGutter + w, ty), grid);
      _label(canvas, formatNumber(tick), Offset(_yGutter - 6, ty), right: true);
    }
    canvas.drawLine(Offset(_yGutter, _top + h + 0.5), Offset(_yGutter + w, _top + h + 0.5),
        Paint()..color = _axisColor);

    // The line, clipped to the plot area; points outside the window only
    // steer the segments that enter it.
    final pts = decimate(s, from, to, w.ceil());
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(_yGutter, _top - 4, w, h + 8));
    if (pts.isNotEmpty) {
      final path = Path()..moveTo(x(pts.first.$1), y(pts.first.$2));
      for (var i = 1; i < pts.length; i++) {
        if (s.stepped) path.lineTo(x(pts[i].$1), y(pts[i - 1].$2));
        path.lineTo(x(pts[i].$1), y(pts[i].$2));
      }
      // Hold the last value up to the right edge.
      if (pts.last.$1 < to) path.lineTo(x(to), y(pts.last.$2));
      canvas.drawPath(
          path,
          Paint()
            ..color = color
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..strokeJoin = StrokeJoin.round
            ..strokeCap = StrokeCap.round);
    }
    canvas.restore();

    // End dot on the newest sample, ringed in the surface colour.
    if (!s.isEmpty && s.lastTime >= from && s.lastTime <= to && hover == null) {
      _dot(canvas, Offset(x(s.lastTime), y(s.lastValue)));
    }

    // The cursor: a hairline through every strip and the held value.
    final t = hover;
    if (t != null && t >= from && t <= to) {
      final cx = x(t).roundToDouble() + 0.5;
      canvas.drawLine(Offset(cx, _top - 4), Offset(cx, _top + h),
          Paint()..color = _secondaryInk.withValues(alpha: 0.6));
      final v = s.heldAt(t);
      if (v != null) _dot(canvas, Offset(x(t), y(v)));
    }
  }

  void _dot(Canvas canvas, Offset p) {
    canvas.drawCircle(p, 6, Paint()..color = _plotSurface);
    canvas.drawCircle(p, 4, Paint()..color = color);
  }

  static void _label(Canvas canvas, String text, Offset at, {bool right = false}) {
    final tp = TextPainter(
      text: TextSpan(
          text: text,
          style: const TextStyle(
              fontSize: 10,
              color: _mutedInk,
              fontFeatures: [FontFeature.tabularFigures()])),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(right ? at.dx - tp.width : at.dx - tp.width / 2, at.dy - tp.height / 2));
  }

  @override
  bool shouldRepaint(covariant _StripPainter old) => true;
}

/// Seconds since the measurement start along the bottom, plus the cursor time.
class _TimeAxisPainter extends CustomPainter {
  final int from, to, zero;
  final int? hover;
  _TimeAxisPainter(this.from, this.to, this.zero, this.hover);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width - _yGutter - _rightPad;
    if (w <= 0) return;
    double x(int t) => _yGutter + (t - from) * w / (to - from);
    final a = (from - zero) / 1e6, b = (to - zero) / 1e6;
    for (final s in niceTicks(a, b, count: math.max(2, (w / 90).floor()))) {
      final tx = x(zero + (s * 1e6).round());
      canvas.drawLine(Offset(tx, 0), Offset(tx, 4), Paint()..color = _axisColor);
      _StripPainter._label(canvas, '${formatNumber(s)} s', Offset(tx, 13));
    }
    final t = hover;
    if (t != null && t >= from && t <= to) {
      final label = '${_seconds(Duration(microseconds: t - zero))} s';
      final tp = TextPainter(
        text: TextSpan(
            text: label,
            style: const TextStyle(
                fontSize: 10,
                color: _primaryInk,
                fontFeatures: [FontFeature.tabularFigures()])),
        textDirection: TextDirection.ltr,
      )..layout();
      final cx = x(t).clamp(_yGutter + tp.width / 2 + 4, _yGutter + w - tp.width / 2 - 4);
      final box = Rect.fromCenter(center: Offset(cx, 13), width: tp.width + 8, height: tp.height + 4);
      canvas.drawRRect(RRect.fromRectAndRadius(box, const Radius.circular(3)),
          Paint()..color = _axisColor);
      tp.paint(canvas, Offset(box.left + 4, box.top + 2));
    }
  }

  @override
  bool shouldRepaint(covariant _TimeAxisPainter old) => true;
}

/// Picks signals to plot from the loaded DBCs; toggles apply at once.
class _SignalPickerDialog extends StatefulWidget {
  final _TracerPageState state;
  const _SignalPickerDialog({required this.state});
  @override
  State<_SignalPickerDialog> createState() => _SignalPickerDialogState();
}

class _SignalPickerDialogState extends State<_SignalPickerDialog> {
  String query = '';

  @override
  Widget build(BuildContext context) {
    final model = widget.state.model;
    final q = query.trim().toLowerCase();
    final rows = <Widget>[];
    for (var ch = 0; ch < TraceModel.channels; ch++) {
      final db = model.dbcs[ch];
      if (db == null) continue;
      final msgs = db.messages.values.toList()..sort((a, b) => a.name.compareTo(b.name));
      for (final m in msgs) {
        final sigs = m.signals
            .where((s) => q.isEmpty ||
                s.name.toLowerCase().contains(q) ||
                m.name.toLowerCase().contains(q))
            .toList();
        if (sigs.isEmpty) continue;
        rows.add(Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 2),
          child: Text('CAN${ch + 1} · ${m.name} (${m.extended ? 'x' : ''}${_hexId(m.id, m.extended)})',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: _secondaryInk)),
        ));
        for (final s in sigs) {
          final key = SignalKey(ch, m.id, m.extended, s.name);
          final on = model.plot.contains(key);
          rows.add(CheckboxListTile(
            key: ValueKey('pick-$ch-${m.name}-${s.name}'),
            dense: true,
            contentPadding: const EdgeInsets.only(left: 8),
            title: Text('${s.name}${s.unit.isEmpty ? '' : ' [${s.unit}]'}',
                style: const TextStyle(fontSize: 13)),
            value: on,
            onChanged: !on && model.plot.full
                ? null
                : (v) => setState(() {
                      if (v!) {
                        model.plotSignal(ch, m, s);
                      } else {
                        model.plot.remove(key);
                      }
                    }),
          ));
        }
      }
    }
    return AlertDialog(
      title: Text('Plot signals (${model.plot.series.length}/${SignalPlot.maxSeries})'),
      content: SizedBox(
        width: 420,
        height: 420,
        child: Column(children: [
          TextField(
            autofocus: true,
            decoration: const InputDecoration(
                labelText: 'Search', prefixIcon: Icon(Icons.search, size: 18)),
            onChanged: (v) => setState(() => query = v),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: rows.isEmpty
                ? const _Empty('No matching signals.')
                : ListView(children: rows),
          ),
        ]),
      ),
      actions: [
        FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Done')),
      ],
    );
  }
}
