import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // rootBundle
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

import 'create_sound_page.dart';
import 'search_sound_page.dart';
import 'sound_editor_page.dart';
import 'upload_sound_page.dart';
import 'import_sound_page.dart';

class SoundLibraryPage extends StatefulWidget {
  const SoundLibraryPage({super.key});

  @override
  State<SoundLibraryPage> createState() => _SoundLibraryPageState();
}

class _SoundLibraryPageState extends State<SoundLibraryPage> {
  String _status = 'Ready';
  bool _disposed = false;
  bool _loading = true;

  static const int _poolSize = 8;

  late final List<AudioPlayer> _players;
  final List<StreamSubscription<PlayerState>> _playerSubs = [];

  late final List<String?> _playerKey;
  late final List<bool> _playerWasPlaying;

  final Map<String, int> _playingCountByKey = {};

  bool _isPlaying = false;
  bool _isLoadingKey = false;

  final List<String> _categories = const [
    'All',
    'Built-in',
    'Imported',
    'Favorites',
  ];
  String _selectedCategory = 'All';
  String _searchQuery = '';

  final Map<String, String> _assetTempCache = {};

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

  final Set<String> _favorites = {};

  bool _soundboardMode = false;

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
          // Category filter
          if (_selectedCategory == 'Built-in' && !s.isAsset) {
            return false;
          }

          if (_selectedCategory == 'Imported' && s.isAsset) {
            return false;
          }

          if (_selectedCategory == 'Favorites' && !_favorites.contains(s.key)) {
            return false;
          }

          // Search filter
          if (q.isNotEmpty && !s.label.toLowerCase().contains(q)) {
            return false;
          }

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
  int get _favoritesCount => _favorites.length;

  @override
  void initState() {
    super.initState();
    _players = List.generate(_poolSize, (_) => AudioPlayer());
    _playerKey = List<String?>.filled(_poolSize, null);
    _playerWasPlaying = List<bool>.filled(_poolSize, false);
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    if (_disposed) return;
    try {
      setState(() {
        _loading = true;
        _status = 'Loading…';
      });
      await _loadDownloadedManifest();
      await _loadFavorites();
      await _initAudio();
      await _prewarmBuiltInAssets();
      _wirePlayerListenersOnce();
      _safeSetState(() {
        _loading = false;
        _recomputeStatus();
      });
    } catch (e) {
      debugPrint('BOOTSTRAP ERROR: $e');
      _safeSetState(() {
        _loading = false;
        _status = 'Init error';
      });
    }
  }

  void _safeSetState(VoidCallback fn) {
    if (_disposed) return;
    if (!mounted) return;
    setState(fn);
  }

