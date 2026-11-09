import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_core/screens/explicit_badge.dart';
import 'package:shared_core/screens/mix_icon.dart';
import 'package:shared_core/services/mix_icon_spec.dart';
import 'package:shared_core/screens/step_icon.dart';
import 'package:shared_core/screens/now_playing_screen.dart';

import '../services/app_state.dart';
import '../services/mixes.dart';
import '../services/system_channel.dart';
import 'library_screen.dart';
import 'mixtape_screen.dart';

/// Compact summary of a mix's activities: icon and name with how many songs.
class _ActivitySummary extends StatelessWidget {
  const _ActivitySummary(this.activities);
  final List<MixActivity> activities;

  @override
  Widget build(BuildContext context) {
    if (activities.isEmpty) return const SizedBox.shrink();
    final style = Theme.of(context).textTheme.bodySmall;
    return Wrap(
      spacing: 8,
      runSpacing: 2,
      children: [
        for (final a in activities)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(iconForKey(a.icon, fallbackName: a.name), size: 14),
              const SizedBox(width: 2),
              Text(a.songs > 1 ? '${a.name} ×${a.songs}' : a.name, style: style),
            ],
          ),
      ],
    );
  }
}

/// Top-level list of installed mixtapes by name (each a `.m3u8` plus its
/// songs). Picking one loads it into the Mix list, which shows the songs.
class MixesScreen extends StatefulWidget {
  const MixesScreen({super.key});

  @override
  State<MixesScreen> createState() => _MixesScreenState();
}

