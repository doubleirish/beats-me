import 'dart:convert';
import 'dart:io';

import 'package:beats_me/services/app_state.dart';
import 'package:beats_me/services/mixes.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_core/services/mixtape/journal.dart';

void main() {
  late Directory tmp;
  late Directory root;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('beats_me_mixlist_');
    root = Directory(p.join(tmp.path, 'Mixtapes'));
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  /// An installed mix `push/<name> [<id>]` with [songs] 10-byte songs.
  File install(String name, String id, int songs) {
    final dir = Directory(p.join(root.path, 'push', '$name [$id]'))..createSync(recursive: true);
    for (var i = 0; i < songs; i++) {
      File(p.join(dir.path, 's$i.mp3')).writeAsBytesSync(List.filled(10, i));
    }
    return File(p.join(dir.path, '$name.m3u8'))
      ..writeAsStringSync('#EXTM3U\n${[for (var i = 0; i < songs; i++) 's$i.mp3'].join('\n')}\n');
  }

  AppState newState() => AppState()
    ..folder = tmp.path
    ..journalEntries = () async => [];

  test('unchanged playlists are served from the cache; changed ones are re-read', () async {
    final gym = install('Gym', 'abc', 2);
    install('Ride', 'def', 1);

    final s = newState();
    expect(await s.listMixes(), hasLength(2));
    expect(s.summarizedCount, 2);
    expect(File(p.join(root.path, '.mixes-cache.json')).existsSync(), isTrue);

    // A fresh app instance reuses the cache file.
    final s2 = newState();
    final again = await s2.listMixes();
    expect(s2.summarizedCount, 0);
    expect(again.firstWhere((m) => m.name == 'Gym').trackCount, 2);

    gym.writeAsStringSync('#EXTM3U\ns0.mp3\n');
    final changed = await s2.listMixes();
    expect(s2.summarizedCount, 1);
    expect(changed.firstWhere((m) => m.name == 'Gym').trackCount, 1);

    await s2.listMixes(force: true);
    expect(s2.summarizedCount, 3);

    await s2.mixesChanged();
    await s2.listMixes();
    expect(s2.summarizedCount, 5);
  });

  test('size on disk covers the whole mix folder', () async {
    install('Gym', 'abc', 3);
    final m = (await newState().listMixes()).single;
    final playlist = File(m.file).lengthSync();
    expect(m.sizeBytes, 30 + playlist);
  });

  test('last played is the newest journal play of the mix (id from the ledger)', () async {
    install('Gym', 'abc', 1);
    install('Ride', 'def', 1);
    File(p.join(root.path, '.imported.json')).writeAsStringSync(jsonEncode({
      'push:abc': {'dir': 'push/Gym [abc]'},
      'push:def': {'dir': 'push/Ride [def]'},
    }));
    final s = newState()
      ..journalEntries = () async => [
            const JournalEntry(type: 'play', at: 1000, device: 'd', mixId: 'abc'),
            const JournalEntry(type: 'play', at: 5000, device: 'd', mixId: 'abc'),
            const JournalEntry(type: 'rate', at: 9000, device: 'd', mixId: 'abc'),
            const JournalEntry(type: 'play', at: 9000, device: 'd'),
          ];
    final mixes = await s.listMixes();
    final gym = mixes.firstWhere((m) => m.name == 'Gym');
    expect(gym.mixId, 'abc');
    expect(gym.lastPlayed, DateTime.fromMillisecondsSinceEpoch(5000));
    expect(mixes.firstWhere((m) => m.name == 'Ride').lastPlayed, isNull);
  });

  test('search matches name and program; sort orders by each key', () {
    MixSummary mix(String name, int mod, {String? program, int? size, int? played}) =>
        MixSummary(name, '$name.m3u8', 1,
            modified: DateTime.fromMillisecondsSinceEpoch(mod),
            programName: program,
            sizeBytes: size,
            lastPlayed: played == null ? null : DateTime.fromMillisecondsSinceEpoch(played));
    final a = mix('alpha', 3, program: 'Classic Program', size: 10);
    final b = mix('Bravo', 1, size: 30, played: 50);
    final c = mix('charlie ride', 2, played: 90);
    final all = [a, b, c];

    expect(filterMixes(all, 'classic'), [a]);
    expect(filterMixes(all, 'RIDE char'), [c]);
    expect(filterMixes(all, '  '), all);

    expect(sortMixes(all, MixSort.imported), [a, c, b]);
    expect(sortMixes(all, MixSort.name), [a, b, c]);
    expect(sortMixes(all, MixSort.lastPlayed), [c, b, a]);
    expect(sortMixes(all, MixSort.size), [b, a, c]);
    expect(MixSort.parse('size'), MixSort.size);
    expect(MixSort.parse(null), MixSort.imported);
  });

  test('deleteMix rewrites the USB inventory without the deleted mix', () async {
    install('Gym', 'abc', 1);
    install('Ride', 'def', 1);
    File(p.join(root.path, '.imported.json')).writeAsStringSync(jsonEncode({
      'push:abc': {'dir': 'push/Gym [abc]'},
      'push:def': {'dir': 'push/Ride [def]'},
    }));
    final s = newState();
    final inv = File(p.join(tmp.path, 'inbox', '.inventory.json'));
    s.mixtapes.inventoryFile = inv;
    final gym = (await s.listMixes()).firstWhere((m) => m.name == 'Gym');
    final before = s.mixesVersion;

    await s.deleteMix(gym);

    final led = jsonDecode(inv.readAsStringSync()) as Map;
    expect(led.keys, ['push:def']);
    expect(s.mixesVersion, greaterThan(before));
    expect((await s.listMixes()).map((m) => m.name), ['Ride']);
  });

  test('checkMixAudio flags damaged songs and the Mixes list counts them', () async {
    final playlist = install('Gym', 'abc', 2);
    // s0 becomes a clean MP3 (frames of a 128k/44.1k stream); s1 stays junk.
    final frame = List<int>.filled(417, 0)..setAll(0, [0xFF, 0xFB, 0x90, 0x00]);
    File(p.join(playlist.parent.path, 's0.mp3'))
        .writeAsBytesSync([for (var i = 0; i < 40; i++) ...frame]);
    final s = newState();
    final m = (await s.listMixes()).single;
    expect(m.damaged, 0);

    expect(await s.checkMixAudio(m), 1);
    final meta = jsonDecode(File(p.join(playlist.parent.path, 's1.mp3.meta.json')).readAsStringSync());
    expect(meta['damaged'], isA<String>());
    expect(File(p.join(playlist.parent.path, 's0.mp3.meta.json')).existsSync(), isFalse);
    expect((await s.listMixes()).single.damaged, 1);
    // Survives the summary cache.
    expect((await newState().listMixes()).single.damaged, 1);
  });}
