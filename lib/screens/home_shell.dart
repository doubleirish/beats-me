import 'package:flutter/material.dart';
import 'package:shared_core/screens/mini_player.dart';

import 'library_screen.dart';
import 'mixes_screen.dart';
import 'own_it_screen.dart';
import 'settings_screen.dart';
import 'stats_screen.dart';

/// Root of the app: Mixes / Library / Stats / Settings / Own it? with the mini player
/// above the bar. Back from another tab goes to Mixes before leaving the app.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: _tab == 0,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) setState(() => _tab = 0);
        },
        child: Scaffold(
          body: IndexedStack(index: _tab, children: [
            const MixesScreen(),
            const LibraryScreen(),
            StatsScreen(active: _tab == 2),
            const SettingsScreen(),
            const OwnItScreen(),
          ]),
          bottomNavigationBar: Column(mainAxisSize: MainAxisSize.min, children: [
            const MiniPlayer(),
            NavigationBar(
              selectedIndex: _tab,
              onDestinationSelected: (i) => setState(() => _tab = i),
              destinations: const [
                NavigationDestination(icon: Icon(Icons.library_music_outlined), selectedIcon: Icon(Icons.library_music), label: 'Mixes'),
                NavigationDestination(icon: Icon(Icons.folder_outlined), selectedIcon: Icon(Icons.folder), label: 'Library'),
                NavigationDestination(icon: Icon(Icons.insights_outlined), selectedIcon: Icon(Icons.insights), label: 'Stats'),
                NavigationDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings), label: 'Settings'),
                NavigationDestination(icon: Icon(Icons.fact_check_outlined), selectedIcon: Icon(Icons.fact_check), label: 'Own it?'),
              ],
            ),
          ]),
        ),
      );
}
