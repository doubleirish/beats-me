import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_core/screens/track_art.dart';
import 'package:shared_core/services/artist_art.dart';

import '../services/app_state.dart';

/// Artist photo (online, cached) falling back to album art of one of their songs.
class ArtistAvatar extends StatefulWidget {
  const ArtistAvatar({super.key, required this.artist, required this.samplePath, required this.size});
  final String artist;
  final String samplePath;
  final double size;

  @override
  State<ArtistAvatar> createState() => _ArtistAvatarState();
}

class _ArtistAvatarState extends State<ArtistAvatar> {
  @override
  void initState() {
    super.initState();
    context.read<AppState>().ensureArtistImage(widget.artist);
  }

  @override
  Widget build(BuildContext context) {
    final key = ArtistArt.keyFor(widget.artist);
    final File? photo = context.select<AppState, File?>((s) => s.artistImages[key]);
    if (photo == null) return TrackArt(path: widget.samplePath, size: widget.size);
    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.size / 2),
      child: Image.file(photo,
          width: widget.size,
          height: widget.size,
          fit: BoxFit.cover,
          cacheWidth: (widget.size * 2).round(),
          errorBuilder: (_, _, _) => TrackArt(path: widget.samplePath, size: widget.size)),
    );
  }
}

class _Browse extends StatefulWidget {
  const _Browse({required this.title, required this.builder});
  final String title;
  final Widget Function(BuildContext, String filter, bool bySongs, int hideUpTo) builder;

  @override
  State<_Browse> createState() => _BrowseState();
}

class _BrowseState extends State<_Browse> {
  String filter = '';
  bool bySongs = true;
  int hideUpTo = 0;

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: Column(children: [
        if (s.indexing)
          LinearProgressIndicator(value: s.tracks.isEmpty ? null : s.indexedCount / s.tracks.length),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(children: [
            Expanded(
              child: TextField(
                decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search), hintText: 'Filter by name', isDense: true),
                onChanged: (v) => setState(() => filter = v),
              ),
            ),
            const SizedBox(width: 8),
            SegmentedButton<bool>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: true, label: Text('Most songs')),
                ButtonSegment(value: false, label: Text('Name')),
              ],
              selected: {bySongs},
              onSelectionChanged: (v) => setState(() => bySongs = v.first),
            ),
            const SizedBox(width: 8),
            DropdownButton<int>(
              value: hideUpTo,
              items: const [
                DropdownMenuItem(value: 0, child: Text('Show all')),
                DropdownMenuItem(value: 1, child: Text('Hide ≤1 song')),
                DropdownMenuItem(value: 2, child: Text('Hide ≤2 songs')),
              ],
              onChanged: (v) => setState(() => hideUpTo = v ?? 0),
            ),
          ]),
        ),
        Expanded(child: widget.builder(context, filter, bySongs, hideUpTo)),
      ]),
    );
  }
}

Widget _grid(int count, Widget Function(int) item) => count == 0
    ? const Center(child: Text('Nothing found yet'))
    : GridView.builder(
        padding: const EdgeInsets.all(8),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 180, childAspectRatio: 0.8, crossAxisSpacing: 8, mainAxisSpacing: 8),
        itemCount: count,
        itemBuilder: (_, i) => item(i),
      );

Widget _card(BuildContext context, Widget image, String title, String sub, VoidCallback onTap) =>
    InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: LayoutBuilder(
            builder: (_, c) => Center(child: image))),
        const SizedBox(height: 4),
        Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleSmall),
        Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall),
      ]),
    );

String _n(int n, String one) => '$n $one${n == 1 ? '' : 's'}';

class ArtistsScreen extends StatelessWidget {
  const ArtistsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return _Browse(
      title: 'Artists',
      builder: (context, filter, bySongs, hide) {
        final s = context.watch<AppState>();
        final list = s.library.artists(filter: filter, bySongs: bySongs, hideUpTo: hide);
        return _grid(list.length, (i) {
          final a = list[i];
          return _card(
            context,
            ArtistAvatar(artist: a.name, samplePath: a.tracks.first, size: 128),
            a.name,
            '${_n(a.albums.length, 'album')} · ${_n(a.tracks.length, 'song')}',
            () {
              s.setFilters(artist: a.name, album: '', exact: true);
              Navigator.of(context).popUntil((r) => r.isFirst);
            },
          );
        });
      },
    );
  }
}

class AlbumsScreen extends StatelessWidget {
  const AlbumsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return _Browse(
      title: 'Albums',
      builder: (context, filter, bySongs, hide) {
        final s = context.watch<AppState>();
        final list = s.library.albums(filter: filter, bySongs: bySongs, hideUpTo: hide);
        return _grid(list.length, (i) {
          final a = list[i];
          return _card(
            context,
            TrackArt(path: a.tracks.first, size: 128),
            a.album,
            '${a.artist} · ${_n(a.tracks.length, 'song')}',
            () {
              s.setFilters(artist: a.artist, album: a.album, exact: true);
              Navigator.of(context).popUntil((r) => r.isFirst);
            },
          );
        });
      },
    );
  }
}
