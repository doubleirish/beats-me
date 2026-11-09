import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:shared_core/screens/mini_player.dart';
import 'package:shared_core/screens/now_playing_screen.dart';
import 'package:shared_core/screens/rating_bar.dart';
import 'package:shared_core/screens/track_art.dart';
import 'package:shared_core/services/library_service.dart';
import 'package:shared_core/services/queue_service.dart';

import '../services/app_state.dart';
import '../services/library_query.dart';
import 'inspect_screen.dart';
import 'browse_screens.dart';

class LibraryScreen extends StatelessWidget {
  const LibraryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(
        title: Text(s.folder == null ? 'beats-me' : baseName(s.folder!)),
        actions: [
          IconButton(
            tooltip: 'Artists',
            icon: const Icon(Icons.people),
            onPressed: s.tracks.isEmpty
                ? null
                : () => Navigator.push(
                    context, MaterialPageRoute(builder: (_) => const ArtistsScreen())),
          ),
          IconButton(
            tooltip: 'Albums',
            icon: const Icon(Icons.album),
            onPressed: s.tracks.isEmpty
                ? null
                : () => Navigator.push(
                    context, MaterialPageRoute(builder: (_) => const AlbumsScreen())),
          ),
          IconButton(
            tooltip: 'Open folder',
            icon: const Icon(Icons.folder_open),
            onPressed: s.pickFolder,
          ),
          IconButton(
            tooltip: s.currentMix == null ? 'Current mix' : 'Current mix: ${s.currentMix!.name}',
            icon: Icon(s.current != null && s.mixList.contains(s.current)
                ? Icons.equalizer
                : Icons.queue_music),
            onPressed: () => Navigator.push(
                context, MaterialPageRoute(builder: (_) => const MixListScreen())),
          ),
        ],
      ),
      body: Column(children: [
        if (s.enrichRunning)
          ListTile(
            dense: true,
            title: Text(s.enrichCancel
                ? 'Cancelling after current song…'
                : 'Fetching art & lyrics ${s.enrichDone} / ${s.enrichTotal}  '
                    '(${s.enrichOk} ok, ${s.enrichFailed} failed)'),
            subtitle: SizedBox(
              height: 8,
              child: CustomPaint(
                  size: Size.infinite, painter: _EnrichBarPainter(List.of(s.enrichResults))),
            ),
            trailing: TextButton(onPressed: s.cancelEnrich, child: const Text('Cancel')),
          ),
        if (s.enrichNote != null && !s.enrichRunning)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Text(s.enrichNote!, style: Theme.of(context).textTheme.bodySmall),
          ),
        if (s.batchRunning)
          ListTile(
            dense: true,
            title: Text(s.batchCancel
                ? 'Cancelling after current file…'
                : 'Analyzing ${s.batchDone} / ${s.batchTotal}'),
            subtitle: LinearProgressIndicator(value: s.batchDone / s.batchTotal),
            trailing: TextButton(onPressed: s.cancelBatch, child: const Text('Cancel')),
          ),
        if (s.error != null)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(s.error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        if (s.folder != null && s.tracks.isNotEmpty) const _FilterBar(),
        Expanded(
          child: s.folder == null
              ? const Center(child: Text('Open a folder of music files (mp3, m4a, wma) to begin'))
              : s.tracks.isEmpty
                  ? const Center(child: Text('No music files in this folder'))
                  : s.shown.isEmpty
                      ? Center(
                          child: Text(s.indexing
                              ? 'Reading tags… ${s.indexedCount} / ${s.tracks.length}'
                              : s.query.active
                                  ? 'No songs match your search and filters'
                                  : 'No songs found'))
                      : ListView.builder(
                          itemCount: s.shown.length,
                          itemBuilder: (_, i) => _TrackTile(path: s.shown[i]),
                        ),
        ),
      ]),
    );
  }
}

class _FilterBar extends StatefulWidget {
  const _FilterBar();

  @override
  State<_FilterBar> createState() => _FilterBarState();
}

