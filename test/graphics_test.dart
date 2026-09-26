// The Graphics view end to end on the virtual bus: plotting from the grouped
// view and the picker, the readout under the cursor, the window, removal.
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pantrace/main.dart';
import 'package:pantrace/src/can.dart';
import 'package:pantrace/src/dbc.dart';
import 'package:pantrace/src/trace.dart';

Future<dynamic> connectDemo(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(1400, 800));
  await tester.pumpWidget(const PantraceApp());
  await tester.pumpAndSettle();
  await tester.tap(find.byType(DropdownButtonFormField<CanDevice>).first);
  await tester.pumpAndSettle();
  await tester.tap(find.text('Demo traffic generator').last);
  await tester.pumpAndSettle();
  await tester.tap(find.text('Connect').first);
  await tester.pump(const Duration(milliseconds: 300));
  return tester.state(find.byType(TracerPage));
}

Future<void> disconnect(WidgetTester tester) async {
  await tester.tap(find.text('Disconnect'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('plot from the grouped view, read values under the cursor', (tester) async {
    final state = await connectDemo(tester);
    final TraceModel model = state.model;

    // Without a DBC there is nothing to pick.
    await tester.tap(find.text('Graphics'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('No signals plotted'), findsOneWidget);
    expect(find.text('Load a DBC to pick signals.'), findsOneWidget);
    expect(tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Add signals')).onPressed,
        isNull);

    model.loadDbc(0, parseDbc(File('example/demo.dbc').readAsStringSync()), 'demo.dbc');
    await tester.tap(find.text('Grouped'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('EngineData'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byTooltip('Plot EngineSpeed in Graphics'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byTooltip('Remove EngineSpeed from Graphics'), findsOneWidget);
    // What was already traced is plotted at once.
    final s = model.plot.series.single;
    expect(s.length, greaterThan(10));

    await tester.tap(find.text('Graphics'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('1: EngineData.EngineSpeed'), findsOneWidget); // sidebar
    expect(find.text('1: EngineData.EngineSpeed [rpm]'), findsOneWidget); // strip title
    expect(find.text('Latest values'), findsOneWidget);

    // Hovering the plot moves the readout to the cursor, snapped to a sample.
    final g = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await g.addPointer(location: const Offset(900, 300));
    await g.moveTo(const Offset(1000, 300));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.textContaining(RegExp(r'^At \d+\.\d{6} s$')), findsOneWidget);
    expect(find.textContaining(' rpm'), findsWidgets);
    await g.moveTo(const Offset(100, 700)); // over the sidebar: out of the plot
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Latest values'), findsOneWidget);
    await g.removePointer();

    // Touch places the cursor too.
    await tester.tapAt(const Offset(1000, 300));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.textContaining(RegExp(r'^At ')), findsOneWidget);

    // The window narrows or widens the time span.
    await tester.tap(find.byKey(const ValueKey('plotWindow')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('All').last);
    await tester.pumpAndSettle();
    expect(state.plotWindow, isNull);

    // Removing it from the sidebar empties the view again.
    await tester.tap(find.byTooltip('Remove EngineSpeed'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(model.plot.series, isEmpty);
    expect(find.textContaining('No signals plotted'), findsOneWidget);
    await disconnect(tester);
  });

  testWidgets('the picker searches, toggles and stops at eight signals', (tester) async {
    final state = await connectDemo(tester);
    final TraceModel model = state.model;
    final db = parseDbc(File('example/demo.dbc').readAsStringSync());
    model.loadDbc(0, db, 'demo.dbc');
    model.loadDbc(1, db, 'demo.dbc');
    await tester.tap(find.text('Graphics'));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('Add signals'));
    await tester.pumpAndSettle();
    expect(find.text('Plot signals (0/8)'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Search'), 'gear');
    await tester.pump();
    expect(find.text('GearState'), findsNWidgets(2)); // one per channel
    expect(find.text('EngineSpeed [rpm]'), findsNothing);
    await tester.enterText(find.widgetWithText(TextField, 'Search'), 'zzz');
    await tester.pump();
    expect(find.text('No matching signals.'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Search'), '');
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('pick-0-GearStatus-GearState')));
    await tester.pump();
    expect(find.text('Plot signals (1/8)'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('pick-0-GearStatus-GearState')));
    await tester.pump();
    expect(model.plot.series, isEmpty);

    // Fill all eight slots; the rest cannot be ticked.
    final keys = [
      for (final ch in [0, 1])
        for (final sig in ['EngineData-EngineSpeed', 'EngineData-CoolantTemp', 'EngineData-ThrottlePos', 'GearStatus-GearState'])
          'pick-$ch-$sig',
    ];
    for (final k in keys) {
      await tester.ensureVisible(find.byKey(ValueKey(k)));
      await tester.tap(find.byKey(ValueKey(k)));
      await tester.pump();
    }
    expect(model.plot.full, isTrue);
    // The list is lazy: scroll to an unticked one.
    const counter = ValueKey('pick-1-J1939Heartbeat-Counter');
    await tester.scrollUntilVisible(find.byKey(counter), 100,
        scrollable: find
            .descendant(of: find.byType(AlertDialog), matching: find.byType(Scrollable))
            .last);
    expect(tester.widget<CheckboxListTile>(find.byKey(counter)).onChanged, isNull);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    // Eight strips do not fit: they scroll, and still share one time axis.
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(SingleChildScrollView), findsWidgets);
    expect(tester.takeException(), isNull);

    // The grouped view's toggle says so when the plot is full.
    await tester.tap(find.text('Grouped'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('J1939Heartbeat').first);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byTooltip('Plot Counter in Graphics').first);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('up to 8 signals'), findsOneWidget);

    // Clearing the trace keeps the selection, drops the samples.
    await tester.tap(find.byTooltip('Clear trace'));
    await tester.pump(const Duration(milliseconds: 10));
    expect(model.plot.series.length, 8);
    await disconnect(tester);
  });
}
