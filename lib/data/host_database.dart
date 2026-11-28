import 'dart:async';
import 'dart:io';

import '../core/constants.dart';
import '../core/ids.dart';
import '../models/audit_entry.dart';
import '../models/chat_message.dart';
import '../models/contact.dart';
import '../models/enums.dart';
import '../models/note.dart';
import '../models/note_ops.dart';
import '../models/pin.dart';
import '../models/settings.dart';
import '../models/user.dart';
import 'json_store.dart';

/// Результат применения операции на хосте: события для рассылки + журнал.
class HostOpResult {
  HostOpResult({this.note, this.audit = const [], this.conflict = false, this.extra = const {}});

  final Note? note;
  final List<AuditEntry> audit;
  final bool conflict;
  final Map<String, Object?> extra;
}

/// Авторитетная база данных хоста (ТЗ, раздел 2): заметки, пользователи,
/// контакты, закрепления, журнал аудита, хостовые настройки.
///
/// Хост проставляет автора/время в журнале из данных сессии,
/// а не из полей, присланных клиентом.
class HostDatabase {
  HostDatabase({required this.dataDir, required this.audioDir})
      : _store = JsonStore(dataDir);

  final Directory dataDir;

  /// Каталог аудиофайлов (для автоочистки).
  final Directory audioDir;

  final JsonStore _store;

  final Map<String, Note> notes = {};
  final Map<String, AppUser> users = {};
  final Map<String, Contact> contacts = {};
  final Map<String, Pin> pins = {};
  final List<AuditEntry> audit = [];
  final List<ChatMessage> messages = [];
  HostSettings settings = HostSettings();

  /// Колбэк: хост рассылает событие клиентам. Устанавливает HostServer.
  void Function(Map<String, dynamic> message, {String? onlyUserId})? broadcast;

  /// Колбэк: нужно автосохранение (резервная копия) — вызывается после изменений.
  void Function()? onDataChanged;

  Future<void> load() async {
    await _store.ensureDir();

    final List<dynamic> n = await _store.readList('notes.json');
    for (final Object? e in n) {
      final Note note = Note.fromJson((e as Map).cast<String, dynamic>());
      notes[note.id] = note;
    }
    final List<dynamic> u = await _store.readList('users.json');
    for (final Object? e in u) {
      final AppUser user = AppUser.fromJson((e as Map).cast<String, dynamic>());
      users[user.id] = user;
    }
    final List<dynamic> c = await _store.readList('contacts.json');
    for (final Object? e in c) {
      final Contact contact = Contact.fromJson((e as Map).cast<String, dynamic>());
      contacts[contact.id] = contact;
    }
    final List<dynamic> p = await _store.readList('pins.json');
    for (final Object? e in p) {
      final Pin pin = Pin.fromJson((e as Map).cast<String, dynamic>());
      pins[pin.key] = pin;
    }
    final List<dynamic> a = await _store.readList('audit.json');
    for (final Object? e in a) {
      audit.add(AuditEntry.fromJson((e as Map).cast<String, dynamic>()));
    }
    final Map<String, dynamic>? s = await _store.readMap('host_settings.json');
    if (s != null) settings.applyJson(s);

    final List<dynamic> m = await _store.readList('messages.json');
    for (final Object? e in m) {
      messages.add(ChatMessage.fromJson((e as Map).cast<String, dynamic>()));
    }
  }

  // ---------- Сохранение ----------

  void saveNotes() => _save('notes.json', notes.values.map((e) => e.toJson()).toList());
  void saveUsers() => _save('users.json', users.values.map((e) => e.toJson()).toList());
  void saveContacts() => _save('contacts.json', contacts.values.map((e) => e.toJson()).toList());
  void savePins() => _save('pins.json', pins.values.map((e) => e.toJson()).toList());
  void saveAudit() => _save('audit.json', audit.map((e) => e.toJson()).toList());

