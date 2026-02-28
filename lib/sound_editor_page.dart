import 'dart:io';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:ffmpeg_kit_audio_flutter/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_audio_flutter/return_code.dart';

/// A page for editing a downloaded sound. Allows the user to play
/// the sound, rename it, and trim it (Trim & Replace) using FFmpegKit.
/// On completion the page returns a Map indicating any rename or
/// replacement so the caller can update its manifest and UI.
class SoundEditorPage extends StatefulWidget {
  final String label;
  final String path;
  const SoundEditorPage({super.key, required this.label, required this.path});

  @override
  State<SoundEditorPage> createState() => _SoundEditorPageState();
}

class _SoundEditorPageState extends State<SoundEditorPage> {
  late final AudioPlayer _player;
  late final TextEditingController _nameController;
  bool _loading = true;
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;
  bool _playing = false;
  // Trim range
  Duration _trimStart = Duration.zero;
  Duration _trimEnd = Duration.zero;
  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.label);
    _player = AudioPlayer();
    _load();
  }

  Future<void> _load() async {
    try {
      await _player.setAudioSource(AudioSource.file(widget.path));
      await _player.load();
      _duration = _player.duration ?? Duration.zero;
      _trimEnd = _duration;
      _player.positionStream.listen((pos) {
        if (!mounted) return;
        setState(() => _position = pos);
      });
    } catch (e) {
      debugPrint('EDITOR LOAD ERROR: $e');
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  void dispose() {
    _player.dispose();
    _nameController.dispose();
    super.dispose();
  }

  /// Rename the file on disk and return. Pops with map {oldPath, newPath, newLabel}.
  Future<void> _save() async {
    final newLabel = _nameController.text.trim();
    if (newLabel.isEmpty || newLabel == widget.label) {
      if (!mounted) return;
      Navigator.of(context).pop();
      return;
    }
    final file = File(widget.path);
    final dir = file.parent;
    final ext = widget.path.toLowerCase().endsWith('.wav') ? 'wav' : 'mp3';
    final newName =
        '${_sanitizeFilename(newLabel)}_${DateTime.now().millisecondsSinceEpoch}.$ext';
    final newFile = File('${dir.path}/$newName');
    try {
      await file.rename(newFile.path);
    } catch (e) {
      debugPrint('RENAME ERROR: $e');
    }
    if (!mounted) return;
    Navigator.of(context).pop({
      'oldPath': widget.path,
      'newPath': newFile.path,
      'newLabel': newLabel,
    });
  }

  /// Trim the audio between [_trimStart] and [_trimEnd] and replace the original.
  /// Uses FFmpegKit directly (no flutter_audio_trimmer dependency).
  Future<void> _trimAndSave() async {
    final input = File(widget.path);
    final dir = input.parent;
    final isWav = widget.path.toLowerCase().endsWith('.wav');
    final ext = isWav ? 'wav' : 'mp3';
    if (_duration == Duration.zero) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Unable to read audio duration')),
        );
      }
      return;
    }
    if (_trimEnd <= _trimStart) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Invalid trim range')));
      }
      return;
    }
    final startSec = _trimStart.inMilliseconds / 1000.0;
    final endSec = _trimEnd.inMilliseconds / 1000.0;
    final tmpOut = File(
      '${dir.path}/${_sanitizeFilename(_nameController.text)}_trim_${DateTime.now().millisecondsSinceEpoch}.$ext',
    );
    final codecArgs = isWav ? '-c copy' : '-c:a libmp3lame -q:a 2';
    final command =
        '-y -ss $startSec -to $endSec -i "${input.path}" $codecArgs "${tmpOut.path}"';
    try {
      if (mounted) setState(() => _loading = true);
      final session = await FFmpegKit.execute(command);
      final rc = await session.getReturnCode();
      if (!ReturnCode.isSuccess(rc)) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Trim failed (code ${rc?.getValue()})')),
          );
        }
        return;
      }
      // Replace original
      try {
        await input.delete();
      } catch (_) {}
      await tmpOut.rename(widget.path);
      // Reload player
      await _player.setAudioSource(AudioSource.file(widget.path));
      await _player.load();
      _duration = _player.duration ?? Duration.zero;
      _trimStart = Duration.zero;
      _trimEnd = _duration;
      _position = Duration.zero;
      _playing = false;
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Trim successful')));
        setState(() {});
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Trim error: $e')));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _sanitizeFilename(String name) {
    final safe = name
        .replaceAll(RegExp(r'[^a-zA-Z0-9_\-]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .trim();
    return safe.isEmpty ? 'sound' : safe;
  }

  String _formatTime(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Edit Sound')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(16),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      controller: _nameController,
                      decoration: const InputDecoration(
                        labelText: 'Sound Name',
                      ),
                    ),
                    const SizedBox(height: 16),
                    // Playback controls
                    Row(
                      children: [
                        IconButton(
                          icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
                          onPressed: () async {
                            if (_playing) {
                              await _player.pause();
                            } else {
                              await _player.seek(Duration.zero);
                              await _player.play();
                            }
                            if (!mounted) return;
                            setState(() => _playing = !_playing);
                          },
                        ),
                        Expanded(
                          child: Slider(
                            min: 0.0,
                            max: _duration.inMilliseconds.toDouble().clamp(
                              1.0,
                              double.infinity,
                            ),
                            value: _position.inMilliseconds.toDouble().clamp(
                              0.0,
                              _duration.inMilliseconds.toDouble(),
                            ),
                            onChanged: (val) async {
                              await _player.seek(
                                Duration(milliseconds: val.toInt()),
                              );
                            },
                          ),
                        ),
                        Text(_formatTime(_position)),
                      ],
                    ),
                    const SizedBox(height: 16),
                    // Trim sliders
                    Text('Trim Start: ${_formatTime(_trimStart)}'),
                    Slider(
                      min: 0.0,
                      max: _duration.inMilliseconds.toDouble().clamp(
                        1.0,
                        double.infinity,
                      ),
                      value: _trimStart.inMilliseconds.toDouble().clamp(
                        0.0,
                        _duration.inMilliseconds.toDouble(),
                      ),
                      onChanged: (val) {
                        final newStart = Duration(milliseconds: val.toInt());
                        if (newStart < _trimEnd) {
                          setState(() => _trimStart = newStart);
                        }
                      },
                    ),
                    const SizedBox(height: 8),
                    Text('Trim End: ${_formatTime(_trimEnd)}'),
                    Slider(
                      min: 0.0,
                      max: _duration.inMilliseconds.toDouble().clamp(
                        1.0,
                        double.infinity,
                      ),
                      value: _trimEnd.inMilliseconds.toDouble().clamp(
                        0.0,
                        _duration.inMilliseconds.toDouble(),
                      ),
                      onChanged: (val) {
                        final newEnd = Duration(milliseconds: val.toInt());
                        if (newEnd > _trimStart) {
                          setState(() => _trimEnd = newEnd);
                        }
                      },
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: _save,
                      child: const Text('Rename & Save'),
                    ),
                    const SizedBox(height: 8),
                    ElevatedButton(
                      onPressed: () async {
                        await _trimAndSave();
                      },
                      child: const Text('Trim & Replace'),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}
