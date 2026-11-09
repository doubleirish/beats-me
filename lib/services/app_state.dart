import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_core/services/bpm_store.dart';
import 'package:shared_core/services/artist_art.dart';
import 'package:shared_core/services/atomic_file.dart';
import 'package:shared_core/services/audio_check.dart';
import 'package:shared_core/services/enrich_service.dart';
import 'package:shared_core/services/library_service.dart';
import 'package:shared_core/services/m3u.dart';
import 'package:shared_core/services/mixtape/importer.dart';
import 'package:shared_core/services/mixtape/manifest.dart' show mixIconTag;
import 'package:shared_core/services/mixtape/journal.dart' show JournalEntry;
import 'package:shared_core/services/playback_controller.dart';
import 'package:shared_core/services/tags.dart';
import 'package:path/path.dart' as p;

import 'journal.dart';
import 'library_index.dart';
import 'library_query.dart';
import 'mixtape_controller.dart';
import 'play_stats.dart';
import 'tag_cache.dart';
import 'shared_plays.dart';
import 'system_channel.dart';

/// One installed mixtape (an `.m3u8` playlist plus its songs), for the
/// top-level Mixes list.
class MixActivity {
  const MixActivity(this.name, this.icon, this.songs, this.seconds);
  final String name;
  final String? icon;
  final int songs;
  final double seconds;
}

class MixSummary {
  MixSummary(this.name, this.file, this.trackCount,
      {required this.modified,
      this.programName,
      this.totalSeconds,
      this.activities = const [],
      this.mixId,
      this.sizeBytes,
      this.lastPlayed,
      this.damaged = 0,
      this.explicit = 0,
      this.icon,
      this.artPaths = const []});

  /// Encoded MixIconSpec from the playlist, or null to show album art.
  final String? icon;

  /// Up to four song paths whose cover art makes the collage.
  final List<String> artPaths;

  /// Songs flagged as damaged audio (by the PC or `checkMixAudio`).
  final int damaged;

  /// Songs the PC marked explicit.
  final int explicit;

  /// The mixtape's id (from the import ledger or its songs' `.meta.json`).
  final String? mixId;

  /// Bytes on disk: the whole mix folder for installed mixes, else the
  /// playlist plus the songs it lists.
  final int? sizeBytes;

  /// Newest play of one of its songs (journal) or of the mix itself.
  DateTime? lastPlayed;

  Map<String, dynamic> toJson() => {
        'name': name,
        'trackCount': trackCount,
        'modified': modified.millisecondsSinceEpoch,
        'programName': ?programName,
        'totalSeconds': ?totalSeconds,
        'mixId': ?mixId,
        'sizeBytes': ?sizeBytes,
        if (damaged > 0) 'damaged': damaged,
        if (explicit > 0) 'explicit': explicit,
        'icon': ?icon,
        if (artPaths.isNotEmpty) 'artPaths': artPaths,
        'activities': [
          for (final a in activities) {'name': a.name, 'icon': ?a.icon, 'songs': a.songs, 'seconds': a.seconds}
        ],
      };

  factory MixSummary.fromJson(String file, Map<String, dynamic> j) => MixSummary(
        j['name'] as String,
        file,
        (j['trackCount'] as num).toInt(),
        modified: DateTime.fromMillisecondsSinceEpoch((j['modified'] as num).toInt()),
        programName: j['programName'] as String?,
        totalSeconds: (j['totalSeconds'] as num?)?.toDouble(),
        mixId: j['mixId'] as String?,
        sizeBytes: (j['sizeBytes'] as num?)?.toInt(),
        damaged: (j['damaged'] as num?)?.toInt() ?? 0,
        explicit: (j['explicit'] as num?)?.toInt() ?? 0,
        icon: j['icon'] as String?,
        artPaths: [for (final a in (j['artPaths'] as List? ?? const [])) a as String],
        activities: [
          for (final a in (j['activities'] as List? ?? const []).cast<Map>())
            MixActivity(a['name'] as String, a['icon'] as String?, (a['songs'] as num).toInt(),
                (a['seconds'] as num).toDouble()),
        ],
      );

  /// Distinct activities in song order, with how many songs/seconds each has.
  final List<MixActivity> activities;
  final String name;
  final String file;
  final int trackCount;
  final DateTime modified;

  /// Program/class this mix was built from (e.g. "Classic Program"), null
  /// when it wasn't built from a program or the mix predates this field.
  final String? programName;

