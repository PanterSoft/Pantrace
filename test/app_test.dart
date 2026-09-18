import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pantrace/main.dart';
import 'package:pantrace/src/can.dart';
import 'package:pantrace/src/dbc.dart';

/// End-to-end through the real widgets, using the virtual backend so it runs
/// headless on CI with no hardware.
void main() {
  testWidgets('connects to the virtual bus, traces, and decodes with a DBC',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 800));
    await tester.pumpWidget(const PantraceApp());
    await tester.pumpAndSettle();

    // Discovery is async; pick the demo generator for CAN1 once it appears.
    await tester.tap(find.byType(DropdownButtonFormField<CanDevice>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Demo traffic generator').last);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Connect').first);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Disconnect'), findsOneWidget);
    // Grouped view shows one row per id; the generator uses 0x123 and 0x100.
    expect(find.text('123'), findsOneWidget);
    expect(find.text('100'), findsOneWidget);
    expect(find.text('—'), findsWidgets); // no DBC yet: unnamed

    // Load the DBC through the model rather than the native file dialog.
    final state = tester.state(find.byType(TracerPage)) as dynamic;
    state.model.loadDbc(
        parseDbc(File('example/demo.dbc').readAsStringSync()), 'demo.dbc');
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('EngineData'), findsOneWidget);
    expect(find.text('GearStatus'), findsOneWidget);

    // Signals are collapsed until the message row is expanded.
    expect(find.textContaining('EngineSpeed'), findsNothing);
    await tester.tap(find.text('EngineData'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('EngineSpeed'), findsOneWidget);
    expect(find.textContaining('CoolantTemp'), findsOneWidget);
    expect(find.textContaining('rpm'), findsWidgets);
    // Collapse again.
    await tester.tap(find.text('EngineData'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('EngineSpeed'), findsNothing);
    // Expand all via the header button.
    await tester.tap(find.byTooltip('Expand all'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('GearState'), findsOneWidget);

    // Live view lists individual frames with a direction column.
    await tester.tap(find.text('Live'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Rx'), findsWidgets);

    // Send a frame and see it echoed as Tx.
    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Identifier (hex)'), '7AB');
    await tester.tap(find.widgetWithText(FilledButton, 'Send'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Tx'), findsWidgets);
    expect(find.text('7AB'), findsWidgets);

    await tester.tap(find.text('Disconnect'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Connect'), findsNWidgets(2));
  });

  testWidgets('traces two buses side by side, keyed per channel', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 800));
    await tester.pumpWidget(const PantraceApp());
    await tester.pumpAndSettle();

    for (final i in [0, 1]) {
      await tester.tap(find.byType(DropdownButtonFormField<CanDevice>).at(i));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Demo traffic generator').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Connect').first);
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Disconnect'), findsNWidgets(2));

    // The same id on both buses is two rows, not one merged counter.
    expect(find.text('123'), findsNWidgets(2));
    final state = tester.state(find.byType(TracerPage)) as dynamic;
    expect(state.model.groupedRows.map((r) => r.channel).toSet(), {0, 1});

    // Sending offers a channel choice.
    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();
    expect(find.text('CAN2'), findsWidgets);
  });
}
