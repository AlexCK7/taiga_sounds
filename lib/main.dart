import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'loading_screen.dart';
import 'audio_sanity_page.dart';

void main() {
  runApp(const TaigaSoundsApp());
}

class TaigaSoundsApp extends StatefulWidget {
  const TaigaSoundsApp({super.key});

  @override
  State<TaigaSoundsApp> createState() => _TaigaSoundsAppState();
}

class _TaigaSoundsAppState extends State<TaigaSoundsApp> {
  ThemeMode _themeMode = ThemeMode.system;

  void setThemeMode(ThemeMode mode) {
    setState(() => _themeMode = mode);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Taiga Sounds',
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: _themeMode,
      home: LoadingScreen(
        onThemeModeChanged: setThemeMode,
        themeMode: _themeMode,
      ),
      routes: {'/sanity': (_) => const AudioSanityPage()},
    );
  }
}
