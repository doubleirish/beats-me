import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/album_catalog_store.dart';
import '../services/app_state.dart';

class OwnItScreen extends StatefulWidget {
  const OwnItScreen({super.key, this.store});

  final AlbumCatalogStore? store;

  @override
  State<OwnItScreen> createState() => _OwnItScreenState();
}

class _OwnItScreenState extends State<OwnItScreen> {
  late AlbumCatalogStore _store;
  String _query = '';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _store = widget.store ?? context.read<AppState>().mixtapes.albumCatalog;
    unawaited(_store.load());
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Own it?')),
    body: ListenableBuilder(
      listenable: _store,
      builder: (context, _) {
        final snapshot = _store.snapshot;
        final matches = snapshot?.search(_query);
        final stamp = _store.snapshotTime
            ?.toLocal()
            .toIso8601String()
            .split('.')
            .first
            .replaceFirst('T', ' ');
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: TextField(
                decoration: const InputDecoration(
                  labelText: 'Search artist and album',
                  prefixIcon: Icon(Icons.search),
                  border: OutlineInputBorder(),
                ),
                onChanged: (value) => setState(() => _query = value),
              ),
            ),
            if (_store.error != null)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Text(
                  _store.error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            if (snapshot != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  'Desktop catalogue • ${snapshot.albums.length} albums\n'
                  'Snapshot time: $stamp\nMetadata only; this does not transfer songs.',
                ),
              ),
            Expanded(
              child: !_store.initialized
                  ? const Center(child: CircularProgressIndicator())
                  : snapshot == null
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          'No desktop catalogue synced yet. Send it from analyze-this '
                          'by paired Wi-Fi push or USB, then check the USB inbox.',
                        ),
                      ),
                    )
                  : matches!.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          snapshot.albums.isEmpty
                              ? 'The synced catalogue is empty. This does not prove you own no albums.'
                              : 'No match in the synced catalogue. This does not prove you do not own it.',
                        ),
                      ),
                    )
                  : ListView.builder(
                      itemCount: matches.length,
                      itemBuilder: (context, index) {
                        final album = matches[index];
                        final incomplete =
                            album.incomplete ||
                            (album.total != null && album.have < album.total!);
                        final status = incomplete
                            ? 'Incomplete (missing album)'
                            : album.total == null
                            ? 'In library (total unknown)'
                            : 'Owned';
                        return ListTile(
                          leading: Icon(
                            incomplete
                                ? Icons.warning_amber
                                : Icons.album_outlined,
                          ),
                          title: Text(album.album),
                          subtitle: Text(
                            '${album.artist}\n$status • ${album.have}/${album.total ?? '?'} tracks',
                          ),
                          isThreeLine: true,
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
