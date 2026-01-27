import 'package:flutter/material.dart';

/// A placeholder page for recording new audio.
///
/// In a future version, this page will allow users to record their
/// own sounds using the microphone, preview them, rename the clip
/// and save it into the sound library. Implementing recording
/// requires additional plugins (e.g. flutter_sound) and permission
/// handling. For now we display a friendly message to set
/// expectations.
class RecordSoundPage extends StatelessWidget {
  const RecordSoundPage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Record')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.mic_none, size: 64, color: theme.colorScheme.primary),
              const SizedBox(height: 24),
              Text(
                'Record your own sounds',
                style: theme.textTheme.headlineSmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              Text(
                'Recording and editing will arrive in a future update. You will be able to capture audio, trim and normalise it before adding it to your library.',
                style: theme.textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
