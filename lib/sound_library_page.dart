import 'dart:convert';
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

import 'create_sound_page.dart';
import 'search_sound_page.dart';
import 'sound_editor_page.dart';

class SoundLibraryPage extends StatefulWidget {
  const SoundLibraryPage({super.key});

  @override
  State<SoundLibraryPage> createState() => _SoundLibraryPageState();
}

class _SoundLibraryPageState extends State<SoundLibraryPage> {
  String _status = 'Ready';
  String? _currentlyPlayingKey;

  String _deriveLabelFromPath(String path) {
    final file = path.split(Platform.pathSeparator).last;
    final withoutExt = file.replaceAll(
      RegExp(r'\.(mp3|wav)$', caseSensitive: false),
      '',
    );
    final withoutTimestamp = withoutExt.replaceAll(RegExp(r'_\d{10,}$'), '');
    final pretty = withoutTimestamp.replaceAll('_', ' ').trim();
    return pretty.isEmpty ? 'Imported sound' : pretty;
  }

  /// Single source of truth: no duplicates.
  String _safeLabel(String? raw, String keyOrPath) {
    final candidate = (raw ?? '').trim();

    // If empty or only punctuation/underscores, generate a clean label.
    if (candidate.isEmpty || RegExp(r'^[\W_]+$').hasMatch(candidate)) {
      return _deriveLabelFromPath(keyOrPath);
    }

    // If somehow the label is literally "..." treat as invalid.
    if (candidate == '...' || candidate == '…') {
      return _deriveLabelFromPath(keyOrPath);
    }

    return candidate;
  }

  final List<({String label, String asset})> _builtInSounds = const [
    (label: 'Airhorn (HI)', asset: 'assets/sounds/airhorn_hi_clean.wav'),
    (
      label: 'Airhorn (MID HI)',
      asset: 'assets/sounds/airhorn_mid_hi_clean.wav',
    ),
    (
      label: 'Airhorn (MID LO)',
      asset: 'assets/sounds/airhorn_mid_lo_clean.wav',
    ),
    (label: 'Airhorn (LO)', asset: 'assets/sounds/airhorn_lo_clean.wav'),
    (label: 'Faaah', asset: 'assets/sounds/faaah.mp3'),
    (label: 'TF Nemesis', asset: 'assets/sounds/tf_nemesis.mp3'),
  ];

  final List<({String label, String path})> _downloadedSounds = [];

  late final Map<String, AudioPlayer> _players;

  int _stopEpoch = 0;
  final Map<String, int> _soundEpoch = {};

  bool _disposed = false;
  bool _loading = true;

  final List<String> _categories = const ['All', 'Built-in', 'Imported'];
  String _selectedCategory = 'All';
  String _searchQuery = '';

  List<({String label, String key, bool isAsset})> get _allSounds {
    final builtIns = _builtInSounds.map(
      (s) => (label: s.label, key: s.asset, isAsset: true),
    );
    final downloads = _downloadedSounds.map(
      (s) => (label: s.label, key: s.path, isAsset: false),
    );
    return [...builtIns, ...downloads];
  }

  List<({String label, String key, bool isAsset})> get _filteredSounds {
    final q = _searchQuery.trim().toLowerCase();
    final results = _allSounds
        .where((s) {
          if (_selectedCategory == 'Built-in' && !s.isAsset) return false;
          if (_selectedCategory == 'Imported' && s.isAsset) return false;
          if (q.isNotEmpty && !s.label.toLowerCase().contains(q)) return false;
          return true;
        })
        .toList(growable: false);

    results.sort(
      (a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()),
    );
    return results;
  }

  int get _builtInCount => _builtInSounds.length;
  int get _importedCount => _downloadedSounds.length;

  @override
  void initState() {
    super.initState();

    _players = {for (final s in _builtInSounds) s.asset: AudioPlayer()};
    for (final s in _builtInSounds) {
      _soundEpoch[s.asset] = 0;
    }

    _bootstrap();
  }

  Future<void> _bootstrap() async {
    try {
      setState(() => _loading = true);

      await _loadDownloadedManifest();

      for (final s in _downloadedSounds) {
        _players.putIfAbsent(s.path, () => AudioPlayer());
        _soundEpoch.putIfAbsent(s.path, () => 0);
      }

      await _initAudio();

      if (!_disposed) {
        setState(() {
          _status = 'Ready';
          _loading = false;
        });
      }
    } catch (e) {
      debugPrint('BOOTSTRAP ERROR: $e');
      if (!_disposed) {
        setState(() {
          _status = 'Init error';
          _loading = false;
        });
      }
    }
  }

