import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:quickpad/data/host_database.dart';
import 'package:quickpad/data/local_cache.dart';
import 'package:quickpad/models/chat_message.dart';
import 'package:quickpad/models/enums.dart';
import 'package:quickpad/models/note.dart';
import 'package:quickpad/models/user.dart';
import 'package:quickpad/net/client_connection.dart';
import 'package:quickpad/net/host_server.dart';
import 'package:quickpad/net/protocol.dart';

/// Сквозной тест: хост + два клиента по WebSocket (ТЗ 2).
void main() {
  test('синхронизация между двумя клиентами в реальном времени', () async {
    final Directory tmp = await Directory.systemTemp.createTemp('qp_sync');
    final HostDatabase db = HostDatabase(
        dataDir: Directory('${tmp.path}/host'), audioDir: Directory('${tmp.path}/audio'));
    await db.load();
    final HostServer server =
        HostServer(db: db, hostName: 'test-host', audioDir: db.audioDir, port: 0);
    await server.start();
    final int port = server.boundPort;

    Future<ClientConnection> mkClient(String id, String name, String dirName) async {
      final LocalCache cache = LocalCache(dataDir: Directory('${tmp.path}/$dirName'));
      await cache.load();
      final ClientConnection c = ClientConnection(cache: cache);
      await c.start(
        host: '127.0.0.1',
        port: port,
        userId: id,
        userName: name,
        deviceId: 'dev_$id',
        deviceName: 'Device $id',
        platform: 'test',
        listenConnectivity: false, // в тесте нет плагина connectivity
      );
      return c;
    }

    Future<void> waitFor(bool Function() cond, [String what = '']) async {
      for (int i = 0; i < 100; i++) {
        if (cond()) return;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      fail('timeout: $what');
    }

    final ClientConnection a = await mkClient('uA', 'Лена', 'ca');
    final ClientConnection b = await mkClient('uB', 'Петя', 'cb');

    await waitFor(() => a.state == ConnState.online && b.state == ConnState.online, 'online');
    await waitFor(() => a.cache.users.length == 2 && b.cache.users.length == 2, 'users sync');

    // Лена создаёт заявку → Петя получает в реальном времени.
    final Note n = Note(
        id: 'note-1', text: 'Принести картриджи', authorId: '', createdAt: DateTime.now().toUtc());
    a.sendOp(ClientMsg.noteCreate(n));
    await waitFor(() => b.cache.notes.containsKey('note-1'), 'note broadcast');
    final Note received = b.cache.notes['note-1']!;
    expect(received.authorId, 'uA'); // автор — от хоста
    expect(received.status, NoteStatus.fresh);
    expect(b.cache.audit.any((e) => e.type == AuditType.create && e.userId == 'uA'), true);

    // Петя берёт в работу → Лена видит статус и запись в журнале.
    b.sendOp(ClientMsg.notePatch('note-1', {NoteFields.status: 'in_progress'}, 1));
    await waitFor(() => a.cache.notes['note-1']!.status == NoteStatus.inProgress, 'patch');
    await waitFor(
        () => a.cache.audit.any((e) => e.type == AuditType.update && e.userId == 'uB'), 'audit');

    // Закрепление Лены персонально: у Пети его нет.
    a.sendOp(ClientMsg.pinSet('note-1', true));
    await waitFor(() => a.cache.pins.containsKey('uA:note-1'), 'pin');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(b.cache.pins.containsKey('uA:note-1'), true); // событие дошло, фильтр — в UI
    expect(b.cache.pins.containsKey('uB:note-1'), false);

    // Присутствие: оба онлайн.
    await waitFor(() => b.cache.users['uA']?.online == true, 'presence');

    // Уведомление о новой заявке пришло Пете.
    // (onNotify вызывается при note_create от другого пользователя)

    // ---------- Мессенджер ----------
    // Лена пишет Пете личное сообщение → доходит live, у Лены оно тоже есть.
    final ChatMessage chat =
        ChatMessage(fromId: 'uA', toId: 'uB', text: 'Принеси картриджи на 2 этаж');
    a.sendOp(ClientMsg.chatSend(chat.toJson()));
    await waitFor(
        () => b.cache.messages.any((m) => m.text.contains('2 этаж')), 'chat to B');
    await waitFor(
        () => a.cache.messages.any((m) => m.text.contains('2 этаж')), 'chat echo to A');
    expect(b.cache.messages.last.toId, 'uB');
    // Третьего пользователя нет — но проверим приватность снапшота:
    // сообщение uA→uB не должно попадать в чужой снапшот.
    final Map<String, dynamic> snapC = db.snapshot(forUserId: 'uC');
    expect((snapC['messages'] as List).isEmpty, true);
    final Map<String, dynamic> snapB = db.snapshot(forUserId: 'uB');
    expect((snapB['messages'] as List).length, 1);

    // Петя прочитал → у Лены сообщение становится прочитанным (✓✓).
    b.sendOp(ClientMsg.chatRead('uA'));
    await waitFor(
        () => a.cache.messages.any((m) => m.readAt != null), 'read receipt');

    await a.stop();
    await b.stop();
    await server.stop();
    await db.flush();
    await a.cache.flush();
    await b.cache.flush();
    // Windows: файлы могут быть ещё заняты — несколько попыток удаления.
    for (int i = 0; i < 20; i++) {
      try {
        await tmp.delete(recursive: true);
        break;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
    }
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('applyUsers заменяет список целиком: удалённый на хосте исчезает',
      () async {
    final Directory tmp = await Directory.systemTemp.createTemp('qp_users');
    final LocalCache cache =
        LocalCache(dataDir: Directory('${tmp.path}/client'));
    await cache.load();

    cache.applyUsers([
      AppUser(id: 'u1', name: 'Иван').toJson(),
      AppUser(id: 'u2', name: 'Мария').toJson(),
    ]);
    expect(cache.users.length, 2);

    // Хост удалил Марию и разослал полный список без неё.
    cache.applyUsers([AppUser(id: 'u1', name: 'Иван').toJson()]);
    expect(cache.users.length, 1);
    expect(cache.users.containsKey('u2'), isFalse);
    expect(cache.users['u1']?.name, 'Иван');
  });
}