  /// Sum of each track's duration, null when none of them carry one.
  final double? totalSeconds;

  /// "45 min" or "1 h 05 min"; null when no length is known.
  String? get timeLabel {
    final t = totalSeconds;
    if (t == null) return null;
    final mins = (t / 60).round();
    return mins >= 60 ? '${mins ~/ 60} h ${(mins % 60).toString().padLeft(2, '0')} min' : '$mins min';
  }

  /// "Classic Program · 12 songs · 45 min".
  String get details => [
        ?programName,
        '$trackCount song${trackCount == 1 ? '' : 's'}',
        ?timeLabel,
      ].join(' · ');
}

class AppState extends PlaybackController {
  AppState() : super(appId: 'beats_me');

  late final MixtapeController mixtapes = MixtapeController(this);
  String? folder;
  List<String> tracks = [];
  List<String> mixList = [];

  /// Name/program/running time of the mix last loaded from a playlist; null
  /// once the list is edited by hand.
  MixSummary? currentMix;
  final LibraryIndex library = LibraryIndex();
  int indexedCount = 0;
  int _indexRun = 0;
  final LibraryQuery query = LibraryQuery();
  final Map<String, File?> artistImages = {};
  final Set<String> _artistLoading = {};
  ArtistArt? _artistArt;

  @override
  List<String> get libraryPaths => tracks;

  @override
  List<String> get mixPaths => mixList;

  @override
  void onPlayFinished(String path, double listened, bool completed) {
    unawaited(logPlay(path, listened, completed));
    unawaited(logSharedPlay(path, listened, completed));
    unawaited(recordPlayStat(path, listened, completed));
  }

  @override
  bool get supportsKeepScreenOn => Platform.isAndroid;

  @override
  void applyKeepScreenOn(bool on) => unawaited(SystemChannel.keepScreenOn(on));

  // ---- ratings (stored in each song's `.meta.json`) ----

  final Map<String, ({int rating, bool fav})> _ratings = {};
  final Set<String> _ratingLoads = {};

  @override
  bool get supportsRating => true;

  @override
  int ratingOf(String path) => _ratingEntry(path)?.rating ?? 0;

  @override
  bool favOf(String path) => _ratingEntry(path)?.fav ?? false;

  /// Cached rating of [path]; starts a background `.meta.json` read on a miss.
  ({int rating, bool fav})? _ratingEntry(String path) {
    final r = _ratings[path];
    if (r == null && _ratingLoads.add(path)) unawaited(loadRating(path));
    return r;
  }

  /// Reads [path]'s rating from its `.meta.json` into the cache.
  Future<({int rating, bool fav})> loadRating(String path) async {
    final meta = await SongMeta.load(path);
    final r = (
      rating: ((meta?['rating'] as num?)?.toInt() ?? 0).clamp(0, 5),
      fav: meta?['fav'] == true,
    );
    if (_ratings[path] == null) {
      _ratings[path] = r;
      if (r.rating > 0 || r.fav) notifyListeners();
    }
    return _ratings[path]!;
  }

  /// Installed copies of the song at [path]: every mixtape file with the same
  /// sha256 or the same original PC path, always including [path] itself.
  Future<List<String>> copiesOf(String path) async {
    final meta = await SongMeta.load(path);
    final sha = meta?['sha256'] as String?;
    final orig = meta?['origPath'] as String?;
    final out = <String>{path};
    if (sha == null && orig == null) return out.toList();
    try {
      for (final t in await MixtapeImporter(await mixtapeRoot()).installedTracks()) {
        if (out.contains(t.file.path) || !await t.file.exists()) continue;
        if (sha != null && t.sha256 == sha) {
          out.add(t.file.path);
        } else if (orig != null && (await SongMeta.load(t.file.path))?['origPath'] == orig) {
          out.add(t.file.path);
        }
      }
    } catch (_) {}
    return out.toList();
  }

  @override
  Future<void> setRatingFor(String path, {int? rating, bool? fav}) async {
    final old = _ratings[path] ?? await loadRating(path);
    final r = (rating: (rating ?? old.rating).clamp(0, 5), fav: fav ?? old.fav);
    for (final c in await copiesOf(path)) {
      _ratings[c] = r;
      try {
        final meta = await SongMeta.load(c) ?? <String, dynamic>{};
        meta['rating'] = r.rating;
        meta['fav'] = r.fav;
        await SongMeta.sidecar(c).writeAsString(jsonEncode(meta));
      } catch (_) {}
    }
    notifyListeners();
    await logRating(path, r.rating, r.fav);
  }

