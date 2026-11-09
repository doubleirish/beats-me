import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_core/shared_core.dart';

/// The desktop's metadata snapshot, separate from the phone's audio library.
class AlbumCatalogStore extends ChangeNotifier {
  AlbumCatalogStore({Future<Directory> Function()? directory})
    : _directory = directory ?? getApplicationDocumentsDirectory;

  final Future<Directory> Function() _directory;
  Future<void> _tail = Future.value();
  File? _file;
  bool _initialized = false;
  bool _disposed = false;
  AlbumCatalog? _snapshot;
  String? _error;

  AlbumCatalog? get snapshot => _snapshot;
  DateTime? get snapshotTime => _snapshot?.generatedAt;
  String? get error => _error;
  bool get initialized => _initialized;

  Future<File> _storage() async {
    if (_file != null) return _file!;
    final dir = await _directory();
    await dir.create(recursive: true);
    return _file = File(p.join(dir.path, albumCatalogName));
  }

  Future<AlbumCatalog> _read(File file) async {
    if (await file.length() > maxAlbumCatalogBytes) {
      throw const FormatException('Album catalogue is too large');
    }
    // Bound the read itself, including files replaced while being read.
    final bytes = <int>[];
    await for (final chunk in file.openRead()) {
      if (bytes.length + chunk.length > maxAlbumCatalogBytes) {
        throw const FormatException('Album catalogue is too large');
      }
      bytes.addAll(chunk);
    }
    return AlbumCatalog.decode(utf8.decode(bytes));
  }

  Future<void> _load() async {
    if (_initialized) return;
    try {
      final file = await _storage();
      if (await file.exists()) _snapshot = await _read(file);
      _error = null;
    } finally {
      _initialized = true;
      _changed();
    }
  }

  Future<void> _enqueue(Future<void> Function() operation) {
    final result = _tail.then((_) async {
      try {
        await operation();
      } catch (e) {
        _error = 'Album catalogue sync failed: $e';
        _changed();
        rethrow;
      }
    });
    // A failed operation must not prevent the next sync.
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  /// Loads once on first use. Read errors remain visible without crashing UI.
  Future<void> load() async {
    try {
      await _enqueue(_load);
    } catch (_) {}
  }

  Future<void> _persist(AlbumCatalog catalog) async {
    final text = catalog.encode();
    if (utf8.encode(text).length > maxAlbumCatalogBytes) {
      throw const FormatException('Album catalogue is too large');
    }
    final validated = AlbumCatalog.decode(text);
    final file = await _storage();
    try {
      await writeStringAtomic(file, text);
    } catch (_) {
      try {
        final staged = File('${file.path}.tmp');
        if (await staged.exists()) await staged.delete();
      } catch (_) {}
      rethrow;
    }
    _snapshot = validated;
    _error = null;
    _changed();
  }

  Future<void> save(AlbumCatalog catalog) => _enqueue(() async {
    try {
      await _load();
    } catch (_) {
      // A valid incoming snapshot can replace a corrupt saved file.
    }
    await _persist(catalog);
  });

  Future<List<File>> _pending(File file) async {
    if (!await file.parent.exists()) return [];
    final prefix = '${p.basename(file.path)}.receiving-';
    final files = await file.parent
        .list()
        .where(
          (entry) => entry is File && p.basename(entry.path).startsWith(prefix),
        )
        .cast<File>()
        .toList();
    files.sort((a, b) => a.path.compareTo(b.path));
    return files;
  }

  Future<bool> hasInbox(File file) async =>
      await file.exists() || (await _pending(file)).isNotEmpty;

  /// Claims each sender snapshot before reading it, so a later atomic send
  /// cannot be deleted with the snapshot currently being persisted.
  Future<void> importInbox(File file) => _enqueue(() async {
    try {
      await _load();
    } catch (_) {}
    final pending = await _pending(file);
    if (await file.exists()) {
      // A new send supersedes failed older claims only after it is saved.
      final older = pending;
      final claimed = await file.rename(
        '${file.path}.receiving-${DateTime.now().microsecondsSinceEpoch}-${newMixtapeId()}',
      );
      await _persist(await _read(claimed));
      await claimed.delete();
      for (final old in older) {
        await old.delete();
      }
      return;
    }
    for (final claimed in pending) {
      await _persist(await _read(claimed));
      await claimed.delete();
    }
  });

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
