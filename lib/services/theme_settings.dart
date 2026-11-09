import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Appearance choices, remembered between runs.
class ThemeSettings extends ChangeNotifier {
  ThemeSettings([this._prefs]);

  static const modeKey = 'theme_mode';
  static const accentKey = 'theme_accent';

  static const accents = <String, Color>{
    'Orange': Colors.deepOrange,
    'Red': Colors.red,
    'Pink': Colors.pink,
    'Purple': Colors.deepPurple,
    'Blue': Colors.blue,
    'Teal': Colors.teal,
    'Green': Colors.green,
    'Amber': Colors.amber,
  };

  static const defaultAccent = 'Orange';

  SharedPreferences? _prefs;
  ThemeMode mode = ThemeMode.system;
  String accent = defaultAccent;

  Color get seed => accents[accent] ?? Colors.deepOrange;

  Future<void> load() async {
    final prefs = _prefs ??= await SharedPreferences.getInstance();
    mode = ThemeMode.values.asNameMap()[prefs.getString(modeKey)] ?? ThemeMode.system;
    final a = prefs.getString(accentKey);
    accent = accents.containsKey(a) ? a! : defaultAccent;
    notifyListeners();
  }

  Future<void> setMode(ThemeMode m) async {
    mode = m;
    notifyListeners();
    await _prefs?.setString(modeKey, m.name);
  }

  Future<void> setAccent(String name) async {
    if (!accents.containsKey(name)) return;
    accent = name;
    notifyListeners();
    await _prefs?.setString(accentKey, name);
  }

  ThemeData themeFor(Brightness b) =>
      ThemeData(colorSchemeSeed: seed, brightness: b, useMaterial3: true);
}
