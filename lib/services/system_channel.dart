import 'dart:io';

import 'package:flutter/services.dart';

/// Thin wrapper over the Android `beats_me/system` channel (MainActivity.kt).
/// Every call is a harmless no-op on other platforms or if it fails.
class SystemChannel {
  static const _ch = MethodChannel('beats_me/system');
  static bool get _android => Platform.isAndroid;

  static Future<T?> _call<T>(String method, [Map<String, Object?>? args]) async {
    if (!_android) return null;
    try {
      return await _ch.invokeMethod<T>(method, args);
    } catch (_) {
      return null;
    }
  }

  static Future<String> deviceName() async =>
      await _call<String>('deviceName') ?? Platform.localHostname;

  static Future<int?> freeBytes([String? path]) async {
    final v = await _call<int>('freeBytes', {'path': path});
    return v == null || v < 0 ? null : v;
  }

  static Future<void> multicastLock(bool on) => _call<void>('multicastLock', {'on': on});

  static Future<void> startTransferService(String text) =>
      _call<bool>('startTransferService', {'text': text});

  static Future<void> stopTransferService() => _call<void>('stopTransferService');

  /// Keeps the screen from sleeping (FLAG_KEEP_SCREEN_ON) or lets it sleep.
  static Future<void> keepScreenOn(bool on) => _call<void>('keepScreenOn', {'on': on});

  /// Listens for files/links handed to the app and returns the one that
  /// launched it, if any. Each map has `type` (file, link, inbox,
  /// receiving, error) and usually `value`.
  static Future<Map<String, String>?> listen(void Function(Map<String, String>) onIntent) async {
    if (!_android) return null;
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'onIntent') {
        onIntent((call.arguments as Map).cast<String, String>());
      }
    });
    final m = await _call<Map>('takePendingIntent');
    return m?.cast<String, String>();
  }
}
