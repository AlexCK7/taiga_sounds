import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'loading_screen.dart';

void main() {
  runApp(const TaigaSoundsApp());
}

class TaigaSoundsApp extends StatelessWidget {
  const TaigaSoundsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Taiga Sounds',

      // ✅ This is the correct place to wire your themes
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,

      // ✅ Use system theme (recommended)
      themeMode: ThemeMode.system, // change to ThemeMode.light to force light

      home: const LoadingScreen(),
    );
  }
}
