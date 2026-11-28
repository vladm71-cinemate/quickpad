import 'dart:async';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../core/constants.dart';
import '../data/local_cache.dart';
import '../models/audit_entry.dart';
import '../models/chat_message.dart';
import '../models/contact.dart';
import '../models/enums.dart';
import '../models/note.dart';
import '../models/pin.dart';
import 'protocol.dart';

/// Устойчивое клиентское подключение к хосту (ТЗ 2, 4.5):
/// автопереподключение, ping/pong, оффлайн-очередь, досинхронизация.
class ClientConnection extends ChangeNotifier {
  ClientConnection({required this.cache});

  final LocalCache cache;

  String host = '';
  int port = kHostPort;
  String userId = '';
  String userName = '';
  String deviceId = '';
  String deviceName = '';
  String platform = '';

  ConnState state = ConnState.offline;
  String hostName = '';
  String hostUserId = '';
  DateTime? lastError;

  /// Уведомление от хоста (показать локально).
  void Function(Map<String, dynamic> msg)? onNotify;

  /// Данные изменились (снапшот/событие) — обновить UI.
  void Function()? onDataChanged;

  WebSocketChannel? _ch;
  StreamSubscription<dynamic>? _sub;
  Timer? _pingTimer;
  Timer? _reconnectTimer;
  StreamSubscription<List<ConnectivityResult>>? _connSub;
  bool _running = false;
  int _retrySec = 2;

  bool get isOnline => state == ConnState.online;

  Future<void> start({
    required String host,
    required int port,
    required String userId,
    required String userName,
    required String deviceId,
    required String deviceName,
    required String platform,
    bool listenConnectivity = true,
  }) async {
    this.host = host;
    this.port = port;
    this.userId = userId;
    this.userName = userName;
    this.deviceId = deviceId;
    this.deviceName = deviceName;
    this.platform = platform;
    _running = true;
    if (listenConnectivity) {
      unawaited(_connSub?.cancel());
      _connSub = Connectivity().onConnectivityChanged.listen((List<ConnectivityResult> results) {
        final bool anyNet = results.any((r) => r != ConnectivityResult.none);
        if (anyNet && state == ConnState.offline) {
          _retrySec = 2;
          _scheduleReconnect(const Duration(milliseconds: 300));
        }
      });
    }
    await _connectOnce();
  }

  Future<void> stop() async {
    _running = false;
    _pingTimer?.cancel();
    _reconnectTimer?.cancel();
    await _connSub?.cancel();
    await _sub?.cancel();
    try {
      await _ch?.sink.close();
    } catch (_) {}
    _ch = null;
    _setState(ConnState.offline);
  }

  /// Отправить операцию. Вернёт true, если ушла сразу; иначе — в оффлайн-очередь.
  bool sendOp(Map<String, dynamic> op, {bool queueIfOffline = true}) {
    if (isOnline && _ch != null) {
      try {
        _ch!.sink.add(jsonEncode(op));
        return true;
      } catch (_) {}
    }
    if (queueIfOffline) cache.enqueue(op);
    return false;
  }

  void requestSync() {
    if (isOnline) {
      sendOp(ClientMsg.requestSnapshot(), queueIfOffline: false);
    } else {
      _retrySec = 2;
      _scheduleReconnect(Duration.zero);
    }
  }

  // ---------- Внутреннее ----------

  Future<void> _connectOnce() async {
    if (!_running) return;
    _setState(ConnState.syncing);
    try {
      final Uri uri = Uri.parse('ws://$host:$port/ws');
      final WebSocketChannel ch = IOWebSocketChannel.connect(uri);
      await ch.ready;
      _ch = ch;
      _sub = ch.stream.listen(_onData, onDone: _onClosed, onError: (_) => _onClosed());
      _ch!.sink.add(jsonEncode(ClientMsg.hello(
        userId: userId,
        userName: userName,
        deviceId: deviceId,
        deviceName: deviceName,
        platform: platform,
        protocolVersion: kProtocolVersion,
      )));
      _startPing();
    } catch (_) {
      lastError = DateTime.now();
      _setState(ConnState.offline);
      _scheduleReconnect();
    }
  }

