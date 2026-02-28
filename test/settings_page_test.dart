import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taiga_sounds/settings_page.dart';

void main() {
  testWidgets('SettingsPage calls onThemeModeChanged when Dark mode toggled', (
    tester,
  ) async {
    ThemeMode? received;

    await tester.pumpWidget(
      MaterialApp(
        home: SettingsPage(
          themeMode: ThemeMode.light,
          onThemeModeChanged: (mode) => received = mode,
        ),
      ),
    );

    // Find the Dark mode switch and toggle it.
    final darkModeTile = find.text('Dark mode');
    expect(darkModeTile, findsOneWidget);

    // SwitchListTile toggles when tapped on the tile text area.
    await tester.tap(darkModeTile);
    await tester.pumpAndSettle();

    expect(received, ThemeMode.dark);
  });
}