class _FilterBarState extends State<_FilterBar> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final q = s.query;
    // keep the field in step with changes made elsewhere (e.g. opening a folder)
    if (_search.text != q.text) _search.text = q.text;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 4, 4),
      child: Column(children: [
        Row(children: [
          Expanded(
            child: TextField(
              controller: _search,
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search),
                hintText: 'Search songs, artists, albums',
                border: const OutlineInputBorder(),
                suffixIcon: q.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Clear search',
                        icon: const Icon(Icons.clear),
                        onPressed: () => s.updateQuery((q) => q.text = ''),
                      ),
              ),
              onChanged: (v) => s.updateQuery((q) => q.text = v),
            ),
          ),
          PopupMenuButton<TrackSort>(
            tooltip: 'Sort: ${q.sort.label}',
            icon: const Icon(Icons.sort),
            initialValue: q.sort,
            onSelected: (v) => s.updateQuery((q) => q.sort = v),
            itemBuilder: (_) => [
              for (final o in TrackSort.values)
                CheckedPopupMenuItem(value: o, checked: o == q.sort, child: Text(o.label)),
            ],
          ),
          IconButton(
            tooltip: 'Filters',
            icon: Badge(
              isLabelVisible: q.filterCount > 0,
              label: Text('${q.filterCount}'),
              child: const Icon(Icons.filter_list),
            ),
            onPressed: () => showModalBottomSheet<void>(
              context: context,
              isScrollControlled: true,
              builder: (_) => const _FilterSheet(),
            ),
          ),
          PopupMenuButton<String>(
            tooltip: 'Library tools',
            onSelected: (v) => v == 'enrich' ? s.enrichAll() : s.analyzeAll(),
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'enrich',
                enabled: !s.enrichRunning,
                child: const ListTile(
                    leading: Icon(Icons.image_search), title: Text('Fetch art & lyrics')),
              ),
              PopupMenuItem(
                value: 'analyze',
                enabled: !s.batchRunning,
                child: const ListTile(
                    leading: Icon(Icons.auto_graph), title: Text('Analyze all songs')),
              ),
            ],
          ),
        ]),
        if (q.artist.isNotEmpty || q.album.isNotEmpty)
          Align(
            alignment: Alignment.centerLeft,
            child: Wrap(spacing: 8, children: [
              if (q.artist.isNotEmpty)
                InputChip(
                  label: Text('Artist: ${q.artist}'),
                  onDeleted: () => s.updateQuery((q) => q.artist = ''),
                ),
              if (q.album.isNotEmpty)
                InputChip(
                  label: Text('Album: ${q.album}'),
                  onDeleted: () => s.updateQuery((q) => q.album = ''),
                ),
            ]),
          ),
      ]),
    );
  }
}

/// BPM range, minimum rating and favourites-only filters.
class _FilterSheet extends StatelessWidget {
  const _FilterSheet();

  static const _lo = 40.0, _hi = 220.0;

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final q = s.query;
    final range = RangeValues(
      (q.bpmMin ?? 100).clamp(_lo, _hi).toDouble(),
      (q.bpmMax ?? 140).clamp(_lo, _hi).toDouble(),
    );
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text('Filters', style: Theme.of(context).textTheme.titleLarge),
            const Spacer(),
            TextButton(
              onPressed: q.filterCount == 0 ? null : s.clearFilters,
              child: const Text('Clear all'),
            ),
          ]),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(q.hasBpmRange
                ? 'BPM ${q.bpmMin!.round()}–${q.bpmMax!.round()}'
                : 'Filter by BPM'),
            value: q.hasBpmRange,
            onChanged: (on) => s.updateQuery((q) {
              q.bpmMin = on ? range.start.roundToDouble() : null;
              q.bpmMax = on ? range.end.roundToDouble() : null;
            }),
          ),
          if (q.hasBpmRange) ...[
            RangeSlider(
              min: _lo,
              max: _hi,
              divisions: (_hi - _lo).round() ~/ 2,
              values: range,
              labels: RangeLabels('${range.start.round()}', '${range.end.round()}'),
              onChanged: (v) => s.updateQuery((q) {
                q.bpmMin = v.start.roundToDouble();
                q.bpmMax = v.end.roundToDouble();
              }),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('Include songs not analyzed yet'),
              value: q.includeUnanalyzed,
              onChanged: (v) => s.updateQuery((q) => q.includeUnanalyzed = v ?? true),
            ),
          ],
          const SizedBox(height: 8),
          const Text('Minimum rating'),
          const SizedBox(height: 4),
          Wrap(spacing: 8, children: [
            for (var n = 0; n <= 5; n++)
              ChoiceChip(
                label: Text(n == 0 ? 'Any' : '$n★${n < 5 ? '+' : ''}'),
                selected: q.minStars == n,
                onSelected: (_) => s.updateQuery((q) => q.minStars = n),
              ),
          ]),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Favourites only'),
            value: q.favOnly,
            onChanged: (v) => s.updateQuery((q) => q.favOnly = v),
          ),
        ]),
      ),
    );
  }
}

