import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../core/constants.dart';
import '../data/host_database.dart';
import '../models/audit_entry.dart';
import '../models/chat_message.dart';
import '../models/contact.dart';
import '../models/enums.dart';
import '../models/note.dart';
import '../models/pin.dart';
import 'protocol.dart';

/// Сессия подключённого клиента.
class ClientSession {
  ClientSession({required this.channel});

  final WebSocketChannel channel;
  String userId = '';
  String userName = '';
  String deviceId = '';
  String deviceName = '';
  DateTime lastPing = DateTime.now().toUtc();
}

/// Сервер хоста (ТЗ, раздел 2 — хост на Windows-ПК):
/// WebSocket для реального времени + HTTP для аудиофайлов и проверки связи.
class HostServer {
  HostServer({
    required this.db,
    required this.hostName,
    required this.audioDir,
    this.port = kHostPort,
  }) {
    db.broadcast = broadcast;
  }

  final HostDatabase db;
  final String hostName;
  final Directory audioDir;
  final int port;

  /// Пользователь, вошедший на самом хосте (администратор хоста) —
  /// конечный адресат эскалации. Устанавливает приложение хоста.
  String hostUserId = '';

  HttpServer? _server;
  final Map<WebSocketChannel, ClientSession> _sessions = {};

  /// Очередь уведомлений для оффлайн-пользователей (доставляются при входе).
  final Map<String, List<Map<String, dynamic>>> _pendingNotify = {};

  bool get running => _server != null;

  /// Фактический порт (после start; при port=0 — выданный ОС).
  int get boundPort => _server?.port ?? port;

  Future<void> start() async {
    await audioDir.create(recursive: true);
    final Router router = Router()
      ..get('/api/ping', _handlePing)
      ..get('/ws', webSocketHandler(_onWebSocket))
      ..get('/audio/<name>', _handleGetAudio)
      ..post('/audio/<name>', _handlePostAudio);

    final Handler handler =
        const Pipeline().addMiddleware(_cors()).addHandler(router.call);
    _server = await shelf_io.serve(handler, InternetAddress.anyIPv4.address, port);
  }

  Future<void> stop() async {
    for (final WebSocketChannel ch in _sessions.keys.toList()) {
      await ch.sink.close();
    }
    _sessions.clear();
    await _server?.close(force: true);
    _server = null;
  }

  Middleware _cors() => (Handler inner) => (Request req) async {
        final Response res = await inner(req);
        return res.change(headers: {'Access-Control-Allow-Origin': '*'});
      };

  Response _handlePing(Request req) => Response.ok(
        jsonEncode({'ok': true, 'name': hostName, 'protocol': kProtocolVersion}),
        headers: {'content-type': 'application/json'},
      );

  // ---------- Аудио ----------

  Future<Response> _handleGetAudio(Request req, String name) async {
    final String safe = _safeName(name);
    final File f = File('${audioDir.path}${Platform.pathSeparator}$safe');
    if (!await f.exists()) return Response.notFound('not found');
    return Response.ok(f.openRead(),
        headers: {'content-type': 'audio/mp4', 'content-length': '${await f.length()}'});
  }

  Future<Response> _handlePostAudio(Request req, String name) async {
    final String safe = _safeName(name);
    final File f = File('${audioDir.path}${Platform.pathSeparator}$safe');
    final IOSink sink = f.openWrite();
    await for (final List<int> chunk in req.read()) {
      sink.add(chunk);
    }
    await sink.flush();
    await sink.close();
    return Response.ok(jsonEncode({'ok': true, 'fileName': safe, 'size': await f.length()}),
        headers: {'content-type': 'application/json'});
  }

  String _safeName(String name) =>
      name.replaceAll(RegExp(r'[^A-Za-z0-9_.\-]'), '_');

  // ---------- WebSocket ----------

