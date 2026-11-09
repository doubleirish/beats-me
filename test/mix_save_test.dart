import 'dart:io';

import 'package:beats_me/services/app_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('beats_me_save_');
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  File song(String rel) =>
      File(p.normalize(p.join(tmp.path, rel)))..createSync(recursive: true)..writeAsBytesSync([1, 2, 3]);

  AppState newState() => AppState()..folder = tmp.path;

  group('importMix', () {
    test('reads relative and absolute entries, ignoring BOM, CRLF and comments', () async {
      final a = song('Songs/a.mp3'), b = song('Songs/b.mp3');
      final list = File(p.join(tmp.path, 'Songs', 'mix.m3u8'))
        ..writeAsStringSync('\uFEFF#EXTM3U\r\n#EXTINF:60,A\r\na.mp3\r\n\r\n${b.path}\r\n');
      final s = newState()..tracks = [a.path, b.path];
      final skipped = await s.importMix(list.path);
      expect(skipped, 0);
      expect(s.mixList, [a.path, b.path]);
      expect(s.mixSource, list.path);
      expect(s.currentMix!.name, 'mix');
      expect(s.currentMix!.trackCount, 2);
      expect(s.currentMix!.totalSeconds, 60);
    });

    test('matches library songs ignoring case, and counts missing files as skipped', () async {
      final a = song('Songs/Alpha.mp3');
      final list = File(p.join(tmp.path, 'mix.m3u8'))
        ..writeAsStringSync('${a.path.toLowerCase()}\nSongs/gone.mp3\nSongs/alpha.mp3\n');
      final s = newState()..tracks = [a.path];
      final skipped = await s.importMix(list.path);
      expect(skipped, 1);
      expect(s.mixList, [a.path, a.path]);
    });
  });

  group('saveMix', () {
    test('save as new writes <root>/Saved/<name>/<name>.m3u8 that imports back in order', () async {
      final a = song('Songs/a.mp3'), b = song('Songs/b.mp3');
      final s = newState()
        ..tracks = [a.path, b.path]
        ..mixList = [b.path, a.path];
      final m = await s.saveMix('Warm: up?');
      final expected = p.join(tmp.path, 'Mixtapes', 'Saved', 'Warm up', 'Warm up.m3u8');
      expect(m.file, expected);
      expect(s.mixSource, expected);
      expect(s.currentMix!.trackCount, 2);

      s.mixList = [];
      await s.importMix(expected);
      expect(s.mixList, [b.path, a.path]);
    });

    test('overwrite keeps the program header and writes songs in the folder relatively', () async {
      final dir = Directory(p.join(tmp.path, 'Mixtapes', 'push', 'Ride [abc]'))..createSync(recursive: true);
      final a = File(p.join(dir.path, 'a.mp3'))..writeAsBytesSync([1]);
      final b = File(p.join(dir.path, 'b.mp3'))..writeAsBytesSync([2]);
      final list = File(p.join(dir.path, 'Ride.m3u8'))
        ..writeAsStringSync('#EXTM3U\n#EXT-X-PROGRAM:Classic Program\n#EXTINF:30,a\na.mp3\n#EXTINF:30,b\nb.mp3\n');
      final s = newState()..tracks = [a.path, b.path];
      await s.importMix(list.path);

      s.toggleMix(a.path); // edit: name is kept as the source
      expect(s.currentMix, isNull);
      expect(s.mixTitle, 'Ride (edited)');

      final m = await s.saveMix('ignored', overwrite: true);
      expect(m.file, list.path);
      expect(m.programName, 'Classic Program');
      expect(m.trackCount, 1);
      final text = list.readAsStringSync();
      expect(text, contains('\nb.mp3\n'));
      expect(text, isNot(contains(dir.path)));
      expect(await s.sourceIsImported(), isFalse); // no ledger in this test
    });

    test('deleting a saved mix keeps the songs it lists', () async {
      final a = song('Songs/a.mp3');
      final s = newState()
        ..tracks = [a.path]
        ..mixList = [a.path];
      final m = await s.saveMix('Mine');
      await s.deleteMix(m);
      expect(File(m.file).existsSync(), isFalse);
      expect(a.existsSync(), isTrue);
      expect(s.mixSource, isNull);
    });

    test('an empty mix list is refused', () async {
      expect(newState().saveMix('x'), throwsStateError);
    });
  });
}