  /// Tracks passing the library search, filters and sort. Recomputed once per
  /// notification, since the screen reads it several times per build.
  List<String> get shown => _shown ??= queryTracks(tracks, query, _factsOf);
  List<String>? _shown;

  @override
  void notifyListeners() {
    _shown = null;
    super.notifyListeners();
  }

  TrackFacts _factsOf(String path) {
    final i = library.infoOf(path);
    final r = _ratings[path];
    return TrackFacts(
      name: relativeName(path, folder),
      artist: i?.artist,
      album: i?.album,
      bpm: mapOf(path)?.medianBpm,
      rating: r?.rating ?? 0,
      fav: r?.fav ?? false,
      added: library.addedOf(path),
    );
  }

  bool get indexing => folder != null && indexedCount < tracks.length;

  /// Loads ratings of every library song in the background so rating
  /// filters and sorting cover the whole list, not just what was shown.
  Future<void> preloadRatings() async {
    final todo = [for (final t in tracks) if (_ratings[t] == null) t];
    for (var i = 0; i < todo.length; i++) {
      if (_ratings[todo[i]] == null) {
        _ratingLoads.add(todo[i]);
        await loadRating(todo[i]);
      }
      if (i % 100 == 99) {
        notifyListeners();
        await Future<void>.delayed(Duration.zero);
      }
    }
    notifyListeners();
  }

  /// Applies [change] to the query, saves the sort order, and loads ratings
  /// when the query needs them.
  void updateQuery(void Function(LibraryQuery q) change) {
    change(query);
    prefs?.setString('library_sort', query.sort.name);
    notifyListeners();
    if (query.needsRatings) unawaited(preloadRatings());
  }

  /// Sets the artist/album filters from the Artists/Albums screens.
  void setFilters({String? artist, String? album, bool exact = false}) =>
      updateQuery((q) {
        q.artist = artist ?? q.artist;
        q.album = album ?? q.album;
        q.exact = exact;
      });

  void clearFilters() => updateQuery((q) => q.clearFilters());

  /// Reads tags of every track in the background (cancelled when a new folder opens).
  Future<void> _buildIndex() async {
    final run = ++_indexRun;
    library.clear();
    indexedCount = 0;
    final list = List<String>.of(tracks);
    await indexTracks(
      library,
      list,
      cacheFile: folder == null ? null : File(p.join(folder!, '.tags-cache.json')),
      cancelled: () => run != _indexRun,
      read: (path) async {
        final t = await readTags(path);
        final meta = await SongMeta.load(path);
        return (
          artist: meta?['artist'] as String? ?? t.artist,
          album: meta?['album'] as String? ?? t.album,
        );
      },
      onProgress: (done) async {
        indexedCount = done;
        notifyListeners();
        await Future<void>.delayed(Duration.zero);
      },
    );
  }

  /// Loads an artist photo (cached on disk, Deezer lookup) in the background.
  Future<void> ensureArtistImage(String artist) async {
    final k = ArtistArt.keyFor(artist);
    if (artistImages.containsKey(k) || !_artistLoading.add(k)) return;
    try {
      _artistArt ??= ArtistArt(Directory(
          '${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}artist_art'));
      artistImages[k] = await _artistArt!.fetch(artist);
    } catch (_) {
      artistImages[k] = null;
    } finally {
      _artistLoading.remove(k);
      notifyListeners();
    }
  }

  Future<void> init() async {
    await initPlayback();
    mixList = prefs!.getStringList('mix') ?? [];
    mixSource = prefs!.getString('mix_source');
    query.sort = TrackSort.parse(prefs!.getString('library_sort'));
    final saved = prefs!.getString('folder');
    if (saved != null && Directory(saved).existsSync()) await openFolder(saved);
  }

  Future<void> ensureStoragePermission() async {
    if (!Platform.isAndroid) return;
    if (!await Permission.manageExternalStorage.isGranted) {
      await Permission.manageExternalStorage.request();
    }
    await Permission.audio.request();
    await Permission.notification.request();
  }

  Future<void> pickFolder() async {
    await ensureStoragePermission();
    final dir = await FilePicker.getDirectoryPath();
    if (dir != null) await openFolder(dir);
  }

  /// Where imported mixtapes are installed: inside the open music folder so
  /// they appear in the library, else a default music location.
  Future<Directory> mixtapeRoot() async {
    if (folder != null) return Directory(p.join(folder!, 'Mixtapes'));
    if (Platform.isAndroid) return Directory('/storage/emulated/0/Music/beats-me');
    return Directory(p.join((await getApplicationDocumentsDirectory()).path, 'beats-me'));
  }