  void _onWebSocket(WebSocketChannel channel, String? protocol) {
    final ClientSession session = ClientSession(channel: channel);
    _sessions[channel] = session;
    channel.stream.listen(
      (dynamic data) => _onMessage(session, data),
      onDone: () => _onDisconnect(session),
      onError: (_) => _onDisconnect(session),
    );
  }

  void _onDisconnect(ClientSession session) {
    _sessions.remove(session.channel);
    if (session.userId.isNotEmpty) {
      _refreshPresence(session.userId);
    }
  }

  void _send(ClientSession session, Map<String, dynamic> msg) {
    try {
      session.channel.sink.add(jsonEncode(msg));
    } catch (_) {}
  }

  /// Рассылка всем подключённым (или только устройствам пользователя [onlyUserId]).
  void broadcast(Map<String, dynamic> msg, {String? onlyUserId}) {
    final String text = jsonEncode(msg);
    for (final ClientSession s in _sessions.values) {
      if (onlyUserId != null && s.userId != onlyUserId) continue;
      try {
        s.channel.sink.add(text);
      } catch (_) {}
    }
  }

  /// Уведомление конкретному пользователю; если оффлайн — в очередь.
  /// Идёт через db.broadcast: тот же канал, что и остальные события, —
  /// обёртка приложения хоста покажет уведомление и локально на хосте.
  void notifyUser(String userId, Map<String, dynamic> msg) {
    final bool online = _sessions.values.any((s) => s.userId == userId);
    if (online) {
      (db.broadcast ?? broadcast)(msg, onlyUserId: userId);
    } else {
      final List<Map<String, dynamic>> q = _pendingNotify.putIfAbsent(userId, () => []);
      q.add(msg);
      if (q.length > 50) q.removeAt(0);
    }
  }

  /// Обновить онлайн-статус пользователя и разослать его.
  void _refreshPresence(String userId) {
    final bool online = _sessions.values.any((s) => s.userId == userId);
    final user = db.users[userId];
    if (user == null) return;
    if (user.online != online) {
      user.online = online;
      if (!online) user.lastSeen = DateTime.now().toUtc();
      db.saveUsers();
    }
    broadcast({
      'type': MsgType.presence,
      'userId': userId,
      'online': online,
      'lastSeen': user.lastSeen?.toIso8601String(),
    });
  }

  /// Вызывается планировщиком: переводит в оффлайн «зависших» пользователей.
  void presenceWatchdog() {
    final DateTime now = DateTime.now().toUtc();
    final Set<String> onlineUsers = _sessions.values.map((s) => s.userId).toSet();
    for (final user in db.users.values) {
      if (onlineUsers.contains(user.id)) continue;
      if (user.online &&
          (user.lastSeen == null || now.difference(user.lastSeen!) > kPresenceTimeout)) {
        user.online = false;
        user.lastSeen ??= now;
        db.saveUsers();
        broadcast({
          'type': MsgType.presence,
          'userId': user.id,
          'online': false,
          'lastSeen': user.lastSeen?.toIso8601String(),
        });
      }
    }
    // Пинги: закрыть сессии без признаков жизни.
    for (final ClientSession s in _sessions.values) {
      if (now.difference(s.lastPing) > kPresenceTimeout * 3) {
        try {
          s.channel.sink.close();
        } catch (_) {}
      }
    }
  }

