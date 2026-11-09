import 'dart:io';

import 'package:beats_me/services/library_index.dart';
import 'package:beats_me/services/tag_cache.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('tagcache'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('unchanged files come from the cache; new and changed files are re-read', () async {
    final a = File('${dir.path}/a.mp3')..writeAsStringSync('aaa');
    final b = File('${dir.path}/b.mp3')..writeAsStringSync('bbb');
    final cache = File('${dir.path}/.tags-cache.json');
    final reads = <String>[];
    Future<({String? artist, String? album})> read(String p) async {
      reads.add(p.split(RegExp(r'[\\/]')).last);
      return (artist: 'Artist ${reads.length}', album: 'Album');
    }

    final first = LibraryIndex();
    await indexTracks(first, [a.path, b.path], cacheFile: cache, read: read);
    expect(reads, ['a.mp3', 'b.mp3']);

    reads.clear();
    final second = LibraryIndex();
    await indexTracks(second, [a.path, b.path], cacheFile: cache, read: read);
    expect(reads, isEmpty);
    expect(second.infoOf(a.path)!.artist, 'Artist 1');

    b.writeAsStringSync('changed contents');
    File('${a.path}.meta.json').writeAsStringSync('{"artist":"X"}');
    final c = File('${dir.path}/c.mp3')..writeAsStringSync('ccc');
    final third = LibraryIndex();
    await indexTracks(third, [a.path, b.path, c.path], cacheFile: cache, read: read);
    expect(reads..sort(), ['a.mp3', 'b.mp3', 'c.mp3']);

    reads.clear();
    final fourth = LibraryIndex();
    await indexTracks(fourth, [a.path, c.path], cacheFile: cache, read: read);
    expect(reads, isEmpty);
    expect(fourth.length, 2);
  });

  test('a cancelled run neither finishes nor rewrites the cache', () async {
    final a = File('${dir.path}/a.mp3')..writeAsStringSync('aaa');
    final cache = File('${dir.path}/.tags-cache.json');
    await indexTracks(LibraryIndex(), [a.path],
        cacheFile: cache, read: (_) async => (artist: 'A', album: 'B'), cancelled: () => true);
    expect(cache.existsSync(), isFalse);
  });
}
