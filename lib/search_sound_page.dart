import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

/// Represents a single search result from an external source.
class _SoundResult {
  final String label;
  final String url;
  const _SoundResult({required this.label, required this.url});
}

/// A page that lets the user search for sounds from MyInstants and preview
/// them before downloading. A single [AudioPlayer] is used for all previews
/// to avoid creating multiple ExoPlayer instances on Android. Results are
/// deduped by URL to avoid duplicates.
class SearchSoundPage extends StatefulWidget {
  /// Callback invoked when a sound is downloaded and saved. The label and
  /// file path of the imported sound are provided so the parent page can
  /// refresh its library.
  final void Function(String label, String path) onImport;

  const SearchSoundPage({super.key, required this.onImport});

  @override
  State<SearchSoundPage> createState() => _SearchSoundPageState();
}

class _SearchSoundPageState extends State<SearchSoundPage> {
  final TextEditingController _controller = TextEditingController();
  bool _loading = false;
  String? _error;
  List<_SoundResult> _results = [];
  // Single player used for previewing results. Using one player avoids
  // multiple ExoPlayer instances and prevents playback conflicts.
  final AudioPlayer _previewPlayer = AudioPlayer();
  String? _currentPreviewUrl;
  bool _disposed = false;
  // HTTP client (reused for all requests)
  final http.Client _client = http.Client();
  static const Map<String, String> _headers = {
    // Some hosts block unknown clients; a realistic UA helps.
    'User-Agent':
        'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36 TaigaSounds/1.0',
    'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
    'Accept-Language': 'en-US,en;q=0.9',
    'Connection': 'keep-alive',
  };
  static const List<_SoundResult> _trendingBase = [
    _SoundResult(
      label: 'Bruh',
      url: 'https://www.myinstants.com/media/sounds/bruh.mp3',
    ),
    _SoundResult(
      label: 'Airhorn',
      url: 'https://www.myinstants.com/media/sounds/airhorn.mp3',
    ),
    _SoundResult(
      label: 'Sad Trombone',
      url: 'https://www.myinstants.com/media/sounds/sad-trombone.mp3',
    ),
    _SoundResult(
      label: 'Dramatic',
      url: 'https://www.myinstants.com/media/sounds/violin.mp3',
    ),
  ];
  late List<_SoundResult> _trending;
  @override
  void initState() {
    super.initState();
    _shuffleTrending();
  }

  void _shuffleTrending() {
    final list = List<_SoundResult>.from(_trendingBase);
    list.shuffle(Random(DateTime.now().millisecondsSinceEpoch));
    _trending = list;
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _disposed = true;
    _previewPlayer.dispose();
    _controller.dispose();
    _client.close();
    super.dispose();
  }