class _MixesScreenState extends State<MixesScreen> {
  late final AppState _app;
  List<MixSummary>? _mixes;
  Object? _error;
  int _loadId = 0;
  int _version = 0;
  int? _free;
  String _query = '';
  MixSort _sort = MixSort.imported;
  final _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    _app = context.read<AppState>();
    _sort = MixSort.parse(_app.mixesSort);
    _app.addListener(_onApp);
    _load();
  }

  @override
  void dispose() {
    _app.removeListener(_onApp);
    _search.dispose();
    super.dispose();
  }

  /// Reloads when mixes were imported, deleted or the folder changed.
  void _onApp() {
    if (_app.mixesVersion != _version) _load();
  }

  Future<void> _load({bool force = false}) async {
    final id = ++_loadId;
    _version = _app.mixesVersion;
    try {
      final mixes = await _app.listMixes(force: force);
      final free = await SystemChannel.freeBytes((await _app.mixtapeRoot()).path);
      if (!mounted || id != _loadId) return;
      setState(() {
        _mixes = mixes;
        _free = free;
        _error = null;
      });
    } catch (e) {
      if (!mounted || id != _loadId) return;
      setState(() => _error = e);
    }
  }

  void _setSort(MixSort s) {
    setState(() => _sort = s);
    _app.mixesSort = s.name;
  }

  Future<void> _open(MixSummary m) async {
    final s = context.read<AppState>();
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await s.importMix(m.file);
      if (s.mixList.isEmpty) {
        messenger.showSnackBar(SnackBar(content: Text('"${m.name}" has no playable songs')));
        return;
      }
      await s.playMix();
      await s.noteMixPlayed(m.file);
      if (mounted) setState(() => m.lastPlayed = DateTime.now());
      navigator.push(MaterialPageRoute(builder: (_) => const NowPlayingScreen()));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not play "${m.name}": $e')));
    }
  }

  Future<void> _songs(MixSummary m) async {
    final s = context.read<AppState>();
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await s.importMix(m.file);
      navigator.push(MaterialPageRoute(builder: (_) => const MixListScreen()));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not load "${m.name}": $e')));
    }
  }

  Future<void> _check(MixSummary m) async {
    final s = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(SnackBar(content: Text('Checking ""…')));
    try {
      final bad = await s.checkMixAudio(m);
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(
          content: Text(bad == 0
              ? 'All songs in "" look fine'
              : ' song in "" look damaged. Replace them on the PC and resend.')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not check "": ')));
    }
  }

  Future<void> _delete(MixSummary m) async {
    final s = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Delete "${m.name}"?'),
        content: const Text('This removes the mix and its downloaded songs from this phone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await s.deleteMix(m);
      messenger.showSnackBar(SnackBar(content: Text('Deleted "${m.name}"')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not delete "${m.name}": $e')));
    }
    // deleteMix bumps mixesVersion, which reloads the list.
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Mixes'),
        actions: [
          ListenableBuilder(
            listenable: s.mixtapes,
            builder: (context, _) => IconButton(
            tooltip: s.mixtapes.receiving
                ? 'Import mixes from PC (ready to receive)'
                : 'Import mixes from PC',
            icon: Badge(
              isLabelVisible: s.mixtapes.receiving,
              smallSize: 8,
              child: const Icon(Icons.download),
            ),
            onPressed: () =>
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const MixtapeScreen()),
                ).then((_) {
                  if (mounted && _app.mixesVersion != _version) _load();
                }),
            ),
          ),
          IconButton(
            tooltip: 'Now playing',
            icon: const Icon(Icons.equalizer),
            onPressed: s.current == null
                ? null
                : () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const NowPlayingScreen()),
                  ),
          ),
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: () => _load(force: true),
          ),
        ],
      ),
      body: Builder(
        builder: (context) {
          if (_error != null) {
            return Center(child: Text('Could not list mixes: $_error'));
          }
          if (_mixes == null) return const Center(child: CircularProgressIndicator());
          final all = _mixes!;
          if (all.isEmpty) {
            return const Center(
              child: Text('No mixes yet. Tap the download button above to import one from your PC.'),
            );
          }
          final mixes = sortMixes(filterMixes(all, _query), _sort);
          final used = all.fold<int>(0, (t, m) => t + (m.sizeBytes ?? 0));
          final small = Theme.of(context).textTheme.bodySmall;
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 4, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _search,
                        decoration: InputDecoration(
                          isDense: true,
                          prefixIcon: const Icon(Icons.search),
                          hintText: 'Search mixes',
                          border: const OutlineInputBorder(),
                          suffixIcon: _query.isEmpty
                              ? null
                              : IconButton(
                                  tooltip: 'Clear',
                                  icon: const Icon(Icons.clear),
                                  onPressed: () {
                                    _search.clear();
                                    setState(() => _query = '');
                                  },
                                ),
                        ),
                        onChanged: (v) => setState(() => _query = v),
                      ),
                    ),
                    PopupMenuButton<MixSort>(
                      tooltip: 'Sort: ${_sort.label}',
                      icon: const Icon(Icons.sort),
                      initialValue: _sort,
                      onSelected: _setSort,
                      itemBuilder: (_) => [
                        for (final o in MixSort.values)
                          CheckedPopupMenuItem(value: o, checked: o == _sort, child: Text(o.label)),
                      ],
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 2),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    [
                      '${all.length} mix${all.length == 1 ? '' : 'es'} · ${formatBytes(used)} used',
                      if (_free != null) '${formatBytes(_free!)} free',
                    ].join(' · '),
                    style: small,
                  ),
                ),
              ),
              Expanded(
                child: mixes.isEmpty
                    ? const Center(child: Text('No mixes match your search.'))
                    : ListView.builder(
                        itemCount: mixes.length,
                        itemBuilder: (_, i) {
                          final m = mixes[i];
                          final running = s.currentMix?.file == m.file && s.current != null;
                          final extra = [
                            if (m.sizeBytes != null) formatBytes(m.sizeBytes!),
                            m.lastPlayed == null
                                ? 'never played'
                                : 'played ${playedLabel(m.lastPlayed!)}',
                          ].join(' · ');
                          return StreamBuilder<bool>(
                            stream: s.player.playingStream,
                            initialData: s.player.playing,
                            builder: (context, snap) {
                              final playing = running && snap.data == true;
                              return ListTile(
                                selected: running,
                                selectedTileColor: Theme.of(context).colorScheme.primaryContainer
                                    .withValues(alpha: 0.5),
                                leading: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    MixIcon(spec: MixIconSpec.decode(m.icon), artPaths: m.artPaths, size: 40),
                                    const SizedBox(width: 8),
                                    Badge(
                                  label: const Icon(Icons.broken_image_outlined, size: 10),
                                  child: IconButton.filled(
                                    tooltip: playing ? 'Pause ${m.name}' : 'Play ${m.name}',
                                    icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                                    onPressed: running
                                        ? () => playing ? s.player.pause() : s.player.play()
                                        : () => _open(m),
                                  ),
                                ),
                                  ],
                                ),
                                title: Row(
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  children: [
                                    Expanded(
                                      flex: 3,
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Row(children: [
                                            Flexible(
                                              child: Text(
                                                m.name,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                            if (m.explicit > 0) ...[
                                              const SizedBox(width: 6),
                                              const ExplicitBadge(size: 14),
                                            ],
                                          ]),
                                          Text(
                                            m.details,
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                            style: Theme.of(context).textTheme.bodySmall,
                                          ),
                                          Text(
                                            extra,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: Theme.of(context).textTheme.bodySmall,
                                          ),
                                          if (m.damaged > 0)
                                            Text(
                                              '${m.damaged} damaged song${m.damaged == 1 ? '' : 's'}: may skip; replace on the PC',
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                                  color: Theme.of(context).colorScheme.error),
                                            ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(flex: 2, child: _ActivitySummary(m.activities)),
                                  ],
                                ),
                                trailing: PopupMenuButton<String>(
                                  tooltip: 'More',
                                  onSelected: (v) => v == 'check' ? _check(m) : _delete(m),
                                  itemBuilder: (_) => const [
                                    PopupMenuItem(
                                        value: 'check',
                                        child: ListTile(
                                            leading: Icon(Icons.healing),
                                            title: Text('Check songs for damage'))),
                                    PopupMenuItem(
                                        value: 'delete',
                                        child: ListTile(
                                            leading: Icon(Icons.delete_outline), title: Text('Delete mix'))),
                                  ],
                                ),
                                onTap: () => _songs(m),
                              );
                            },
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}
