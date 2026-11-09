import 'dart:io';

import 'package:beats_me/services/album_catalog_store.dart';
import 'package:beats_me/services/app_state.dart';
import 'package:beats_me/services/mixtape_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_core/shared_core.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late MixtapeController controller;
  late HttpOverrides? oldOverrides;
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');

  setUp(() async {
    oldOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    dir = Directory.current.createTempSync('.catalog-receive-test-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, (_) async => dir.path);
    final app = AppState()..folder = dir.path;
    controller = app.mixtapes;
    controller.trusted.add(TrustedPc('pc', 'PC', 'paired-token'));
    await controller.startReceiving();
    expect(controller.receiving, isTrue);
  });
  tearDown(() async {
    await controller.stopReceiving();
    controller.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, null);
    HttpOverrides.global = oldOverrides;
    dir.deleteSync(recursive: true);
  });

  test(
    'paired push persists metadata, rejects session code and malformed updates',
    () async {
      final base = Uri.parse('http://127.0.0.1:${controller.receiver!.port}');
      final sender = PushSender(base, 'paired-token');
      expect((await sender.hello()).catalog, isTrue);
      final catalog = AlbumCatalog(
        generatedAt: DateTime.utc(2026, 11, 7),
        albums: [
          CatalogAlbum(
            artist: 'Artist',
            album: 'Owned album',
            have: 8,
            total: 8,
            key: 'owned',
          ),
        ],
      );
      await sender.sendCatalog(catalog);
      expect(
        controller.albumCatalog.snapshot!.albums.single.album,
        'Owned album',
      );
      expect(controller.log, contains(contains('Synced desktop catalogue')));
      final saved = File(p.join(dir.path, albumCatalogName)).readAsStringSync();
      await expectLater(
        PushSender(base, controller.receiver!.token).sendCatalog(catalog),
        throwsA(isA<TransferException>()),
      );
      final client = HttpClient();
      try {
        final request = await client.putUrl(base.resolve('/push/v1/catalog'));
        request.headers.set('x-token', 'paired-token');
        request.write('{}');
        final response = await request.close();
        await response.drain<void>();
        expect(response.statusCode, greaterThanOrEqualTo(400));
      } finally {
        client.close(force: true);
      }
      expect(
        controller.albumCatalog.snapshot!.albums.single.album,
        'Owned album',
      );
      expect(
        File(p.join(dir.path, albumCatalogName)).readAsStringSync(),
        saved,
      );
      final restored = AlbumCatalogStore(directory: () async => dir);
      addTearDown(restored.dispose);
      await restored.load();
      expect(restored.snapshot!.albums.single.album, 'Owned album');
      expect(
        await Directory(p.join(dir.path, 'Mixtapes')).list().toList(),
        isEmpty,
      );
    },
  );
}
