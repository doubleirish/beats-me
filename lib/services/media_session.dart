import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_core/shared_core.dart' show lockScreenLines;
import 'package:shared_core/services/library_service.dart';

import 'app_state.dart';

/// Exposes the playback engine to the Android notification, lock screen and
/// headset buttons.
class BeatsAudioHandler extends BaseAudioHandler with SeekHandler {
  BeatsAudioHandler(this._s) {
    _s.addListener(_syncItem);
    _s.player.playingStream.listen((_) => _syncState());
    _s.player.positionStream.listen((_) => _syncState());
    _s.player.processingStateStream.listen((_) => _syncState());
    _syncItem();
    _syncState();
  }

  final AppState _s;
  String? _itemPath;
  String? _itemArt;
  Duration? _itemDuration;
  String? _itemLines;

  /// Lock-screen text for the current sub-activity; null without a step plan.
  ({String subtitle, String? next})? _lines() {
    final plan = _s.currentPlan;
    final seg = plan?.segmentAt(_s.player.position.inMilliseconds / 1000);
    if (plan == null || seg == null) return null;
    final up = plan.segmentAfter(_s.player.position.inMilliseconds / 1000);
    return lockScreenLines(seg, _s.gearAt(plan, seg), up, _s.gearAt(plan, up));
  }

  void _syncItem() {
    final path = _s.current;
    if (path == null) return;
    final media = _s.media[path];
    final dur = _s.player.duration;
    final lines = _lines();
    final key = lines == null ? null : '${lines.subtitle}|${lines.next}';
    if (path == _itemPath &&
        dur == _itemDuration &&
        media?.art?.path == _itemArt &&
        key == _itemLines) {
      return;
    }
    _itemLines = key;
    _itemPath = path;
    _itemDuration = dur;
    _itemArt = media?.art?.path;
    mediaItem.add(MediaItem(
      id: path,
      title: media?.title ?? baseName(path),
      artist: media?.artist,
      album: media?.album,
      duration: dur,
      artUri: media?.art?.uri,
      displaySubtitle: lines?.subtitle,
      displayDescription: lines?.next,
    ));
  }

  void _syncState() {
    if (_itemDuration != _s.player.duration) {
      _syncItem();
    } else {
      final l = _lines();
      if ((l == null ? null : '${l.subtitle}|${l.next}') != _itemLines) _syncItem();
    }
    final p = _s.player;
    playbackState.add(PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        p.playing ? MediaControl.pause : MediaControl.play,
        MediaControl.skipToNext,
      ],
      systemActions: const {MediaAction.seek, MediaAction.seekForward, MediaAction.seekBackward},
      androidCompactActionIndices: const [0, 1, 2],
      processingState: const {
        ProcessingState.idle: AudioProcessingState.idle,
        ProcessingState.loading: AudioProcessingState.loading,
        ProcessingState.buffering: AudioProcessingState.buffering,
        ProcessingState.ready: AudioProcessingState.ready,
        ProcessingState.completed: AudioProcessingState.completed,
      }[p.processingState]!,
      playing: p.playing,
      updatePosition: p.position,
    ));
  }

  @override
  Future<void> play() => _s.player.play();

  @override
  Future<void> pause() => _s.player.pause();

  @override
  Future<void> seek(Duration position) => _s.player.seek(position);

  @override
  Future<void> skipToNext() => _s.playNext();

  @override
  Future<void> skipToPrevious() => _s.playPrevious();

  @override
  Future<void> stop() => _s.player.pause();
}
