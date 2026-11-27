import 'dart:async';
import 'dart:io';

import '../core/constants.dart';
import '../models/audit_entry.dart';
import '../models/contact.dart';
import '../models/note.dart';
import '../models/pin.dart';
import '../models/settings.dart';
import '../models/user.dart';
import 'json_store.dart';

/// Локальный кэш клиента (ТЗ 4.5): все записи хранятся локально,
/// оффлайн-правки складываются в очередь [outbox] и уходят при синхронизации.
class LocalCache {
  LocalCache({required this.dataDir}) : _store = JsonStore(dataDir);

  final Directory dataDir;
  final JsonStore _store;

  final Map<String, Note> notes = {};
  final Map<String, AppUser> users = {};
  final Map<String, Contact> contacts = {};
  final Map<String, Pin> pins = {};
  final List<AuditEntry> audit = [];
  HostSettings hostSettings = HostSettings();

  /// Очередь исходящих операций (JSON-сообщения протокола).
  final List<Map<String, dynamic>> outbox = [];

  Future<void> load() async {
    await _store.ensureDir();
    for (final Object? e in await _store.readList('notes.json')) {
      final Note n = Note.fromJson((e as Map).cast<String, dynamic>());
      notes[n.id] = n;
    }
    for (final Object? e in await _store.readList('users.json')) {
      final AppUser u = AppUser.fromJson((e as Map).cast<String, dynamic>());
      users[u.id] = u;
    }
    for (final Object? e in await _store.readList('contacts.json')) {
      final Contact c = Contact.fromJson((e as Map).cast<String, dynamic>());
      contacts[c.id] = c;
    }
    for (final Object? e in await _store.readList('pins.json')) {
      final Pin p = Pin.fromJson((e as Map).cast<String, dynamic>());
      pins[p.key] = p;
    }
    for (final Object? e in await _store.readList('audit.json')) {
      audit.add(AuditEntry.fromJson((e as Map).cast<String, dynamic>()));
    }
    final Map<String, dynamic>? hs = await _store.readMap('host_settings.json');
    if (hs != null) hostSettings.applyJson(hs);
    for (final Object? e in await _store.readList('outbox.json')) {
      outbox.add((e as Map).cast<String, dynamic>());
    }
  }

  void saveNotes() => _save('notes.json', notes.values.map((e) => e.toJson()).toList());
  void saveUsers() => _save('users.json', users.values.map((e) => e.toJson()).toList());
  void saveContacts() => _save('contacts.json', contacts.values.map((e) => e.toJson()).toList());
  void savePins() => _save('pins.json', pins.values.map((e) => e.toJson()).toList());
  void saveAudit() => _save('audit.json', audit.map((e) => e.toJson()).toList());
  void saveHostSettings() =>
      unawaited(_store.writeNow('host_settings.json', hostSettings.toJson()));
  void saveOutbox() => _save('outbox.json', outbox);

  void _save(String name, List<Map<String, dynamic>> items) {
    _store.writeDebounced(name, () => {'items': items});
  }

  Future<void> flush() => _store.flush();

  // ---------- Применение событий от хоста ----------

  void applySnapshot(Map<String, dynamic> s) {
    notes
      ..clear()
      ..addEntries((s['notes'] as List? ?? []).map((e) {
        final Note n = Note.fromJson((e as Map).cast<String, dynamic>());
        return MapEntry(n.id, n);
      }));
    users
      ..clear()
      ..addEntries((s['users'] as List? ?? []).map((e) {
        final AppUser u = AppUser.fromJson((e as Map).cast<String, dynamic>());
        return MapEntry(u.id, u);
      }));
    contacts
      ..clear()
      ..addEntries((s['contacts'] as List? ?? []).map((e) {
        final Contact c = Contact.fromJson((e as Map).cast<String, dynamic>());
        return MapEntry(c.id, c);
      }));
    pins
      ..clear()
      ..addEntries((s['pins'] as List? ?? []).map((e) {
        final Pin p = Pin.fromJson((e as Map).cast<String, dynamic>());
        return MapEntry(p.key, p);
      }));
    audit
      ..clear()
      ..addAll((s['audit'] as List? ?? [])
          .map((e) => AuditEntry.fromJson((e as Map).cast<String, dynamic>())));
    final Object? hs = s['hostSettings'];
    if (hs is Map) hostSettings.applyJson(hs.cast<String, dynamic>());
    saveAll();
  }

  void applyNoteUpsert(Note note) {
    notes[note.id] = note;
    saveNotes();
  }

  void applyUsers(List<dynamic> list) {
    for (final Object? e in list) {
      final AppUser u = AppUser.fromJson((e as Map).cast<String, dynamic>());
      users[u.id] = u;
    }
    saveUsers();
  }

  void applyPresence(String userId, bool online, DateTime? lastSeen) {
    final AppUser? u = users[userId];
    if (u != null) {
      u.online = online;
      u.lastSeen = lastSeen ?? u.lastSeen;
      saveUsers();
    }
  }

  void applyAuditEntries(List<dynamic> list) {
    for (final Object? e in list) {
      final AuditEntry entry = AuditEntry.fromJson((e as Map).cast<String, dynamic>());
      if (!audit.any((x) => x.id == entry.id)) audit.add(entry);
    }
    // Храним ограниченный хвост журнала на клиенте.
    if (audit.length > kAuditSnapshotLimit) {
      audit.removeRange(0, audit.length - kAuditSnapshotLimit);
    }
    saveAudit();
  }

  void applyPin(Pin pin) {
    pins[pin.key] = pin;
    savePins();
  }

  void removePin(String userId, String noteId) {
    pins.remove('$userId:$noteId');
    savePins();
  }

  void applyContact(Contact c) {
    contacts[c.id] = c;
    saveContacts();
  }

  void removeContact(String id) {
    contacts.remove(id);
    for (final Note n in notes.values) {
      if (n.contactId == id) n.contactId = null;
    }
    saveContacts();
    saveNotes();
  }

  void applyHostSettings(Map<String, dynamic> j) {
    hostSettings.applyJson(j);
    saveHostSettings();
  }

  void saveAll() {
    saveNotes();
    saveUsers();
    saveContacts();
    savePins();
    saveAudit();
    saveHostSettings();
  }

  // ---------- Оффлайн-очередь ----------

  void enqueue(Map<String, dynamic> op) {
    outbox.add(op);
    saveOutbox();
  }

  /// Успешно отправленные операции удаляются из очереди.
  void dequeueFirst(int count) {
    if (count <= 0) return;
    outbox.removeRange(0, count > outbox.length ? outbox.length : count);
    saveOutbox();
  }
}
