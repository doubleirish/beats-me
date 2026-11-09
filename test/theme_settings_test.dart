import 'package:beats_me/services/theme_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('theme choices persist and unknown values fall back', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final t = ThemeSettings(prefs);
    await t.load();
    expect(t.mode, ThemeMode.system);
    expect(t.accent, ThemeSettings.defaultAccent);

    await t.setMode(ThemeMode.light);
    await t.setAccent('Teal');
    await t.setAccent('Nope');
    final again = ThemeSettings(prefs);
    await again.load();
    expect(again.mode, ThemeMode.light);
    expect(again.accent, 'Teal');
    expect(again.seed, Colors.teal);

    await prefs.setString(ThemeSettings.modeKey, 'bogus');
    await prefs.setString(ThemeSettings.accentKey, 'bogus');
    await again.load();
    expect(again.mode, ThemeMode.system);
    expect(again.accent, ThemeSettings.defaultAccent);
  });
}
