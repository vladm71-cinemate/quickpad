import 'dart:async';
import 'dart:io';

import '../core/constants.dart';
import '../data/host_database.dart';
import '../models/audit_entry.dart';
import '../models/enums.dart';
import '../models/note.dart';
import 'host_server.dart';
import 'protocol.dart';

/// Планировщик хоста (ТЗ 4.4): напоминания, эскалация, автоочистка аудио
/// по сроку хранения, watchdog присутствия.
class HostJobs {
  HostJobs({required this.db, required this.server});

  final HostDatabase db;
  final HostServer server;
  Timer? _timer;

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(kSchedulerTick, (_) => tick());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Один проход планировщика (выносим для тестов).
  void tick({DateTime? nowUtc}) {
    final DateTime now = nowUtc ?? DateTime.now().toUtc();
    server.presenceWatchdog();
    _checkReminders(now);
    _checkEscalation(now);
    _checkAudioRetention(now);
  }

  // ---------- Напоминания ----------

  void _checkReminders(DateTime now) {
    if (!db.settings.remindersEnabled) return;
    for (final Note note in db.notes.values.toList()) {
      final Reminder? r = note.reminder;
      if (r == null) continue;
      if (!note.isActive) continue;
      if (now.isBefore(r.at)) continue;

      final bool isRepeat =
          r.repeat && r.repeatInterval != null && db.settings.recurringRemindersEnabled;
      if (r.firedAt != null && !isRepeat) continue;

      // Сработало.
      r.firedAt = now;
      final Map<String, dynamic> msg = {
        'type': MsgType.notify,
        'kind': NotifyKind.reminder.wire,
        'noteId': note.id,
        'title': 'Напоминание',
        'body': note.text,
      };
      switch (r.recipients) {
        case ReminderRecipients.all:
          server.broadcast(msg);
          break;
        case ReminderRecipients.author:
          server.notifyUser(note.authorId, msg);
          break;
        case ReminderRecipients.assignee:
          server.notifyUser(note.assigneeId ?? note.authorId, msg);
          break;
      }
      db.auditSystem(note.id, AuditType.reminderFired,
          details: 'получатели: ${r.recipients.label}');

      if (isRepeat) {
        // Переносим на следующий интервал (пропуская прошедшие).
        do {
          r.at = r.at.add(r.repeatInterval!);
        } while (now.isAfter(r.at));
      }
      db.saveNotes();
      server.broadcast({
        'type': MsgType.noteUpsert,
        'note': note.toJson(),
        'audit': [db.audit.last.toJson()],
      });
    }
  }

  // ---------- Эскалация ----------

  void _checkEscalation(DateTime now) {
    final s = db.settings;
    if (!s.escalationEnabled) return;
    if (s.escalationWorkHoursOnly) {
      final int h = now.toLocal().hour;
      if (h < s.workDayStart || h >= s.workDayEnd) return;
    }
    for (final Note note in db.notes.values.toList()) {
      if (note.escalated) continue;
      final bool applicable = (note.status == NoteStatus.fresh && s.escalateNew) ||
          (note.status == NoteStatus.inProgress && s.escalateInProgress);
      if (!applicable) continue;
      final Duration age = now.difference(note.createdAt);
      if (age < Duration(minutes: s.escalationMinutes)) continue;

      // Ответственный: исполнитель → автор → хост (если автор недоступен).
      String targetId = note.assigneeId ?? note.authorId;
      if (targetId.isEmpty) targetId = server.hostUserId;
      final target = db.users[targetId];
      final bool targetOnline = target?.online ?? false;
      if (!targetOnline && server.hostUserId.isNotEmpty && targetId != server.hostUserId) {
        targetId = server.hostUserId; // «если недоступен, хост»
      }

      note.escalated = true;
      note.escalatedAt = now;
      note.updatedAt = now;
      final String targetName = db.userName(targetId);
      final AuditEntry entry = db.auditSystem(note.id, AuditType.escalation,
          details: 'не взята в работу за ${s.escalationMinutes} мин, уведомлён $targetName');
      db.saveNotes();

      server.notifyUser(targetId, {
        'type': MsgType.notify,
        'kind': NotifyKind.escalation.wire,
        'noteId': note.id,
        'title': 'Заявка требует внимания',
        'body': 'Нет реакции ${s.escalationMinutes} мин: ${note.text}',
      });
      server.broadcast({
        'type': MsgType.noteUpsert,
        'note': note.toJson(),
        'audit': [entry.toJson()],
      });
    }
  }

  // ---------- Срок хранения аудио ----------

  void _checkAudioRetention(DateTime now) {
    final int days = db.settings.audioKeepDays;
    if (days <= 0) return;
    for (final Note note in db.notes.values.toList()) {
      final audio = note.audio;
      if (audio == null || audio.deleted) continue;
      final DateTime base = note.updatedAt;
      if (now.difference(base).inDays < days) continue;
      try {
        final File f = File('${server.audioDir.path}${Platform.pathSeparator}${audio.fileName}');
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
      audio.deleted = true;
      final AuditEntry entry =
          db.auditSystem(note.id, AuditType.audioDeleted, details: 'срок хранения $days дн.');
      db.saveNotes();
      server.broadcast({
        'type': MsgType.noteUpsert,
        'note': note.toJson(),
        'audit': [entry.toJson()],
      });
    }
  }
}