  void _onMessage(ClientSession session, dynamic data) {
    Map<String, dynamic> msg;
    try {
      msg = (jsonDecode(data as String) as Map).cast<String, dynamic>();
    } catch (_) {
      return;
    }
    final String type = msg['type'] as String? ?? '';
    switch (type) {
      case MsgType.hello:
        _onHello(session, msg);
        break;
      case MsgType.ping:
        session.lastPing = DateTime.now().toUtc();
        final user = db.users[session.userId];
        if (user != null) {
          user.lastSeen = session.lastPing;
          db.saveUsers();
        }
        _send(session, {'type': MsgType.pong, 'serverTime': session.lastPing.toIso8601String()});
        break;
      case MsgType.noteCreate:
        if (!sessionReady(session)) return;
        final Note note = Note.fromJson((msg['note'] as Map).cast<String, dynamic>());
        final HostOpResult r =
            db.createNote(note, userId: session.userId, deviceId: session.deviceId);
        _broadcastNoteResult(r, actorId: session.userId, isNew: true);
        break;
      case MsgType.notePatch:
        if (!sessionReady(session)) return;
        final HostOpResult r = db.patchNote(
          msg['noteId'] as String,
          (msg['patch'] as Map).cast<String, dynamic>(),
          baseVersion: (msg['baseVersion'] as num?)?.toInt() ?? 0,
          userId: session.userId,
          deviceId: session.deviceId,
        );
        _broadcastNoteResult(r, actorId: session.userId);
        break;
      case MsgType.pinSet:
        if (!sessionReady(session)) return;
        final String noteId = msg['noteId'] as String;
        final bool pinned = msg['pinned'] as bool? ?? false;
        final HostOpResult r =
            db.setPin(session.userId, noteId, pinned, deviceId: session.deviceId);
        if (pinned) {
          final Pin? p = db.pins['${session.userId}:$noteId'];
          if (p != null) {
            broadcast({'type': MsgType.pinUpsert, 'pin': p.toJson(), 'audit': _auditJson(r.audit)});
          }
        } else {
          broadcast({
            'type': MsgType.pinRemove,
            'userId': session.userId,
            'noteId': noteId,
            'audit': _auditJson(r.audit),
          });
        }
        break;
      case MsgType.pinsOrder:
        if (!sessionReady(session)) return;
        final List<String> ids =
            (msg['noteIds'] as List? ?? []).map((e) => e.toString()).toList();
        db.reorderPins(session.userId, ids);
        broadcast({'type': MsgType.pinsOrder, 'userId': session.userId, 'noteIds': ids});
        break;
      case MsgType.contactUpsert:
        if (!sessionReady(session)) return;
        final Contact c = Contact.fromJson((msg['contact'] as Map).cast<String, dynamic>());
        final HostOpResult r =
            db.upsertContact(c, userId: session.userId, deviceId: session.deviceId);
        broadcast({
          'type': MsgType.contactUpsert,
          'contact': c.toJson(),
          'audit': _auditJson(r.audit),
        });
        _notifyContactChange(session.userId, r.audit.isEmpty ? null : r.audit.last.details);
        break;
      case MsgType.contactDelete:
        if (!sessionReady(session)) return;
        final HostOpResult r = db.deleteContact(msg['contactId'] as String,
            userId: session.userId, deviceId: session.deviceId);
        broadcast({
          'type': MsgType.contactDeleted,
          'contactId': msg['contactId'],
          'audit': _auditJson(r.audit),
        });
        _notifyContactChange(session.userId, r.audit.isEmpty ? null : r.audit.last.details);
        break;
      case MsgType.requestSnapshot:
        _sendSnapshot(session);
        break;
      case MsgType.chatSend:
        if (!sessionReady(session)) return;
        final ChatMessage chatMsg =
            ChatMessage.fromJson((msg['message'] as Map).cast<String, dynamic>());
        _deliverChat(chatMsg);
        break;
      case MsgType.chatRead:
        if (!sessionReady(session)) return;
        _deliverChatRead(fromId: msg['fromId'] as String? ?? '', toId: session.userId);
        break;
    }
  }

  bool sessionReady(ClientSession s) => s.userId.isNotEmpty;

