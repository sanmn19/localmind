import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'models/desktop_window.dart';

/// Persists the desktop window layout as a single JSON string.
class DesktopLayoutStore {
  DesktopLayoutStore(this._preferences);

  /// Versioned so a future layout change can be read next to this one.
  static const String key = 'desktop.layout.v1';

  final SharedPreferences _preferences;

  /// Returns the saved layout, or `null` when nothing valid is stored.
  DesktopLayout? load() {
    try {
      final raw = _preferences.getString(key);
      if (raw == null) return null;
      return DesktopLayout.fromJson(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  Future<void> save(DesktopLayout layout) {
    return _preferences.setString(key, jsonEncode(layout.toJson()));
  }
}