class _TrackTile extends StatelessWidget {
  const _TrackTile({required this.path});
  final String path;

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final tm = s.mapOf(path);
    final busy = s.analyzing.contains(path);
    return ListTile(
      leading: busy
          ? const SizedBox(width: 48, height: 48, child: Center(child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))))
          : TrackArt(path: path, size: 48),
      title: Text(relativeName(path, s.folder), maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text((tm == null
              ? 'Not analyzed'
              : tm.segments.isEmpty
                  ? 'No tempo found'
                  : '${tm.medianBpm!.toStringAsFixed(0)} BPM median'
                      '${tm.segments.length > 1 ? ' · ${tm.segments.length} tempos' : ''}'
                      '${s.isComplete(s.tempos[path]) ? '' : ' · baseline only'}') +
          (s.media[path]?.lyrics == null ? '' : ' · lyrics') +
          ratingLabel(s, path)),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        IconButton(
          tooltip: 'Inspect',
          icon: const Icon(Icons.analytics_outlined),
          onPressed: () => Navigator.push(context,
              MaterialPageRoute(builder: (_) => InspectScreen(path: path))),
        ),
        IconButton(
          tooltip: s.mixList.contains(path) ? 'Remove from mix' : 'Add to mix',
          icon: Icon(s.mixList.contains(path) ? Icons.playlist_add_check : Icons.playlist_add),
          onPressed: () => s.toggleMix(path),
        ),
      ]),
      onTap: () {
        s.play(path);
        Navigator.push(context, MaterialPageRoute(builder: (_) => const NowPlayingScreen()));
      },
      onLongPress: () => showRateSheet(context, s, path),
    );
  }
}

/// " · ★★★ · ♥" for a rated/favourite song, else empty.
String ratingLabel(AppState s, String path) {
  final r = s.ratingOf(path);
  return '${r > 0 ? ' · ${'★' * r}' : ''}${s.favOf(path) ? ' · ♥' : ''}';
}

/// Bottom sheet with "Rate…" (stars dialog) and a favourite toggle for [path].
Future<void> showRateSheet(BuildContext context, AppState s, String path) =>
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            title: Text(baseName(path), maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(ratingLabel(s, path).replaceFirst(' · ', '')),
          ),
          ListTile(
            leading: const Icon(Icons.star_outline),
            title: const Text('Rate…'),
            onTap: () async {
              Navigator.pop(ctx);
              final r = await showRatingDialog(context,
                  title: baseName(path), initial: s.ratingOf(path));
              if (r != null) await s.setRatingFor(path, rating: r);
            },
          ),
          ListTile(
            leading: Icon(s.favOf(path) ? Icons.favorite : Icons.favorite_border),
            title: Text(s.favOf(path) ? 'Remove favourite' : 'Favourite'),
            onTap: () {
              Navigator.pop(ctx);
              s.setRatingFor(path, fav: !s.favOf(path));
            },
          ),
        ]),
      ),
    );

/// Asks for a name and whether to overwrite the loaded mix or save a new
/// one, then writes the mix list as a playlist.
Future<void> _saveMix(BuildContext context, AppState s) async {
  final messenger = ScaffoldMessenger.of(context);
  final canOverwrite = s.mixSource != null && File(s.mixSource!).existsSync();
  final imported = canOverwrite && await s.sourceIsImported();
  if (!context.mounted) return;
  final name = TextEditingController(
      text: s.mixSource == null ? 'My mix' : p.basenameWithoutExtension(s.mixSource!));
  var overwrite = canOverwrite;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: const Text('Save mix'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (canOverwrite)
            RadioGroup<bool>(
              groupValue: overwrite,
              onChanged: (v) => setState(() => overwrite = v ?? true),
              child: Column(children: [
                RadioListTile<bool>(
                  contentPadding: EdgeInsets.zero,
                  value: true,
                  title: Text('Overwrite "${p.basenameWithoutExtension(s.mixSource!)}"'),
                  subtitle: imported
                      ? const Text('Imported from your PC: importing it again may replace your changes.')
                      : null,
                ),
                const RadioListTile<bool>(
                    contentPadding: EdgeInsets.zero, value: false, title: Text('Save as new mix')),
              ]),
            ),
          if (!overwrite)
            TextField(
              controller: name,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Mix name'),
            ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
        ],
      ),
    ),
  );
  final chosen = name.text;
  name.dispose();
  if (ok != true) return;
  try {
    if (!overwrite && await (await s.savedMixFile(chosen)).exists()) {
      if (!context.mounted) return;
      final replace = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('Replace "${AppState.safeMixName(chosen)}"?'),
          content: const Text('A saved mix with that name already exists.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Replace')),
          ],
        ),
      );
      if (replace != true) return;
    }
    final m = await s.saveMix(chosen, overwrite: overwrite);
    messenger.showSnackBar(SnackBar(content: Text('Saved "${m.name}" (${m.trackCount} songs)')));
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Could not save the mix: $e')));
  }
}

