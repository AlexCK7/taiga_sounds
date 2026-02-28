import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taiga_sounds/app_theme.dart';

void main() {
  test('AppTheme light and dark themes build with expected brightness', () {
    expect(AppTheme.lightTheme.brightness, Brightness.light);
    expect(AppTheme.darkTheme.brightness, Brightness.dark);
  });
}
