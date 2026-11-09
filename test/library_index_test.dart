import 'package:beats_me/services/library_index.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  LibraryIndex build() => LibraryIndex()
    ..add('1.mp3', artist: 'Oasis', album: 'Morning Glory')
    ..add('2.mp3', artist: 'oasis ', album: 'morning glory')
    ..add('3.mp3', artist: 'Oasis', album: 'Definitely Maybe')
    ..add('4.mp3', artist: 'Blur', album: 'Parklife')
    ..add('5.mp3');

  test('groups artists and albums ignoring case', () {
    final i = build();
    final artists = i.artists();
    expect(artists.map((a) => a.name.trim().toLowerCase()), ['oasis', 'blur', 'unknown artist']);
    final oasis = artists[0];
    expect((oasis.tracks.length, oasis.albums.length), (3, 2));
    expect(i.artists(bySongs: false).first.name, 'Blur');
    expect(i.artists(hideUpTo: 1).single.name.trim(), 'Oasis');
    expect(i.albums(hideUpTo: 1), hasLength(1));
    expect(i.artists(filter: 'blu'), hasLength(1));
    expect(i.albums(artist: 'OASIS').map((a) => a.tracks.length).toList()..sort(), [1, 2]);
    expect(i.albums(filter: 'park').single.artist, 'Blur');
  });

  test('filters tracks by substring or exact names', () {
    final i = build();
    const all = ['1.mp3', '2.mp3', '3.mp3', '4.mp3', '5.mp3', '6.mp3'];
    expect(i.filter(all), all);
    expect(i.filter(all, artist: 'as'), ['1.mp3', '2.mp3', '3.mp3']);
    expect(i.filter(all, artist: 'as', exact: true), isEmpty);
    expect(i.filter(all, artist: 'oasis', album: 'morning glory', exact: true), ['1.mp3', '2.mp3']);
    expect(i.filter(all, album: 'life'), ['4.mp3']); // untagged 6.mp3 hidden
  });
}
