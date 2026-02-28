import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:ffmpeg_kit_audio_flutter/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_audio_flutter/return_code.dart';

/// A page that allows the user to import a sound by pasting a URL. The URL
/// can point directly to an MP3/WAV file or to a MyInstants page; in the
/// latter case the first sound on the page is extracted. The downloaded
/// audio is saved into the app's sounds directory. If the file is not an
/// MP3 it is converted to MP3 for consistent playback. When the import
/// succeeds the provided [onImport] callback is invoked so the library can
/// refresh itself.
class ImportSoundPage extends StatefulWidget {
  final void Function(String label, String path) onImport;
  const ImportSoundPage({super.key, required this.onImport});

  @override
  State<ImportSoundPage> createState() => _ImportSoundPageState();
}

class _ImportSoundPageState extends State<ImportSoundPage> {
  final TextEditingController _controller = TextEditingController();

  String _status = '';
  bool _isError = false;
  bool _importing = false;
  bool _disposed = false;

  static const Map<String, String> _headers = {
    'User-Agent': 'Mozilla/5.0 (Android) TaigaSounds/1.0',
    'Accept': '*/*',
  };

  @override
  void dispose() {
    _disposed = true;
    _controller.dispose();
    super.dispose();
  }

  void _setStatus(String msg, {bool isError = false}) {
    if (_disposed) return;
    if (!mounted) return;
    setState(() {
      _status = msg;
      _isError = isError;
    });
  }

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

  String _defaultLabelFromUrl(Uri uri) {
    final seg = uri.pathSegments.isNotEmpty ? uri.pathSegments.last : 'sound';
    final noQuery = seg.split('?').first;
    final base = noQuery.replaceAll(
      RegExp(r'\.(mp3|wav)$', caseSensitive: false),
      '',
    );
    final pretty = base.replaceAll('_', ' ').trim();
    return pretty.isEmpty ? 'Sound' : pretty;
  }

  /// Resolve a pasted URL into a direct media URI. Supports direct .mp3/.wav
  /// links or MyInstants pages. If the URL is a MyInstants page the first
  /// sound is extracted from the page HTML. Returns null on failure.
  Future<Uri?> _resolveMediaUri(String input) async {
    Uri uri;
    try {
      uri = Uri.parse(input);
    } catch (_) {
      return null;
    }

    final lower = input.toLowerCase();
    if (lower.endsWith('.mp3') || lower.endsWith('.wav')) return uri;

    if (uri.host.contains('myinstants.com')) {
      try {
        final resp = await http.get(uri, headers: _headers);
        if (resp.statusCode < 200 || resp.statusCode >= 300) return null;
        final html = resp.body;

        // Matches: /media/sounds/<something>.mp3 (no quotes)
        final re = RegExp(r'/media/sounds/[^"\s>]+\.mp3', caseSensitive: false);
        final m = re.firstMatch(html);
        if (m == null) return null;

        final path = m.group(0);
        if (path == null || path.isEmpty) return null;

        return Uri.parse('https://www.myinstants.com$path');
      } catch (e) {
        debugPrint('MYINSTANTS RESOLVE ERROR: $e');
        return null;
      }
    }

    return null;
  }

  /// Called when the user taps the Download button. Resolves the pasted URL,
  /// downloads the audio, optionally converts it to MP3 and saves it into
  /// the sounds directory. Invokes the onImport callback on success.
  Future<void> _handleImport() async {
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);

    final input = _controller.text.trim();
    if (input.isEmpty) {
      _setStatus('Please paste a URL.', isError: true);
      return;
    }

    if (!mounted || _disposed) return;

    setState(() => _importing = true);
    _setStatus('Resolving URL…');

    final mediaUri = await _resolveMediaUri(input);

    if (!mounted || _disposed) return;

    if (mediaUri == null) {
      setState(() => _importing = false);
      _setStatus(
        'Could not resolve a sound URL. Please check the link.',
        isError: true,
      );
      return;
    }

    _setStatus('Downloading…');