class MixListScreen extends StatelessWidget {
  const MixListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(title: Text(s.mixTitle ?? 'Mix list'), actions: [
        IconButton(
          tooltip: 'Save mix as .m3u8',
          icon: const Icon(Icons.save_outlined),
          onPressed: s.mixList.isEmpty ? null : () => _saveMix(context, s),
        ),
        IconButton(
          tooltip: 'Import .m3u8 mix (replaces list)',
          icon: const Icon(Icons.file_open),
          onPressed: () async {
            final messenger = ScaffoldMessenger.of(context);
            final picked = await FilePicker.pickFiles(
                type: FileType.custom, allowedExtensions: ['m3u8', 'm3u']);
            final path = picked.isEmpty ? null : picked.first.path;
            if (path == null) return;
            try {
              final skipped = await s.importMix(path);
              messenger.showSnackBar(SnackBar(
                  content: Text(skipped == 0
                      ? 'Imported ${s.mixList.length} songs'
                      : 'Imported ${s.mixList.length} songs, $skipped missing files skipped')));
            } catch (e) {
              messenger.showSnackBar(SnackBar(content: Text('Import failed: $e')));
            }
          },
        ),
      ]),
      body: s.mixList.isEmpty
          ? const Center(child: Text('Add songs with the playlist button in the library'))
          : Column(children: [
              if (s.currentMix != null)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.queue_music),
                  title: Text(s.currentMix!.details),
                  trailing: FilledButton.icon(
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Play'),
                    onPressed: () async {
                      final nav = Navigator.of(context);
                      await s.playMix();
                      nav.push(MaterialPageRoute(builder: (_) => const NowPlayingScreen()));
                    },
                  ),
                ),
              Expanded(
                child: ReorderableListView.builder(
                  itemCount: s.mixList.length,
                  onReorderItem: (o, n) => s.reorderMix(o, n > o ? n + 1 : n),
                  itemBuilder: (_, i) {
                    final path = s.mixList[i];
                    final playing = path == s.current;
                    return ListTile(
                      key: ValueKey(path),
                      leading: playing ? const Icon(Icons.equalizer) : null,
                      title: Row(children: [
                        Expanded(
                            flex: 3,
                            child: Text(baseName(path), maxLines: 2, overflow: TextOverflow.ellipsis)),
                        const SizedBox(width: 8),
                        Expanded(flex: 2, child: SongActivity(path: path)),
                      ]),
                      selected: playing,
                      subtitle: ratingLabel(s, path).isEmpty
                          ? null
                          : Text(ratingLabel(s, path).replaceFirst(' · ', '')),
                      onTap: () async {
                        final nav = Navigator.of(context);
                        if (!playing) {
                          s.setMode(PlayMode.mix);
                          await s.play(path);
                        }
                        nav.push(MaterialPageRoute(builder: (_) => const NowPlayingScreen()));
                      },
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        IconButton(
                          tooltip: 'Rate / favourite',
                          icon: Icon(s.favOf(path) ? Icons.favorite : Icons.star_outline),
                          onPressed: () => showRateSheet(context, s, path),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () => s.toggleMix(path),
                        ),
                      ]),
                    );
                  },
                ),
              ),
            ]),
      bottomNavigationBar: const MiniPlayer(),
    );
  }
}

class _EnrichBarPainter extends CustomPainter {
  _EnrichBarPainter(this.results);
  final List<bool?> results;

  @override
  void paint(Canvas canvas, Size size) {
    final n = results.length;
    if (n == 0) return;
    final bg = Paint()..color = Colors.grey.withValues(alpha: 0.3);
    canvas.drawRect(Offset.zero & size, bg);
    final w = size.width / n;
    for (var i = 0; i < n; i++) {
      final r = results[i];
      if (r == null) continue;
      final p = Paint()..color = r ? Colors.green : Colors.red;
      canvas.drawRect(Rect.fromLTWH(i * w, 0, w < 1 ? 1 : w, size.height), p);
    }
  }

  @override
  bool shouldRepaint(_EnrichBarPainter old) => true;
}