  /// Perform a search on MyInstants for the given [query]. Results are parsed
  /// from the HTML using a simple regular expression. Up to 30 unique
  /// .mp3 links are returned. If no results are found an error message is set.
  Future<void> _search(String query) async {
    final q = query.trim();
    if (q.isEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
      _results = [];
    });
    // Use the English search path explicitly for consistency.
    final encoded = Uri.encodeQueryComponent(q);
    final uri = Uri.parse(
      'https://www.myinstants.com/en/search/?name=$encoded',
    );
    try {
      final resp = await _client
          .get(uri, headers: _headers)
          .timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) {
        if (!mounted) return;
        setState(() {
          _loading = false;
          _error = 'Search failed (HTTP ${resp.statusCode})';
        });
        return;
      }
      final html = resp.body;
      // Capture audio paths like: /media/sounds/whatever.mp3 .wav or .ogg.
      final urlRegex = RegExp(
        r'/media/sounds/[^\s>]+\.(mp3|wav|ogg)',
        caseSensitive: false,
      );
      final matches = urlRegex.allMatches(html);
      final Map<String, _SoundResult> dedup = {};
      for (final m in matches) {
        final path = m.group(0);
        if (path == null) continue;
        final cleanPath = path
            .replaceAll('"', '')
            .replaceAll("'", '')
            .replaceAll(')', '')
            .replaceAll(']', '')
            .replaceAll(',', '')
            .trim();
        if (!cleanPath.startsWith('/media/sounds/')) continue;
        final fullUrl = 'https://www.myinstants.com$cleanPath';
        if (dedup.containsKey(fullUrl)) continue;
        final fileName = cleanPath.split('/').last;
        var label = fileName
            .replaceAll(RegExp(r'_+'), ' ')
            .replaceAll(RegExp(r'\.(mp3|wav|ogg)\$', caseSensitive: false), '')
            .trim();
        // Remove trailing timestamps like _1700000000000
        label = label.replaceAll(RegExp(r'[_\-\s]\d{10,}\$?'), '').trim();
        if (label.isEmpty) label = 'Sound';
        dedup[fullUrl] = _SoundResult(label: label, url: fullUrl);
        if (dedup.length >= 30) break;
      }
      if (!mounted) return;
      setState(() {
        _results = dedup.values.toList(growable: false);
        _loading = false;
        _error = _results.isEmpty ? 'No results found.' : null;
      });
    } on SocketException catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error =
            'No internet on the emulator. (Fix emulator Wi‑Fi / permissions and try again.)';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Search error: $e';
      });
    }
  }

  /// Stop playback of the preview player and clear the current URL.
  Future<void> _stopPreview() async {
    try {
      await _previewPlayer.stop();
    } catch (_) {}
    if (!mounted) return;
    setState(() => _currentPreviewUrl = null);
  }

  /// Preview a sound. If the same sound is currently playing it stops; if a
  /// different sound is playing it stops the current playback and starts
  /// the new one. Errors are shown via SnackBar.
  Future<void> _preview(_SoundResult result) async {
    if (_disposed) return;
    final url = result.url;
    // If the same URL is already playing, toggle playback off.
    if (_currentPreviewUrl == url && _previewPlayer.playing) {
      await _stopPreview();
      return;
    }
    // Always stop before switching sources; improves stability on Android.
    try {
      await _previewPlayer.stop();
    } catch (_) {}
    try {
      await _previewPlayer.setUrl(url, headers: _headers);
      if (!mounted) return;
      setState(() => _currentPreviewUrl = url);
      await _previewPlayer.play();
    } on SocketException catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No internet on emulator (preview failed).'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Preview failed: $e')));
    }
  }

  /// Download a sound to local storage. The file is stored in the
  /// `sounds/` directory and the [onImport] callback is invoked. The
  /// preview player is stopped before downloading to avoid stream conflicts.
  Future<void> _download(_SoundResult result) async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    setState(() => _loading = true);
    try {
      await _previewPlayer.stop();
    } catch (_) {}
    try {
      final resp = await _client
          .get(Uri.parse(result.url), headers: _headers)
          .timeout(const Duration(seconds: 25));
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        if (!mounted) return;
        setState(() => _loading = false);
        messenger.showSnackBar(
          SnackBar(content: Text('Download failed (HTTP ${resp.statusCode})')),
        );
        return;
      }
      final bytes = resp.bodyBytes;
      final soundsDir = await _soundsDir();
      final cleanLabel = result.label.trim().isEmpty ? 'Sound' : result.label;
      final fileName =
          '${_sanitizeFilename(cleanLabel)}_${DateTime.now().millisecondsSinceEpoch}.mp3';
      final file = File('${soundsDir.path}/$fileName');
      await file.writeAsBytes(bytes, flush: true);
      widget.onImport(cleanLabel, file.path);
      if (!mounted) return;
      setState(() => _loading = false);
      messenger.showSnackBar(SnackBar(content: Text('Imported: $cleanLabel')));
      navigator.pop();
    } on SocketException catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
      messenger.showSnackBar(
        const SnackBar(
          content: Text('No internet on emulator (download failed).'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      messenger.showSnackBar(SnackBar(content: Text('Download error: $e')));
    }
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

  void _clearSearch() {
    _controller.clear();
    setState(() {
      _results = [];
      _error = null;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final query = _controller.text.trim();
    final showResults = query.isNotEmpty;
    final list = showResults ? _results : _trending;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Discover Sounds'),
        actions: [
          IconButton(
            tooltip: 'Shuffle trending',
            icon: const Icon(Icons.shuffle),
            onPressed: _shuffleTrending,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _controller,
              decoration: InputDecoration(
                hintText: 'Search sounds (e.g. meme, mario)',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: query.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Clear',
                        icon: const Icon(Icons.close),
                        onPressed: _clearSearch,
                      ),
              ),
              textInputAction: TextInputAction.search,
              onSubmitted: _search,
            ),
          ),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            ),
          if (_error != null && !_loading)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                _error!,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.error,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          const SizedBox(height: 8),
          Expanded(
            child: list.isEmpty
                ? _DiscoverEmptyState(
                    showResults: showResults,
                    onTryTrending: _clearSearch,
                  )
                : ListView.builder(
                    itemCount: list.length,
                    itemBuilder: (context, index) {
                      final res = list[index];
                      final isPlaying =
                          _currentPreviewUrl == res.url &&
                          _previewPlayer.playing;
                      return Card(
                        margin: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        child: ListTile(
                          leading: Icon(
                            Icons.music_note,
                            color: theme.colorScheme.secondary,
                          ),
                          title: Text(
                            res.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyLarge?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          subtitle: Text(
                            showResults ? 'Search result' : 'Trending',
                            style: theme.textTheme.bodySmall,
                          ),
                          trailing: Wrap(
                            spacing: 8,
                            children: [
                              IconButton(
                                tooltip: isPlaying ? 'Stop preview' : 'Preview',
                                icon: Icon(
                                  isPlaying ? Icons.stop : Icons.play_arrow,
                                ),
                                onPressed: _loading
                                    ? null
                                    : () => _preview(res),
                              ),
                              IconButton(
                                tooltip: 'Download & Import',
                                icon: const Icon(Icons.download),
                                onPressed: _loading
                                    ? null
                                    : () => _download(res),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _DiscoverEmptyState extends StatelessWidget {
  final bool showResults;
  final VoidCallback onTryTrending;
  const _DiscoverEmptyState({
    required this.showResults,
    required this.onTryTrending,
  });
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Card(
          margin: const EdgeInsets.all(16),
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.search_off_outlined, size: 44),
                const SizedBox(height: 12),
                Text(
                  showResults ? 'No results' : 'Discover new sounds',
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  showResults
                      ? 'Try a different search term, or browse trending sounds.'
                      : 'Search by keyword or browse trending picks.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurface.withAlpha(
                      (0.75 * 255).toInt(),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                if (showResults)
                  OutlinedButton.icon(
                    onPressed: onTryTrending,
                    icon: const Icon(Icons.trending_up),
                    label: const Text('View Trending'),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