  void _onHello(ClientSession session, Map<String, dynamic> msg) {
    session.userId = msg['userId'] as String? ?? '';
    session.userName = msg['userName'] as String? ?? 'Без имени';
    session.deviceId = msg['deviceId'] as String? ?? '';
    session.deviceName = msg['deviceName'] as String? ?? '';
    if (session.userId.isEmpty) return;

    db.helloUser(
        userId: session.userId, userName: session.userName, deviceId: session.deviceId);
    final user = db.users[session.userId]!;
    user.online = true;
    user.lastSeen = DateTime.now().toUtc();
    db.saveUsers();

    _send(session, {
      'type': MsgType.welcome,
      'hostName': hostName,
      'hostUserId': hostUserId,
      'serverTime': DateTime.now().toUtc().toIso8601String(),
      'protocol': kProtocolVersion,
    });
    _sendSnapshot(session);

    // Доставить отложенные уведомления.
    final List<Map<String, dynamic>> pending = _pendingNotify.remove(session.userId) ?? [];
    for (final Map<String, dynamic> m in pending) {
      _send(session, m);
    }
    _refreshPresence(session.userId);
  }

  void _sendSnapshot(ClientSession session) {
    final Map<String, dynamic> snap = db.snapshot(forUserId: session.userId);
    snap['type'] = MsgType.snapshot;
    _send(session, snap);
  }

  List<dynamic> _auditJson(List<AuditEntry> entries) => entries.map((e) => e.toJson()).toList();

  void _broadcastNoteResult(HostOpResult r, {String? actorId, bool isNew = false}) {
    if (r.note == null) return;
    broadcast({
      'type': MsgType.noteUpsert,
      'note': r.note!.toJson(),
      'audit': _auditJson(r.audit),
    });
    // Уведомление о редактировании заявки (ТЗ 6.2, отключаемо на клиенте).
    // Создание уведомляет HostDatabase._maybeNotifyNew; здесь — только правки.
    if (isNew) return;
    final List<AuditEntry> updates =
        r.audit.where((e) => e.type == AuditType.update).toList();
    if (updates.isEmpty) return;
    final String who = actorId != null ? db.userName(actorId) : '';
    final List<String> parts = updates.take(3).map((e) {
      final String f = NoteFields.labels[e.field] ?? e.field ?? '';
      return '$f: «${e.oldValue ?? '—'}» → «${e.newValue ?? '—'}»';
    }).toList();
    if (updates.length > 3) parts.add('…');
    // Через db.broadcast: уведомление увидят и клиенты, и сам хост локально.
    (db.broadcast ?? broadcast)({
      'type': MsgType.notify,
      'kind': NotifyKind.noteChanged.wire,
      'noteId': r.note!.id,
      'actorId': actorId,
      'title': 'Заявка изменена${who.isEmpty ? '' : ' — $who'}',
      'body': parts.join('; '),
    });
  }

  /// Уведомление об изменении библиотеки контактов (отключаемо на клиенте).
  void _notifyContactChange(String? actorId, String? details) {
    if (details == null) return;
    final String who = actorId != null ? db.userName(actorId) : '';
    (db.broadcast ?? broadcast)({
      'type': MsgType.notify,
      'kind': NotifyKind.noteChanged.wire,
      'actorId': actorId,
      'title': 'Контакты',
      'body': '${who.isEmpty ? 'Пользователь' : who}: $details',
    });
  }

  // ---------- Мессенджер ----------

  /// Принять и доставить личное сообщение: обоим участникам (live) +
  /// уведомление получателю (или в оффлайн-очередь).
  void _deliverChat(ChatMessage m) {
    db.addChatMessage(m);
    final Map<String, dynamic> event = {'type': MsgType.chatMessage, 'message': m.toJson()};
    // Отправителю (все его устройства) и получателю.
    for (final String uid in {m.fromId, m.toId}) {
      if (_sessions.values.any((s) => s.userId == uid)) {
        broadcast(event, onlyUserId: uid);
      }
    }
    // Уведомление получателю — через db.broadcast, чтобы хост тоже увидел локально.
    final String preview =
        m.text.isNotEmpty ? m.text : '🎤 Голосовое сообщение (${m.audioDurationSec ?? 0} c)';
    notifyUser(m.toId, {
      'type': MsgType.notify,
      'kind': NotifyKind.chat.wire,
      'actorId': m.fromId,
      'title': 'Сообщение от ${db.userName(m.fromId)}',
      'body': preview.length > 120 ? '${preview.substring(0, 120)}…' : preview,
    });
  }

