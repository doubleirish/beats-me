import 'dart:convert';
import 'dart:io';

import 'package:shared_core/services/mixtape/importer.dart' show SongMeta;

/// Appends a play to the log shared with analyze-this
/// (`%APPDATA%\music-share\plays.jsonl`); analyze-this imports it.
/// Does nothing where there is no APPDATA (Android uses the journal).
Future<void> logSharedPlay(String path, double listened, bool completed) async {
  try {
    final base = Platform.environment['APPDATA'];
    if (base == null) return;
    final dir = Directory('$base${Platform.pathSeparator}music-share');
    await dir.create(recursive: true);
    final meta = await SongMeta.load(path);
    final line = jsonEncode({
      'path': path,
      'at': DateTime.now().millisecondsSinceEpoch,
      'listened': listened,
      'done': completed,
      'app': 'beats-me',
      for (final k in const ['origPath', 'sha256', 'title', 'artist', 'duration'])
        if (meta?[k] != null) k: meta![k],
    });
    await File('${dir.path}${Platform.pathSeparator}plays.jsonl')
        .writeAsString('$line\n', mode: FileMode.append);
  } catch (_) {}
}