  Future<void> _loadDownloadedManifest() async {
    try {
      final mf = await _manifestFile();
      if (!await mf.exists()) return;

      final raw = await mf.readAsString();
      if (raw.trim().isEmpty) return;

      final decoded = jsonDecode(raw);
      if (decoded is! List) return;

      _downloadedSounds.clear();
      for (final item in decoded) {
        if (item is Map) {
          final rawLabel = item['label']?.toString();
          final path = item['path']?.toString();
          if (path != null) {
            final f = File(path);
            if (await f.exists()) {
              final label = _safeLabel(rawLabel, path);
              _downloadedSounds.add((label: label, path: path));
            }
          }
        }
      }
    } catch (e) {
      debugPrint('MANIFEST LOAD ERROR: $e');
    }
  }

  Future<void> _saveDownloadedManifest() async {
    try {
      final mf = await _manifestFile();
      final data = _downloadedSounds
          .map((s) => {'label': s.label, 'path': s.path})
          .toList(growable: false);
      await mf.writeAsString(jsonEncode(data));
    } catch (e) {
      debugPrint('MANIFEST SAVE ERROR: $e');
    }
  }

  Future<File> _manifestFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/sounds_manifest.json');
  }

  Future<void> _initAudio() async {
    try {
      final session = await AudioSession.instance;
      await session.configure(
        const AudioSessionConfiguration(
          avAudioSessionCategory: AVAudioSessionCategory.playback,
          avAudioSessionCategoryOptions: AVAudioSessionCategoryOptions.none,
          avAudioSessionMode: AVAudioSessionMode.defaultMode,
          avAudioSessionRouteSharingPolicy:
              AVAudioSessionRouteSharingPolicy.defaultPolicy,
          avAudioSessionSetActiveOptions: AVAudioSessionSetActiveOptions.none,
          androidAudioAttributes: AndroidAudioAttributes(
            contentType: AndroidAudioContentType.music,
            usage: AndroidAudioUsage.media,
          ),
          androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
          androidWillPauseWhenDucked: true,
        ),
      );

      // Preload sources for instant playback.
      for (final entry in _players.entries) {
        final key = entry.key;
        final player = entry.value;

        await player.setVolume(1.0);
        if (key.startsWith('assets/')) {
          await player.setAudioSource(AudioSource.asset(key));
        } else {
          await player.setAudioSource(AudioSource.file(key));
        }
        await player.load();
        await player.seek(Duration.zero);
      }

      debugPrint('AUDIO SESSION READY');
    } catch (e) {
      debugPrint('AUDIO SESSION INIT ERROR: $e');
      if (!_disposed) setState(() => _status = 'Audio init error');
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _currentlyPlayingKey = null;
    _stopEpoch++;
    for (final p in _players.values) {
      p.dispose();
    }
    super.dispose();
  }

  Future<void> _restartSound(String key) async {
    final player = _players[key];
    if (player == null) return;

    // ===== DEBUG LINES YOU ASKED FOR =====
    debugPrint('PLAY KEY: $key');
    if (!key.startsWith('assets/')) {
      final exists = await File(key).exists();
      debugPrint('PLAY FILE EXISTS? $exists');
    }
    // ====================================

    final newEpoch = (_soundEpoch[key] ?? 0) + 1;
    _soundEpoch[key] = newEpoch;
    final int enqueueStopEpoch = _stopEpoch;
    final int enqueueSoundEpoch = newEpoch;

    bool stillValid() {
      if (_disposed) return false;
      if (_stopEpoch != enqueueStopEpoch) return false;
      if ((_soundEpoch[key] ?? 0) != enqueueSoundEpoch) return false;
      return true;
    }

    if (!stillValid()) return;

    if (!_disposed) {
      setState(() {
        _status = 'Playing';
        _currentlyPlayingKey = key;
      });
    }

    try {
      await player.setVolume(1.0);
      if (!stillValid()) return;

      // Always re-trigger from start (your requested “repeat tap feeling”).
      await player.stop();
      if (!stillValid()) return;

      await player.seek(Duration.zero);
      if (!stillValid()) return;

      await player.play();
      if (!stillValid()) return;

      if (!_disposed) setState(() => _status = 'Ready');
    } catch (e) {
      debugPrint('AUDIO ERROR ($key): $e');
      if (!_disposed) setState(() => _status = 'Audio error');
    }
  }

  Future<void> _stopAll() async {
    _stopEpoch++;
    for (final k in _players.keys) {
      _soundEpoch[k] = (_soundEpoch[k] ?? 0) + 1;
    }

    if (!_disposed) {
      setState(() {
        _status = 'Stopped';
        _currentlyPlayingKey = null;
      });
    }

    await Future.wait(
      _players.values.map((p) async {
        try {
          await p.stop();
        } catch (_) {}
      }),
    );

    if (!_disposed) setState(() => _status = 'Ready');
  }

  Future<void> _removeDownloadedSound(String key) async {
    final index = _downloadedSounds.indexWhere((s) => s.path == key);
    if (index == -1) return;

    final messenger = ScaffoldMessenger.of(context);

    final removed = _downloadedSounds.removeAt(index);
    await _saveDownloadedManifest();

    final player = _players.remove(key);
    _soundEpoch.remove(key);
    try {
      await player?.dispose();
    } catch (_) {}

    try {
      final f = File(removed.path);
      if (await f.exists()) {
        await f.delete();
      }
    } catch (_) {}

    if (!_disposed) {
      setState(() => _status = 'Deleted');
      messenger.showSnackBar(
        SnackBar(content: Text('Deleted: ${removed.label}')),
      );
    }
  }

  Future<void> _onImportComplete(String label, String path) async {
    if (_downloadedSounds.any((s) => s.path == path)) return;

    final messenger = ScaffoldMessenger.of(context);

    _downloadedSounds.add((label: label, path: path));
    await _saveDownloadedManifest();

    final player = _players.putIfAbsent(path, () => AudioPlayer());
    _soundEpoch.putIfAbsent(path, () => 0);

    try {
      await player.setVolume(1.0);
      await player.setAudioSource(AudioSource.file(path));
      await player.load();
      await player.seek(Duration.zero);
    } catch (e) {
      debugPrint('PLAYER PREP ERROR: $e');
    }

    if (!_disposed) {
      setState(() => _status = 'Imported');
      messenger.showSnackBar(SnackBar(content: Text('Imported: $label')));
    }
  }

  Future<void> _editSound(String label, String path) async {
    if (!mounted) return;

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => SoundEditorPage(label: label, path: path),
      ),
    );

    await _loadDownloadedManifest();
    if (!_disposed) setState(() {});
  }

  Future<void> _confirmDelete({
    required String label,
    required String key,
  }) async {
    if (!mounted) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Delete sound?'),
          content: Text(
            'This will permanently delete "$label" from your device.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );

    if (ok == true) {
      await _removeDownloadedSound(key);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final filtered = _filteredSounds;

    final screenWidth = MediaQuery.of(context).size.width;
    final crossAxisCount = screenWidth > 900
        ? 4
        : screenWidth > 600
        ? 3
        : 2;

    return Scaffold(
      appBar: AppBar(
        title: const Text('My Sounds'),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: 'Discover Sounds',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => SearchSoundPage(onImport: _onImportComplete),
                ),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.add_box_outlined),
            tooltip: 'Create Sound',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => CreateSoundPage(
                    sounds: _allSounds,
                    onImport: _onImportComplete,
                  ),
                ),
              );
            },
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => SearchSoundPage(onImport: _onImportComplete),
            ),
          );
        },
        tooltip: 'Discover Sounds',
        child: const Icon(Icons.search),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _TopStatusRow(
              status: _status,
              builtInCount: _builtInCount,
              importedCount: _importedCount,
              isLoading: _loading,
              onStopAll: _stopAll,
            ),
            const SizedBox(height: 12),

            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: _categories
                    .map((cat) {
                      final selected = _selectedCategory == cat;
                      return Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text(cat),
                          selected: selected,
                          onSelected: (_) =>
                              setState(() => _selectedCategory = cat),
                        ),
                      );
                    })
                    .toList(growable: false),
              ),
            ),

            const SizedBox(height: 12),

            TextField(
              decoration: const InputDecoration(
                hintText: 'Filter by name…',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: (val) => setState(() => _searchQuery = val),
            ),

            const SizedBox(height: 16),

            Expanded(
              child: RefreshIndicator(
                onRefresh: _bootstrap,
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : filtered.isEmpty
                    ? _EmptyState(
                        category: _selectedCategory,
                        query: _searchQuery,
                        onDiscover: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) =>
                                  SearchSoundPage(onImport: _onImportComplete),
                            ),
                          );
                        },
                        onClearFilters: () {
                          setState(() {
                            _selectedCategory = 'All';
                            _searchQuery = '';
                          });
                        },
                      )
                    : GridView.builder(
                        physics: const AlwaysScrollableScrollPhysics(),
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: crossAxisCount,
                          crossAxisSpacing: 12,
                          mainAxisSpacing: 12,

                          // Make tiles a bit taller to avoid any edge cases.
                          childAspectRatio: 2.0,
                        ),
                        itemCount: filtered.length,
                        itemBuilder: (context, index) {
                          final s = filtered[index];
                          final isAsset = s.isAsset;

                          final Color tint = isAsset
                              ? theme.colorScheme.secondary.withAlpha(
                                  (0.07 * 255).round(),
                                )
                              : theme.colorScheme.primary.withAlpha(
                                  (0.07 * 255).round(),
                                );

                          final displayLabel = isAsset
                              ? s.label
                              : _safeLabel(s.label, s.key);
                          final isPlaying = _currentlyPlayingKey == s.key;

                          return _SoundCard(
                            label: displayLabel,
                            tint: tint,
                            isImported: !isAsset,
                            isPlaying: isPlaying,
                            onPlay: () => _restartSound(s.key),
                            onEdit: isAsset
                                ? null
                                : () => _editSound(displayLabel, s.key),
                            onDelete: isAsset
                                ? null
                                : () => _confirmDelete(
                                    label: displayLabel,
                                    key: s.key,
                                  ),
                          );
                        },
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TopStatusRow extends StatelessWidget {
  final String status;
  final int builtInCount;
  final int importedCount;
  final bool isLoading;
  final VoidCallback onStopAll;

  const _TopStatusRow({
    required this.status,
    required this.builtInCount,
    required this.importedCount,
    required this.isLoading,
    required this.onStopAll,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurface.withAlpha((0.70 * 255).toInt()),
      fontWeight: FontWeight.w600,
    );

    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (isLoading)
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else
                    const Icon(Icons.graphic_eq, size: 18),
                  const SizedBox(width: 8),
                  Text('Status: $status', style: muted),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'Built-in: $builtInCount • Imported: $importedCount',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface.withAlpha(
                    (0.60 * 255).toInt(),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        OutlinedButton.icon(
          onPressed: onStopAll,
          icon: const Icon(Icons.stop_circle_outlined),
          label: const Text('Stop All'),
        ),
      ],
    );
  }
}

