import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:quickpad/data/host_database.dart';
import 'package:quickpad/models/chat_message.dart';
import 'package:quickpad/models/enums.dart';
import 'package:quickpad/models/user.dart';
import 'package:quickpad/models/note.dart';
import 'package:quickpad/net/host_jobs.dart';
import 'package:quickpad/net/host_server.dart';

HostDatabase _makeDb(Directory tmp) =>
    HostDatabase(dataDir: Directory('${tmp.path}/host'), audioDir: Directory('${tmp.path}/audio'));

void main() {
  late Directory tmp;
  late HostDatabase db;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('quickpad_test');
    db = _makeDb(tmp);
    await db.load();
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Note note({String id = 'n1', String author = 'u1', DateTime? createdAt}) => Note(
        id: id,
        text: 'Тестовая заявка $id',
        authorId: author,
        createdAt: createdAt ?? DateTime.now().toUtc(),
      );

  group('Журнал аудита', () {
    test('создание фиксирует автора сессии, а не поля клиента', () {
      final Note forged = Note(
        id: 'n1',
        text: 'x',
        authorId: 'hacker', // клиент пытается подменить автора
        createdAt: DateTime.utc(2000),
      );
      final HostOpResult r = db.createNote(forged, userId: 'lena', deviceId: 'dev1');
      expect(r.note!.authorId, 'lena'); // автор — из сессии
      expect(r.audit.single.type, AuditType.create);
      expect(r.audit.single.userId, 'lena');
    });

    test('изменение пишет «старое → новое» по каждому полю', () {
      db.createNote(note(), userId: 'lena', deviceId: 'd1');
      final HostOpResult r = db.patchNote(
        'n1',
        {NoteFields.status: NoteStatus.inProgress.wire, NoteFields.text: 'Новый текст'},
        baseVersion: 1,
        userId: 'petya',
        deviceId: 'd2',
      );
      expect(r.conflict, false);
      final statusEntry = r.audit.firstWhere((e) => e.field == NoteFields.status);
      expect(statusEntry.oldValue, 'Новая');
      expect(statusEntry.newValue, 'В работе');
      final textEntry = r.audit.firstWhere((e) => e.field == NoteFields.text);
      expect(textEntry.oldValue, 'Тестовая заявка n1');
      expect(textEntry.newValue, 'Новый текст');
      expect(db.notes['n1']!.version, 2);
    });

    test('конфликт: устаревшая версия — применяется и фиксируется', () {
      db.createNote(note(), userId: 'lena', deviceId: 'd1');
      db.patchNote('n1', {NoteFields.text: 'v2'}, baseVersion: 1, userId: 'lena', deviceId: 'd1');
      // Петя правит на основе устаревшей версии 1
      final HostOpResult r = db.patchNote(
          'n1', {NoteFields.text: 'v3 от Пети'}, baseVersion: 1, userId: 'petya', deviceId: 'd2');
      expect(r.conflict, true);
      expect(db.notes['n1']!.text, 'v3 от Пети'); // приоритет последнего изменения
      expect(r.audit.any((e) => e.type == AuditType.conflict), true);
    });

    test('закрепление — персональное, пишется в журнал', () {
      db.createNote(note(), userId: 'lena', deviceId: 'd1');
      db.setPin('lena', 'n1', true, deviceId: 'd1');
      db.setPin('petya', 'n1', true, deviceId: 'd2');
      expect(db.pinCount('lena'), 1);
      expect(db.pinCount('petya'), 1);
      db.setPin('lena', 'n1', false, deviceId: 'd1');
      expect(db.pinCount('lena'), 0);
      expect(db.pinCount('petya'), 1); // у Пети осталось
      expect(db.audit.any((e) => e.type == AuditType.pin), true);
      expect(db.audit.any((e) => e.type == AuditType.unpin), true);
    });
  });

  group('Планировщик хоста', () {
    test('эскалация: не взята в работу за N минут → ответственному, запись в журнале', () async {
      final HostServer server =
          HostServer(db: db, hostName: 'test', audioDir: Directory('${tmp.path}/audio'));
      server.hostUserId = 'host-user';
      final HostJobs jobs = HostJobs(db: db, server: server);

      db.helloUser(userId: 'lena', userName: 'Лена', deviceId: 'd1');
      db.helloUser(userId: 'host-user', userName: 'Админ', deviceId: 'd0');
      db.settings.escalationMinutes = 30;

      // Заявка создана 40 минут назад, не взята в работу
      // (хост проставляет createdAt при создании — отматываем вручную).
      db.createNote(note(), userId: 'lena', deviceId: 'd1');
      db.notes['n1']!.createdAt = DateTime.now().toUtc().subtract(const Duration(minutes: 40));

      jobs.tick();

      final Note n = db.notes['n1']!;
      expect(n.escalated, true);
      expect(n.escalatedAt, isNotNull);
      final esc = db.audit.where((e) => e.type == AuditType.escalation);
      expect(esc, isNotEmpty);
      // Автор оффлайн (нет активной сессии) → эскалация уходит хосту («если недоступен, хост»).
      expect(esc.first.details, contains('Админ'));

      // Повторно не эскалируется.
      final int auditCount = db.audit.length;
      jobs.tick();
      expect(db.audit.length, auditCount);
    });

    test('эскалация уходит исполнителю, если назначен', () {
      final HostServer server =
          HostServer(db: db, hostName: 'test', audioDir: Directory('${tmp.path}/audio'));
      final HostJobs jobs = HostJobs(db: db, server: server);
      db.helloUser(userId: 'lena', userName: 'Лена', deviceId: 'd1');
      db.helloUser(userId: 'petya', userName: 'Петя', deviceId: 'd2');

      final Note n = note();
      n.assigneeId = 'petya';
      db.createNote(n, userId: 'lena', deviceId: 'd1');
      db.notes['n1']!.createdAt = DateTime.now().toUtc().subtract(const Duration(minutes: 60));

      jobs.tick();
      final esc = db.audit.lastWhere((e) => e.type == AuditType.escalation);
      expect(esc.details, contains('Петя'));
    });

    test('эскалация при выключенной настройке не срабатывает', () {
      final HostServer server =
          HostServer(db: db, hostName: 'test', audioDir: Directory('${tmp.path}/audio'));
      final HostJobs jobs = HostJobs(db: db, server: server);
      db.settings.escalationEnabled = false;
      db.createNote(note(), userId: 'lena', deviceId: 'd1');
      db.notes['n1']!.createdAt = DateTime.now().toUtc().subtract(const Duration(minutes: 60));
      jobs.tick();
      expect(db.notes['n1']!.escalated, false);
    });

    test('однократное напоминание срабатывает один раз, повторяющееся — переносится', () {
      final HostServer server =
          HostServer(db: db, hostName: 'test', audioDir: Directory('${tmp.path}/audio'));
      final HostJobs jobs = HostJobs(db: db, server: server);

      final Note n1 = note(id: 'r1');
      n1.reminder = Reminder(at: DateTime.now().toUtc().subtract(const Duration(minutes: 1)));
      db.createNote(n1, userId: 'lena', deviceId: 'd1');

      final Note n2 = note(id: 'r2');
      n2.reminder = Reminder(
          at: DateTime.now().toUtc().subtract(const Duration(minutes: 5)),
          repeat: true,
          repeatInterval: const Duration(minutes: 10));
      db.createNote(n2, userId: 'lena', deviceId: 'd1');

      db.settings.recurringRemindersEnabled = true;
      jobs.tick();

      expect(db.notes['r1']!.reminder!.firedAt, isNotNull);
      final Reminder rep = db.notes['r2']!.reminder!;
      expect(rep.firedAt, isNotNull);
      expect(rep.at.isAfter(DateTime.now().toUtc()), true); // перенесено вперёд

      final int fired = db.audit.where((e) => e.type == AuditType.reminderFired).length;
      jobs.tick();
      expect(db.audit.where((e) => e.type == AuditType.reminderFired).length, fired);
    });
  });

  group('Пользователи', () {
    test('имена не дублируются: повторное имя получает суффикс', () {
      db.helloUser(userId: 'u1', userName: 'Лена', deviceId: 'd1');
      final AppUser u2 = db.helloUser(userId: 'u2', userName: 'Лена', deviceId: 'd2');
      expect(u2.name, 'Лена 2');
      // И без учёта регистра.
      final u3 = db.helloUser(userId: 'u3', userName: 'лена', deviceId: 'd3');
      expect(u3.name, 'лена 3');
      // Сам себе имя не «портит»: повторный вход с тем же именем не меняет его.
      final u1again = db.helloUser(userId: 'u1', userName: 'Лена', deviceId: 'd1');
      expect(u1again.name, 'Лена');
    });
  });

  group('Мессенджер', () {
    test('удаление сообщения и очистка переписки', () {
      db.addChatMessage(ChatMessage(fromId: 'u1', toId: 'u2', text: 'раз'));
      db.addChatMessage(ChatMessage(fromId: 'u2', toId: 'u1', text: 'два'));
      db.addChatMessage(ChatMessage(fromId: 'u1', toId: 'u3', text: 'три'));
      expect(db.messages.length, 3);

      expect(db.deleteChatMessage(db.messages.first.id), true);
      expect(db.messages.length, 2);

      // Очистка переписки u1↔u2 не трогает чужой чат u1↔u3.
      expect(db.clearChat('u1', 'u2'), 1);
      expect(db.messages.length, 1);
      expect(db.messages.single.text, 'три');
    });

    test('автоочистка по сроку хранения (0 — хранить всегда)', () {
      final DateTime old = DateTime.now().toUtc().subtract(const Duration(days: 10));
      db.addChatMessage(
          ChatMessage(fromId: 'u1', toId: 'u2', text: 'старое', createdAt: old));
      db.addChatMessage(ChatMessage(fromId: 'u1', toId: 'u2', text: 'новое'));
      expect(db.chatRetentionSweep(DateTime.now().toUtc()), 0); // 0 дней = выкл
      db.settings.chatKeepDays = 7;
      expect(db.chatRetentionSweep(DateTime.now().toUtc()), 1);
      expect(db.messages.single.text, 'новое');
    });

    test('снапшот содержит только сообщения участника', () {
      db.addChatMessage(ChatMessage(fromId: 'u1', toId: 'u2', text: 'личное'));
      expect((db.snapshot(forUserId: 'u3')['messages'] as List).isEmpty, true);
      expect((db.snapshot(forUserId: 'u2')['messages'] as List).length, 1);
    });
  });
}