  /// Полная очистка журнала аудита (ТЗ: очистка журнала у хоста).
  /// Клиенты получают сигнал и тоже чистят локальную копию.
  void clearAudit() {
    audit.clear();
    saveAudit();
    broadcast?.call({'type': 'audit_cleared'});
  }
  void saveMessages() => _save('messages.json', messages.map((e) => e.toJson()).toList());
  void saveSettings() => unawaited(_store.writeNow('host_settings.json', settings.toJson()));

  void _save(String name, List<Map<String, dynamic>> items) {
    _store.writeDebounced(name, () => {'items': items});
    onDataChanged?.call();
  }

  Future<void> flush() => _store.flush();

  // ---------- Пользователи ----------

  /// Регистрация/обновление пользователя при входе. Возвращает пользователя.
  /// Уникальное имя: если такое уже занято другим пользователем,
  /// добавляет суффикс « 2», « 3» и т.д. (без учёта регистра).
  String _uniqueName(String name, {String? excludeUserId}) {
    String base = name.trim();
    if (base.isEmpty) base = 'Без имени';
    final Set<String> taken = users.values
        .where((u) => u.id != excludeUserId)
        .map((u) => u.name.toLowerCase())
        .toSet();
    if (!taken.contains(base.toLowerCase())) return base;
    int i = 2;
    while (taken.contains('$base $i'.toLowerCase())) {
      i++;
    }
    return '$base $i';
  }

  AppUser helloUser({
    required String userId,
    required String userName,
    required String deviceId,
  }) {
    final AppUser? existing = users[userId];
    if (existing == null) {
      final String unique = _uniqueName(userName);
      final AppUser user = AppUser(id: userId, name: unique, deviceIds: [deviceId]);
      users[userId] = user;
      _audit(null, userId, deviceId, AuditType.userChange, details: 'создан профиль «$unique»');
      saveUsers();
      broadcast?.call({'type': 'users', 'users': users.values.map((e) => e.toJson()).toList()});
      return user;
    }
    bool changed = false;
    if (existing.name != userName && userName.isNotEmpty) {
      // Имена не должны дублироваться: занятое имя получит суффикс.
      final String unique = _uniqueName(userName, excludeUserId: userId);
      _audit(null, userId, deviceId, AuditType.userChange,
          field: 'name', oldValue: existing.name, newValue: unique,
          details: 'переименование «${existing.name}» → «$unique»');
      existing.name = unique;
      changed = true;
    }
    if (!existing.deviceIds.contains(deviceId)) {
      existing.deviceIds.add(deviceId);
      changed = true;
    }
    if (changed) {
      saveUsers();
      broadcast?.call({'type': 'users', 'users': users.values.map((e) => e.toJson()).toList()});
    }
    return existing;
  }

  /// Удаление профиля пользователя (только на хосте, ТЗ 6.10).
  /// Заявки и записи журнала сохраняются.
  void deleteUser(String userId, {required String actorId}) {
    final AppUser? u = users.remove(userId);
    if (u == null) return;
    _audit(null, actorId, 'host', AuditType.userChange, details: 'удалён профиль «${u.name}»');
    // Закрепления удалённого пользователя тоже чистим.
    pins.removeWhere((key, p) => p.userId == userId);
    saveUsers();
    savePins();
    broadcast?.call({'type': 'users', 'users': users.values.map((e) => e.toJson()).toList()});
  }

  String userName(String id) => users[id]?.name ?? (id.isEmpty ? '—' : id);

  /// Смена роли пользователя (только на хосте): 'manager' | 'worker'.
  void setUserRole(String userId, String role, {required String actorId}) {
    final AppUser? u = users[userId];
    if (u == null || u.role == role) return;
    u.role = role;
    _audit(null, actorId, 'host', AuditType.userChange,
        details: 'роль «${u.name}»: ${role == 'manager' ? 'руководитель' : 'работник'}');
    saveUsers();
    broadcast?.call({'type': 'users', 'users': users.values.map((e) => e.toJson()).toList()});
  }

  // ---------- Заявки ----------

