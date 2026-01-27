import 'package:flutter/material.dart';

import 'sound_library_page.dart';
import 'upload_sound_page.dart';
import 'record_sound_page.dart';
import 'settings_page.dart';

/// Hosts the bottom navigation bar and manages switching between
/// the library, import, record and settings pages. The actual pages
/// are provided in a list so that their state persists when
/// switching tabs. If you add or remove pages, update both this list
/// and the BottomNavigationBar items accordingly.
class RootPage extends StatefulWidget {
  const RootPage({super.key});

  @override
  State<RootPage> createState() => _RootPageState();
}

class _RootPageState extends State<RootPage> {
  int _selectedIndex = 0;

  /// List of tabs in the bottom navigation. These must match the order
  /// of the items in the [BottomNavigationBar].
  static final List<Widget> _pages = <Widget>[
    const SoundLibraryPage(),
    const UploadSoundPage(),
    const RecordSoundPage(),
    const SettingsPage(),
  ];

  void _onItemTapped(int index) {
    setState(() => _selectedIndex = index);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _pages[_selectedIndex],
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _selectedIndex,
        onTap: _onItemTapped,
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.library_music),
            label: 'Library',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.folder_open),
            label: 'Device',
          ),
          BottomNavigationBarItem(icon: Icon(Icons.mic), label: 'Record'),
          BottomNavigationBarItem(
            icon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}
