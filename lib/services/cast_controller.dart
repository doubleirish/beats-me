import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_core/shared_core.dart';

/// "Play on…": sends playback to a Chromecast / Google Cast device and back.
class CastController extends ChangeNotifier {
  CastController(this.playback);

  final PlaybackController playback;

  List<CastDevice> devices = [];
  bool scanning = false;
  CastDevice? casting;
  CastDevice? connecting;
  String? error;
  CastRenderer? _renderer;

  PlayerEngine get _engine => playback.player;

  bool get isCasting => casting != null;

  Future<void> scan() async {
    if (scanning) return;
    scanning = true;
    error = null;
    notifyListeners();
    try {
      devices = await discoverCastDevices();
      if (devices.isEmpty) error = 'No cast devices found on this network.';
    } catch (e) {
      error = 'Could not search for cast devices: $e';
    } finally {
      scanning = false;
      notifyListeners();
    }
  }

  Future<void> cast(CastDevice device) async {
    if (connecting != null) return;
    error = null;
    connecting = device;
    notifyListeners();
    final old = _renderer;
    final r = CastRenderer(device, info: _info);
    r.onError = (e) => unawaited(_failed(r, e));
    try {
      await _engine.useRemote(r);
      _renderer = r;
      casting = device;
    } catch (e) {
      error = 'Could not play on ${device.name}: $e';
      unawaited(r.stop().catchError((_) {}));
      _renderer = old;
    } finally {
      connecting = null;
      notifyListeners();
    }
  }

  Future<CastTrackInfo> _info(String path) async {
    if (!playback.media.containsKey(path)) {
      await playback.ensureMedia(path).timeout(const Duration(seconds: 3), onTimeout: () {});
    }
    final m = playback.media[path];
    return (title: m?.title, artist: m?.artist, album: m?.album, art: m?.art, lyrics: m?.lyrics);
  }

  Future<void> _failed(CastRenderer r, Object e) async {
    if (!identical(r, _renderer)) return;
    error = '${r.device.name}: $e. Playing on this phone again.';
    await stop();
  }

  Future<void> stop() async {
    _renderer = null;
    casting = null;
    try {
      await _engine.useRemote(null);
    } catch (_) {}
    notifyListeners();
  }
}
