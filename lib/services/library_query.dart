/// How the Library list is ordered.
enum TrackSort {
  name('Name'),
  artist('Artist'),
  bpm('BPM'),
  rating('Rating'),
  added('Recently added');

  const TrackSort(this.label);
  final String label;

  static TrackSort parse(String? name) =>
      TrackSort.values.firstWhere((s) => s.name == name, orElse: () => TrackSort.name);
}

/// The Library screen's search, filters and sort order.
class LibraryQuery {
  LibraryQuery({
    this.text = '',
    this.artist = '',
    this.album = '',
    this.exact = false,
    this.sort = TrackSort.name,
    this.bpmMin,
    this.bpmMax,
    this.includeUnanalyzed = true,
    this.minStars = 0,
    this.favOnly = false,
  });

  String text, artist, album;
  bool exact;
  TrackSort sort;

  /// BPM range; null bounds are open. Songs without a tempo pass only when
  /// [includeUnanalyzed].
  double? bpmMin, bpmMax;
  bool includeUnanalyzed;
  int minStars;
  bool favOnly;

  bool get hasBpmRange => bpmMin != null || bpmMax != null;

  /// Number of active filters (search text and sort excluded).
  int get filterCount =>
      (hasBpmRange ? 1 : 0) + (minStars > 0 ? 1 : 0) + (favOnly ? 1 : 0) +
      (artist.isNotEmpty ? 1 : 0) + (album.isNotEmpty ? 1 : 0);

  bool get active => filterCount > 0 || text.trim().isNotEmpty;

  /// Whether ratings are needed to answer this query.
  bool get needsRatings => minStars > 0 || favOnly || sort == TrackSort.rating;

  void clearFilters() {
    artist = album = '';
    exact = false;
    bpmMin = bpmMax = null;
    includeUnanalyzed = true;
    minStars = 0;
    favOnly = false;
  }
}

/// What the query needs to know about each track.
class TrackFacts {
  const TrackFacts({
    required this.name,
    this.artist,
    this.album,
    this.bpm,
    this.rating = 0,
    this.fav = false,
    this.added,
  });
  final String name;
  final String? artist, album;
  final double? bpm;
  final int rating;
  final bool fav;
  final int? added;
}

String _norm(String s) => s.trim().toLowerCase();

/// [tracks] passing [q]'s search and filters, in [q]'s sort order. Search
/// words must each appear in the name, artist or album. Untagged tracks are
/// hidden while an artist/album filter is active, matching `LibraryIndex.filter`.
List<String> queryTracks(List<String> tracks, LibraryQuery q, TrackFacts Function(String) facts) {
  final words = _norm(q.text).split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  final a = _norm(q.artist), b = _norm(q.album);
  bool field(String? have, String want) =>
      want.isEmpty || (have != null && (q.exact ? _norm(have) == want : _norm(have).contains(want)));

  final rows = <(String, TrackFacts)>[];
  for (final t in tracks) {
    final f = facts(t);
    if (words.isNotEmpty) {
      final hay = _norm('${f.name} ${f.artist ?? ''} ${f.album ?? ''}');
      if (!words.every(hay.contains)) continue;
    }
    if (!field(f.artist, a) || !field(f.album, b)) continue;
    if (q.hasBpmRange) {
      final bpm = f.bpm;
      if (bpm == null) {
        if (!q.includeUnanalyzed) continue;
      } else if ((q.bpmMin != null && bpm < q.bpmMin!) || (q.bpmMax != null && bpm > q.bpmMax!)) {
        continue;
      }
    }
    if (f.rating < q.minStars) continue;
    if (q.favOnly && !f.fav) continue;
    rows.add((t, f));
  }

  int byName((String, TrackFacts) x, (String, TrackFacts) y) =>
      _norm(x.$2.name).compareTo(_norm(y.$2.name));
  // Unknown values go last; ties fall back to the name.
  int cmpNum(num? x, num? y, {bool desc = false}) {
    if (x == null || y == null) return x == y ? 0 : (x == null ? 1 : -1);
    return desc ? y.compareTo(x) : x.compareTo(y);
  }

  switch (q.sort) {
    case TrackSort.name:
      rows.sort(byName);
    case TrackSort.artist:
      rows.sort((x, y) {
        final ax = x.$2.artist, ay = y.$2.artist;
        if (ax == null || ay == null) return ax == ay ? byName(x, y) : (ax == null ? 1 : -1);
        final c = _norm(ax).compareTo(_norm(ay));
        return c != 0 ? c : byName(x, y);
      });
    case TrackSort.bpm:
      rows.sort((x, y) {
        final c = cmpNum(x.$2.bpm, y.$2.bpm);
        return c != 0 ? c : byName(x, y);
      });
    case TrackSort.rating:
      rows.sort((x, y) {
        final r = y.$2.rating.compareTo(x.$2.rating);
        if (r != 0) return r;
        final f = (y.$2.fav ? 1 : 0) - (x.$2.fav ? 1 : 0);
        return f != 0 ? f : byName(x, y);
      });
    case TrackSort.added:
      rows.sort((x, y) {
        final c = cmpNum(x.$2.added, y.$2.added, desc: true);
        return c != 0 ? c : byName(x, y);
      });
  }
  return [for (final r in rows) r.$1];
}