  void _startPing() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(kPingInterval, (_) {
      try {
        _ch?.sink.add(jsonEncode(ClientMsg.ping()));
      } catch (_) {}
    });
  }

  void _scheduleReconnect([Duration? delay]) {
    if (!_running) return;
    _reconnectTimer?.cancel();
    final Duration d = delay ?? Duration(seconds: _retrySec);
    _reconnectTimer = Timer(d, () {
      _retrySec = (_retrySec * 2).clamp(2, 20);
      unawaited(_connectOnce());
    });
  }

  void _onClosed() {
    _pingTimer?.cancel();
    _sub?.cancel();
    _ch = null;
    if (!_running) return;
    _setState(ConnState.offline);
    _scheduleReconnect();
  }

  void _setState(ConnState s) {
    if (state == s) return;
    state = s;
    notifyListeners();
  }

  void _onData(dynamic data) {
    Map<String, dynamic> msg;
    try {
      msg = (jsonDecode(data as String) as Map).cast<String, dynamic>();
    } catch (_) {
      return;
    }
    switch (msg['type'] as String? ?? '') {
      case MsgType.welcome:
        hostName = msg['hostName'] as String? ?? '';
        hostUserId = msg['hostUserId'] as String? ?? '';
        _flushOutbox();
        break;
      case MsgType.snapshot:
        cache.applySnapshot(msg);
        _setState(ConnState.online);
        _retrySec = 2;
        onDataChanged?.call();
        break;
      case MsgType.noteUpsert:
        final Object? n = msg['note'];
        if (n is Map) cache.applyNoteUpsert(Note.fromJson(n.cast<String, dynamic>()));
        cache.applyAuditEntries(msg['audit'] as List? ?? []);
        onDataChanged?.call();
        break;
      case MsgType.noteDeleted:
        cache.removeNote(msg['noteId'] as String? ?? '');
        cache.applyAuditEntries(msg['audit'] as List? ?? []);
        onDataChanged?.call();
        break;
      case MsgType.users:
        cache.applyUsers(msg['users'] as List? ?? []);
        onDataChanged?.call();
        break;
      case MsgType.presence:
        cache.applyPresence(
          msg['userId'] as String? ?? '',
          msg['online'] as bool? ?? false,
          msg['lastSeen'] != null ? DateTime.tryParse(msg['lastSeen'] as String) : null,
        );
        onDataChanged?.call();
        break;
      case MsgType.pinUpsert:
        final Object? p = msg['pin'];
        if (p is Map) cache.applyPin(Pin.fromJson(p.cast<String, dynamic>()));
        cache.applyAuditEntries(msg['audit'] as List? ?? []);
        onDataChanged?.call();
        break;
      case MsgType.pinRemove:
        cache.removePin(msg['userId'] as String? ?? '', msg['noteId'] as String? ?? '');
        cache.applyAuditEntries(msg['audit'] as List? ?? []);
        onDataChanged?.call();
        break;
      case MsgType.pinsOrder:
        _applyPinsOrder(msg);
        break;
      case MsgType.contactUpsert:
        final Object? c = msg['contact'];
        if (c is Map) cache.applyContact(Contact.fromJson(c.cast<String, dynamic>()));
        cache.applyAuditEntries(msg['audit'] as List? ?? []);
        onDataChanged?.call();
        break;
      case MsgType.contactDeleted:
        cache.removeContact(msg['contactId'] as String? ?? '');
        cache.applyAuditEntries(msg['audit'] as List? ?? []);
        onDataChanged?.call();
        break;
      case MsgType.hostSettings:
        final Object? s = msg['settings'];
        if (s is Map) cache.applyHostSettings(s.cast<String, dynamic>());
        onDataChanged?.call();
        break;
      case MsgType.auditCleared:
        // Хост очистил журнал — чистим локальную копию.
        cache.audit.clear();
        cache.saveAudit();
        onDataChanged?.call();
        break;
      case MsgType.notify:
        onNotify?.call(msg);
        break;
      case MsgType.chatMessage:
        final Object? m = msg['message'];
        if (m is Map) {
          cache.applyChatMessage(ChatMessage.fromJson(m.cast<String, dynamic>()));
          onDataChanged?.call();
        }
        break;
      case MsgType.chatRead:
        // Пользователь toId прочитал сообщения от fromId — отметить их прочитанными.
        cache.applyChatRead(
            fromId: msg['fromId'] as String? ?? '', toId: msg['toId'] as String? ?? '');
        onDataChanged?.call();
        break;
      case MsgType.chatDeleted:
        cache.removeChatMessage(msg['messageId'] as String? ?? '');
        onDataChanged?.call();
        break;
      case MsgType.chatCleared:
        cache.clearChat(
            msg['userA'] as String? ?? '', msg['userB'] as String? ?? '');
        onDataChanged?.call();
        break;
      case MsgType.pong:
        break;
    }
  }

  void _applyPinsOrder(Map<String, dynamic> msg) {
    if ((msg['userId'] as String? ?? '') != userId) return;
    final List<String> ids = (msg['noteIds'] as List? ?? []).map((e) => e.toString()).toList();
    for (int i = 0; i < ids.length; i++) {
      final Pin? p = cache.pins['$userId:${ids[i]}'];
      if (p != null) p.orderIndex = i;
    }
    cache.savePins();
    onDataChanged?.call();
  }

  /// Досинхронизация после возврата в сеть (ТЗ 4.5): отправляем очередь,
  /// затем просим снапшот — хост авторитетен.
  void _flushOutbox() {
    int sent = 0;
    for (final Map<String, dynamic> op in cache.outbox) {
      try {
        _ch!.sink.add(jsonEncode(op));
        sent++;
      } catch (_) {
        break;
      }
    }
    cache.dequeueFirst(sent);
    sendOp(ClientMsg.requestSnapshot(), queueIfOffline: false);
  }

  /// Список аудита новых записей из последнего события — вспомогательно.
  List<AuditEntry> recentAuditFor(String noteId) =>
      cache.audit.where((e) => e.noteId == noteId).toList();
}