  /// Создание заявки. Автор и время — от хоста.
  HostOpResult createNote(Note incoming, {required String userId, required String deviceId}) {
    final DateTime now = DateTime.now().toUtc();
    incoming.authorId = userId;
    incoming.createdAt = now;
    incoming.updatedAt = now;
    incoming.version = 1;
    notes[incoming.id] = incoming;
    final List<AuditEntry> entries = [
      _audit(incoming.id, userId, deviceId, AuditType.create,
          details: incoming.text.length > 80 ? '${incoming.text.substring(0, 80)}…' : incoming.text),
    ];
    saveNotes();
    _maybeNotifyNew(incoming);
    return HostOpResult(note: incoming, audit: entries);
  }

  /// Изменение полей заявки. patch: {поле: json-значение} (см. NoteFields).
  /// Конфликт: baseVersion < текущей — фиксируется в журнале, изменение применяется
  /// (приоритет последнего изменения на хосте, ТЗ раздел 2).
  HostOpResult patchNote(
    String noteId,
    Map<String, dynamic> patch, {
    required int baseVersion,
    required String userId,
    required String deviceId,
  }) {
    final Note? note = notes[noteId];
    if (note == null) return HostOpResult();
    final DateTime now = DateTime.now().toUtc();
    final Map<String, String?> before = note.fieldSnapshot(
        userName: userName, contactName: (id) => contacts[id]?.name ?? id);
    final NoteStatus oldStatus = note.status;
    final bool conflict = baseVersion < note.version;
    final List<AuditEntry> entries = [];

    applyPatchToNote(note, patch);

    // Побочные эффекты смены статуса (автоочистка аудио и т.п.).
    if (patch.containsKey(NoteFields.status)) {
      _applyStatusSideEffects(note, oldStatus, note.status, userId, deviceId, entries);
    }
    note.updatedAt = now;
    note.version += 1;

    // Журнал: «старое → новое» по каждому изменившемуся полю.
    if (settings.auditEnabled) {
      final Map<String, String?> after = note.fieldSnapshot(
          userName: userName, contactName: (id) => contacts[id]?.name ?? id);
      for (final String field in patch.keys) {
        final String? oldV = before[field];
        final String? newV = after[field];
        if (oldV != newV) {
          entries.add(_audit(noteId, userId, deviceId, AuditType.update,
              field: field, oldValue: oldV, newValue: newV));
        }
      }
      if (conflict) {
        entries.add(_audit(noteId, userId, deviceId, AuditType.conflict,
            details:
                'правка на основе версии $baseVersion, актуальная была ${note.version - 1}; применено последнее изменение'));
      }
    }
    saveNotes();

    if (conflict) {
      // Уведомление о конфликте автору предыдущей правки и редактору.
      broadcast?.call({
        'type': 'notify',
        'kind': NotifyKind.conflict.wire,
        'noteId': noteId,
        'title': 'Конфликт синхронизации',
        'body': 'Заявка изменялась одновременно. Применена последняя версия, обе — в журнале.',
      });
    }
    return HostOpResult(note: note, audit: entries, conflict: conflict);
  }

  /// Побочные эффекты смены статуса: автоочистка аудио (ТЗ 4.4, 6.4).
  void _applyStatusSideEffects(Note note, NoteStatus oldS, NoteStatus newS, String userId,
      String deviceId, List<AuditEntry> entries) {
    if (oldS == newS) return;
    final AudioAttachment? audio = note.audio;
    if (audio == null || audio.deleted) return;
    final bool cleanup = (newS == NoteStatus.done && settings.cleanupOnDone) ||
        ((newS == NoteStatus.rejected || newS == NoteStatus.postponed) && settings.cleanupOnRejected);
    if (cleanup) {
      _deleteAudioFile(audio.fileName);
      audio.deleted = true;
      if (settings.auditEnabled) {
        entries.add(_audit(note.id, userId, deviceId, AuditType.audioDeleted,
            details: 'статус «${newS.label}», автоочистка'));
      }
    }
  }