class _SoundCard extends StatelessWidget {
  final String label;
  final Color tint;
  final bool isImported;
  final bool isPlaying;
  final VoidCallback onPlay;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  const _SoundCard({
    required this.label,
    required this.tint,
    required this.isImported,
    required this.isPlaying,
    required this.onPlay,
    this.onEdit,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      color: tint,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            // Always “play” (re-trigger). Stop is global via Stop All.
            IconButton(
              icon: Icon(isPlaying ? Icons.graphic_eq : Icons.play_circle),
              onPressed: onPlay,
            ),
            const SizedBox(width: 8),

            Expanded(
              child: Text(
                label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),

            if (isImported)
              PopupMenuButton<String>(
                tooltip: 'Options',
                onSelected: (v) {
                  if (v == 'edit') onEdit?.call();
                  if (v == 'delete') onDelete?.call();
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'edit', child: Text('Edit')),
                  PopupMenuItem(value: 'delete', child: Text('Delete')),
                ],
                child: Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: Icon(
                    Icons.more_vert,
                    color: theme.colorScheme.onSurface.withAlpha(
                      (0.75 * 255).toInt(),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final String category;
  final String query;
  final VoidCallback onDiscover;
  final VoidCallback onClearFilters;

  const _EmptyState({
    required this.category,
    required this.query,
    required this.onDiscover,
    required this.onClearFilters,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final String title;
    final String body;

    if (query.trim().isNotEmpty) {
      title = 'No matches';
      body = 'Try a different search or clear filters.';
    } else if (category == 'Imported') {
      title = 'No imported sounds yet';
      body = 'Discover sounds to download, or import from your device.';
    } else {
      title = 'Nothing to show';
      body = 'Try Discover Sounds to add more.';
    }

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.library_music_outlined, size: 42),
                const SizedBox(height: 12),
                Text(title, style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                Text(
                  body,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurface.withAlpha(
                      (0.75 * 255).toInt(),
                    ),
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  alignment: WrapAlignment.center,
                  children: [
                    FilledButton.icon(
                      onPressed: onDiscover,
                      icon: const Icon(Icons.search),
                      label: const Text('Discover Sounds'),
                    ),
                    OutlinedButton.icon(
                      onPressed: onClearFilters,
                      icon: const Icon(Icons.filter_alt_off_outlined),
                      label: const Text('Clear Filters'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
