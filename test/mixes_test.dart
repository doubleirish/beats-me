import 'dart:io';

import 'package:beats_me/services/app_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('beats_me_mixes_');
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  test('listMixes finds each installed mixtape by its .m3u8, newest first', () async {
    final root = Directory(p.join(tmp.path, 'Mixtapes'));
    final gym = Directory(p.join(root.path, 'push', 'Gym Mix [abc]', 'songs'))
      ..createSync(recursive: true);
    File(p.join(gym.path, 'a.mp3')).writeAsBytesSync([1]);
    File(p.join(gym.path, 'b.mp3')).writeAsBytesSync([2]);
    File(p.join(gym.path.replaceAll('songs', ''), 'Gym Mix.m3u8'))
        .writeAsStringSync('#EXTM3U\nsongs/a.mp3\nsongs/b.mp3\n');
    await Future<void>.delayed(const Duration(milliseconds: 30));

    final hiit = Directory(p.join(root.path, 'zip', 'Hiit [def]', 'songs'))
      ..createSync(recursive: true);
    File(p.join(hiit.path, 'c.mp3')).writeAsBytesSync([3]);
    File(p.join(hiit.path.replaceAll('songs', ''), 'Hiit.m3u8'))
        .writeAsStringSync('#EXTM3U\nsongs/c.mp3\n');

    final s = AppState();
    s.folder = tmp.path;
    final mixes = await s.listMixes();

    expect(mixes.map((m) => m.name), ['Hiit', 'Gym Mix']);
    expect(mixes.firstWhere((m) => m.name == 'Gym Mix').trackCount, 2);
    expect(mixes.firstWhere((m) => m.name == 'Hiit').trackCount, 1);
  });

  test('listMixes reads the program name and total running time from the playlist', () async {
    final dir = Directory(p.join(tmp.path, 'Mixtapes', 'push', 'Ride [abc]'))
      ..createSync(recursive: true);
    File(p.join(dir.path, 'Ride.m3u8')).writeAsStringSync(
        '#EXTM3U\n#EXT-X-PROGRAM:Classic Program\n#EXTINF:200,A - x\na.mp3\n#EXTINF:100.4,B - y\nb.mp3\n');
    File(p.join(dir.path, 'Old.m3u8')).writeAsStringSync('#EXTM3U\n#EXTINF:-1,z\nc.mp3\n');

    final s = AppState();
    s.folder = tmp.path;
    final mixes = await s.listMixes();
    final ride = mixes.firstWhere((m) => m.name == 'Ride');
    expect(ride.programName, 'Classic Program');
    expect(ride.totalSeconds, closeTo(300.4, 0.01));
    expect(ride.details, 'Classic Program · 2 songs · 5 min');
    final old = mixes.firstWhere((m) => m.name == 'Old');
    expect(old.programName, isNull);
    expect(old.totalSeconds, isNull);
  });

  test('deleteMix removes an installed mixtape folder and its ledger entry', () async {
    final root = Directory(p.join(tmp.path, 'Mixtapes'));
    final dir = Directory(p.join(root.path, 'push', 'Gym [abc]'))..createSync(recursive: true);
    final song = File(p.join(dir.path, 'a.mp3'))..writeAsBytesSync([1]);
    File(p.join(dir.path, 'Gym.m3u8')).writeAsStringSync('#EXTM3U\na.mp3\n');
    File(p.join(root.path, '.imported.json'))
        .writeAsStringSync('{"push:abc":{"dir":"push/Gym [abc]"},"push:zzz":{"dir":"push/Other"}}');

    final s = AppState();
    s.folder = tmp.path;
    s.mixList = [song.path];
    final m = (await s.listMixes()).single;
    await s.deleteMix(m);

    expect(dir.existsSync(), isFalse);
    expect(s.mixList, isEmpty);
    final led = File(p.join(root.path, '.imported.json')).readAsStringSync();
    expect(led.contains('abc'), isFalse);
    expect(led.contains('zzz'), isTrue);
  });

  test('listMixes does not double-count when the open folder nests the mixtape root', () async {
    final root = Directory(p.join(tmp.path, 'Mixtapes', 'push', 'Gym [abc]', 'songs'))
      ..createSync(recursive: true);
    File(p.join(root.path, 'a.mp3')).writeAsBytesSync([1]);
    File(p.join(root.path.replaceAll('songs', ''), 'Gym.m3u8'))
        .writeAsStringSync('#EXTM3U\nsongs/a.mp3\n');

    final s = AppState();
    s.folder = tmp.path;
    final mixes = await s.listMixes();
    expect(mixes, hasLength(1));
  });
}
