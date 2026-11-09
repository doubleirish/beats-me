import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:provider/provider.dart';
import 'package:shared_core/services/mixtape/http_transport.dart';
import 'package:shared_core/services/playback_controller.dart';

import 'nav.dart';
import 'screens/home_shell.dart';
import 'screens/mixtape_screen.dart';
import 'services/app_state.dart';
import 'services/media_session.dart';
import 'services/theme_settings.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  JustAudioMediaKit.ensureInitialized(
      linux: false, windows: true, android: false, iOS: false, macOS: false);
  final state = AppState();
  _wireMixtapes(state);
  unawaited(state.init().then((_) => state.mixtapes.init()));
  if (Platform.isAndroid) {
    await AudioService.init(
      builder: () => BeatsAudioHandler(state),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.beatsme.beats_me.playback',
        androidNotificationChannelName: 'beats-me playback',
        androidNotificationOngoing: true,
      ),
    );
  }
  final themeSettings = ThemeSettings();
  unawaited(themeSettings.load());
  runApp(MultiProvider(providers: [
    ChangeNotifierProvider<AppState>.value(value: state),
    ChangeNotifierProvider<PlaybackController>.value(value: state),
    ChangeNotifierProvider<ThemeSettings>.value(value: themeSettings),
  ], child: BeatsMeApp(state: state)));
}

/// Lets the mixtape importer show the Import screen, pairing prompts and
/// notices from anywhere (QR links, opened files, USB sends).
void _wireMixtapes(AppState state) {
  final c = state.mixtapes;
  c.showImportScreen = () {
    if (MixtapeScreen.isOpen) return;
    navigatorKey.currentState?.push(MaterialPageRoute(builder: (_) => const MixtapeScreen()));
  };
  c.notify = (m) {
    if (!MixtapeScreen.isOpen) toast(m);
  };
  c.confirmPair = (PairRequest req) async {
    final ctx = navigatorKey.currentContext;
    if (ctx == null) return false;
    final ok = await showDialog<bool>(
      context: ctx,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text('Allow ${req.name}?'),
        content: Text('${req.name} wants to send mixes to this phone.\n\n'
            'Only allow it if the PC shows this code:\n\n${req.code}'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Deny')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Allow')),
        ],
      ),
    ).timeout(const Duration(seconds: 85), onTimeout: () {
      navigatorKey.currentState?.maybePop();
      return false;
    });
    return ok ?? false;
  };
}

class BeatsMeApp extends StatefulWidget {
  const BeatsMeApp({super.key, required this.state});
  final AppState state;

  @override
  State<BeatsMeApp> createState() => _BeatsMeAppState();
}

class _BeatsMeAppState extends State<BeatsMeApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) unawaited(widget.state.mixtapes.onResume());
    if (s == AppLifecycleState.paused) unawaited(widget.state.mixtapes.onPause());
  }

  @override
  Widget build(BuildContext context) {
    final t = context.watch<ThemeSettings>();
    return MaterialApp(
      title: 'beats-me',
      navigatorKey: navigatorKey,
      scaffoldMessengerKey: messengerKey,
      debugShowCheckedModeBanner: false,
      theme: t.themeFor(Brightness.light),
      darkTheme: t.themeFor(Brightness.dark),
      themeMode: t.mode,
      home: const HomeShell(),
    );
  }
}
