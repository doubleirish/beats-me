/// In-memory artist/album index built from track tags.
class ArtistEntry {
  ArtistEntry(this.name);
  final String name;
  final List<String> tracks = [];
  final Set<String> albums = {};
}

class AlbumEntry {
  AlbumEntry(this.album, this.artist);
  final String album;
  final String artist;
  final List<String> tracks = [];
}

String _norm(String s) => s.trim().toLowerCase();

class LibraryIndex {
  static const unknownArtist = 'Unknown artist';
  static const unknownAlbum = 'Unknown album';

  final Map<String, ({String artist, String album})> _info = {};
  final Map<String, int> _added = {};

  int get length => _info.length;
  bool has(String path) => _info.containsKey(path);
  ({String artist, String album})? infoOf(String path) => _info[path];

  /// File modification time (ms since epoch) when the index was built.
  int? addedOf(String path) => _added[path];
  void setAdded(String path, int ms) => _added[path] = ms;

  void add(String path, {String? artist, String? album}) {
    final a = artist?.trim() ?? '';
    final b = album?.trim() ?? '';
    _info[path] = (artist: a.isEmpty ? unknownArtist : a, album: b.isEmpty ? unknownAlbum : b);
  }

  void clear() {
    _info.clear();
    _added.clear();
  }

  /// Artists by name (case-insensitive grouping), optionally name-filtered.
  List<ArtistEntry> artists({String filter = '', bool bySongs = true, int hideUpTo = 0}) {
    final out = <String, ArtistEntry>{};
    final f = _norm(filter);
    _info.forEach((path, i) {
      if (f.isNotEmpty && !_norm(i.artist).contains(f)) return;
      final e = out.putIfAbsent(_norm(i.artist), () => ArtistEntry(i.artist));
      e.tracks.add(path);
      e.albums.add(_norm(i.album));
    });
    final list = out.values.where((e) => e.tracks.length > hideUpTo).toList();
    return list
      ..sort((a, b) {
        if (bySongs && a.tracks.length != b.tracks.length) return b.tracks.length - a.tracks.length;
        return _norm(a.name).compareTo(_norm(b.name));
      });
  }

  List<AlbumEntry> albums(
      {String filter = '', String? artist, bool bySongs = true, int hideUpTo = 0}) {
    final out = <String, AlbumEntry>{};
    final f = _norm(filter);
    final who = artist == null ? null : _norm(artist);
    _info.forEach((path, i) {
      if (f.isNotEmpty && !_norm(i.album).contains(f)) return;
      if (who != null && _norm(i.artist) != who) return;
      final e = out.putIfAbsent('${_norm(i.artist)}\u0000${_norm(i.album)}',
          () => AlbumEntry(i.album, i.artist));
      e.tracks.add(path);
    });
    final list = out.values.where((e) => e.tracks.length > hideUpTo).toList();
    return list
      ..sort((a, b) {
        if (bySongs && a.tracks.length != b.tracks.length) return b.tracks.length - a.tracks.length;
        return _norm(a.album).compareTo(_norm(b.album));
      });
  }

  /// Tracks matching the artist/album text filters (substring, or exact when
  /// [exact]). Tracks not tagged yet are hidden while a filter is active.
  List<String> filter(List<String> tracks,
      {String artist = '', String album = '', bool exact = false}) {
    final a = _norm(artist), b = _norm(album);
    if (a.isEmpty && b.isEmpty) return tracks;
    bool ok(String have, String want) =>
        want.isEmpty || (exact ? _norm(have) == want : _norm(have).contains(want));
    return [
      for (final t in tracks)
        if (_info[t] case final i? when ok(i.artist, a) && ok(i.album, b)) t
    ];
  }
}
