import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:beats_me/services/app_state.dart';
import 'package:beats_me/services/journal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_core/services/mixtape/importer.dart';
import 'package:shared_core/services/mixtape/journal.dart';
import 'package:shared_core/services/mixtape/manifest.dart';
import 'package:shared_core/services/mixtape/package_writer.dart';
import 'package:shared_core/services/mixtape/transports.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late List<MixtapeSource> sources;
  late MixtapeImporter importer;
  late PlayJournal journal;
  late AppState s;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('beats_me_ratings_');
    final rnd = Random(5);
    final lib = Directory(p.join(tmp.path, 'pc'))..createSync();
    sources = [
      for (var i = 0; i < 3; i++)
        MixtapeSource(
          path: (File(p.join(lib.path, 'src$i.mp3'))
                ..writeAsBytesSync(Uint8List.fromList(List.generate(2000 + i, (_) => rnd.nextInt(256)))))
              .path,
          title: 'Song $i',
          duration: 60.0,
        ),
    ];
    importer = MixtapeImporter(Directory(p.join(tmp.path, 'Mixtapes')));
    journal = PlayJournal(File(p.join(tmp.path, 'journal.jsonl')));
    AppJournal.useJournal(journal, device: 'phone1');
    s = AppState()..folder = tmp.path;
  });

  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Future<List<String>> install(String id, List<MixtapeSource> srcs) async {
    final root = Directory(p.join(tmp.path, 'out', id));
    await FolderTransport.export(PackageWriter(), id: id, name: id, sources: srcs, root: root);
    final r = await importer.importPackage(labelDir(root, Transport.folder, id));
    expect(r.errors, isEmpty);
    return r.paths;
  }

  Future<Map<String, dynamic>> meta(String path) async => (await SongMeta.load(path))!;

  test('rating one copy updates every installed copy with the same sha256', () async {
    final a = await install('mixA', [sources[0], sources[1]]);
    final b = await install('mixB', [sources[1], sources[2]]);
    final shared = a[1], other = b[1];
    expect(b[0], isNot(shared));

    await s.setRatingFor(shared, rating: 4);
    await s.setRatingFor(b[0], fav: true);

    for (final c in [shared, b[0]]) {
      expect((await meta(c))['rating'], 4);
      expect((await meta(c))['fav'], true);
      expect(s.ratingOf(c), 4);
      expect(s.favOf(c), isTrue);
    }
    expect((await meta(other))['rating'], 0);
    expect((await meta(a[0]))['fav'], false);
    expect((await meta(shared))['title'], 'Song 1', reason: 'other meta keys are kept');

    final rates = (await journal.since(0)).where((e) => e.isRate).toList();
    expect(rates.map((e) => (e.path, e.rating, e.fav)),
        [(shared, 4, false), (b[0], 4, true)]);
    expect(rates.first.device, 'phone1');
    expect(rates.first.sha256, isNotNull);
  });

  test('falls back to the original PC path when the sha256 is unknown', () async {
    final a = await install('mixA', [sources[0]]);
    final b = await install('mixB', [sources[0], sources[1]]);
    final m = await meta(a[0])..remove('sha256');
    await SongMeta.sidecar(a[0]).writeAsString(jsonEncode(m));

    await s.setRatingFor(a[0], rating: 2);

    expect((await meta(b[0]))['rating'], 2);
    expect((await meta(b[1]))['rating'], 0);
  });

  test('a plain library song gets a sidecar; cache loads lazily from disk', () async {
    final song = File(p.join(tmp.path, 'loose.mp3'))..writeAsBytesSync([1, 2, 3]);
    await s.setRatingFor(song.path, rating: 3);
    expect((await meta(song.path))['rating'], 3);

    final fresh = AppState()..folder = tmp.path;
    expect(fresh.ratingOf(song.path), 0, reason: 'first sync call only starts the load');
    await fresh.loadRating(song.path);
    expect(fresh.ratingOf(song.path), 3);

    await s.setRatingFor(song.path, rating: 0);
    expect(s.ratingOf(song.path), 0);
    expect((await meta(song.path))['rating'], 0);
  });
}
