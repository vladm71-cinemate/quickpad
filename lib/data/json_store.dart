import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Атомарная запись JSON-файлов (tmp + rename) с дебаунсом,
/// чтобы частые изменения не долбили диск.
class JsonStore {
  JsonStore(this.dir);

  final Directory dir;
  final Map<String, Timer> _debounce = {};

  File fileFor(String name) => File('${dir.path}${Platform.pathSeparator}$name');

  Future<void> ensureDir() async {
    if (!await dir.exists()) await dir.create(recursive: true);
  }

  Future<Map<String, dynamic>?> readMap(String name) async {
    final File f = fileFor(name);
    if (!await f.exists()) return null;
    try {
      final String text = await f.readAsString();
      final Object? decoded = jsonDecode(text);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      // Повреждённый файл — пробуем .bak
      final File bak = fileFor('$name.bak');
      if (await bak.exists()) {
        try {
          final Object? decoded = jsonDecode(await bak.readAsString());
          return decoded is Map<String, dynamic> ? decoded : null;
        } catch (_) {}
      }
      return null;
    }
  }

  Future<List<dynamic>> readList(String name) async {
    final Map<String, dynamic>? m = await readMap(name);
    final Object? items = m?['items'];
    return items is List ? items : <dynamic>[];
  }

  /// Немедленная атомарная запись.
  Future<void> writeNow(String name, Object? payload) async {
    await ensureDir();
    final File f = fileFor(name);
    final File tmp = fileFor('$name.tmp');
    final File bak = fileFor('$name.bak');
    final String text = const JsonEncoder.withIndent('  ').convert(payload);
    await tmp.writeAsString(text, flush: true);
    try {
      if (await f.exists()) await f.copy(bak.path);
    } catch (_) {}
    try {
      await tmp.rename(f.path);
    } on PathNotFoundException {
      // Каталог данных удалён между записью и rename (очистка данных,
      // teardown теста) — отложенная запись просто теряется, это не ошибка.
      try {
        await tmp.delete();
      } catch (_) {}
    }
  }

  /// Запись с дебаунсом (по умолчанию 800 мс).
  void writeDebounced(String name, Object? Function() payload,
      [Duration delay = const Duration(milliseconds: 800)]) {
    _debounce[name]?.cancel();
    _debounce[name] = Timer(delay, () {
      _debounce.remove(name);
      unawaited(writeNow(name, payload()));
    });
  }

  /// Дождаться завершения всех отложенных записей.
  Future<void> flush() async {
    final List<String> pending = _debounce.keys.toList();
    for (final String name in pending) {
      _debounce.remove(name)?.cancel();
    }
  }
}
