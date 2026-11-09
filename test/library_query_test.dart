import 'package:beats_me/services/library_query.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final facts = {
    'a.mp3': const TrackFacts(name: 'Alpha', artist: 'Oasis', album: 'Morning Glory', bpm: 120, rating: 3, added: 10),
    'b.mp3': const TrackFacts(name: 'Beta', artist: 'Blur', album: 'Parklife', bpm: 90, rating: 5, fav: true, added: 30),
    'c.mp3': const TrackFacts(name: 'Gamma', artist: 'Oasis', album: 'Definitely Maybe', added: 20),
    'd.mp3': const TrackFacts(name: 'delta', bpm: 150, rating: 3, fav: true),
  };
  final all = facts.keys.toList();
  List<String> run(LibraryQuery q) => queryTracks(all, q, (p) => facts[p]!);

  test('search needs every word in name, artist or album', () {
    expect(run(LibraryQuery(text: 'oasis glory')), ['a.mp3']);
    expect(run(LibraryQuery(text: 'GAMMA')), ['c.mp3']);
    expect(run(LibraryQuery(text: 'zzz')), isEmpty);
  });

  test('artist/album filters are substring or exact and hide untagged songs', () {
    expect(run(LibraryQuery(artist: 'as')), ['a.mp3', 'c.mp3']);
    expect(run(LibraryQuery(artist: 'as', exact: true)), isEmpty);
    expect(run(LibraryQuery(artist: 'oasis', album: 'parklife', exact: true)), isEmpty);
  });

  test('BPM range keeps unanalyzed songs only when asked', () {
    expect(run(LibraryQuery(bpmMin: 100, bpmMax: 130)), ['a.mp3', 'c.mp3']);
    expect(run(LibraryQuery(bpmMin: 100, bpmMax: 130, includeUnanalyzed: false)), ['a.mp3']);
    expect(run(LibraryQuery(bpmMin: 140)), ['d.mp3', 'c.mp3']);
  });

  test('rating and favourite filters', () {
    expect(run(LibraryQuery(minStars: 4)), ['b.mp3']);
    expect(run(LibraryQuery(minStars: 3)), ['a.mp3', 'b.mp3', 'd.mp3']);
    expect(run(LibraryQuery(favOnly: true)), ['b.mp3', 'd.mp3']);
  });

  test('sorts put unknown values last', () {
    expect(run(LibraryQuery(sort: TrackSort.name)), ['a.mp3', 'b.mp3', 'd.mp3', 'c.mp3']);
    expect(run(LibraryQuery(sort: TrackSort.bpm)), ['b.mp3', 'a.mp3', 'd.mp3', 'c.mp3']);
    expect(run(LibraryQuery(sort: TrackSort.rating)), ['b.mp3', 'd.mp3', 'a.mp3', 'c.mp3']);
    expect(run(LibraryQuery(sort: TrackSort.added)), ['b.mp3', 'c.mp3', 'a.mp3', 'd.mp3']);
    expect(run(LibraryQuery(sort: TrackSort.artist)), ['b.mp3', 'a.mp3', 'c.mp3', 'd.mp3']);
  });

  test('filterCount and clearFilters', () {
    final q = LibraryQuery(text: 'x', bpmMin: 90, minStars: 2, favOnly: true, artist: 'a');
    expect(q.filterCount, 4);
    q.clearFilters();
    expect((q.filterCount, q.text), (0, 'x'));
  });
}
