import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_core/shared_core.dart';

import '../services/app_state.dart';
import '../services/theme_settings.dart';

/// Appearance, playback, import and library options in one place.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = context.watch<ThemeSettings>();
    final app = context.watch<AppState>();
    final mixtapes = app.mixtapes;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(children: [
        const _Header('Appearance'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SegmentedButton<ThemeMode>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: ThemeMode.system, icon: Icon(Icons.brightness_auto), label: Text('System')),
              ButtonSegment(value: ThemeMode.light, icon: Icon(Icons.light_mode), label: Text('Light')),
              ButtonSegment(value: ThemeMode.dark, icon: Icon(Icons.dark_mode), label: Text('Dark')),
            ],
            selected: {theme.mode},
            onSelectionChanged: (v) => theme.setMode(v.first),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Wrap(spacing: 12, runSpacing: 12, children: [
            for (final e in ThemeSettings.accents.entries)
              Tooltip(
                message: e.key,
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () => theme.setAccent(e.key),
                  child: CircleAvatar(
                    radius: 18,
                    backgroundColor: e.value,
                    child: theme.accent == e.key
                        ? const Icon(Icons.check, color: Colors.white)
                        : null,
                  ),
                ),
              ),
          ]),
        ),
        const _Header('Playback'),
        const Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: PlaybackSettingsPanel()),
        const _Header('Import from PC'),
        ListenableBuilder(
          listenable: mixtapes,
          builder: (context, _) => Column(children: [
            SwitchListTile(
              value: mixtapes.autoReceive,
              onChanged: mixtapes.setAutoReceive,
              title: const Text('Receive mixes while beats-me is open'),
              subtitle: const Text('Only PCs you have trusted can send.'),
            ),
            if (mixtapes.trusted.isEmpty)
              const ListTile(title: Text('No trusted PCs yet'), subtitle: Text('Pair one from the Import screen.')),
            for (final t in mixtapes.trusted)
              ListTile(
                leading: const Icon(Icons.computer),
                title: Text(t.name),
                trailing: IconButton(
                  tooltip: 'Forget ${t.name}',
                  icon: const Icon(Icons.link_off),
                  onPressed: () => mixtapes.forgetPc(t.id),
                ),
              ),
          ]),
        ),
        const _Header('Library'),
        ListTile(
          leading: const Icon(Icons.folder_open),
          title: const Text('Music folder'),
          subtitle: Text(app.folder ?? 'Not chosen'),
          onTap: app.pickFolder,
        ),
        const SizedBox(height: 24),
      ]),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
        child: Text(text, style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
            )),
      );
}
