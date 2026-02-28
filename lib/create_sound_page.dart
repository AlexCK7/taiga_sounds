import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:ffmpeg_kit_audio_flutter/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_audio_flutter/return_code.dart';

/// A page that allows users to combine multiple existing sounds into a
/// single sound. Users can select a set of sounds, name the new sound
/// and optionally overlay them. When a sound is imported the provided
/// [onImport] callback is invoked so the library can update itself.
class CreateSoundPage extends StatefulWidget {
  /// List of available sounds (both built‑in and imported) that can be
  /// combined. Each entry contains the label, key (asset path or file
  /// path) and a flag indicating whether it comes from the asset bundle.
  final List<({String label, String key, bool isAsset})> sounds;

  /// Callback invoked when a new combined sound is created. The label
  /// and file path of the newly created sound are passed to this
  /// callback so the parent page can import it into the library.
  final void Function(String label, String path) onImport;
  const CreateSoundPage({
    super.key,
    required this.sounds,
    required this.onImport,
  });
  @override
  State<CreateSoundPage> createState() => _CreateSoundPageState();
}

class _CreateSoundPageState extends State<CreateSoundPage> {
  final Set<int> _selectedIndices = {};
  final TextEditingController _nameController = TextEditingController();

  /// Whether to overlay selected sounds (mix) instead of concatenating them
  /// end‑to‑end.
  bool _overlayMix = false;

  /// Offset in seconds to delay the second sound when overlay mixing.
  double _offsetSeconds = 0.0;
  Future<Directory> _soundsDir() async {
    final dir = await getApplicationDocumentsDirectory();
    final sounds = Directory('${dir.path}/sounds');
    if (!await sounds.exists()) {
      await sounds.create(recursive: true);
    }
    return sounds;
  }

  String _sanitizeFilename(String name) {
    final safe = name
        .replaceAll(RegExp(r'[^a-zA-Z0-9_\-]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .trim();
    return safe.isEmpty ? 'sound' : safe;
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Create Sound')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Select one or more sounds to combine:',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                itemCount: widget.sounds.length,
                itemBuilder: (context, index) {
                  final s = widget.sounds[index];
                  final selected = _selectedIndices.contains(index);
                  return CheckboxListTile(
                    value: selected,
                    onChanged: (bool? val) {
                      setState(() {
                        if (val == true) {
                          _selectedIndices.add(index);
                        } else {
                          _selectedIndices.remove(index);
                        }
                      });
                    },
                    title: Text(s.label),
                    subtitle: Text(s.isAsset ? 'Built‑in' : 'Imported'),
                  );
                },
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(labelText: 'New Sound Name'),
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              title: const Text('Overlay Mix'),
              subtitle: const Text(
                'Play selected sounds simultaneously instead of one after the other',
              ),
              value: _overlayMix,
              onChanged: (val) {
                setState(() => _overlayMix = val);
              },
            ),
            if (_overlayMix) ...[
              const SizedBox(height: 8),
              Text(
                'Offset for next sound: ${_offsetSeconds.toStringAsFixed(1)} sec',
                style: theme.textTheme.bodySmall,
              ),
              Slider(
                min: 0.0,
                max: 5.0,
                divisions: 50,
                value: _offsetSeconds,
                label: '${_offsetSeconds.toStringAsFixed(1)}s',
                onChanged: (val) {
                  setState(() => _offsetSeconds = val);
                },
              ),
            ],
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: () async {
                final navigator = Navigator.of(context);
                final messenger = ScaffoldMessenger.of(context);
                final selected = _selectedIndices.toList();
                if (selected.length < 2) {
                  messenger.showSnackBar(
                    const SnackBar(content: Text('Select at least two sounds')),
                  );
                  return;
                }
                final newName = _nameController.text.trim();
                if (newName.isEmpty) {
                  messenger.showSnackBar(
                    const SnackBar(
                      content: Text('Enter a name for the new sound'),
                    ),
                  );
                  return;
                }
                final List<String> sources = [];
                final Directory appDir =
                    await getApplicationDocumentsDirectory();
                final List<File> tempFiles = [];
                for (final idx in selected) {
                  final s = widget.sounds[idx];
                  if (s.isAsset) {
                    try {
                      final data = await rootBundle.load(s.key);
                      final ext = s.key.toLowerCase().endsWith('.wav')
                          ? 'wav'
                          : 'mp3';
                      final temp = File(
                        '${appDir.path}/tmp_${DateTime.now().millisecondsSinceEpoch}_$idx.$ext',
                      );
                      await temp.writeAsBytes(
                        data.buffer.asUint8List(),
                        flush: true,
                      );
                      tempFiles.add(temp);
                      sources.add(temp.path);
                    } catch (e) {
                      debugPrint('ASSET COPY ERROR: $e');
                    }
                  } else {
                    sources.add(s.key);
                  }
                }
                if (sources.length < 2) {
                  messenger.showSnackBar(
                    const SnackBar(
                      content: Text('Unable to resolve selected files'),
                    ),
                  );
                  for (final f in tempFiles) {
                    try {
                      await f.delete();
                    } catch (_) {}
                  }
                  return;
                }
                final soundsDir = await _soundsDir();
                final sanitized = _sanitizeFilename(newName);
                final outputFile = File(
                  '${soundsDir.path}/${sanitized}_${DateTime.now().millisecondsSinceEpoch}.mp3',
                );
                String command;
                if (!_overlayMix) {
                  final inputString = sources.join('|');
                  command =
                      '-y -i "concat:$inputString" -acodec copy "${outputFile.path}"';
                } else {
                  final buf = StringBuffer('-y');
                  for (final src in sources) {
                    buf.write(' -i "${src.replaceAll('"', '\\"')}"');
                  }
                  String filter;
                  if (sources.length == 2 && _offsetSeconds > 0.0) {
                    final delayMs = (_offsetSeconds * 1000).round();
                    filter =
                        '[1:a]adelay=$delayMs|$delayMs[a1];[0:a][a1]amix=inputs=2:duration=longest';
                  } else {
                    final inputs = sources.length;
                    filter = 'amix=inputs=$inputs:duration=longest';
                  }
                  buf
                    ..write(' -filter_complex "')
                    ..write(filter)
                    ..write('"')
                    ..write(' -c:a libmp3lame -q:a 4 "${outputFile.path}"');
                  command = buf.toString();
                }
                final session = await FFmpegKit.execute(command);
                final returnCode = await session.getReturnCode();
                for (final f in tempFiles) {
                  try {
                    await f.delete();
                  } catch (_) {}
                }
                if (ReturnCode.isSuccess(returnCode)) {
                  widget.onImport(newName, outputFile.path);
                  if (mounted) {
                    messenger.showSnackBar(
                      SnackBar(content: Text('Created $newName')),
                    );
                    navigator.pop();
                  }
                } else {
                  if (mounted) {
                    messenger.showSnackBar(
                      SnackBar(
                        content: Text(
                          'Failed to combine sounds (code ${returnCode?.getValue()})',
                        ),
                      ),
                    );
                  }
                }
              },
              child: const Text('Combine & Save'),
            ),
          ],
        ),
      ),
    );
  }
}
