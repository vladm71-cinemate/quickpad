import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/settings.dart';

/// Контроллер локальных настроек устройства (ТЗ, раздел 6):
/// хранит [LocalSettings] в SharedPreferences, уведомляет UI.
class SettingsController extends ChangeNotifier {
  SettingsController(this._prefs) {
    _load();
  }

  final SharedPreferences _prefs;
  final LocalSettings settings = LocalSettings();

  static const String _prefix = 'ls.';

  void _load() {
    final Map<String, dynamic> j = <String, dynamic>{};
    for (final String key in settings.toFullJson().keys) {
      final Object? v = _prefs.get('$_prefix$key');
      if (v != null) j[key] = v;
    }
    settings.applyJson(j);
  }

  Future<void> _save() async {
    final Map<String, dynamic> j = settings.toFullJson();
    for (final MapEntry<String, dynamic> e in j.entries) {
      final Object? v = e.value;
      if (v is bool) {
        await _prefs.setBool('$_prefix${e.key}', v);
      } else if (v is int) {
        await _prefs.setInt('$_prefix${e.key}', v);
      } else if (v is String) {
        await _prefs.setString('$_prefix${e.key}', v);
      }
    }
  }

  /// Переключить булеву настройку по ключу (см. LocalSettings.toJson).
  Future<void> setFlag(String key, bool value) async {
    settings.setFlag(key, value);
    await _save();
    notifyListeners();
  }

  Future<void> setDarkTheme(bool v) async {
    settings.darkTheme = v;
    await _save();
    notifyListeners();
  }

  Future<void> setLanguage(String code) async {
    settings.language = code;
    await _save();
    notifyListeners();
  }

  Future<void> setSttLocale(String locale) async {
    settings.sttLocale = locale;
    await _save();
    notifyListeners();
  }

  Future<void> setWorkHours(int start, int end) async {
    settings.workStart = start;
    settings.workEnd = end;
    await _save();
    notifyListeners();
  }

  Future<void> setQuietHours(int start, int end) async {
    settings.quietStart = start;
    settings.quietEnd = end;
    await _save();
    notifyListeners();
  }

  Future<void> setVolumeBoost(int db) async {
    settings.volumeBoostDb = db.clamp(0, 10);
    await _save();
    notifyListeners();
  }

  // ---------- Шаблоны заявок ----------

  static const String _kTemplates = 'templates';

  /// Заготовки текста заявки (вставляются одним нажатием в редакторе).
  List<String> get templates => _prefs.getStringList(_kTemplates) ?? <String>[];

  Future<void> setTemplates(List<String> value) async {
    await _prefs.setStringList(_kTemplates, value);
    notifyListeners();
  }
}