  void _deleteAudioFile(String fileName) {
    try {
      final File f = File('${audioDir.path}${Platform.pathSeparator}$fileName');
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  /// Удаление заявки целиком (очистка архива и т.п.).
  /// Файлы вложений (аудио, фото) удаляются с диска, закрепления чистятся.
  HostOpResult deleteNote(String noteId,
      {required String userId, required String deviceId}) {
    final Note? note = notes.remove(noteId);
    if (note == null) return HostOpResult();
    final AudioAttachment? a = note.audio;
    if (a != null) _deleteAudioFile(a.fileName);
    for (final PhotoAttachment p in note.photos) {
      _deleteAudioFile(p.fileName);
    }
    pins.removeWhere((String key, Pin p) => p.noteId == noteId);
    final List<AuditEntry> entries = [];
    if (settings.auditEnabled) {
      final String short = note.text.length > 60
          ? '${note.text.substring(0, 60)}…'
          : note.text;
      entries.add(_audit(noteId, userId, deviceId, AuditType.noteDeleted,
          details: 'удалена заявка «$short»'));
    }
    saveNotes();
    savePins();
    return HostOpResult(note: note, audit: entries);
  }

  // ---------- Закрепления (персональные) ----------

  HostOpResult setPin(String userId, String noteId, bool pinned, {required String deviceId}) {
    final String key = '$userId:$noteId';
    final List<AuditEntry> entries = [];
    if (pinned) {
      if (!pins.containsKey(key) && notes.containsKey(noteId)) {
        final int maxOrder = pins.values
            .where((p) => p.userId == userId)
            .fold<int>(-1, (m, p) => p.orderIndex > m ? p.orderIndex : m);
        pins[key] = Pin(userId: userId, noteId: noteId, pinnedAt: DateTime.now().toUtc(), orderIndex: maxOrder + 1);
        entries.add(_audit(noteId, userId, deviceId, AuditType.pin));
      }
    } else {
      if (pins.remove(key) != null) {
        entries.add(_audit(noteId, userId, deviceId, AuditType.unpin));
      }
    }
    savePins();
    return HostOpResult(audit: entries);
  }

  /// Ручная сортировка закреплённых (порядок синхронизируется между устройствами).
  void reorderPins(String userId, List<String> orderedNoteIds) {
    for (int i = 0; i < orderedNoteIds.length; i++) {
      final Pin? p = pins['$userId:${orderedNoteIds[i]}'];
      if (p != null) p.orderIndex = i;
    }
    savePins();
  }

  int pinCount(String userId) => pins.values.where((p) => p.userId == userId).length;

  // ---------- Контакты ----------

  HostOpResult upsertContact(Contact contact, {required String userId, required String deviceId}) {
    final bool isNew = !contacts.containsKey(contact.id);
    contact.updatedAt = DateTime.now().toUtc();
    contacts[contact.id] = contact;
    final entries = [
      _audit(null, userId, deviceId, AuditType.contactChange,
          details: isNew ? 'добавлен «${contact.name}»' : 'изменён «${contact.name}»'),
    ];
    saveContacts();
    return HostOpResult(audit: entries, extra: {'contact': contact.toJson()});
  }

  HostOpResult deleteContact(String contactId, {required String userId, required String deviceId}) {
    final Contact? c = contacts.remove(contactId);
    final entries = <AuditEntry>[];
    if (c != null) {
      entries.add(_audit(null, userId, deviceId, AuditType.contactChange,
          details: 'удалён «${c.name}»'));
      // Отвязать контакт от заявок.
      for (final Note n in notes.values) {
        if (n.contactId == contactId) n.contactId = null;
      }
      saveNotes();
    }
    saveContacts();
    return HostOpResult(audit: entries, extra: {'contactId': contactId});
  }

  // ---------- Журнал ----------

  AuditEntry _audit(String? noteId, String userId, String deviceId, AuditType type,
      {String? field, String? oldValue, String? newValue, String? details}) {
    final AuditEntry e = AuditEntry(
      id: newId(),
      at: DateTime.now().toUtc(),
      userId: userId,
      deviceId: deviceId,
      type: type,
      noteId: noteId,
      field: field,
      oldValue: oldValue,
      newValue: newValue,
      details: details,
    );
    if (settings.auditEnabled) {
      audit.add(e);
      saveAudit();
    }
    return e;
  }

  /// Явное добавление системного события (эскалация/напоминание) — для планировщика.
  AuditEntry auditSystem(String? noteId, AuditType type, {String? details}) =>
      _audit(noteId, 'host', 'host', type, details: details);

  void _maybeNotifyNew(Note note) {
    broadcast?.call({
      'type': 'notify',
      'kind': NotifyKind.newNote.wire,
      'noteId': note.id,
      'actorId': note.authorId,
      'title': 'Новая заявка от ${userName(note.authorId)}',
      'body': note.text.length > 120 ? '${note.text.substring(0, 120)}…' : note.text,
    });
  }

  // ---------- Мессенджер ----------

  /// Добавить личное сообщение. История ограничена [kChatHistoryLimit].
  void addChatMessage(ChatMessage msg) {
    messages.add(msg);
    if (messages.length > kChatHistoryLimit) {
      messages.removeRange(0, messages.length - kChatHistoryLimit);
    }
    saveMessages();
  }

  /// Удалить одно сообщение (для всех участников).
  bool deleteChatMessage(String messageId) {
    final int i = messages.indexWhere((m) => m.id == messageId);
    if (i < 0) return false;
    messages.removeAt(i);
    saveMessages();
    return true;
  }

  /// Очистить переписку между двумя пользователями. Возвращает число удалённых.
  int clearChat(String userA, String userB) {
    final int before = messages.length;
    messages.removeWhere((m) =>
        (m.fromId == userA && m.toId == userB) ||
        (m.fromId == userB && m.toId == userA));
    final int removed = before - messages.length;
    if (removed > 0) saveMessages();
    return removed;
  }

  /// Автоочистка старых сообщений по сроку хранения (0 — хранить всегда).
  int chatRetentionSweep(DateTime nowUtc) {
    final int days = settings.chatKeepDays;
    if (days <= 0) return 0;
    final DateTime cut = nowUtc.subtract(Duration(days: days));
    final int before = messages.length;
    messages.removeWhere((m) => m.createdAt.isBefore(cut));
    final int removed = before - messages.length;
    if (removed > 0) saveMessages();
    return removed;
  }

  /// Отметить прочитанными все сообщения от [fromId] адресату [toId].
  /// Возвращает true, если хоть одно сообщение изменилось.
  bool markChatRead({required String fromId, required String toId}) {
    bool changed = false;
    final DateTime now = DateTime.now().toUtc();
    for (final ChatMessage m in messages) {
      if (m.fromId == fromId && m.toId == toId && m.readAt == null) {
        m.readAt = now;
        changed = true;
      }
    }
    if (changed) saveMessages();
    return changed;
  }

  // ---------- Снапшот для клиента ----------

  Map<String, dynamic> snapshot({String? forUserId}) {
    final List<AuditEntry> recent = audit.length > kAuditSnapshotLimit
        ? audit.sublist(audit.length - kAuditSnapshotLimit)
        : audit;
    // Личные сообщения — только те, где клиент участник.
    final List<ChatMessage> chat = forUserId == null
        ? messages
        : messages
            .where((m) => m.fromId == forUserId || m.toId == forUserId)
            .toList();
    return {
      'notes': notes.values.map((e) => e.toJson()).toList(),
      'users': users.values.map((e) => e.toJson()).toList(),
      'contacts': contacts.values.map((e) => e.toJson()).toList(),
      'pins': pins.values.map((e) => e.toJson()).toList(),
      'audit': recent.map((e) => e.toJson()).toList(),
      'hostSettings': settings.toJson(),
      'messages': chat.map((e) => e.toJson()).toList(),
    };
  }
}
