import 'dart:io';

import 'package:beats_me/services/play_stats.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_core/services/mixtape/journal.dart';

PlayRecord rec(DateTime at, double listened,
        {bool done = true, String? title, String? artist, String? mixId}) =>
    PlayRecord(
        at: at.millisecondsSinceEpoch,
        listened: listened,
        done: done,
        path: 'C:/m/$title.mp3',
        title: title,
        artist: artist,
        mixId: mixId);

void main() {
  test('summarizeStats ranks songs/artists and tracks mixes, completion, weeks', () {
    final mon = DateTime(2025, 1, 6, 10);
    final s = summarizeStats([
      rec(mon, 200, title: 'A', artist: 'X', mixId: 'm1'),
      rec(mon.add(const Duration(days: 1)), 100, done: false, title: 'A', artist: 'X', mixId: 'm1'),
      rec(mon.add(const Duration(days: 8)), 50, title: 'B', artist: 'Y', mixId: 'm2'),
    ]);
    expect(s.plays, 3);
    expect(s.listenedSeconds, 350);
    expect(s.completionRate, closeTo(2 / 3, 1e-9));
    expect(s.topSongs.first.label, 'A');
    expect(s.topSongs.first.plays, 2);
    expect(s.topArtists.map((a) => a.label), ['X', 'Y']);
    expect(s.mixes.first.mixId, 'm2');
    expect(s.mixes.last.plays, 2);
    expect(s.perWeek.length, 2);
    expect(s.perWeek.first.$2, 300);
  });

  test('summarizeStats honours since and handles empty input', () {
    final old = DateTime(2024, 1, 1);
    final s = summarizeStats([rec(old, 10, title: 'A')], since: DateTime(2025, 1, 1));
    expect(s.plays, 0);
    expect(s.completionRate, 0);
  });

  test('store seeds from the journal once, then appends and survives reload', () async {
    final dir = await Directory.systemTemp.createTemp('stats');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/stats.jsonl');
    Future<List<JournalEntry>> seed() async => [
          JournalEntry.forPlay(device: 'd', listened: 30, done: true, path: 'a.mp3', at: 1000),
          JournalEntry.forRating(device: 'd', rating: 4, fav: false, path: 'a.mp3', at: 2000),
        ];
    final st = PlayStats(file, seed: seed);
    await st.append(rec(DateTime(2025, 1, 6), 60, title: 'B'));
    final again = PlayStats(file, seed: seed);
    final all = await again.all();
    expect(all.length, 2);
    expect(all.first.at, 1000);
  });
}
