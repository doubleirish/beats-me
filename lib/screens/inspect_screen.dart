import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_core/models/tempo.dart';
import 'package:shared_core/screens/tempo_graph.dart';
import 'package:shared_core/services/algorithms.dart';
import 'package:shared_core/services/library_service.dart';

import '../services/app_state.dart';

class InspectScreen extends StatelessWidget {
  const InspectScreen({super.key, required this.path});
  final String path;

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final res = s.tempos[path];
    final busy = s.analyzing.contains(path);
    final theme = Theme.of(context);
    final shown = res == null
        ? <TempoAlgorithm>[]
        : allAlgorithms.where((a) => res.byAlgo.containsKey(a.id)).toList();
    return Scaffold(
      appBar: AppBar(title: Text(baseName(path), overflow: TextOverflow.ellipsis)),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          FilledButton.icon(
            onPressed: busy ? null : () => s.analyze(path),
            icon: busy
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.analytics),
            label: Text(res == null ? 'Analyze tempo' : 'Re-analyze'),
          ),
          if (res != null) const Text('Saved to .bpm file'),
          OutlinedButton.icon(
            onPressed: s.fetching.contains(path) ? null : () => s.fetchMedia(path),
            icon: s.fetching.contains(path)
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.lyrics_outlined),
            label: const Text('Fetch art & lyrics'),
          ),
        ]),
        if (s.enrichNote != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(s.enrichNote!, style: theme.textTheme.bodySmall),
          ),
        if (s.error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(s.error!, style: TextStyle(color: theme.colorScheme.error)),
          ),
        const SizedBox(height: 16),
        if (res == null)
          const Text('Not analyzed yet.')
        else ...[
          Text('Length ${fmtTime(res.durationSec)} · the starred algorithm drives the library and Now Playing',
              style: theme.textTheme.bodyMedium),
          if (!s.isComplete(res))
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text('Older .bpm file: re-analyze to compare all algorithms.'),
            ),
          const SizedBox(height: 12),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columnSpacing: 16,
              dataRowMinHeight: 36,
              dataRowMaxHeight: 36,
              columns: const [
                DataColumn(label: Text('Algorithm')),
                DataColumn(label: Text('Median'), numeric: true),
                DataColumn(label: Text('Avg'), numeric: true),
                DataColumn(label: Text('Tempos'), numeric: true),
                DataColumn(label: Text('First'), numeric: true),
              ],
              rows: [
                for (final a in shown)
                  DataRow(
                    selected: s.algorithm == a.id,
                    onSelectChanged: (_) => s.setAlgorithm(a.id),
                    cells: [
                      DataCell(Text('${s.algorithm == a.id ? '★ ' : ''}${a.name}')),
                      DataCell(Text(_f(res.byAlgo[a.id]!.medianBpm))),
                      DataCell(Text(_f(res.byAlgo[a.id]!.averageBpm))),
                      DataCell(Text('${res.byAlgo[a.id]!.segments.length}')),
                      DataCell(Text(_f(res.byAlgo[a.id]!.firstBpm))),
                    ],
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          for (final a in shown) _AlgoCard(algo: a, map: res.byAlgo[a.id]!),
        ],
      ]),
    );
  }

  static String _f(double? v) => v == null ? '—' : v.toStringAsFixed(1);
}

class _AlgoCard extends StatelessWidget {
  const _AlgoCard({required this.algo, required this.map});
  final TempoAlgorithm algo;
  final TempoMap map;

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final theme = Theme.of(context);
    final chosen = s.algorithm == algo.id;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text('${chosen ? '★ ' : ''}${algo.name}', style: theme.textTheme.titleMedium),
            ),
            if (map.segments.isNotEmpty)
              Text('median ${map.medianBpm!.toStringAsFixed(1)} · avg ${map.averageBpm!.toStringAsFixed(1)}'),
            const SizedBox(width: 8),
            TextButton(
              onPressed: chosen ? null : () => s.setAlgorithm(algo.id),
              child: Text(chosen ? 'In use' : 'Use this'),
            ),
          ]),
          Text(algo.description, style: theme.textTheme.bodySmall),
          const SizedBox(height: 8),
          if (map.segments.isEmpty)
            const Text('No steady tempo detected.')
          else ...[
            TempoGraph(map: map),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text('Segments'),
              children: [
                for (final seg in map.segments)
                  ListTile(
                    dense: true,
                    title: Text('${seg.bpm.toStringAsFixed(1)} BPM'),
                    subtitle: Text('${fmtTime(seg.startSec)} – ${fmtTime(seg.endSec)}'),
                  ),
              ],
            ),
          ],
        ]),
      ),
    );
  }
}
