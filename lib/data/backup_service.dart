import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:intl/intl.dart';

import '../models/audit_entry.dart';
import '../models/contact.dart';
import '../models/note.dart';
import '../models/pin.dart';
import '../models/settings.dart';
import '../models/user.dart';
import 'host_database.dart';

/// Резервное копирование на хосте (ТЗ 4.6):
/// автосохранение, экспорт/восстановление, ротация копий.
class BackupService {
  BackupService({required this.db, required this.backupDir});

  final HostDatabase db;
  final Directory backupDir;
  Timer? _debounce;

  static String _stamp() => DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());

  Future<void> ensureDir() async {
    if (!await backupDir.exists()) await backupDir.create(recursive: true);
  }

  /// Автосохранение «при изменениях» — с дебаунсом.
  void scheduleAutoBackup() {
    if (!db.settings.backupAuto) return;
    _debounce?.cancel();
    final Duration delay =
        db.settings.backupOnChanges ? const Duration(seconds: 30) : const Duration(hours: 1);
    _debounce = Timer(delay, () {
      unawaited(autoBackup());
    });
  }

  /// Сформировать содержимое копии.
  Map<String, dynamic> bundle() => {
        'format': 'quickpad-backup',
        'version': 1,
        'exportedAt': DateTime.now().toUtc().toIso8601String(),
        'notes': db.notes.values.map((e) => e.toJson()).toList(),
        'users': db.users.values.map((e) => e.toJson()).toList(),
        'contacts': db.contacts.values.map((e) => e.toJson()).toList(),
        'pins': db.pins.values.map((e) => e.toJson()).toList(),
        'hostSettings': db.settings.toJson(),
        if (db.settings.backupIncludeAudit) 'audit': db.audit.map((e) => e.toJson()).toList(),
      };

  /// Автоматическая копия в каталог бэкапов + ротация.
  Future<File?> autoBackup() async {
    try {
      await ensureDir();
      await db.flush();
      final File f = File('${backupDir.path}${Platform.pathSeparator}quickpad_auto_${_stamp()}.json');
      await f.writeAsString(const JsonEncoder.withIndent('  ').convert(bundle()));
      await _rotate();
      return f;
    } catch (_) {
      return null;
    }
  }

  /// Экспорт в файл по указанному пути (кнопка «Экспорт»).
  Future<File> exportTo(String path, {bool includeAudit = true}) async {
    await db.flush();
    final Map<String, dynamic> b = bundle();
    if (!includeAudit) b.remove('audit');
    final File f = File(path);
    await f.writeAsString(const JsonEncoder.withIndent('  ').convert(b));
    return f;
  }

  /// Восстановление из файла (на хосте). Возвращает null при успехе, иначе текст ошибки.
  Future<String?> importFrom(String path) async {
    try {
      final Object? decoded = jsonDecode(await File(path).readAsString());
      if (decoded is! Map<String, dynamic> || decoded['format'] != 'quickpad-backup') {
        return 'Файл не является резервной копией QuickPad';
      }
      // Перед восстановлением — страховочная копия текущего состояния.
      await autoBackup();

      db.notes.clear();
      db.users.clear();
      db.contacts.clear();
      db.pins.clear();
      db.audit.clear();

      for (final Object? e in (decoded['notes'] as List? ?? [])) {
        final Note n = Note.fromJson((e as Map).cast<String, dynamic>());
        db.notes[n.id] = n;
      }
      for (final Object? e in (decoded['users'] as List? ?? [])) {
        final AppUser u = AppUser.fromJson((e as Map).cast<String, dynamic>());
        db.users[u.id] = u;
      }
      for (final Object? e in (decoded['contacts'] as List? ?? [])) {
        final Contact c = Contact.fromJson((e as Map).cast<String, dynamic>());
        db.contacts[c.id] = c;
      }
      for (final Object? e in (decoded['pins'] as List? ?? [])) {
        final Pin p = Pin.fromJson((e as Map).cast<String, dynamic>());
        db.pins[p.key] = p;
      }
      for (final Object? e in (decoded['audit'] as List? ?? [])) {
        db.audit.add(AuditEntry.fromJson((e as Map).cast<String, dynamic>()));
      }
      final Object? hs = decoded['hostSettings'];
      if (hs is Map<String, dynamic>) {
        db.settings = HostSettings.fromJson(hs);
        db.saveSettings();
      }
      db.saveNotes();
      db.saveUsers();
      db.saveContacts();
      db.savePins();
      db.saveAudit();
      await db.flush();
      return null;
    } catch (e) {
      return 'Ошибка восстановления: $e';
    }
  }

  Future<void> _rotate() async {
    if (!db.settings.backupRotation) return;
    final List<FileSystemEntity> files = await backupDir
        .list()
        .where((e) => e.path.contains('quickpad_auto_') && e.path.endsWith('.json'))
        .toList();
    files.sort((a, b) => b.path.compareTo(a.path)); // новые первыми
    final int keep = db.settings.backupKeep;
    for (int i = keep; i < files.length; i++) {
      try {
        await files[i].delete();
      } catch (_) {}
    }
  }
}
