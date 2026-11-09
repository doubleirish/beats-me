import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/app_state.dart';
import '../services/play_stats.dart';

enum StatsRange {
  week('7 days', Duration(days: 7)),
  month('30 days', Duration(days: 30)),
  all('All time', null);

  const StatsRange(this.label, this.span);
  final String label;
  final Duration? span;
}

String formatListening(double seconds) {
  final m = (seconds / 60).round();
  if (m < 60) return '$m min';
  final h = m ~/ 60;
  return '$h h ${m % 60} min';
}

/// What you've been listening to, from the permanent play history.
class StatsScreen extends StatefulWidget {
  const StatsScreen({super.key, this.active = true, this.loader, this.mixNames});

  /// Reloads each time the tab becomes visible.
  final bool active;
  final Future<List<PlayRecord>> Function()? loader;

  /// Mix names by id; defaults to the installed mixes.
  final Future<Map<String, String>> Function()? mixNames;

  @override
  State<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends State<StatsScreen> {
  List<PlayRecord>? _records;
  Map<String, String> _mixNames = {};
  StatsRange _range = StatsRange.month;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(StatsScreen old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active) _load();
  }

  Future<void> _load() async {
    final app = widget.mixNames == null ? context.read<AppState>() : null;
    List<PlayRecord> rs;
    try {
      rs = await (widget.loader ?? () async => (await PlayStats.instance).all())();
    } catch (_) {
      rs = [];
    }
    var names = <String, String>{};
    try {
      if (widget.mixNames != null) {
        names = await widget.mixNames!();
      } else {
        for (final m in await app!.listMixes()) {
          if (m.mixId != null) names[m.mixId!] = m.name;
        }
      }
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _records = rs;
      _mixNames = names;
    });
  }

  @override
  Widget build(BuildContext context) {
    final rs = _records;
    final span = _range.span;
    final sum = rs == null
        ? null
        : summarizeStats(rs, since: span == null ? null : DateTime.now().subtract(span));
    return Scaffold(
      appBar: AppBar(title: const Text('Stats')),
      body: sum == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.all(16), children: [
              SegmentedButton<StatsRange>(
                showSelectedIcon: false,
                segments: [
                  for (final r in StatsRange.values) ButtonSegment(value: r, label: Text(r.label)),
                ],
                selected: {_range},
                onSelectionChanged: (v) => setState(() => _range = v.first),
              ),
              const SizedBox(height: 16),
              if (sum.plays == 0)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 48),
                  child: Center(child: Text('No plays yet. Play a song and it will show up here.')),
                )
              else ...[
                Row(children: [
                  _Tile('Plays', '${sum.plays}'),
                  _Tile('Listened', formatListening(sum.listenedSeconds)),
                  _Tile('Finished', '${(sum.completionRate * 100).round()}%'),
                ]),
                _Section('Top songs', [
                  for (final r in sum.topSongs) _RankRow(r),
                ]),
                _Section('Top artists', [
                  for (final r in sum.topArtists) _RankRow(r),
                ]),
                _Section('Mixes played', [
                  for (final m in sum.mixes)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(_mixNames[m.mixId] ?? 'Removed mix'),
                      subtitle: Text('last ${_date(m.last)}'),
                      trailing: Text('${m.plays} plays'),
                    ),
                ]),
              ],
            ]),
    );
  }

  static String _date(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

class _Tile extends StatelessWidget {
  const _Tile(this.label, this.value);
  final String label, value;

  @override
  Widget build(BuildContext context) => Expanded(
        child: Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Column(children: [
              Text(value, style: Theme.of(context).textTheme.titleLarge),
              Text(label, style: Theme.of(context).textTheme.bodySmall),
            ]),
          ),
        ),
      );
}

class _Section extends StatelessWidget {
  const _Section(this.title, this.children);
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => children.isEmpty
      ? const SizedBox.shrink()
      : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.only(top: 20, bottom: 4),
            child: Text(title, style: Theme.of(context).textTheme.titleMedium),
          ),
          ...children,
        ]);
}

class _RankRow extends StatelessWidget {
  const _RankRow(this.r);
  final Ranked r;

  @override
  Widget build(BuildContext context) => ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        title: Text(r.label, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(formatListening(r.seconds)),
        trailing: Text('${r.plays} plays'),
      );
}