  /// Получатель прочитал переписку: отметить и сообщить отправителю.
  void _deliverChatRead({required String fromId, required String toId}) {
    if (fromId.isEmpty || toId.isEmpty) return;
    if (db.markChatRead(fromId: fromId, toId: toId)) {
      final Map<String, dynamic> event = {
        'type': MsgType.chatRead,
        'fromId': fromId,
        'toId': toId,
      };
      for (final String uid in {fromId, toId}) {
        if (_sessions.values.any((s) => s.userId == uid)) {
          broadcast(event, onlyUserId: uid);
        }
      }
      // Локальный UI хоста обновится сам: markChatRead → saveMessages → onDataChanged.
    }
  }

  /// Отправка сообщения пользователем самого хоста.
  void localSendChat(ChatMessage m) => _deliverChat(m);

  /// Пользователь хоста прочитал переписку.
  void localChatRead({required String fromId, required String toId}) {
    _deliverChatRead(fromId: fromId, toId: toId);
  }

  // ---------- Локальные операции (пользователь самого хоста) ----------

  /// Создание заявки на самом хосте — те же правила, что и у клиентов.
  void localCreateNote(Note note, {required String userId}) {
    final HostOpResult r = db.createNote(note, userId: userId, deviceId: 'host');
    _broadcastNoteResult(r, actorId: userId, isNew: true);
  }

  /// Изменение полей заявки на самом хосте.
  void localPatchNote(String noteId, Map<String, dynamic> patch,
      {required int baseVersion, required String userId}) {
    final HostOpResult r = db.patchNote(noteId, patch,
        baseVersion: baseVersion, userId: userId, deviceId: 'host');
    _broadcastNoteResult(r, actorId: userId);
  }

  /// Закрепление/открепление пользователем хоста.
  void localSetPin(String userId, String noteId, bool pinned) {
    final HostOpResult r = db.setPin(userId, noteId, pinned, deviceId: 'host');
    if (pinned) {
      final Pin? p = db.pins['$userId:$noteId'];
      if (p != null) {
        broadcast({'type': MsgType.pinUpsert, 'pin': p.toJson(), 'audit': _auditJson(r.audit)});
      }
    } else {
      broadcast({
        'type': MsgType.pinRemove,
        'userId': userId,
        'noteId': noteId,
        'audit': _auditJson(r.audit),
      });
    }
  }

  /// Ручной порядок закреплённых пользователем хоста.
  void localReorderPins(String userId, List<String> orderedNoteIds) {
    db.reorderPins(userId, orderedNoteIds);
    broadcast({'type': MsgType.pinsOrder, 'userId': userId, 'noteIds': orderedNoteIds});
  }

  void localUpsertContact(Contact contact, {required String userId}) {
    final HostOpResult r = db.upsertContact(contact, userId: userId, deviceId: 'host');
    broadcast({
      'type': MsgType.contactUpsert,
      'contact': contact.toJson(),
      'audit': _auditJson(r.audit),
    });
    _notifyContactChange(userId, r.audit.isEmpty ? null : r.audit.last.details);
  }

  void localDeleteContact(String contactId, {required String userId}) {
    final HostOpResult r = db.deleteContact(contactId, userId: userId, deviceId: 'host');
    broadcast({
      'type': MsgType.contactDeleted,
      'contactId': contactId,
      'audit': _auditJson(r.audit),
    });
    _notifyContactChange(userId, r.audit.isEmpty ? null : r.audit.last.details);
  }

  /// Трансляция хостовых настроек всем клиентам после изменения на хосте.
  void broadcastHostSettings() {
    broadcast({'type': MsgType.hostSettings, 'settings': db.settings.toJson()});
  }

  /// Полная пересылка снапшота всем подключённым (после восстановления из копии).
  void broadcastSnapshotToAll() {
    for (final ClientSession s in _sessions.values) {
      _sendSnapshot(s);
    }
  }
}
