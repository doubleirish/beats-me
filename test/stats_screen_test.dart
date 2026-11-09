import 'package:beats_me/screens/stats_screen.dart';
import 'package:beats_me/services/play_stats.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> pump(WidgetTester t, List<PlayRecord> rs) => t.pumpWidget(
      MaterialApp(home: StatsScreen(loader: () async => rs, mixNames: () async => {})),
    );

void main() {
  testWidgets('shows an empty state without plays', (t) async {
    await pump(t, []);
    await t.pumpAndSettle();
    expect(find.textContaining('No plays yet'), findsOneWidget);
  });

  testWidgets('shows totals and top songs, and the range filters them', (t) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final old = DateTime.now().subtract(const Duration(days: 90)).millisecondsSinceEpoch;
    await pump(t, [
      PlayRecord(at: now, listened: 600, done: true, title: 'Recent', artist: 'X'),
      PlayRecord(at: old, listened: 60, done: true, title: 'Ancient', artist: 'Y'),
    ]);
    await t.pumpAndSettle();
    expect(find.text('Recent'), findsOneWidget);
    expect(find.text('Ancient'), findsNothing);
    await t.tap(find.text('All time'));
    await t.pumpAndSettle();
    expect(find.text('Ancient'), findsOneWidget);
  });
}
