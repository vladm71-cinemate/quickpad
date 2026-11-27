import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:quickpad/models/enums.dart';
import 'package:quickpad/models/note.dart';
import 'package:quickpad/models/settings.dart';

void main() {
  group('Note JSON', () {
    test('roundtrip сохраняет все поля', () {
      final Note n = Note(
        id: 'n1',
        text: 'Тестовая заявка',
        authorId: 'u1',
        createdAt: DateTime.utc(2026, 11, 27, 10),
        status: NoteStatus.inProgress,
        assigneeId: 'u2',
        priority: NotePriority.high,
        deadline: DateTime.utc(2026, 11, 28, 18),
        reminder: Reminder(
          at: DateTime.utc(2026, 11, 27, 15),
          recipients: ReminderRecipients.assignee,
          repeat: true,
          repeatInterval: const Duration(hours: 2),
        ),
        tags: ['срочно', 'склад'],
        colorValue: 0xFFE53935,
        contactId: 'c1',
        audio: AudioAttachment(fileName: 'a.m4a', sizeBytes: 1234, transcript: 'текст'),
        version: 3,
        escalated: true,
        escalatedAt: DateTime.utc(2026, 11, 27, 11),
      );
      final Note r = Note.fromJson(n.toJson());
      expect(r.id, 'n1');
      expect(r.status, NoteStatus.inProgress);
      expect(r.assigneeId, 'u2');
      expect(r.priority, NotePriority.high);
      expect(r.reminder!.repeat, true);
      expect(r.reminder!.repeatInterval!.inHours, 2);
      expect(r.tags, ['срочно', 'склад']);
      expect(r.colorValue, 0xFFE53935);
      expect(r.audio!.transcript, 'текст');
      expect(r.version, 3);
      expect(r.escalated, true);
    });

    test('isOverdue учитывает статус', () {
      final DateTime past = DateTime.now().toUtc().subtract(const Duration(hours: 1));
      final Note n = Note(id: 'x', text: 't', authorId: 'u', createdAt: past, deadline: past);
      expect(n.isOverdue(), true);
      n.status = NoteStatus.done;
      expect(n.isOverdue(), false);
    });

    test('по умолчанию статус «Новая»', () {
      final Note n = Note(id: 'x', text: 't', authorId: 'u', createdAt: DateTime.now().toUtc());
      expect(n.status, NoteStatus.fresh);
      expect(n.isActive, true);
    });
  });

  group('Настройки', () {
    test('значения по умолчанию соответствуют ТЗ (раздел 6)', () {
      final HostSettings hs = HostSettings();
      expect(hs.escalationMinutes, 30);
      expect(hs.escalationEnabled, true);
      expect(hs.escalateNew, true);
      expect(hs.escalateInProgress, false);
      expect(hs.auditEnabled, true);
      expect(hs.cleanupOnDone, true);
      expect(hs.cleanupOnRejected, false);
      expect(hs.backupKeep, 5);
      expect(hs.recurringRemindersEnabled, false);

      final LocalSettings ls = LocalSettings();
      expect(ls.darkTheme, false); // светлая по умолчанию
      expect(ls.notifNew, true);
      expect(ls.dnd, false);
      expect(ls.myByDefault, false);
      expect(ls.offlineMode, true);
      expect(ls.realtime, true);
    });

    test('roundtrip HostSettings через JSON', () {
      final HostSettings hs = HostSettings()..escalationMinutes = 45..auditEnabled = false;
      final HostSettings r = HostSettings.fromJson(hs.toJson());
      expect(r.escalationMinutes, 45);
      expect(r.auditEnabled, false);
    });

    test('LocalSettings setFlag/applyJson', () {
      final LocalSettings ls = LocalSettings();
      ls.setFlag('dnd', true);
      expect(ls.dnd, true);
      final Map<String, dynamic> j = ls.toFullJson();
      final LocalSettings ls2 = LocalSettings()..applyJson(j);
      expect(ls2.dnd, true);
      expect(ls2.sttLocale, 'ru-RU');
    });
  });

  group('Файл настроек', () {
    test('JSON настроек сериализуется', () {
      final LocalSettings ls = LocalSettings();
      final Map<String, bool> j = ls.toJson();
      expect(j.length, greaterThan(30));
    });
  });

  // Заглушка, чтобы dart:io точно линковался в тестах VM
  test('среда VM доступна', () => expect(Directory.current.existsSync(), true));
}