    try {
      final resp = await http.get(mediaUri, headers: _headers);

      if (!mounted || _disposed) return;

      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        setState(() => _importing = false);
        _setStatus('Download failed: HTTP ${resp.statusCode}', isError: true);
        return;
      }

      // Validate we actually got audio (prevents saving HTML / garbage)
      final contentType = resp.headers['content-type'] ?? '';
      final lowerPath = mediaUri.path.toLowerCase();
      final looksLikeAudioByExt =
          lowerPath.endsWith('.mp3') || lowerPath.endsWith('.wav');

      if (!contentType.contains('audio') && !looksLikeAudioByExt) {
        setState(() => _importing = false);
        _setStatus(
          'Download did not return audio (got: $contentType). Try a direct .mp3/.wav link.',
          isError: true,
        );
        return;
      }

      if (resp.bodyBytes.isEmpty) {
        setState(() => _importing = false);
        _setStatus(
          'Downloaded file is empty (0 bytes). Link may be blocked or invalid.',
          isError: true,
        );
        return;
      }

      // Save or convert to MP3
      final soundsDir = await _soundsDir();
      final ext = lowerPath.endsWith('.wav') ? 'wav' : 'mp3';
      final label = _defaultLabelFromUrl(mediaUri);

      final filename =
          '${_sanitizeFilename(label)}_${DateTime.now().millisecondsSinceEpoch}.mp3';
      final outFile = File('${soundsDir.path}/$filename');

      if (ext == 'mp3') {
        await outFile.writeAsBytes(resp.bodyBytes, flush: true);
      } else {
        // Write to temp wav then convert to mp3
        final tempWav = File(
          '${soundsDir.path}/tmp_${DateTime.now().microsecondsSinceEpoch}.wav',
        );
        await tempWav.writeAsBytes(resp.bodyBytes, flush: true);

        final cmd =
            '-y -i "${tempWav.path}" -vn -c:a libmp3lame -q:a 2 "${outFile.path}"';

        final session = await FFmpegKit.execute(cmd);
        final rc = await session.getReturnCode();

        try {
          await tempWav.delete();
        } catch (_) {}

        if (!ReturnCode.isSuccess(rc)) {
          setState(() => _importing = false);
          _setStatus('Import failed (conversion error).', isError: true);
          return;
        }
      }

      // Only import if the file exists and has size > 0
      if (await outFile.exists() && await outFile.length() > 0) {
        widget.onImport(label, outFile.path);

        if (!mounted || _disposed) return;

        setState(() {
          _importing = false;
          _controller.clear();
          _status = '';
          _isError = false;
        });

        messenger.showSnackBar(SnackBar(content: Text('Imported: $label')));

        // Auto-back to the library after success.
        navigator.pop();
        return;
      }

      setState(() => _importing = false);
      _setStatus('Import failed: file could not be saved.', isError: true);
    } catch (e) {
      if (!mounted || _disposed) return;
      setState(() => _importing = false);
      _setStatus('Import error: $e', isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final statusColor = _isError
        ? theme.colorScheme.error
        : theme.colorScheme.onSurface.withAlpha((0.70 * 255).toInt());

    return Scaffold(
      appBar: AppBar(
        title: const Text('Import Sound'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: _importing ? null : () => Navigator.of(context).pop(),
          tooltip: 'Back',
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Paste a MyInstants page or direct .mp3/.wav URL:',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _controller,
              enabled: !_importing,
              decoration: const InputDecoration(
                hintText: 'https://www.myinstants.com/en/...',
                prefixIcon: Icon(Icons.link),
              ),
              onSubmitted: (_) => _importing ? null : _handleImport(),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _importing ? null : _handleImport,
              child: _importing
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Download & Add'),
            ),
            const SizedBox(height: 12),
            if (_status.isNotEmpty)
              Text(
                _status,
                style: theme.textTheme.bodySmall?.copyWith(color: statusColor),
              ),
            const SizedBox(height: 12),
            Text(
              'Tip: For MyInstants pages we automatically extract the first sound file link.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withAlpha(
                  (0.70 * 255).toInt(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