  void _recomputeStatus() {
    if (_loading) {
      _status = 'Loading…';
      return;
    }
    if (_isLoadingKey) {
      _status = 'Loading';
      return;
    }
    if (_isPlaying) {
      _status = 'Playing';
      return;
    }
    _status = 'Ready';
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
            contentType: AndroidAudioContentType.sonification,
            usage: AndroidAudioUsage.game,
          ),
          androidAudioFocusGainType:
              AndroidAudioFocusGainType.gainTransientMayDuck,
          androidWillPauseWhenDucked: false,
        ),
      );
      await session.setActive(true);
      debugPrint('AUDIO SESSION READY (active=true)');
    } catch (e) {
      debugPrint('AUDIO SESSION INIT ERROR: $e');
      _safeSetState(() => _status = 'Audio init error');
    }
  }

  void _wirePlayerListenersOnce() {
    if (_playerSubs.isNotEmpty) return;
    for (var i = 0; i < _players.length; i++) {
      final player = _players[i];
      final sub = player.playerStateStream.listen(
        (state) async {
          if (_disposed) return;
          final ps = state.processingState;
          final nowPlaying = state.playing;
          final wasPlaying = _playerWasPlaying[i];
          final key = _playerKey[i];

          if (key != null && wasPlaying != nowPlaying) {
            if (nowPlaying) {
              _incPlayingCount(key);
            } else {
              _decPlayingCount(key);
            }
          }

          _playerWasPlaying[i] = nowPlaying;

          if (ps == ProcessingState.completed) {
            try {
              await player.pause();
              await player.seek(Duration.zero);
            } catch (_) {}
            _playerKey[i] = null;
            _playerWasPlaying[i] = false;
          }

          _isLoadingKey = _players.any((p) {
            final s = p.playerState;
            return s.processingState == ProcessingState.loading ||
                s.processingState == ProcessingState.buffering;
          });
          _isPlaying = _players.any((p) => p.playing);

          _safeSetState(_recomputeStatus);
        },
        onError: (Object e, StackTrace st) {
          debugPrint('PLAYER($i) ERROR: $e');
          final key = _playerKey[i];
          if (key != null && _playerWasPlaying[i]) {
            _decPlayingCount(key);
          }
          _playerKey[i] = null;
          _playerWasPlaying[i] = false;

          _isPlaying = _players.any((p) => p.playing);
          _isLoadingKey = _players.any((p) {
            final s = p.playerState;
            return s.processingState == ProcessingState.loading ||
                s.processingState == ProcessingState.buffering;
          });
          _safeSetState(_recomputeStatus);
        },
      );
      _playerSubs.add(sub);
    }
  }

  void _incPlayingCount(String key) {
    _playingCountByKey[key] = (_playingCountByKey[key] ?? 0) + 1;
  }

  void _decPlayingCount(String key) {
    final cur = _playingCountByKey[key] ?? 0;
    if (cur <= 1) {
      _playingCountByKey.remove(key);
    } else {
      _playingCountByKey[key] = cur - 1;
    }
  }

  bool _isKeyPlaying(String key) => (_playingCountByKey[key] ?? 0) > 0;

  @override
  void dispose() {
    _disposed = true;
    for (final s in _playerSubs) {
      s.cancel();
    }
    for (final p in _players) {
      p.dispose();
    }
    _saveFavorites();
    super.dispose();
  }

  Future<File> _manifestFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/sounds_manifest.json');
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
      final existingPaths = <String>{};

      for (final item in decoded) {
        if (item is Map) {
          final rawLabel = item['label']?.toString();
          final path = item['path']?.toString();
          if (path == null) continue;
          if (existingPaths.contains(path)) continue;

          final f = File(path);
          if (await f.exists()) {
            final label = _safeLabel(rawLabel ?? '', path);
            _downloadedSounds.add((label: label, path: path));
            existingPaths.add(path);
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

  String _deriveLabelFromPath(String path) {
    try {
      var base = path.split(Platform.pathSeparator).last;
      base = base.replaceAll(RegExp(r'\.(mp3|wav)$', caseSensitive: false), '');
      base = base.replaceAll(RegExp(r'[_\-\s]\d{10,}$'), '');
      base = base.replaceAll(RegExp(r'_+'), ' ').trim();
      return base.isEmpty ? 'Imported Sound' : base;
    } catch (_) {
      return 'Imported Sound';
    }
  }

  String _safeLabel(String label, String path) {
    final trimmed = label.trim();
    if (trimmed.isEmpty || RegExp(r'^[\W_]+$').hasMatch(trimmed)) {
      return _deriveLabelFromPath(path);
    }
    return trimmed;
  }

  Future<File> _favoritesFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/favorites.json');
  }

  Future<void> _loadFavorites() async {
    try {
      final f = await _favoritesFile();
      if (!await f.exists()) return;
      final raw = await f.readAsString();
      if (raw.trim().isEmpty) return;

      final decoded = jsonDecode(raw);
      if (decoded is List) {
        _favorites.clear();
        for (final k in decoded) {
          if (k is String) _favorites.add(k);
        }
      }
    } catch (e) {
      debugPrint('FAVOURITES LOAD ERROR: $e');
    }
  }

  Future<void> _saveFavorites() async {
    try {
      final f = await _favoritesFile();
      await f.writeAsString(jsonEncode(_favorites.toList()));
    } catch (e) {
      debugPrint('FAVOURITES SAVE ERROR: $e');
    }
  }

  void _toggleFavorite(String key) {
    setState(() {
      if (_favorites.contains(key)) {
        _favorites.remove(key);
      } else {
        _favorites.add(key);
      }
    });
    _saveFavorites();
  }

  Future<void> _prewarmBuiltInAssets() async {
    for (final s in _builtInSounds) {
      await _ensureAssetTempPath(s.asset);
    }
  }

  Future<String> _ensureAssetTempPath(String assetPath) async {
    final existing = _assetTempCache[assetPath];
    if (existing != null) {
      final f = File(existing);
      if (await f.exists() && await f.length() > 0) return existing;
      _assetTempCache.remove(assetPath);
    }

    final bd = await rootBundle.load(assetPath);
    final bytes = bd.buffer.asUint8List();
    final dir = await getTemporaryDirectory();
    final ext = assetPath.toLowerCase().endsWith('.wav') ? 'wav' : 'mp3';
    final safeName = assetPath
        .replaceAll('/', '_')
        .replaceAll('\\', '_')
        .replaceAll(':', '_');
    final file = File('${dir.path}/taiga_asset_$safeName.$ext');
    await file.writeAsBytes(bytes, flush: true);
    _assetTempCache[assetPath] = file.path;
    return file.path;
  }

  int _findFreePlayerIndex() {
    for (var i = 0; i < _players.length; i++) {
      final p = _players[i];
      final s = p.playerState;
      final busy =
          p.playing ||
          s.processingState == ProcessingState.loading ||
          s.processingState == ProcessingState.buffering;
      if (!busy) return i;
    }
    return 0;
  }

  Future<void> _stopPlayerAt(int i) async {
    final p = _players[i];
    final key = _playerKey[i];
    if (key != null && _playerWasPlaying[i]) {
      _decPlayingCount(key);
    }
    _playerWasPlaying[i] = false;
    _playerKey[i] = null;
    try {
      await p.stop();
      await p.seek(Duration.zero);
    } catch (_) {}
  }

  Future<void> _stopAllInstancesOfKey(String key) async {
    for (var i = 0; i < _players.length; i++) {
      if (_playerKey[i] == key) {
        await _stopPlayerAt(i);
      }
    }
  }

  Future<void> _playKey(String key) async {
    _safeSetState(() {
      _isLoadingKey = true;
      _recomputeStatus();
    });

    try {
      final session = await AudioSession.instance;
      await session.setActive(true);

      if (_isKeyPlaying(key)) {
        await _stopAllInstancesOfKey(key);
      }

      final i = _findFreePlayerIndex();
      if (_playerKey[i] != null || _players[i].playing) {
        await _stopPlayerAt(i);
      }

      final player = _players[i];
      _playerKey[i] = key;
      _playerWasPlaying[i] = false;

      if (key.startsWith('assets/')) {
        final tempPath = await _ensureAssetTempPath(key);
        await player.setFilePath(tempPath);
      } else {
        await player.setFilePath(key);
      }

      await player.setVolume(1.0);
      await player.setSpeed(1.0);
      await player.play();

      _safeSetState(() {
        _isLoadingKey = false;
        _isPlaying = _players.any((p) => p.playing);
        _recomputeStatus();
      });
    } catch (e) {
      debugPrint('AUDIO ERROR ($key): $e');
      for (var i = 0; i < _players.length; i++) {
        if (_playerKey[i] == key && !_players[i].playing) {
          if (_playerWasPlaying[i]) {
            _playerWasPlaying[i] = false;
            _decPlayingCount(key);
          }
          _playerKey[i] = null;
        }
      }
      _safeSetState(() {
        _isLoadingKey = false;
        _isPlaying = _players.any((p) => p.playing);
        _status = 'Audio error';
      });
    }
  }

  Future<void> _stopAll() async {
    for (var i = 0; i < _players.length; i++) {
      await _stopPlayerAt(i);
    }
    _safeSetState(() {
      _playingCountByKey.clear();
      _isPlaying = false;
      _isLoadingKey = false;
      _recomputeStatus();
    });
  }

  Future<void> _removeDownloadedSound(String key) async {
    final index = _downloadedSounds.indexWhere((s) => s.path == key);
    if (index == -1) return;

    final messenger = ScaffoldMessenger.of(context);
    await _stopAllInstancesOfKey(key);

    final removed = _downloadedSounds.removeAt(index);
    await _saveDownloadedManifest();

    try {
      final f = File(removed.path);
      if (await f.exists()) await f.delete();
    } catch (_) {}

    messenger.showSnackBar(
      SnackBar(content: Text('Deleted: ${removed.label}')),
    );

    _safeSetState(() {
      _isPlaying = _players.any((p) => p.playing);
      _isLoadingKey = _players.any((p) {
        final s = p.playerState;
        return s.processingState == ProcessingState.loading ||
            s.processingState == ProcessingState.buffering;
      });
      _recomputeStatus();
    });
  }

  Future<void> _onImportComplete(String label, String path) async {
    if (_downloadedSounds.any((s) => s.path == path)) return;

    final messenger = ScaffoldMessenger.of(context);
    _downloadedSounds.add((label: label, path: path));
    await _saveDownloadedManifest();

    messenger.showSnackBar(SnackBar(content: Text('Imported: $label')));
    _safeSetState(_recomputeStatus);
  }

  Future<void> _editSound(String label, String path) async {
    if (!mounted) return;

    final result = await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => SoundEditorPage(label: label, path: path),
      ),
    );

    if (result is Map && result.containsKey('oldPath')) {
      final String oldPath = result['oldPath'];
      final String newPath = result['newPath'];
      final String newLabel = result['newLabel'];

      final index = _downloadedSounds.indexWhere((s) => s.path == oldPath);
      if (index != -1) {
        _downloadedSounds[index] = (label: newLabel, path: newPath);

        if (_favorites.remove(oldPath)) {
          _favorites.add(newPath);
          _saveFavorites();
        }

        await _saveDownloadedManifest();
        _safeSetState(_recomputeStatus);
      }
    }
  }

  Future<void> _confirmDelete({
    required String label,
    required String key,
  }) async {
    if (!mounted) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
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
      ),
    );

    if (ok == true) {
      await _removeDownloadedSound(key);
    }
  }

  void _showAddMenu() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.search),
                title: const Text('Discover sounds'),
                onTap: () {
                  Navigator.pop(ctx);
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) =>
                          SearchSoundPage(onImport: _onImportComplete),
                    ),
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.folder_open),
                title: const Text('Import from device'),
                onTap: () {
                  Navigator.pop(ctx);
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) =>
                          UploadSoundPage(onImport: _onImportComplete),
                    ),
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.link),
                title: const Text('Import from URL'),
                onTap: () {
                  Navigator.pop(ctx);
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) =>
                          ImportSoundPage(onImport: _onImportComplete),
                    ),
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.library_add),
                title: const Text('Create sound'),
                onTap: () {
                  Navigator.pop(ctx);
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
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final filtered = _filteredSounds;
    final screenWidth = MediaQuery.of(context).size.width;
    final crossAxisCount = screenWidth > 900 ? 4 : (screenWidth > 600 ? 3 : 2);
    final tileAspectRatio = _soundboardMode ? 1.0 : 1.70;

    return Scaffold(
      appBar: AppBar(
        title: const Text('My Sounds'),
        actions: [
          IconButton(
            enableFeedback: false,
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
            enableFeedback: false,
            icon: const Icon(Icons.add),
            tooltip: 'Add sound',
            onPressed: _showAddMenu,
          ),
          IconButton(
            enableFeedback: false,
            icon: Icon(
              _soundboardMode ? Icons.grid_view : Icons.dashboard_customize,
            ),
            tooltip: _soundboardMode
                ? 'Exit soundboard mode'
                : 'Quick soundboard mode',
            onPressed: () => setState(() => _soundboardMode = !_soundboardMode),
          ),
        ],
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
              favoritesCount: _favoritesCount,
              isLoading: _loading,
              onStopAll: _stopAll,
              soundboardMode: _soundboardMode,
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
                          childAspectRatio: tileAspectRatio,
                        ),
                        itemCount: filtered.length,
                        itemBuilder: (context, index) {
                          final s = filtered[index];
                          final isAsset = s.isAsset;

                          final tint = isAsset
                              ? theme.colorScheme.secondary.withAlpha(
                                  (0.05 * 255).round(),
                                )
                              : theme.colorScheme.primary.withAlpha(
                                  (0.05 * 255).round(),
                                );

                          final label = isAsset
                              ? s.label
                              : _safeLabel(s.label, s.key);

                          final isPlayingThis = _isKeyPlaying(s.key);
                          final isFav = _favorites.contains(s.key);

                          return _SoundCard(
                            label: label,
                            tint: tint,
                            isImported: !isAsset,
                            isPlaying: isPlayingThis,
                            isFavorite: isFav,
                            isQuickMode: _soundboardMode,
                            onToggle: () => _playKey(s.key),
                            onEdit: isAsset
                                ? null
                                : () => _editSound(label, s.key),
                            onDelete: isAsset
                                ? null
                                : () =>
                                      _confirmDelete(label: label, key: s.key),
                            onToggleFavorite: () => _toggleFavorite(s.key),
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
  final int favoritesCount;
  final bool isLoading;
  final bool soundboardMode;
  final VoidCallback onStopAll;

  const _TopStatusRow({
    required this.status,
    required this.builtInCount,
    required this.importedCount,
    required this.favoritesCount,
    required this.isLoading,
    required this.onStopAll,
    required this.soundboardMode,
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
                  Expanded(
                    child: Text(
                      'Status: $status',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: muted,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'Built-in: $builtInCount • Imported: $importedCount • Favourites: $favoritesCount${soundboardMode ? ' • Soundboard' : ''}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
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
        LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < 380;
            if (compact) {
              return IconButton(
                tooltip: 'Stop All',
                onPressed: onStopAll,
                icon: const Icon(Icons.stop_circle_outlined),
              );
            }
            return OutlinedButton.icon(
              onPressed: onStopAll,
              icon: const Icon(Icons.stop_circle_outlined),
              label: const Text('Stop All'),
            );
          },
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
  final bool isFavorite;
  final bool isQuickMode;
  final VoidCallback onToggle;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  final VoidCallback onToggleFavorite;

  const _SoundCard({
    required this.label,
    required this.tint,
    required this.isImported,
    required this.isPlaying,
    required this.isFavorite,
    required this.isQuickMode,
    required this.onToggle,
    this.onEdit,
    this.onDelete,
    required this.onToggleFavorite,
  });

  Widget _miniIconButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
  }) {
    return IconButton(
      enableFeedback: false,
      icon: Icon(icon, size: 20),
      tooltip: tooltip,
      onPressed: onPressed,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 34, height: 34),
      visualDensity: VisualDensity.compact,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      color: tint,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        side: BorderSide(
          color: isPlaying ? theme.colorScheme.primary : Colors.transparent,
          width: 2,
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: isQuickMode
            ? const EdgeInsets.fromLTRB(10, 10, 10, 10)
            : const EdgeInsets.fromLTRB(10, 10, 10, 6),
        child: Column(
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                IconButton(
                  enableFeedback: false,
                  icon: Icon(
                    isPlaying ? Icons.stop : Icons.play_arrow,
                    size: isQuickMode ? 28 : 20,
                  ),
                  tooltip: isPlaying
                      ? 'Stop'
                      : 'Play (restart if already playing)',
                  onPressed: onToggle,
                  padding: EdgeInsets.zero,
                  constraints: BoxConstraints.tightFor(
                    width: isQuickMode ? 42 : 34,
                    height: isQuickMode ? 42 : 34,
                  ),
                  visualDensity: VisualDensity.compact,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    label,
                    maxLines: isQuickMode ? 3 : 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      height: 1.12,
                    ),
                  ),
                ),
              ],
            ),
            const Spacer(),
            Row(
              children: [
                if (!isQuickMode)
                  Expanded(
                    child: Text(
                      isImported ? 'Imported' : 'Built-in',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurface.withAlpha(
                          (0.60 * 255).toInt(),
                        ),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  )
                else
                  const Spacer(),
                IconButton(
                  enableFeedback: false,
                  icon: Icon(
                    isFavorite ? Icons.star : Icons.star_border,
                    size: 20,
                    color: isFavorite
                        ? theme.colorScheme.secondary
                        : theme.colorScheme.onSurface.withAlpha(
                            (0.70 * 255).toInt(),
                          ),
                  ),
                  tooltip: isFavorite
                      ? 'Remove from favourites'
                      : 'Add to favourites',
                  onPressed: onToggleFavorite,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 34,
                    height: 34,
                  ),
                  visualDensity: VisualDensity.compact,
                ),
                if (!isQuickMode && isImported) ...[
                  _miniIconButton(
                    icon: Icons.edit_outlined,
                    tooltip: 'Edit',
                    onPressed: onEdit,
                  ),
                  _miniIconButton(
                    icon: Icons.delete_outline,
                    tooltip: 'Delete',
                    onPressed: onDelete,
                  ),
                ],
              ],
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
    } else if (category == 'Favorites') {
      title = 'No favourites yet';
      body = 'Star sounds to see them here.';
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
