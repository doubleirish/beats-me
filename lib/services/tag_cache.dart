import 'dart:convert';
import 'dart:io';

import 'library_index.dart';

typedef TagRead = Future<({String? artist, String? album})> Function(String path);

/// Audio file size/mtime plus the `.meta.json` sidecar's mtime (it can
/// override the tags), so a cache entry goes stale when either changes.
Future<List<int>> _stamp(String path) async {
  final a = await FileStat.stat(path);
  final m = await FileStat.stat('$path.meta.json');
  return [
    a.modified.millisecondsSinceEpoch,
    a.size,
    m.type == FileSystemEntityType.notFound ? 0 : m.modified.millisecondsSinceEpoch,
  ];
}

bool _same(Object? a, List<int> b) =>
    a is List && a.length == b.length && [for (var i = 0; i < b.length; i++) a[i] == b[i]].every((x) => x);

/// Fills [index] for [tracks], reusing artist/album from [cacheFile] for
/// files whose stamp is unchanged and calling [read] only for new or changed
/// ones. The cache is rewritten when anything changed, unless [cancelled].
Future<void> indexTracks(
  LibraryIndex index,
  List<String> tracks, {
  required File? cacheFile,
  required TagRead read,
  bool Function()? cancelled,
  Future<void> Function(int done)? onProgress,
  int progressEvery = 25,
}) async {
  var old = <String, dynamic>{};
  try {
    old = (jsonDecode(await cacheFile!.readAsString()) as Map).cast<String, dynamic>();
  } catch (_) {}
  final fresh = <String, dynamic>{};
  var changed = false;
  for (var i = 0; i < tracks.length; i++) {
    if (cancelled?.call() == true) return;
    final path = tracks[i];
    List<int>? stamp;
    try {
      stamp = await _stamp(path);
    } catch (_) {}
    final hit = old[path];
    if (stamp != null) index.setAdded(path, stamp[0]);
    if (stamp != null && hit is Map && _same(hit['k'], stamp)) {
      index.add(path, artist: hit['a'] as String?, album: hit['b'] as String?);
      fresh[path] = hit;
    } else {
      changed = true;
      try {
        final t = await read(path);
        index.add(path, artist: t.artist, album: t.album);
        if (stamp != null) fresh[path] = {'k': stamp, 'a': t.artist, 'b': t.album};
      } catch (_) {
        index.add(path);
      }
    }
    if (onProgress != null && (i % progressEvery == progressEvery - 1 || i == tracks.length - 1)) {
      await onProgress(i + 1);
    }
  }
  if (cacheFile != null && (changed || fresh.length != old.length)) {
    try {
      final tmp = File('${cacheFile.path}.tmp');
      await tmp.writeAsString(jsonEncode(fresh));
      await tmp.rename(cacheFile.path);
    } catch (_) {}
  }
}
