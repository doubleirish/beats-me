import 'dart:io';

import 'package:beats_me/services/album_catalog_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_core/shared_core.dart';

AlbumCatalog catalog(String title) => AlbumCatalog(
  generatedAt: DateTime.utc(2026, 11, 7, 12),
  albums: [
    CatalogAlbum(artist: 'Artist', album: title, have: 4, total: 4, key: title),
  ],
);

void main() {
  late Directory dir;
  late AlbumCatalogStore store;
  setUp(() {
    dir = Directory.current.createTempSync('.catalog-store-test-');
    store = AlbumCatalogStore(directory: () async => dir);
  });
  tearDown(() {
    store.dispose();
    dir.deleteSync(recursive: true);
  });

  test('saves serially and reloads the last durable snapshot', () async {
    var notifications = 0;
    store.addListener(() => notifications++);
    await Future.wait([
      store.save(catalog('First')),
      store.save(catalog('Second')),
    ]);
    expect(store.snapshot!.albums.single.album, 'Second');
    expect(store.snapshotTime, DateTime.utc(2026, 11, 7, 12));
    expect(notifications, greaterThan(0));
    final restored = AlbumCatalogStore(directory: () async => dir);
    addTearDown(restored.dispose);
    await restored.load();
    expect(restored.snapshot!.albums.single.album, 'Second');
    expect(restored.error, isNull);
    expect(
      File(p.join(dir.path, '$albumCatalogName.tmp')).existsSync(),
      isFalse,
    );
  });

  test(
    'malformed inbox keeps the saved snapshot and is not consumed',
    () async {
      await store.save(catalog('Good'));
      final saved = File(p.join(dir.path, albumCatalogName)).readAsStringSync();
      final inbox = File(p.join(dir.path, 'incoming.json'))
        ..writeAsStringSync('{"albums":');
      await expectLater(store.importInbox(inbox), throwsFormatException);
      expect(store.snapshot!.albums.single.album, 'Good');
      expect(store.error, contains('sync failed'));
      expect(await store.hasInbox(inbox), isTrue);
      expect(
        File(p.join(dir.path, albumCatalogName)).readAsStringSync(),
        saved,
      );
      inbox.writeAsStringSync(catalog('Replacement').encode());
      await store.importInbox(inbox);
      expect(inbox.existsSync(), isFalse);
      expect(store.snapshot!.albums.single.album, 'Replacement');
      expect(store.error, isNull);
    },
  );

  test(
    'failed persistent write retains snapshot and inbox; later sync recovers',
    () async {
      await store.save(catalog('Good'));
      final saved = File(p.join(dir.path, albumCatalogName)).readAsStringSync();
      final blocker = Directory(p.join(dir.path, '$albumCatalogName.tmp'))
        ..createSync();
      final inbox = File(p.join(dir.path, 'incoming.json'))
        ..writeAsStringSync(catalog('New').encode());
      await expectLater(
        store.importInbox(inbox),
        throwsA(isA<FileSystemException>()),
      );
      expect(store.snapshot!.albums.single.album, 'Good');
      expect(
        File(p.join(dir.path, albumCatalogName)).readAsStringSync(),
        saved,
      );
      expect(await store.hasInbox(inbox), isTrue);
      expect(store.error, isNotNull);
      blocker.deleteSync();
      await store.importInbox(inbox);
      expect(store.snapshot!.albums.single.album, 'New');
      expect(store.error, isNull);
    },
  );

  test(
    'corrupt saved data surfaces error and a valid sync replaces it',
    () async {
      final file = File(p.join(dir.path, albumCatalogName))
        ..writeAsStringSync('{}');
      await store.load();
      expect(store.snapshot, isNull);
      expect(store.error, isNotNull);
      expect(file.readAsStringSync(), '{}');
      await store.save(catalog('Recovered'));
      expect(store.snapshot!.albums.single.album, 'Recovered');
      expect(store.error, isNull);
    },
  );

  test('oversized inbox is rejected without replacing the snapshot', () async {
    await store.save(catalog('Good'));
    final inbox = File(p.join(dir.path, 'incoming.json'))
      ..writeAsBytesSync(List.filled(maxAlbumCatalogBytes + 1, 32));
    await expectLater(store.importInbox(inbox), throwsFormatException);
    expect(store.snapshot!.albums.single.album, 'Good');
    expect(await store.hasInbox(inbox), isTrue);
  });

  test('new atomic delivery during persistence is not deleted', () async {
    await store.save(catalog('Initial'));
    final inbox = File(p.join(dir.path, 'incoming.json'))
      ..writeAsStringSync(catalog('Claimed').encode());
    var delivered = false;
    store.addListener(() {
      if (!delivered && store.snapshot?.albums.single.album == 'Claimed') {
        delivered = true;
        final next = File('${inbox.path}.sending')
          ..writeAsStringSync(catalog('Newer').encode());
        next.renameSync(inbox.path);
      }
    });
    await store.importInbox(inbox);
    expect(delivered, isTrue);
    expect(store.snapshot!.albums.single.album, 'Claimed');
    expect(inbox.existsSync(), isTrue);
    expect(
      AlbumCatalog.decode(inbox.readAsStringSync()).albums.single.album,
      'Newer',
    );
    await store.importInbox(inbox);
    expect(store.snapshot!.albums.single.album, 'Newer');
    expect(await store.hasInbox(inbox), isFalse);
  });
}
