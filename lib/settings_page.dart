import 'package:flutter/material.dart';

class SettingsPage extends StatefulWidget {
  final ThemeMode
  themeMode; // kept for compatibility, not required for UI state
  final ValueChanged<ThemeMode> onThemeModeChanged;

  const SettingsPage({
    super.key,
    required this.themeMode,
    required this.onThemeModeChanged,
  });

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool _lowLatency = false;
  bool _stopOnNew = false;
  bool _haptics = true;

  void _showNotImplemented(String feature) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('$feature not implemented yet')));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurface.withAlpha((0.70 * 255).toInt()),
      fontWeight: FontWeight.w600,
    );

    // ✅ Always reflect the real current theme (even if RootPage has old props)
    final isDarkNow = theme.brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const _SectionHeader(
            title: 'Playback',
            subtitle: 'Tweak how sounds behave and feel.',
          ),
          const SizedBox(height: 10),
          Card(
            child: Column(
              children: [
                SwitchListTile(
                  title: const Text('Low-latency mode'),
                  subtitle: const Text('Reduce buffering for minimal delay'),
                  value: _lowLatency,
                  onChanged: (val) => setState(() => _lowLatency = val),
                  secondary: const Icon(Icons.speed_outlined),
                ),
                const Divider(height: 1),
                SwitchListTile(
                  title: const Text('Stop others on new sound'),
                  subtitle: const Text(
                    'Automatically stop playing sounds when a new one starts',
                  ),
                  value: _stopOnNew,
                  onChanged: (val) => setState(() => _stopOnNew = val),
                  secondary: const Icon(Icons.stop_circle_outlined),
                ),
                const Divider(height: 1),
                SwitchListTile(
                  title: const Text('Haptic feedback'),
                  subtitle: const Text('Vibrate on button presses'),
                  value: _haptics,
                  onChanged: (val) => setState(() => _haptics = val),
                  secondary: const Icon(Icons.vibration_outlined),
                ),
                const Divider(height: 1),
                SwitchListTile(
                  title: const Text('Dark mode'),
                  subtitle: const Text('Toggle the app theme'),
                  value: isDarkNow,
                  onChanged: (val) {
                    widget.onThemeModeChanged(
                      val ? ThemeMode.dark : ThemeMode.light,
                    );
                    // No local setState needed — theme change will rebuild via InheritedWidget
                  },
                  secondary: const Icon(Icons.dark_mode_outlined),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Tip: Theme switching is live now. Other toggles are session-only.',
            style: muted,
          ),
          const SizedBox(height: 22),
          const _SectionHeader(
            title: 'Library management',
            subtitle: 'Backup, restore, or reset your library.',
          ),
          const SizedBox(height: 10),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.backup_outlined),
                  title: const Text('Export library'),
                  subtitle: const Text(
                    'Save your sounds and settings to a file',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _showNotImplemented('Export'),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.restore_outlined),
                  title: const Text('Import library'),
                  subtitle: const Text('Load sounds and settings from a file'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _showNotImplemented('Import'),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: Icon(
                    Icons.delete_forever_outlined,
                    color: theme.colorScheme.error,
                  ),
                  title: Text(
                    'Clear library',
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                  subtitle: const Text(
                    'Delete all imported sounds and reset settings',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _showNotImplemented('Clear'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  final String? subtitle;

  const _SectionHeader({required this.title, this.subtitle});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final subtitleStyle = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurface.withAlpha((0.70 * 255).toInt()),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: theme.textTheme.titleMedium),
        if (subtitle != null) ...[
          const SizedBox(height: 4),
          Text(subtitle!, style: subtitleStyle),
        ],
      ],
    );
  }
}