  /// The mixtapes installed on this phone (each is a `.m3u8` next to its
  /// songs), newest first. Lets the Mixes screen list mix *names* at the
  /// top level, separately from the flat Mix list of individual songs.
  ///
  /// Summaries are cached in `<mixtapeRoot>/.mixes-cache.json` by playlist
  /// path, mtime and size, so unchanged mixes don't re-read every song's
  /// sidecars; [force] rebuilds them all.
  Future<List<MixSummary>> listMixes({bool force = false}) async {
    final mixRoot = await mixtapeRoot();
    final cache = await _loadMixCache(mixRoot);
    if (force) cache.clear();
    final ids = await _ledgerIds(mixRoot);
    final roots = <String>{mixRoot.path, ?folder};
    final seen = <String>{};
    final out = <MixSummary>[];
    var dirty = force;
    for (final rootPath in roots) {
      final root = Directory(rootPath);
      if (!await root.exists()) continue;
      try {
        // Unreadable subfolders (common on Windows) must not abort the scan.
        await for (final e in root
            .list(recursive: true, followLinks: false)
            .handleError((_) {}, test: (e) => e is FileSystemException)) {
          if (e is! File || !e.path.toLowerCase().endsWith('.m3u8')) continue;
          final key = p.normalize(e.path);
          if (!seen.add(key)) continue; // folder nests mixtapeRoot
          try {
            final st = await e.stat();
            final hit = cache[key];
            if (hit is Map &&
                hit['mtime'] == st.modified.millisecondsSinceEpoch &&
                hit['size'] == st.size &&
                hit['summary'] is Map) {
              out.add(MixSummary.fromJson(e.path, (hit['summary'] as Map).cast<String, dynamic>()));
              continue;
            }
            final m = await _summarize(e, mixId: ids[p.normalize(e.parent.path)], withSize: mixRoot);
            cache[key] = {'mtime': st.modified.millisecondsSinceEpoch, 'size': st.size, 'summary': m.toJson()};
            dirty = true;
            out.add(m);
          } catch (_) {}
        }
      } on FileSystemException {
        continue;
      }
    }
    if (cache.keys.any((k) => !seen.contains(k))) {
      cache.removeWhere((k, _) => !seen.contains(k));
      dirty = true;
    }
    if (dirty) await _saveMixCache(mixRoot);
    await _applyLastPlayed(out);
    out.sort((a, b) => b.modified.compareTo(a.modified));
    return out;
  }

  /// How many playlists were summarized from scratch (cache misses).
  @visibleForTesting
  int summarizedCount = 0;

  /// Bumped whenever the installed mixes change (import, delete, folder).
  int mixesVersion = 0;

  /// The Mixes screen's saved sort order (a `MixSort` name).
  String? get mixesSort => prefs?.getString('mixes_sort');
  set mixesSort(String? v) => v == null ? prefs?.remove('mixes_sort') : prefs?.setString('mixes_sort', v);

  Map<String, dynamic>? _mixCache;
  String? _mixCacheRoot;

  File _mixCacheFile(Directory root) => File(p.join(root.path, '.mixes-cache.json'));

  Future<Map<String, dynamic>> _loadMixCache(Directory root) async {
    if (_mixCache != null && _mixCacheRoot == root.path) return _mixCache!;
    _mixCacheRoot = root.path;
    try {
      _mixCache = (jsonDecode(await _mixCacheFile(root).readAsString()) as Map).cast<String, dynamic>();
    } catch (_) {
      _mixCache = {};
    }
    return _mixCache!;
  }

  Future<void> _saveMixCache(Directory root) async {
    try {
      if (await root.exists()) await writeStringAtomic(_mixCacheFile(root), jsonEncode(_mixCache ?? {}));
    } catch (_) {}
  }

