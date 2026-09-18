import 'dart:io';

import 'package:pantrace/main.dart';
import 'package:pantrace/src/dbc.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The app is a desktop window the user can shrink; nothing may overflow and
/// every control must stay hittable. 640x480 is the floor the native runners
/// enforce as the minimum window size.
void main() {
  for (final size in const [Size(640, 480), Size(800, 600), Size(1024, 768), Size(1440, 900)]) {
    testWidgets('lays out and stays operable at ${size.width}x${size.height}',
        (tester) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(const PantraceApp());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      // Controls that must remain reachable without a maximised window.
      for (final label in ['Connect', 'Load DBC', 'Export CSV']) {
        final finder = find.text(label);
        expect(finder, findsWidgets, reason: '$label missing at $size');
        for (final e in finder.evaluate()) {
          final rect = tester.getRect(find.byWidget(e.widget));
          expect(rect.right, lessThanOrEqualTo(size.width),
              reason: '$label clipped at $size');
        }
      }

      // Connecting swaps labels and icons; none of that may move the toolbar,
      // or controls get pushed onto another run and out of the window.
      Map<String, Rect> geometry() => {
            for (final l in ['Load DBC', 'Export CSV', 'Send'])
              l: tester.getRect(find.text(l)),
          };
      final layout = geometry();

      // The trace table degrades to a sideways scroll rather than crushed columns.
      await tester.tap(find.text('Connect').first);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(geometry(), layout, reason: 'toolbar shifted on connect at $size');

      final state = tester.state(find.byType(TracerPage)) as dynamic;
      state.model.loadDbc(
          parseDbc(File('example/demo.dbc').readAsStringSync()), 'demo.dbc');
      await tester.pumpAndSettle();
      expect(geometry(), layout, reason: 'toolbar shifted on DBC load at $size');
    });
  }
}
