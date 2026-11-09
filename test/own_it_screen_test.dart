import 'dart:io';

import 'package:beats_me/screens/own_it_screen.dart';
import 'package:beats_me/services/album_catalog_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_core/shared_core.dart';

void main() {
  late Directory dir;
  late AlbumCatalogStore store;
  setUp(() {
    dir = Directory.current.createTempSync('.own-it-test-');
    store = AlbumCatalogStore(directory: () async => dir);
  });
  tearDown(() {
    store.dispose();
    dir.deleteSync(recursive: true);
  });

  Future<void> show(WidgetTester tester, {List<CatalogAlbum>? albums}) async {
    // Resolve disk I/O outside the widget tester's fake async zone.
    await tester.runAsync(() async {
      if (albums == null) {
        await store.load();
      } else {
        await store.save(
          AlbumCatalog(
            generatedAt: DateTime.utc(2026, 11, 7, 12),
            albums: albums,
          ),
        );
      }
    });
    await tester.pumpWidget(MaterialApp(home: OwnItScreen(store: store)));
    await tester.pumpAndSettle();
  }

  testWidgets('no snapshot prompts sync instead of asserting not owned', (
    tester,
  ) async {
    await show(tester);
    expect(
      find.textContaining('No desktop catalogue synced yet'),
      findsOneWidget,
    );
    expect(find.textContaining('paired Wi-Fi push or USB'), findsOneWidget);
  });

  testWidgets('invalid persistent snapshot is visibly reported', (
    tester,
  ) async {
    File(p.join(dir.path, albumCatalogName)).writeAsStringSync('{}');
    await show(tester);
    expect(find.textContaining('Album catalogue sync failed:'), findsOneWidget);
    expect(
      find.textContaining('No desktop catalogue synced yet'),
      findsOneWidget,
    );
  });

  testWidgets('search combines artist and album tokens and explains no match', (
    tester,
  ) async {
    await show(
      tester,
      albums: [
        CatalogAlbum(
          artist: 'Nina Simone',
          album: 'Pastel Blues',
          have: 9,
          total: 9,
          key: 'one',
        ),
        CatalogAlbum(
          artist: 'Other',
          album: 'Pastel',
          have: 2,
          total: 2,
          key: 'two',
        ),
      ],
    );
    await tester.enterText(find.byType(TextField), 'BLUES nina');
    await tester.pumpAndSettle();
    expect(find.text('Pastel Blues'), findsOneWidget);
    expect(find.text('Pastel'), findsNothing);
    expect(find.textContaining('Owned • 9/9 tracks'), findsOneWidget);
    expect(find.textContaining('Snapshot time:'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'unknown record');
    await tester.pumpAndSettle();
    expect(
      find.textContaining('No match in the synced catalogue'),
      findsOneWidget,
    );
    expect(
      find.textContaining('does not prove you do not own it'),
      findsOneWidget,
    );
  });

  testWidgets(
    'incomplete flags and unknown totals are not presented as complete',
    (tester) async {
      await show(
        tester,
        albums: [
          CatalogAlbum(
            artist: 'A',
            album: 'Missing tracks',
            have: 2,
            total: 5,
            incomplete: true,
            key: 'tracks',
          ),
          CatalogAlbum(
            artist: 'B',
            album: 'Missing disc',
            have: 5,
            total: 5,
            incomplete: true,
            key: 'disc',
          ),
          CatalogAlbum(
            artist: 'C',
            album: 'Unknown total',
            have: 3,
            key: 'unknown',
          ),
        ],
      );
      expect(
        find.textContaining('Incomplete (missing album)'),
        findsNWidgets(2),
      );
      expect(
        find.textContaining('In library (total unknown) • 3/? tracks'),
        findsOneWidget,
      );
      expect(find.textContaining('Owned'), findsNothing);
    },
  );

  testWidgets('empty snapshot is distinguished from never synced', (
    tester,
  ) async {
    await show(tester, albums: []);
    expect(
      find.textContaining('The synced catalogue is empty'),
      findsOneWidget,
    );
    expect(
      find.textContaining('No desktop catalogue synced yet'),
      findsNothing,
    );
  });
}
