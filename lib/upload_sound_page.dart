import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:ffmpeg_kit_audio_flutter/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_audio_flutter/return_code.dart';

/// Page that allows the user to pick one or more media files from their
/// device and import them into the app's sound library. Files are copied
/// into the app's documents directory under the `sounds/` subdirectory.
/// Non-MP3 audio and supported video formats are converted to MP3 using
/// FFmpeg for consistent playback. When an import succeeds the provided
/// [onImport] callback is invoked so the library can refresh itself.
class UploadSoundPage extends StatefulWidget {
  final void Function(String label, String path) onImport;

  /// If true, the page will automatically pop back after importing at least one file.
  final bool autoCloseOnSuccess;

  const UploadSoundPage({
    super.key,
    required this.onImport,
    this.autoCloseOnSuccess = true,
  });

  @override
  State<UploadSoundPage> createState() => _UploadSoundPageState();
}

class _UploadSoundPageState extends State<UploadSoundPage> {
  String _status = '';
  bool _importing = false;

  /// Create or return the directory for downloaded sounds.
  Future<Directory> _soundsDir() async {
    final dir = await getApplicationDocumentsDirectory();
    final sounds = Directory('${dir.path}/sounds');
    if (!await sounds.exists()) {
      await sounds.create(recursive: true);
    }
    return sounds;
  }

  /// Sanitize a filename by replacing non-alphanumeric characters with
  /// underscores and collapsing multiple underscores.
  String _sanitizeFilename(String name) {
    final safe = name
        .replaceAll(RegExp(r'[^a-zA-Z0-9_\-]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .trim();
    return safe.isEmpty ? 'sound' : safe;
  }

  /// Extract a human friendly label from a file path. Removes the extension
  /// and replaces underscores with spaces.
  String _defaultLabelFromPath(String path) {
    final seg = path.split(Platform.pathSeparator).last;
    final dot = seg.lastIndexOf('.');
    final noExt = dot == -1 ? seg : seg.substring(0, dot);
    final pretty = noExt.replaceAll('_', ' ').trim();
    return pretty.isEmpty ? 'Sound' : pretty;
  }

  /// Choose files from the device using FilePicker, convert as needed
  /// and save them into the app's sounds directory. Invokes the onImport
  /// callback for each successfully imported sound.
  Future<void> _pickFiles() async {
    if (!mounted) return;

    setState(() {
      _importing = true;
      _status = 'Selecting files…';
    });

    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.custom,
        allowedExtensions: [
          'mp3',
          'wav',
          'm4a',
          'aac',
          'ogg',
          'flac',
          'mp4',
          'mkv',
          'mov',
        ],
      );

      if (!mounted) return;

      // User cancelled -> not an error
      if (result == null) {
        setState(() {
          _importing = false;
          _status = 'Cancelled.';
        });
        return;
      }

      if (result.files.isEmpty) {
        setState(() {
          _importing = false;
          _status = 'No files selected.';
        });
        return;
      }

      final soundsDir = await _soundsDir();
      int importedCount = 0;

      setState(() => _status = 'Importing…');

      for (final picked in result.files) {
        if (!mounted) return;

        final path = picked.path;
        if (path == null) continue;

        final file = File(path);
        if (!await file.exists()) continue;

        final ext = path.split('.').last.toLowerCase();

        // Derive a friendly label from the original filename
        final label = _defaultLabelFromPath(path);
        final filename =
            '${_sanitizeFilename(label)}_${DateTime.now().millisecondsSinceEpoch}.mp3';
        final dest = File('${soundsDir.path}/$filename');

        try {
          if (ext == 'mp3') {
            await dest.writeAsBytes(await file.readAsBytes(), flush: true);
          } else {
            final cmd =
                '-y -i "${file.path}" -vn -c:a libmp3lame -q:a 2 "${dest.path}"';
            final session = await FFmpegKit.execute(cmd);
            final rc = await session.getReturnCode();

            if (!ReturnCode.isSuccess(rc)) {
              debugPrint(
                'FFmpeg conversion failed (code ${rc?.getValue()}) for $path',
              );
              continue;
            }
          }

          if (await dest.exists() && await dest.length() > 0) {
            widget.onImport(label, dest.path);
            importedCount++;
          }
        } catch (e) {
          debugPrint('IMPORT ERROR: $e');
        }
      }

      if (!mounted) return;

      setState(() {
        _importing = false;
        _status = importedCount > 0
            ? 'Imported $importedCount file${importedCount == 1 ? '' : 's'}.'
            : 'No files were imported.';
      });

      if (importedCount > 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Imported $importedCount sound(s).')),
        );

        // Auto-close back to the library if enabled.
        if (widget.autoCloseOnSuccess && mounted) {
          Navigator.of(context).pop();
        }
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _importing = false;
        _status = 'Import error: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isSuccess = _status.startsWith('Imported') || _status == 'Cancelled.';
    final statusColor = isSuccess
        ? theme.colorScheme.primary
        : theme.colorScheme.error;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Import from Device'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: _importing ? null : () => Navigator.of(context).pop(),
          tooltip: 'Back',
        ),
        actions: [
          TextButton(
            onPressed: _importing ? null : _pickFiles,
            child: const Text('Pick'),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Select one or more media files to add to your library.\n\n'
              'On an emulator, Downloads may be empty because it is a separate device. '
              'Try dragging an mp3/wav onto the emulator window or use adb push to /sdcard/Download/.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _importing ? null : _pickFiles,
              icon: const Icon(Icons.folder_open),
              label: Text(_importing ? 'Importing…' : 'Pick Files'),
            ),
            const SizedBox(height: 16),
            if (_status.isNotEmpty)
              Text(
                _status,
                style: theme.textTheme.bodySmall?.copyWith(color: statusColor),
              ),
          ],
        ),
      ),
    );
  }
}
