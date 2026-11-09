import 'dart:io';

import 'package:beats_me/services/journal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_core/shared_core.dart';

void main() {
  late Directory tmp;
  late PlayJournal j;
  late File ack;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('journal_ack_');
    j = PlayJournal(File(p.join(tmp.path, 'journal.jsonl')));
    ack = File(p.join(tmp.path, '.journal-ack.json'));
    for (var i = 0; i < 3; i++) {
      await j.append(JournalEntry.forPlay(device: 'd', listened: 10, done: true, path: 's$i.mp3'));
    }
  });
  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Future<List<int>> seqs() async => [for (final e in await j.since(0)) e.seq];

  test('trims acknowledged entries and deletes the ack', () async {
    await ack.writeAsString(ackJson(2));
    expect(await applyJournalAck(j, ack), 2);
    expect(await seqs(), [3]);
    expect(await ack.exists(), isFalse);
  });

  test('an ack beyond lastSeq only trims to lastSeq', () async {
    await ack.writeAsString(ackJson(99));
    expect(await applyJournalAck(j, ack), 3);
    expect(await seqs(), isEmpty);
    final e = await j.append(JournalEntry.forPlay(device: 'd', listened: 1, done: false));
    expect(e.seq, 4);
  });

  test('missing or corrupt ack leaves the journal alone', () async {
    expect(await applyJournalAck(j, ack), isNull);
    await ack.writeAsString('{not json');
    expect(await applyJournalAck(j, ack), isNull);
    expect(await ack.exists(), isFalse);
    expect(await seqs(), [1, 2, 3]);
  });
}