  /// Forgets cached mix summaries (all of them, or just [file]'s).
  Future<void> invalidateMixCache([String? file]) async {
    final root = await mixtapeRoot();
    final cache = await _loadMixCache(root);
    if (file == null) {
      cache.clear();
      try {
        final f = _mixCacheFile(root);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    } else if (cache.remove(p.normalize(file)) != null) {
      await _saveMixCache(root);
    }
  }

  /// Installed mixes changed (e.g. an import finished): drops the summary
  /// cache and tells the Mixes screen to reload.
  Future<void> mixesChanged() async {
    await invalidateMixCache();
    mixesVersion++;
    notifyListeners();
  }

  /// Mix folder (normalized, absolute) → mixtape id, from the import ledger.
  Future<Map<String, String>> _ledgerIds(Directory root) async {
    try {
      final led = jsonDecode(await File(p.join(root.path, '.imported.json')).readAsString()) as Map;
      return {
        for (final e in led.entries)
          if (e.value is Map && (e.value as Map)['dir'] is String)
            p.normalize(p.join(root.path, (e.value as Map)['dir'] as String)):
                '${e.key}'.substring('${e.key}'.indexOf(':') + 1),
      };
    } catch (_) {
      return {};
    }
  }

  /// Every journal entry; tests replace it.
  @visibleForTesting
  Future<List<JournalEntry>> Function() journalEntries =
      () async => (await AppJournal.journal).since(0);

  static String _lastPlayedKey(String file) => 'mix_last_played:${p.normalize(file)}';

  /// Remembers that the mix in [file] was just played from the Mixes list.
  Future<void> noteMixPlayed(String file) async =>
      prefs?.setInt(_lastPlayedKey(file), DateTime.now().millisecondsSinceEpoch);

  Future<void> _applyLastPlayed(List<MixSummary> mixes) async {
    var byMix = <String, DateTime>{};
    try {
      byMix = lastPlayedByMix(await journalEntries());
    } catch (_) {}
    for (final m in mixes) {
      final j = m.mixId == null ? null : byMix[m.mixId];
      final ms = prefs?.getInt(_lastPlayedKey(m.file));
      final pref = ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
      m.lastPlayed = j == null || (pref != null && pref.isAfter(j)) ? pref : j;
    }
  }

  /// Newest play time per mixtape id.
  static Map<String, DateTime> lastPlayedByMix(Iterable<JournalEntry> entries) {
    final out = <String, DateTime>{};
    for (final e in entries) {
      final id = e.mixId;
      if (!e.isPlay || id == null) continue;
      final at = DateTime.fromMillisecondsSinceEpoch(e.at);
      final prev = out[id];
      if (prev == null || at.isAfter(prev)) out[id] = at;
    }
    return out;
  }

  /// Bytes used by the mix in [playlist]: its whole folder when installed
  /// under [root], else the playlist plus the songs it lists.
  Future<int> _mixSize(File playlist, Directory root, String text) async {
    var total = 0;
    final dir = playlist.parent;
    if (p.isWithin(root.path, dir.path)) {
      await for (final f in dir
          .list(recursive: true, followLinks: false)
          .handleError((_) {}, test: (e) => e is FileSystemException)) {
        if (f is File) total += await f.length().catchError((_) => 0);
      }
      return total;
    }
    total += await playlist.length();
    for (final s in parseM3u(text, baseDir: dir.path).toSet()) {
      try {
        total += await File(s).length();
      } catch (_) {}
    }
    return total;
  }

  /// Name, program and total running time of an installed mixtape's playlist.
  /// Songs whose playlist entry has no length fall back to their metadata.
  /// [withSize] (the mixtape root) also measures its size on disk.
  Future<MixSummary> _summarize(File e, {String? mixId, Directory? withSize}) async {
    summarizedCount++;
    final text = utf8.decode(await e.readAsBytes(), allowMalformed: true);
    String? program, icon;
    final art = <String>[];
    double total = 0;
    var any = false, count = 0, damaged = 0, explicit = 0;
    double? pending;
    final acts = <MixActivity>[];
    for (var line in text.replaceFirst('\uFEFF', '').split(RegExp(r'\r?\n'))) {
      line = line.trim();
      if (line.startsWith('#EXT-X-PROGRAM:')) {
        program = line.substring('#EXT-X-PROGRAM:'.length).trim();
      } else if (line.startsWith(mixIconTag)) {
        icon = line.substring(mixIconTag.length).trim();
      } else if (line.startsWith('#EXTINF:')) {
        pending = double.tryParse(line.substring(8).split(',').first.trim());
      } else if (line.isNotEmpty && !line.startsWith('#')) {
        count++;
        final path = p.isAbsolute(line) ? line : p.join(e.parent.path, line);
        if (art.length < 4) art.add(path);
        final meta = await SongMeta.load(path);
        final mid = meta?['mixId'];
        if (mid is String && mid.isNotEmpty) mixId ??= mid;
        if (_metaDamaged(meta)) damaged++;
        if (meta?['explicit'] == true) explicit++;
        var secs = pending != null && pending >= 0 ? pending : null;
        secs ??= (meta?['duration'] as num?)?.toDouble() ?? (await BpmStore.load(path))?.durationSec;
        if (secs != null) {
          total += secs;
          any = true;
        }
        final plan = meta?['plan'];
        final name = (plan is Map ? plan['activity'] as String? : null) ?? meta?['step'] as String?;
        if (name != null && name.isNotEmpty) {
          final icon = plan is Map ? plan['icon'] as String? : null;
          final i = acts.indexWhere((a) => a.name == name);
          if (i < 0) {
            acts.add(MixActivity(name, icon, 1, secs ?? 0));
          } else {
            acts[i] = MixActivity(name, acts[i].icon ?? icon, acts[i].songs + 1, acts[i].seconds + (secs ?? 0));
          }
        }
        pending = null;
      }
    }
    return MixSummary(p.basenameWithoutExtension(e.path), e.path, count,
        modified: (await e.stat()).modified,
        programName: program == null || program.isEmpty ? null : program,
        totalSeconds: any ? total : null,
        activities: acts,
        mixId: mixId,
        damaged: damaged,
        explicit: explicit,
        icon: icon == null || icon.isEmpty ? null : icon,
        artPaths: art,
        sizeBytes: withSize == null ? null : await _mixSize(e, withSize, text));
  }

  static bool _metaDamaged(Map<String, dynamic>? meta) =>
      meta?['damaged'] is String || (meta?['tags'] is List && (meta!['tags'] as List).contains('corrupt'));

  /// Re-checks every song in [m] with the quick damage check and records the
  /// result in each song's sidecar, so the Mixes list can flag it. Returns
  /// how many songs look damaged (missing files count too).
  Future<int> checkMixAudio(MixSummary m) async {
    final text = utf8.decode(await File(m.file).readAsBytes(), allowMalformed: true);
    var bad = 0;
    for (final path in parseM3u(text, baseDir: p.dirname(m.file)).toSet()) {
      String? reason;
      try {
        final r = await quickCheckFile(path);
        if (r.damaged) reason = r.reason ?? 'damaged audio';
      } catch (_) {
        bad++; // missing or unreadable: nothing to annotate
        continue;
      }
      final meta = Map<String, dynamic>.of(await SongMeta.load(path) ?? const {});
      final changed = meta['damaged'] != reason;
      if (reason == null) {
        meta.remove('damaged');
      } else {
        meta['damaged'] = reason;
      }
      // A 'corrupt' tag from the PC (maybe from its deeper check) still counts.
      if (_metaDamaged(meta)) bad++;
      if (!changed) continue;
      try {
        await SongMeta.sidecar(path).writeAsString(jsonEncode(meta));
      } catch (_) {}
    }
    await invalidateMixCache(m.file);
    mixesVersion++;
    notifyListeners();
    return bad;
  }

  /// Deletes an installed mixtape: its folder (songs and sidecars) when it
  /// lives under the mixtape root, otherwise just its playlist file. Also
  /// forgets it in the import ledger so the PC can send it again.
  Future<void> deleteMix(MixSummary m) async {
    final root = await mixtapeRoot();
    final dir = Directory(p.dirname(m.file));
    final installed = p.isWithin(root.path, dir.path);
    final gone = <String>{};
    if (installed) {
      await for (final e in dir.list(recursive: true, followLinks: false)) {
        if (e is File) gone.add(p.normalize(e.path));
      }
      await dir.delete(recursive: true);
      try {
        final ledger = File(p.join(root.path, '.imported.json'));
        final led = (jsonDecode(await ledger.readAsString()) as Map).cast<String, dynamic>();
        final rel = p.relative(dir.path, from: root.path).replaceAll('\\', '/');
        led.removeWhere((_, v) => v is Map && v['dir'] == rel);
        await writeStringAtomic(ledger, jsonEncode(led));
      } catch (_) {}
      // So a USB re-send of this mix copies its songs again.
      await mixtapes.writeInventory();
    } else {
      await File(m.file).delete();
    }
    await invalidateMixCache(m.file);
    await prefs?.remove(_lastPlayedKey(m.file));
    mixesVersion++;
    final before = mixList.length;
    mixList.removeWhere((s) => gone.contains(p.normalize(s)));
    if (currentMix?.file == m.file) currentMix = null;
    if (mixSource != null && p.normalize(mixSource!) == p.normalize(m.file)) {
      mixSource = null;
      await prefs?.remove('mix_source');
    }
    if (mixList.length != before) await prefs?.setStringList('mix', mixList);
    if (installed) tracks.removeWhere((s) => gone.contains(p.normalize(s)));
    notifyListeners();
  }

  /// Makes an imported mixtape the current mix and shows its songs in the library.
  Future<void> applyImported(ImportResult r) async {
    if (r.paths.isEmpty) return;
    final root = await mixtapeRoot();
    await openFolder(folder ?? root.path);
    mixList = r.paths;
    mixSource = null;
    await prefs?.remove('mix_source');
    await prefs?.setStringList('mix', mixList);
    notifyListeners();
  }

  Future<void> openFolder(String dir) async {
    try {
      if (folder != dir) {
        _mixCache = null;
        mixesVersion++;
      }
      folder = dir;
      tracks = await scanMp3s(dir);
      error = null;
      await prefs?.setString('folder', dir);
      tempos.clear();
      media.clear();
      query.clearFilters();
      query.text = '';
      notifyListeners();
      unawaited(_buildIndex());
      unawaited(_loadTempos(dir, List.of(tracks)));
    } catch (e) {
      error = 'Cannot read folder: $e';
    }
    notifyListeners();
  }

  /// Reads tempo sidecars in the background so opening a big library (or
  /// finishing an import) doesn't wait on thousands of small files.
  Future<void> _loadTempos(String dir, List<String> list) async {
    for (var i = 0; i < list.length; i++) {
      if (folder != dir) return;
      tempos[list[i]] = await BpmStore.load(list[i]);
      if (i % 200 == 199) notifyListeners();
    }
    if (folder == dir) notifyListeners();
  }

  int batchDone = 0;
  int batchTotal = 0;
  bool batchCancel = false;
  bool get batchRunning => batchTotal > 0;

  int enrichDone = 0;
  int enrichTotal = 0;
  bool enrichCancel = false;
  bool get enrichRunning => enrichTotal > 0;

  /// Per-song outcome of the running folder batch: true ok, false failed, null pending.
  List<bool?> enrichResults = [];
  int get enrichOk => enrichResults.where((r) => r == true).length;
  int get enrichFailed => enrichResults.where((r) => r == false).length;

  /// Fetches art and lyrics for every song not yet attempted, one at a time.
  Future<void> enrichAll() async {
    if (enrichRunning) return;
    final todo = <String>[];
    for (final t in tracks) {
      if (!await EnrichService.markerFile(t).exists()) todo.add(t);
    }
    if (todo.isEmpty) {
      enrichNote = 'Nothing to fetch: every song was already attempted.';
      notifyListeners();
      return;
    }
    enrichTotal = todo.length;
    enrichDone = 0;
    enrichResults = List<bool?>.filled(todo.length, null);
    enrichCancel = false;
    enrichNote = null;
    notifyListeners();
    for (var i = 0; i < todo.length; i++) {
      if (enrichCancel) break;
      enrichResults[i] = await fetchMedia(todo[i], force: false);
      enrichDone++;
      notifyListeners();
    }
    final ok = enrichOk, bad = enrichFailed;
    enrichTotal = 0;
    enrichDone = 0;
    enrichResults = [];
    enrichNote = 'Enrich finished: $ok succeeded, $bad failed.';
    notifyListeners();
  }

  void cancelEnrich() {
    enrichCancel = true;
    notifyListeners();
  }

  /// Analyzes every track lacking a valid .bpm file, one at a time.
  Future<void> analyzeAll() async {
    if (batchRunning) return;
    final todo = <String>[];
    for (final t in tracks) {
      if (!isComplete(await tempoFor(t))) todo.add(t);
    }
    if (todo.isEmpty) return;
    batchTotal = todo.length;
    batchDone = 0;
    batchCancel = false;
    notifyListeners();
    for (final t in todo) {
      if (batchCancel) break;
      await analyze(t);
      batchDone++;
      notifyListeners();
    }
    batchTotal = 0;
    batchDone = 0;
    notifyListeners();
  }

  void cancelBatch() {
    batchCancel = true;
    notifyListeners();
  }

  void toggleMix(String path) {
    currentMix = null;
    mixList.contains(path) ? mixList.remove(path) : mixList.add(path);
    prefs?.setStringList('mix', mixList);
    notifyListeners();
  }

  void reorderMix(int oldI, int newI) {
    if (newI > oldI) newI--;
    currentMix = null;
    mixList.insert(newI, mixList.removeAt(oldI));
    prefs?.setStringList('mix', mixList);
    notifyListeners();
  }

  /// Playlist file the mix list was loaded from (or last saved to); stays
  /// set while the list is edited by hand so it can be saved back.
  String? mixSource;

  /// Name shown for the mix list: the loaded mix, or its source when edited.
  String? get mixTitle =>
      currentMix?.name ??
      (mixSource == null ? null : '${p.basenameWithoutExtension(mixSource!)} (edited)');

  static final _badName = RegExp(r'[\\/:*?"<>|\x00-\x1f]');

  /// A file-system safe mix name; never empty.
  static String safeMixName(String name) {
    final n = name.replaceAll(_badName, ' ').replaceAll(RegExp(r'\s+'), ' ').trim().replaceFirst(RegExp(r'\.+$'), '');
    return n.isEmpty ? 'Mix' : n;
  }

  /// Where "save as new" writes a mix called [name]: its own folder under
  /// `<mixtapeRoot>/Saved`, so deleting it never touches other mixes' songs.
  Future<File> savedMixFile(String name) async {
    final n = safeMixName(name);
    return File(p.join((await mixtapeRoot()).path, 'Saved', n, '$n.m3u8'));
  }

  /// Whether [mixSource] is a mixtape imported from the PC (a later import
  /// can replace its playlist), as opposed to a hand-made one.
  Future<bool> sourceIsImported() async {
    final src = mixSource;
    if (src == null) return false;
    final root = await mixtapeRoot();
    final saved = p.join(root.path, 'Saved');
    return p.isWithin(root.path, src) && !p.isWithin(saved, src) && (await _ledgerIds(root)).containsKey(p.normalize(p.dirname(src)));
  }

  /// Writes the mix list as an `.m3u8`: over [mixSource] when [overwrite],
  /// else as a new mix named [name]. Songs inside the playlist's folder are
  /// written relative. Makes it the current mix and refreshes the Mixes list.
  Future<MixSummary> saveMix(String name, {bool overwrite = false}) async {
    if (mixList.isEmpty) throw StateError('The mix list is empty');
    final src = mixSource;
    final File target;
    if (overwrite && src != null) {
      target = File(src);
    } else {
      target = await savedMixFile(name);
    }
    String? program;
    try {
      if (src != null && await File(src).exists()) {
        for (final l in const LineSplitter().convert(utf8.decode(await File(src).readAsBytes(), allowMalformed: true))) {
          if (l.startsWith('#EXT-X-PROGRAM:')) program = l.substring('#EXT-X-PROGRAM:'.length).trim();
        }
      }
    } catch (_) {}
    final entries = <MixEntry>[];
    for (final path in mixList) {
      final meta = await SongMeta.load(path);
      final secs = (meta?['duration'] as num?)?.toDouble() ?? (await BpmStore.load(path))?.durationSec;
      entries.add(MixEntry(
        path,
        (meta?['title'] as String?) ?? p.basenameWithoutExtension(path),
        artist: meta?['artist'] as String?,
        durationSec: secs,
      ));
    }
    await target.parent.create(recursive: true);
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsString(buildM3u8(entries, program: program, baseDir: target.parent.path));
    await tmp.rename(target.path);
    mixSource = target.path;
    await prefs?.setString('mix_source', target.path);
    await invalidateMixCache(target.path);
    currentMix = await _summarize(target);
    mixesVersion++;
    notifyListeners();
    return currentMix!;
  }

  /// Replaces the mix list with the songs in an .m3u/.m3u8 file (e.g. from
  /// analyze-this). Returns the number of entries skipped because the file is
  /// missing.
  Future<int> importMix(String file) async {
    final text = utf8.decode(await File(file).readAsBytes(), allowMalformed: true);
    final byLower = {for (final t in tracks) t.toLowerCase(): t};
    final imported = <String>[];
    var skipped = 0;
    for (final path in parseM3u(text, baseDir: File(file).parent.path)) {
      final known = byLower[path.toLowerCase()];
      if (known != null) {
        imported.add(known);
      } else if (await File(path).exists()) {
        imported.add(path);
      } else {
        skipped++;
      }
    }
    mixList = imported;
    mixSource = file;
    await prefs?.setString('mix_source', file);
    try {
      currentMix = await _summarize(File(file));
    } catch (_) {
      currentMix = null;
    }
    await prefs?.setStringList('mix', mixList);
    notifyListeners();
    return skipped;
  }
}
