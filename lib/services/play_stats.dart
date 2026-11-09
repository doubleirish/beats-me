import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_core/shared_core.dart';

import 'journal.dart';

/// One finished play, as kept for the stats screen.
class PlayRecord {
  const PlayRecord({
    required this.at,
    required this.listened,
    required this.done,
    this.path,
    this.title,
    this.artist,
    this.mixId,
  });

  final int at;
  final double listened;
  final bool done;
  final String? path;
  final String? title;
  final String? artist;
  final String? mixId;

  /// Stable key for "same song" across devices and renames.
  String get songKey => path ?? '${artist ?? ''}|${title ?? ''}';

  String get songLabel => title ?? (path == null ? '?' : baseName(path!));

  Map<String, dynamic> toJson() => {
        'at': at,
        'listened': listened,
        'done': done,
        if (path != null) 'path': path,
        if (title != null) 'title': title,
        if (artist != null) 'artist': artist,
        if (mixId != null) 'mixId': mixId,
      };

  static PlayRecord? fromJson(Map<String, dynamic> j) {
    final at = j['at'];
    final listened = j['listened'];
    if (at is! int || listened is! num) return null;
    return PlayRecord(
      at: at,
      listened: listened.toDouble(),
      done: j['done'] == true,
      path: j['path'] as String?,
      title: j['title'] as String?,
      artist: j['artist'] as String?,
      mixId: j['mixId'] as String?,
    );
  }

  static PlayRecord? fromEntry(JournalEntry e) => e.isPlay
      ? PlayRecord(
          at: e.at,
          listened: e.listened ?? 0,
          done: e.done ?? false,
          path: e.path,
          title: e.title,
          artist: e.artist,
          mixId: e.mixId,
        )
      : null;
}

class Ranked {
  const Ranked(this.label, this.plays, this.seconds);
  final String label;
  final int plays;
  final double seconds;
}

class MixPlays {
  const MixPlays(this.mixId, this.plays, this.last);
  final String mixId;
  final int plays;
  final DateTime last;
}

class StatsSummary {
  const StatsSummary({
    required this.plays,
    required this.listenedSeconds,
    required this.completionRate,
    required this.topSongs,
    required this.topArtists,
    required this.mixes,
    required this.perWeek,
  });

  final int plays;
  final double listenedSeconds;

  /// Share of plays heard to the end (0..1); 0 when there are none.
  final double completionRate;
  final List<Ranked> topSongs;
  final List<Ranked> topArtists;
  final List<MixPlays> mixes;

  /// Seconds listened per week, oldest first; keys are each week's Monday.
  final List<(DateTime, double)> perWeek;
}

DateTime _monday(DateTime d) {
  final day = DateTime(d.year, d.month, d.day);
  return day.subtract(Duration(days: day.weekday - 1));
}

/// Aggregates [records] at or after [since] (all when null).
StatsSummary summarizeStats(Iterable<PlayRecord> records, {DateTime? since, int top = 10}) {
  final from = since?.millisecondsSinceEpoch ?? 0;
  final rs = [for (final r in records) if (r.at >= from) r];
  final songs = <String, (String, int, double)>{};
  final artists = <String, (int, double)>{};
  final mixes = <String, (int, int)>{};
  final weeks = <DateTime, double>{};
  var total = 0.0;
  var done = 0;
  for (final r in rs) {
    total += r.listened;
    if (r.done) done++;
    final s = songs[r.songKey];
    songs[r.songKey] = (r.songLabel, (s?.$2 ?? 0) + 1, (s?.$3 ?? 0) + r.listened);
    final a = r.artist;
    if (a != null && a.isNotEmpty) {
      final x = artists[a];
      artists[a] = ((x?.$1 ?? 0) + 1, (x?.$2 ?? 0) + r.listened);
    }
    final m = r.mixId;
    if (m != null) {
      final x = mixes[m];
      mixes[m] = ((x?.$1 ?? 0) + 1, x == null || r.at > x.$2 ? r.at : x.$2);
    }
    final w = _monday(DateTime.fromMillisecondsSinceEpoch(r.at));
    weeks[w] = (weeks[w] ?? 0) + r.listened;
  }
  int byPlays(Ranked a, Ranked b) {
    final c = b.plays.compareTo(a.plays);
    return c != 0 ? c : b.seconds.compareTo(a.seconds);
  }

  return StatsSummary(
    plays: rs.length,
    listenedSeconds: total,
    completionRate: rs.isEmpty ? 0 : done / rs.length,
    topSongs: ([for (final e in songs.values) Ranked(e.$1, e.$2, e.$3)]..sort(byPlays))
        .take(top)
        .toList(),
    topArtists: ([for (final e in artists.entries) Ranked(e.key, e.value.$1, e.value.$2)]
          ..sort(byPlays))
        .take(top)
        .toList(),
    mixes: [
      for (final e in mixes.entries)
        MixPlays(e.key, e.value.$1, DateTime.fromMillisecondsSinceEpoch(e.value.$2)),
    ]..sort((a, b) => b.last.compareTo(a.last)),
    perWeek: [for (final e in weeks.entries) (e.key, e.value)]
      ..sort((a, b) => a.$1.compareTo(b.$1)),
  );
}

/// Permanent play history (`<app support>/stats.jsonl`). Unlike the journal it
/// is never trimmed after a sync to analyze-this.
class PlayStats {
  PlayStats(this.file, {this.seed});

  final File file;

  /// Plays to import the first time the file is created.
  final Future<Iterable<JournalEntry>> Function()? seed;

  static PlayStats? _instance;

  static Future<PlayStats> get instance async {
    if (_instance != null) return _instance!;
    final dir = await getApplicationSupportDirectory();
    return _instance = PlayStats(File(p.join(dir.path, 'stats.jsonl')),
        seed: () async => (await AppJournal.journal).since(0));
  }

  Future<void> _chain = Future.value();

  Future<T> _locked<T>(Future<T> Function() op) {
    final r = _chain.then((_) => op());
    _chain = r.then((_) {}, onError: (_) {});
    return r;
  }

  Future<void> _seedIfNew() async {
    if (await file.exists()) return;
    final lines = StringBuffer();
    try {
      for (final e in await seed?.call() ?? const <JournalEntry>[]) {
        final r = PlayRecord.fromEntry(e);
        if (r != null) lines.writeln(jsonEncode(r.toJson()));
      }
    } catch (_) {}
    await file.parent.create(recursive: true);
    await file.writeAsString(lines.toString());
  }

  Future<void> append(PlayRecord r) => _locked(() async {
        await _seedIfNew();
        await file.writeAsString('${jsonEncode(r.toJson())}\n', mode: FileMode.append);
      });

  Future<List<PlayRecord>> all() => _locked(() async {
        await _seedIfNew();
        final out = <PlayRecord>[];
        for (final line in const LineSplitter().convert(await file.readAsString())) {
          try {
            final r = PlayRecord.fromJson((jsonDecode(line) as Map).cast<String, dynamic>());
            if (r != null) out.add(r);
          } catch (_) {}
        }
        return out;
      });
}

/// Adds a finished play of [path] to the permanent history.
Future<void> recordPlayStat(String path, double listened, bool completed) async {
  try {
    final e = await JournalEntry.playOf(path,
        device: await AppJournal.deviceId(), listened: listened, done: completed);
    final r = PlayRecord.fromEntry(e);
    if (r != null) await (await PlayStats.instance).append(r);
  } catch (_) {}
}
