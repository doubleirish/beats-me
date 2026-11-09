import 'dart:convert';
import 'dart:io';

import 'package:beats_me/services/app_state.dart';
import 'package:beats_me/services/auto_receive.dart';
import 'package:beats_me/services/mixtape_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_core/shared_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

ReceiveAction _decide({
  bool? setting,
  int trusted = 1,
  bool foreground = true,
  bool held = false,
  bool receiving = false,
  bool transferring = false,
}) =>
    AutoReceive.decide(
      setting: setting,
      trustedCount: trusted,
      foreground: foreground,
      held: held,
      receiving: receiving,
      transferring: transferring,
    );

void main() {
  group('AutoReceive rules', () {
    test('unset setting is on only once a PC is trusted', () {
      expect(AutoReceive.enabled(trustedCount: 0), isFalse);
      expect(AutoReceive.enabled(trustedCount: 1), isTrue);
      expect(_decide(trusted: 0), ReceiveAction.keep);
      expect(_decide(trusted: 2), ReceiveAction.start);
    });

    test('an explicit choice wins, but nothing starts without a trusted PC', () {
      expect(AutoReceive.enabled(setting: false, trustedCount: 3), isFalse);
      expect(_decide(setting: false, trusted: 3), ReceiveAction.keep);
      expect(AutoReceive.enabled(setting: true, trustedCount: 0), isTrue);
      expect(_decide(setting: true, trusted: 0), ReceiveAction.keep);
    });

    test('starts only in the foreground and never twice', () {
      expect(_decide(foreground: false), ReceiveAction.keep);
      expect(_decide(receiving: true), ReceiveAction.keep);
    });

    test('going to the background stops an idle auto-receive but not a transfer', () {
      expect(_decide(foreground: false, receiving: true), ReceiveAction.stop);
      expect(_decide(foreground: false, receiving: true, transferring: true), ReceiveAction.keep);
    });

    test('the Import screen keeps receiving whatever the setting or app state', () {
      expect(_decide(setting: false, foreground: false, held: true, receiving: true), ReceiveAction.keep);
      expect(_decide(trusted: 0, held: true, receiving: true), ReceiveAction.keep);
    });

    test('switching off or forgetting the last PC stops receiving once idle', () {
      expect(_decide(setting: false, receiving: true), ReceiveAction.stop);
      expect(_decide(setting: false, receiving: true, transferring: true), ReceiveAction.keep);
      expect(_decide(trusted: 0, receiving: true), ReceiveAction.stop);
    });
  });

  group('MixtapeController auto-receive over localhost', () {
    late Directory tmp;
    late MixtapeController c;

    setUpAll(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      // The test binding fakes HttpClient; these tests talk to a real server.
      HttpOverrides.global = null;
    });

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('beats_me_auto_');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'), (_) async => tmp.path);
      SharedPreferences.setMockInitialValues({
        'trusted_pcs': jsonEncode([
          {'id': 'pc1', 'name': 'Studio PC', 'token': 'trusted-token'}
        ]),
      });
      final app = AppState()..folder = tmp.path;
      c = app.mixtapes;
      await c.init();
      for (var i = 0; i < 200 && !c.receiving; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });

    tearDown(() async {
      await c.stopReceiving();
      await tmp.delete(recursive: true);
    });

    Uri base() => Uri.parse('http://127.0.0.1:${c.receiver!.port}');
    bool isKind(Object? e, TransferError k) => e is TransferException && e.kind == k;

    test('starts by itself for trusted PCs only; new PCs need the Import screen', () async {
      expect(c.autoReceive, isTrue);
      expect(c.autoReceiving, isTrue);
      expect((await PushSender(base(), 'trusted-token').hello()).name, c.deviceName);
      await expectLater(PushSender(base(), c.receiver!.token).hello(),
          throwsA(predicate((e) => isKind(e, TransferError.auth))));

      c.confirmPair = (_) async => true;
      await expectLater(PushSender.pair(base(), pcName: 'New PC', pcId: 'pc2', code: '111111'),
          throwsA(predicate((e) => isKind(e, TransferError.declined) && '$e'.contains('Get mixes from PC'))));
      expect(c.trusted, hasLength(1));
      expect(c.log.first, contains('New PC'));

      // Opening the Import screen allows the on-screen code and pairing.
      await c.startReceiving();
      expect(c.autoReceiving, isFalse);
      await PushSender(base(), c.receiver!.token).hello();
      final paired = await PushSender.pair(base(), pcName: 'New PC', pcId: 'pc2', code: '111111');
      expect(c.trusted.map((t) => t.token), contains(paired.token));
    });

    test('pause stops it unless the Import screen is open or a transfer runs', () async {
      await c.onPause();
      expect(c.receiving, isFalse);
      await c.onResume();
      expect(c.autoReceiving, isTrue);

      c.busy = 'Receiving "Gym"';
      await c.onPause();
      expect(c.receiving, isTrue);
      c.busy = null;
      await c.onPause();
      expect(c.receiving, isFalse);

      await c.onResume();
      await c.startReceiving();
      await c.onPause();
      expect(c.receiving, isTrue, reason: 'the Import screen holds it open');
      await c.releaseReceiving();
      expect(c.receiving, isFalse);
    });

    test('closing the Import screen keeps auto-receive running, without the code', () async {
      await c.startReceiving();
      final code = c.receiver!.token;
      await c.releaseReceiving();
      expect(c.autoReceiving, isTrue);
      await expectLater(PushSender(base(), code).hello(),
          throwsA(predicate((e) => isKind(e, TransferError.auth))));
    });

    test('switching it off stops receiving and is remembered', () async {
      await c.setAutoReceive(false);
      expect(c.receiving, isFalse);
      expect((await SharedPreferences.getInstance()).getBool(AutoReceive.prefKey), isFalse);
      await c.onResume();
      expect(c.receiving, isFalse);

      await c.setAutoReceive(true);
      expect(c.autoReceiving, isTrue);
      await c.forgetPc('pc1');
      expect(c.receiving, isFalse);
    });
  });
}
