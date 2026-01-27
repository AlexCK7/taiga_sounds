import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:file_picker/file_picker.dart';
// Removed unused import. Styling is derived from the current theme.

/// Page that allows the user to pick one or more audio files from their
/// device and import them into the app's sound library. Files are
/// copied into the app's documents directory under the `sounds/`
/// subdirectory. Upon successful import the user is shown a
/// confirmation message.
class UploadSoundPage extends StatefulWidget {
  const UploadSoundPage({super.key});
  @override
  State<UploadSoundPage> createState() => _UploadSoundPageState();
}

class _UploadSoundPageState extends State<UploadSoundPage> {
  String _status = '';
  bool _importing = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Import from Device')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Select one or more audio files to add to your library.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _importing ? null : _pickFiles,
              icon: const Icon(Icons.folder_open),
              label: const Text('Pick Files'),
            ),
            const SizedBox(height: 16),
            if (_status.isNotEmpty)
              Text(
                _status,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: _status.startsWith('Imported')
                      ? theme.colorScheme.primary
                      : theme.colorScheme.error,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickFiles() async {
    setState(() {
      _importing = true;
      _status = 'Selecting files…';
    });
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['mp3', 'wav'],
        allowMultiple: true,
      );
      if (result == null || result.files.isEmpty) {
        setState(() {
          _importing = false;
          _status = 'No files selected.';
        });
        return;
      }
      // Process each selected file.
      final soundsDir = await _soundsDir();
      int importedCount = 0;
      for (final picked in result.files) {
        final path = picked.path;
        if (path == null) continue;
        final file = File(path);
        if (!await file.exists()) continue;
        final ext = path.toLowerCase().endsWith('.wav') ? 'wav' : 'mp3';
        final label = _defaultLabelFromPath(path);
        final filename =
            '${_sanitizeFilename(label)}_${DateTime.now().millisecondsSinceEpoch}.$ext';
        final dest = File('${soundsDir.path}/$filename');
        try {
          await dest.writeAsBytes(await file.readAsBytes(), flush: true);
          importedCount++;
        } catch (e) {
          debugPrint('FILE COPY ERROR: $e');
        }
      }
      setState(() {
        _importing = false;
        _status = importedCount > 0
            ? 'Imported $importedCount file(s).'
            : 'No files were imported.';
      });
    } catch (e) {
      setState(() {
        _importing = false;
        _status = 'Import error: $e';
      });
    }
  }

  /// Create or return the directory for downloaded sounds.
  Future<Directory> _soundsDir() async {
    final dir = await getApplicationDocumentsDirectory();
    final sounds = Directory('${dir.path}/sounds');
    if (!await sounds.exists()) {
      await sounds.create(recursive: true);
    }
    return sounds;
  }

  /// Sanitize a filename by replacing non‑alphanumeric characters with
  /// underscores and collapsing multiple underscores.
  String _sanitizeFilename(String name) {
    final safe = name
        .replaceAll(RegExp(r'[^a-zA-Z0-9_\-]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .trim();
    return safe.isEmpty ? 'sound' : safe;
  }

  /// Extract a human friendly label from a file path. The file name
  /// portion of the path is used, with the extension stripped and
  /// underscores converted to spaces.
  String _defaultLabelFromPath(String path) {
    final seg = path.split(Platform.pathSeparator).last;
    final noExt = seg.replaceAll(
      RegExp(r'\.(mp3|wav)\$', caseSensitive: false),
      '',
    );
    final pretty = noExt.replaceAll('_', ' ').trim();
    return pretty.isEmpty ? 'Sound' : pretty;
  }
}
