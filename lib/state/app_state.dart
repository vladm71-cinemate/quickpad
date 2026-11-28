import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/constants.dart';
import '../core/ids.dart';
import '../core/timefmt.dart';
import '../data/backup_service.dart';
import '../data/host_database.dart';
import '../data/local_cache.dart';
import '../models/audit_entry.dart';
import '../models/chat_message.dart';
import '../models/contact.dart';
import '../models/enums.dart';
import '../models/note.dart';
import '../models/note_ops.dart';
import '../models/pin.dart';
import '../services/photo_service.dart';
import '../models/settings.dart';
import '../models/user.dart';
import '../net/client_connection.dart';
import '../net/discovery.dart';
import '../net/host_jobs.dart';
import '../net/host_server.dart';
import '../net/protocol.dart';
import '../services/audio_service.dart';
import '../services/background_service.dart';
import '../services/device_info.dart';
import '../services/notification_service.dart';
import '../services/stt_service.dart';
import '../services/widget_service.dart';
import 'settings_controller.dart';

/// Сводка дня (ТЗ 4.4): Новых / В работе / Выполнено сегодня / Просрочено.
class DaySummary {
  const DaySummary({
    required this.fresh,
    required this.inProgress,
    required this.doneToday,
    required this.overdue,
  });

  final int fresh;
  final int inProgress;
  final int doneToday;
  final int overdue;

  static DaySummary compute(Iterable<Note> notes) {
    final DateTime now = DateTime.now();
    final DateTime todayUtc = DateTime.utc(now.year, now.month, now.day);
    int fresh = 0, inProgress = 0, doneToday = 0, overdue = 0;
    for (final Note n in notes) {
      if (n.status == NoteStatus.fresh) fresh++;
      if (n.status == NoteStatus.inProgress) inProgress++;
      if (n.status == NoteStatus.done && n.updatedAt.isAfter(todayUtc)) doneToday++;
      if (n.isOverdue()) overdue++;
    }
    return DaySummary(fresh: fresh, inProgress: inProgress, doneToday: doneToday, overdue: overdue);
  }
}

/// Глобальное состояние приложения: режим (хост/клиент), данные, операции.
///
/// Хост (Windows): HostDatabase + HostServer + HostJobs + BackupService + HostAnnouncer.
/// Клиент (Android/Windows): ClientConnection + LocalCache (оффлайн-режим, ТЗ 4.5).
class AppState extends ChangeNotifier {
  AppState({required this.prefs, required this.settingsCtl});

  final SharedPreferences prefs;
  final SettingsController settingsCtl;

  final NotificationService notifications = NotificationService();
  final SttService stt = SttService();
  final AudioService audio = AudioService();
  final WidgetService _widget = WidgetService();
  final BackgroundService background = BackgroundService();

  late final Directory baseDir;
  late final DeviceIdentity device;

  HostDatabase? _db;
  HostServer? _server;
  HostJobs? _jobs;
  HostAnnouncer? _announcer;
  BackupService? _backup;

  ClientConnection? _client;
  LocalCache? _cache;

  bool ready = false;
  DeviceRole role = DeviceRole.client;
  AppUser? currentUser;
  String lastError = '';

  static const String _kRole = 'app.role';
  static const String _kUserId = 'app.userId';
  static const String _kUserName = 'app.userName';
  static const String _kHostAddr = 'app.hostAddress';
  static const String _kHostPort = 'app.hostPort';
  static const String _kConfigured = 'app.configured';

  // ---------- Общие геттеры ----------

  LocalSettings get ls => settingsCtl.settings;
  bool get configured => prefs.getBool(_kConfigured) ?? false;
  bool get isHost => role == DeviceRole.host;
  bool get serverRunning => _server?.running ?? false;

  HostSettings get hs =>
      isHost ? (_db?.settings ?? HostSettings()) : (_cache?.hostSettings ?? HostSettings());

  List<Note> get notes => isHost
      ? (_db?.notes.values.toList() ?? [])
      : (_cache?.notes.values.toList() ?? []);
  List<AppUser> get users => isHost
      ? (_db?.users.values.toList() ?? [])
      : (_cache?.users.values.toList() ?? []);
  List<Contact> get contacts => isHost
      ? (_db?.contacts.values.toList() ?? [])
      : (_cache?.contacts.values.toList() ?? []);
  List<Pin> get pins => isHost
      ? (_db?.pins.values.toList() ?? [])
      : (_cache?.pins.values.toList() ?? []);
  List<AuditEntry> get audit =>
      isHost ? (_db?.audit ?? const []) : (_cache?.audit ?? const []);

  // ---------- Мессенджер ----------

  /// Все видимые мне сообщения (на хосте — только мои чаты).
  List<ChatMessage> get messages {
    final String? uid = currentUser?.id;
    final List<ChatMessage> all =
        isHost ? (_db?.messages ?? []) : (_cache?.messages ?? []);
    if (uid == null) return const [];
    return all.where((m) => m.fromId == uid || m.toId == uid).toList();
  }

  /// Переписка с конкретным пользователем, по времени.
  List<ChatMessage> chatWith(String peerId) {
    final String? uid = currentUser?.id;
    if (uid == null) return const [];
    final List<ChatMessage> list = messages
        .where((m) =>
            (m.fromId == uid && m.toId == peerId) ||
            (m.fromId == peerId && m.toId == uid))
        .toList();
    list.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return list;
  }

  /// Непрочитанные от [peerId] мне.
  int unreadFrom(String peerId) {
    final String? uid = currentUser?.id;
    if (uid == null) return 0;
    return messages
        .where((m) => m.fromId == peerId && m.toId == uid && m.readAt == null)
        .length;
  }

  /// Всего непрочитанных (для бейджа на кнопке).
  int get unreadChatTotal {
    final String? uid = currentUser?.id;
    if (uid == null) return 0;
    return messages.where((m) => m.toId == uid && m.readAt == null).length;
  }

  /// Пользователи, с которыми можно переписываться (все, кроме меня),
  /// с последним сообщением для сортировки/превью.
  List<AppUser> get chatPeers => users.where((u) => u.id != currentUser?.id).toList();

  /// Отправить текстовое или голосовое сообщение пользователю [toId].
  Future<ChatMessage> sendChatMessage(String toId,
      {String text = '', AudioAttachment? audio, String? replyToId}) async {
    final AppUser me = currentUser!;
    final ChatMessage m = ChatMessage(
      fromId: me.id,
      toId: toId,
      text: text.trim(),
      audioFileName: audio?.fileName,
      audioDurationSec: audio?.durationSec,
      replyToId: replyToId,
    );
    if (isHost) {
      _server?.localSendChat(m);
    } else {
      _client?.sendOp(ClientMsg.chatSend(m.toJson()));
      _cache?.applyChatMessage(m); // оптимистично
    }
    notifyListeners();
    return m;
  }

  /// Отметить переписку с [peerId] прочитанной.
  Future<void> markChatRead(String peerId) async {
    final String? uid = currentUser?.id;
    if (uid == null) return;
    if (isHost) {
      _server?.localChatRead(fromId: peerId, toId: uid);
    } else {
      _cache?.applyChatRead(fromId: peerId, toId: uid); // оптимистично
      _client?.sendOp(ClientMsg.chatRead(peerId), queueIfOffline: false);
    }
    notifyListeners();
  }

  /// Удалить одно сообщение (у всех участников).
  Future<void> deleteChatMessage(ChatMessage m) async {
    final String? uid = currentUser?.id;
    if (uid == null) return;
    if (isHost) {
      _server?.localDeleteChatMessage(m.id, byUserId: uid);
    } else {
      _cache?.removeChatMessage(m.id); // оптимистично
      _client?.sendOp(ClientMsg.chatDelete(m.id));
    }
    notifyListeners();
  }

  /// Очистить всю переписку с [peerId] (у обоих участников).
  Future<void> clearChat(String peerId) async {
    final String? uid = currentUser?.id;
    if (uid == null) return;
    if (isHost) {
      _server?.localClearChat(peerId, myUserId: uid);
    } else {
      _cache?.clearChat(uid, peerId); // оптимистично
      _client?.sendOp(ClientMsg.chatClear(peerId));
    }
    notifyListeners();
  }

  ConnState get connState => isHost
      ? (serverRunning ? ConnState.online : ConnState.offline)
      : (_client?.state ?? ConnState.offline);

  int get queuedCount => _cache?.outbox.length ?? 0;
  String get hostAddress => prefs.getString(_kHostAddr) ?? '';
  int get hostPort => prefs.getInt(_kHostPort) ?? kHostPort;

  // ---------- Виджет рабочего стола (Android) ----------

  Timer? _widgetTimer;

  /// Отложенное обновление виджета: закреплённая заявка (первая по порядку),
  /// иначе — последняя по времени изменения. Размер виджета настраивает
  /// пользователь на рабочем столе (ресайз включён).
  void syncWidget() {
    if (!(Platform.isAndroid)) return;
    _widgetTimer?.cancel();
    _widgetTimer = Timer(const Duration(milliseconds: 700), () {
      Note? shown;
      bool pinned = false;
      for (final Pin p in myPins) {
        final Note? n = noteById(p.noteId);
        if (n != null &&
            n.status != NoteStatus.done &&
            n.status != NoteStatus.rejected) {
          shown = n;
          pinned = true;
          break;
        }
      }
      if (shown == null) {
        final List<Note> active = notes
            .where((n) =>
                n.status != NoteStatus.done && n.status != NoteStatus.rejected)
            .toList()
          ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
        if (active.isNotEmpty) shown = active.first;
      }
      shown ??= notes.isEmpty
          ? null
          : (List<Note>.from(notes)
            ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt)))
              .first;
      if (shown == null) {
        unawaited(_widget.update(status: '', text: '', meta: ''));
        return;
      }
      final String status =
          '${pinned ? '📌 ' : ''}${shown.status.label}${shown.isOverdue() ? ' · просрочена' : ''}';
      final String meta =
          '${userName(shown.authorId)} · ${formatRelative(shown.updatedAt)}';
      unawaited(_widget.update(status: status, text: shown.text, meta: meta));
    });
  }

  String get connectionLabel {
    if (isHost) return serverRunning ? 'Хост запущен (порт $kHostPort)' : 'Хост остановлен';
    switch (connState) {
      case ConnState.online:
        return 'Подключено к хосту';
      case ConnState.syncing:
        return 'Синхронизация…';
      case ConnState.offline:
        return queuedCount > 0 ? 'Оффлайн (в очереди: $queuedCount)' : 'Нет связи (оффлайн)';
    }
  }

  // ---------- Инициализация ----------

  bool _baseReady = false;
  bool _hostStarted = false;

  /// Одноразовая инициализация. Повторные вызовы безопасны (идемпотентно).
  Future<void> init() async {
    if (_baseReady) return;
    _baseReady = true;
    final Directory support = await getApplicationSupportDirectory();
    baseDir = Directory('${support.path}${Platform.pathSeparator}quickpad');
    await baseDir.create(recursive: true);

    device = await loadDeviceIdentity(prefs);
    role = prefs.getString(_kRole) == 'host' ? DeviceRole.host : DeviceRole.client;

    await notifications.init();
    // Фоновая связь на Android: foreground service держит процесс живым,
    // чтобы уведомления приходили при закрытом окне.
    unawaited(background.setEnabled(ls.bgKeepAlive));
    // STT инициализируется лениво при первом нажатии кнопки диктовки —
    // разрешение микрофона не запрашиваем при старте приложения.
    unawaited(audio.cleanupTemp());
    // Усиление громкости (Android) и обновление настроек на лету.
    audio.initBoost();
    audio.boostDb = ls.volumeBoostDb;
    settingsCtl.addListener(() {
      audio.boostDb = settingsCtl.settings.volumeBoostDb;
    });

    if (isHost) {
      await _startHostStack();
    } else if (configured) {
      // Сеть не должна блокировать запуск приложения: подключаемся в фоне,
      // оффлайн-режим (ТЗ 4.5) позволяет работать до появления связи.
      unawaited(_startClientStack());
    }

    ready = true;
    syncWidget();
    notifyListeners();
  }

  Future<void> _startHostStack() async {
    if (_hostStarted) return; // стек уже запущен
    final Directory hostDir = Directory('${baseDir.path}${Platform.pathSeparator}host');
    final Directory audioDir = Directory('${hostDir.path}${Platform.pathSeparator}audio');
    final Directory backupDir = Directory('${hostDir.path}${Platform.pathSeparator}backups');

    _db = HostDatabase(dataDir: hostDir, audioDir: audioDir);
    await _db!.load();

    final String? uid = prefs.getString(_kUserId);
    final String uname = prefs.getString(_kUserName) ?? 'Хост';
    if (uid != null) {
      currentUser =
          _db!.helloUser(userId: uid, userName: uname, deviceId: device.deviceId);
      currentUser!.online = true;
      currentUser!.lastSeen = DateTime.now().toUtc();
      _db!.saveUsers();
    }

    _server = HostServer(db: _db!, hostName: device.deviceName, audioDir: audioDir);
    if (uid != null) _server!.hostUserId = uid;

    // Цепочка на рассылку: локальные уведомления на хосте + обновление UI.
    final void Function(Map<String, dynamic>, {String? onlyUserId}) orig = _server!.broadcast;
    _db!.broadcast = (Map<String, dynamic> msg, {String? onlyUserId}) {
      orig(msg, onlyUserId: onlyUserId);
      _onHostBroadcast(msg, onlyUserId);
    };

    _backup = BackupService(db: _db!, backupDir: backupDir);
    _db!.onDataChanged = () {
      _backup!.scheduleAutoBackup();
      notifyListeners();
    };

    await _server!.start();
    _jobs = HostJobs(db: _db!, server: _server!)..start();
    _announcer = HostAnnouncer(hostName: device.deviceName);
    unawaited(_announcer!.start());
    _hostStarted = true;
  }

  void _onHostBroadcast(Map<String, dynamic> msg, String? onlyUserId) {
    if (msg['type'] == MsgType.notify) {
      final String? hostUid = _server?.hostUserId;
      // Не уведомляем автора о его собственных правках.
      if (msg['actorId'] != null && msg['actorId'] == currentUser?.id) return;
      if (onlyUserId == null || onlyUserId == hostUid) {
        unawaited(notifications.showFromHost(msg, ls));
      }
    }
    syncWidget();
    notifyListeners();
  }

  Future<void> _startClientStack() async {
    final String? addr = prefs.getString(_kHostAddr);
    final String? uid = prefs.getString(_kUserId);
    if (addr == null || addr.isEmpty || uid == null) return;

    _cache ??= LocalCache(dataDir: Directory('${baseDir.path}${Platform.pathSeparator}client'));
    await _cache!.load();

    final String uname = prefs.getString(_kUserName) ?? '';
    currentUser = _cache!.users[uid] ??
        AppUser(id: uid, name: uname.isEmpty ? 'Без имени' : uname, deviceIds: [device.deviceId]);

    await _client?.stop();
    _client = ClientConnection(cache: _cache!);
    _client!.onDataChanged = () {
      // Имя могло быть уточнено хостом (уникальность имён).
      final String? uid = currentUser?.id;
      final AppUser? fresh = uid == null ? null : _cache!.users[uid];
      if (fresh != null && !identical(fresh, currentUser)) {
        currentUser = fresh;
      }
      syncWidget();
      notifyListeners();
    };
    _client!.onNotify = (Map<String, dynamic> msg) {
      // Не уведомляем автора о его собственных правках.
      if (msg['actorId'] != null && msg['actorId'] == currentUser?.id) return;
      unawaited(notifications.showFromHost(msg, ls));
    };
    // Подключение — в фоне: у хоста может быть долгий TCP-таймаут,
    // UI блокировать нельзя. Клиент сам переподключается.
    unawaited(_client!.start(
      host: addr,
      port: prefs.getInt(_kHostPort) ?? kHostPort,
      userId: uid,
      userName: currentUser!.name,
      deviceId: device.deviceId,
      deviceName: device.deviceName,
      platform: device.platform,
    ));
  }

  // ---------- Онбординг ----------

  Future<void> chooseRole(DeviceRole r) async {
    role = r;
    await prefs.setString(_kRole, r == DeviceRole.host ? 'host' : 'client');
    notifyListeners();
  }

  /// Создать/войти в профиль пользователя на этом устройстве (ТЗ 3, 6.10).
  Future<AppUser> signIn(String name) async {
    final String id = prefs.getString(_kUserId) ?? newId();
    await prefs.setString(_kUserId, id);
    await prefs.setString(_kUserName, name.trim());
    if (isHost) {
      await _startHostStack(); // идемпотентно: если уже запущен — сразу выйдет
      currentUser =
          _db!.helloUser(userId: id, userName: name.trim(), deviceId: device.deviceId);
      // Хост мог уточнить имя (уникальность) — запоминаем фактическое.
      await prefs.setString(_kUserName, currentUser!.name);
      currentUser!.online = true;
      currentUser!.lastSeen = DateTime.now().toUtc();
      // Пользователь самого хоста — всегда руководитель (видит все заявки).
      currentUser!.role = 'manager';
      _db!.saveUsers();
      _server?.hostUserId = id;
    } else {
      currentUser =
          AppUser(id: id, name: name.trim(), deviceIds: [device.deviceId]);
    }
    notifyListeners();
    return currentUser!;
  }

  /// Смена пользователя на устройстве (если разрешено настройкой).
  Future<void> switchUser(AppUser user) async {
    await prefs.setString(_kUserId, user.id);
    await prefs.setString(_kUserName, user.name);
    currentUser = user;
    if (isHost && _db != null) {
      _db!.helloUser(userId: user.id, userName: user.name, deviceId: device.deviceId);
      _server?.hostUserId = user.id;
      user.online = true;
      user.role = 'manager'; // хост — всегда руководитель
      _db!.saveUsers();
    } else {
      await _startClientStack(); // переподключение под новым профилем
    }
    notifyListeners();
  }

  Future<void> renameUser(String newName) async {
    final AppUser? u = currentUser;
    if (u == null || newName.trim().isEmpty) return;
    u.name = newName.trim();
    await prefs.setString(_kUserName, u.name);
    if (isHost && _db != null) {
      _db!.helloUser(userId: u.id, userName: u.name, deviceId: device.deviceId);
    } else {
      _cache?.saveUsers();
      await _startClientStack();
    }
    notifyListeners();
  }

  /// Подключение клиента к хосту (ручной ввод или автопоиск).
  /// Не блокирует: подключение и переподключение идут в фоне.
  Future<void> connectToHost(String address, [int port = kHostPort]) async {
    await prefs.setString(_kHostAddr, address.trim());
    await prefs.setInt(_kHostPort, port);
    await _startClientStack();
    notifyListeners();
  }

  /// Завершение онбординга: запуск стека под выбранную роль.
  /// Возвращает null при успехе, иначе текст ошибки для показа пользователю.
  Future<String?> activateAfterOnboarding() async {
    try {
      if (isHost) {
        await _startHostStack().timeout(const Duration(seconds: 15));
        if (!serverRunning) {
          return 'Сервер хоста не запустился. Закройте другие копии приложения '
              'и попробуйте снова.';
        }
      }
      return null;
    } catch (e) {
      return 'Ошибка запуска: $e';
    }
  }

  Future<List<DiscoveredHost>> findHosts() => discoverHosts();

  Future<void> finishOnboarding() async {
    await prefs.setBool(_kConfigured, true);
    notifyListeners();
  }

  /// Полный сброс настройки «роль+подключение» (повторный онбординг).
  Future<void> resetConfiguration() async {
    await _client?.stop();
    _client = null;
    await prefs.setBool(_kConfigured, false);
    notifyListeners();
  }

  // ---------- Заявки ----------

  Note? noteById(String id) {
    final Map<String, Note>? m = isHost ? _db?.notes : _cache?.notes;
    return m?[id];
  }

  AppUser? userById(String id) {
    final Map<String, AppUser>? m = isHost ? _db?.users : _cache?.users;
    return m?[id];
  }

  String userName(String id) => userById(id)?.name ?? (id.isEmpty ? '—' : id);

  Future<Note> createNote({
    required String text,
    String? assigneeId,
    NotePriority? priority,
    DateTime? deadline,
    Reminder? reminder,
    List<String> tags = const [],
    int? colorValue,
    String? contactId,
    AudioAttachment? audioAttachment,
    List<PhotoAttachment> photoAttachments = const [],
  }) async {
    final AppUser me = currentUser!;
    final Note note = Note(
      id: newId(),
      text: text.trim(),
      authorId: me.id,
      createdAt: DateTime.now().toUtc(),
      assigneeId: assigneeId,
      priority: priority,
      deadline: deadline,
      reminder: reminder,
      tags: List<String>.from(tags),
      colorValue: colorValue,
      contactId: contactId,
      audio: audioAttachment,
      photos: List<PhotoAttachment>.from(photoAttachments),
    );
    if (isHost) {
      _server?.localCreateNote(note, userId: me.id);
    } else {
      _client?.sendOp(ClientMsg.noteCreate(note));
      _cache?.applyNoteUpsert(note); // оптимистично, хост пришлёт авторитетную версию
    }
    syncWidget();
    notifyListeners();
    return note;
  }

  /// Патч различий между версией «до» и «после» — основа журнала «старое → новое».
  Map<String, dynamic> diffToPatch(Note before, Note after) {
    final Map<String, dynamic> p = <String, dynamic>{};
    if (before.text != after.text) p[NoteFields.text] = after.text;
    if (before.status != after.status) p[NoteFields.status] = after.status.wire;
    if (before.assigneeId != after.assigneeId) p[NoteFields.assignee] = after.assigneeId;
    if (before.priority != after.priority) p[NoteFields.priority] = after.priority?.wire;
    if (before.deadline != after.deadline) {
      p[NoteFields.deadline] = after.deadline?.toIso8601String();
    }
    if (jsonEncode(before.reminder?.toJson()) != jsonEncode(after.reminder?.toJson())) {
      p[NoteFields.reminder] = after.reminder?.toJson();
    }
    if (!listEquals(before.tags, after.tags)) p[NoteFields.tags] = after.tags;
    if (before.colorValue != after.colorValue) p[NoteFields.color] = after.colorValue;
    if (before.contactId != after.contactId) p[NoteFields.contact] = after.contactId;
    if (jsonEncode(before.audio?.toJson()) != jsonEncode(after.audio?.toJson())) {
      p[NoteFields.audio] = after.audio?.toJson();
    }
    if (jsonEncode(before.photos.map((e) => e.toJson()).toList()) !=
        jsonEncode(after.photos.map((e) => e.toJson()).toList())) {
      p[NoteFields.photos] = after.photos.map((e) => e.toJson()).toList();
    }
    return p;
  }

  Future<void> updateNote(Note before, Note after) async {
    final Map<String, dynamic> patch = diffToPatch(before, after);
    if (patch.isEmpty) return;
    final String uid = currentUser?.id ?? '';
    if (isHost) {
      _server?.localPatchNote(before.id, patch, baseVersion: before.version, userId: uid);
    } else {
      _client?.sendOp(ClientMsg.notePatch(before.id, patch, before.version));
      final Note? local = _cache?.notes[before.id];
      if (local != null) {
        applyPatchToNote(local, patch); // оптимистично
        local.updatedAt = DateTime.now().toUtc();
        _cache?.saveNotes();
      }
    }
    syncWidget();
    notifyListeners();
  }

  Future<void> setStatus(Note note, NoteStatus status) async {
    final Note after = note.copy()..status = status;
    await updateNote(note, after);
  }

  /// Удаление заявки целиком (очистка архива и т.п.).
  /// На хосте удаляются также файлы вложений; всем клиентам уходит событие.
  Future<void> deleteNote(Note note) async {
    if (isHost) {
      _server?.localDeleteNote(note.id, userId: currentUser?.id ?? 'host');
    } else {
      _client?.sendOp(ClientMsg.noteDelete(note.id));
      _cache?.removeNote(note.id); // оптимистично
    }
    syncWidget();
    notifyListeners();
  }

  // ---------- Закрепления (персональные) ----------

  bool isPinned(String noteId) {
    final String? uid = currentUser?.id;
    if (uid == null) return false;
    return pins.any((p) => p.userId == uid && p.noteId == noteId);
  }

  List<Pin> get myPins {
    final String? uid = currentUser?.id;
    if (uid == null) return [];
    final List<Pin> list = pins.where((p) => p.userId == uid).toList()
      ..sort((a, b) => a.orderIndex.compareTo(b.orderIndex));
    return list;
  }

  /// Переключить закрепление. Возвращает предупреждение о мягком лимите или null.
  Future<String?> togglePin(Note note) async {
    final AppUser? me = currentUser;
    if (me == null) return null;
    final bool pinned = !isPinned(note.id);
    if (isHost) {
      _server?.localSetPin(me.id, note.id, pinned);
    } else {
      _client?.sendOp(ClientMsg.pinSet(note.id, pinned));
      if (pinned) {
        _cache?.applyPin(Pin(
            userId: me.id,
            noteId: note.id,
            pinnedAt: DateTime.now().toUtc(),
            orderIndex: myPins.length));
      } else {
        _cache?.removePin(me.id, note.id);
      }
    }
    syncWidget();
    notifyListeners();
    // Мягкий лимит 20: только предупреждение, не блокируем (ТЗ 12).
    if (pinned && myPins.length > kPinSoftLimit) {
      return 'Закреплено больше $kPinSoftLimit заявок — список может быть неудобным';
    }
    return null;
  }

  /// Ручной порядок закреплённых; синхронизируется между устройствами пользователя.
  Future<void> reorderMyPins(List<String> orderedNoteIds) async {
    final AppUser? me = currentUser;
    if (me == null) return;
    if (isHost) {
      _server?.localReorderPins(me.id, orderedNoteIds);
    } else {
      _client?.sendOp(ClientMsg.pinsOrder(orderedNoteIds));
      for (int i = 0; i < orderedNoteIds.length; i++) {
        final Pin? p = _cache?.pins['${me.id}:${orderedNoteIds[i]}'];
        if (p != null) p.orderIndex = i;
      }
      _cache?.savePins();
    }
    notifyListeners();
  }

  // ---------- Контакты ----------

  Future<Contact> saveContact(Contact contact) async {
    if (isHost) {
      _server?.localUpsertContact(contact, userId: currentUser?.id ?? '');
    } else {
      _client?.sendOp(ClientMsg.contactUpsert(contact.toJson()));
      _cache?.applyContact(contact);
    }
    notifyListeners();
    return contact;
  }

  Future<void> deleteContact(Contact contact) async {
    if (isHost) {
      _server?.localDeleteContact(contact.id, userId: currentUser?.id ?? '');
    } else {
      _client?.sendOp(ClientMsg.contactDelete(contact.id));
      _cache?.removeContact(contact.id);
    }
    notifyListeners();
  }

  // ---------- Пользователи (хост) ----------

  Future<void> deleteUser(AppUser user) async {
    if (!isHost || _db == null) return;
    _db!.deleteUser(user.id, actorId: currentUser?.id ?? 'host');
    notifyListeners();
  }

  /// Смена роли пользователя: руководитель видит все заявки и статистику,
  /// работник — только свои (фильтр на главном экране).
  Future<void> setUserRole(AppUser user, String role) async {
    if (!isHost || _db == null) return;
    _db!.setUserRole(user.id, role, actorId: currentUser?.id ?? 'host');
    notifyListeners();
  }

  // ---------- Очистка кэша и журнала ----------

  /// Имена файлов, которые реально используются (аудио заявок, фото,
  /// аудио сообщений чата) — всё остальное в папке хоста считается мусором.
  Set<String> _referencedFiles() {
    final Set<String> used = <String>{};
    for (final Note n in notes) {
      final AudioAttachment? a = n.audio;
      if (a != null && !a.deleted) used.add(a.fileName);
      for (final PhotoAttachment p in n.photos) {
        used.add(p.fileName);
      }
    }
    for (final ChatMessage m in messages) {
      if (m.audioFileName != null && m.audioFileName!.isNotEmpty) {
        used.add(m.audioFileName!);
      }
    }
    return used;
  }

  /// Статистика кэша: временные файлы устройства и (на хосте) файлы-сироты.
  Future<({int tempBytes, int orphanBytes, int orphanCount})>
      cacheStats() async {
    int tempBytes = 0;
    try {
      final Directory tmp = await getTemporaryDirectory();
      if (await tmp.exists()) {
        await for (final FileSystemEntity e in tmp.list(recursive: true)) {
          if (e is File) {
            try {
              tempBytes += await e.length();
            } catch (_) {}
          }
        }
      }
    } catch (_) {}
    int orphanBytes = 0;
    int orphanCount = 0;
    if (isHost && _server != null) {
      final Set<String> used = _referencedFiles();
      try {
        await for (final FileSystemEntity e in _server!.audioDir.list()) {
          if (e is File && !used.contains(e.uri.pathSegments.last)) {
            orphanCount++;
            try {
              orphanBytes += await e.length();
            } catch (_) {}
          }
        }
      } catch (_) {}
    }
    return (
      tempBytes: tempBytes,
      orphanBytes: orphanBytes,
      orphanCount: orphanCount
    );
  }

  /// Очистка кэша: временные файлы этого устройства (черновики записей,
  /// WAV гибридной диктовки, файлы экспорта) + на хосте файлы без заявок.
  /// Заявки, вложения и настройки не трогаем. Возвращает (байт, файлов).
  Future<({int bytes, int files})> clearCache() async {
    int bytes = 0;
    int files = 0;
    try {
      final Directory tmp = await getTemporaryDirectory();
      if (await tmp.exists()) {
        await for (final FileSystemEntity e in tmp.list(recursive: true)) {
          try {
            if (e is File) bytes += await e.length();
            await e.delete(recursive: true);
            files++;
          } catch (_) {}
        }
      }
    } catch (_) {}
    if (isHost && _server != null) {
      final Set<String> used = _referencedFiles();
      try {
        await for (final FileSystemEntity e in _server!.audioDir.list()) {
          if (e is File && !used.contains(e.uri.pathSegments.last)) {
            try {
              bytes += await e.length();
              await e.delete();
              files++;
            } catch (_) {}
          }
        }
      } catch (_) {}
    }
    return (bytes: bytes, files: files);
  }

  /// Полная очистка журнала аудита (только хост; клиенты получают сигнал).
  Future<void> clearAudit() async {
    if (!isHost || _db == null) return;
    _db!.clearAudit();
    notifyListeners();
  }

  // ---------- Хостовые настройки (только на хосте, ТЗ 6) ----------

  Future<void> saveHostSettings(HostSettings s) async {
    if (!isHost || _db == null) return;
    _db!.settings = s;
    _db!.saveSettings();
    _server?.broadcastHostSettings();
    notifyListeners();
  }

  // ---------- Резервное копирование (хост, ТЗ 4.6) ----------

  Future<File?> backupNow() => _backup?.autoBackup() ?? Future<File?>.value(null);

  Future<File?> exportBackup(String path) => _backup?.exportTo(path) ?? Future<File?>.value(null);

  /// null = успех, иначе текст ошибки.
  Future<String?> importBackup(String path) async {
    final String? err = await _backup?.importFrom(path);
    if (err == null) {
      _server?.broadcastSnapshotToAll();
    }
    notifyListeners();
    return err;
  }

  // ---------- Аудио ----------

  /// Прикрепить записанный файл к хосту (копирование на хосте / HTTP-загрузка с клиента).
  Future<AudioAttachment?> attachAudio(RecordedAudio rec) async {
    if (isHost && _server != null) {
      try {
        final File dest = File(
            '${_server!.audioDir.path}${Platform.pathSeparator}${rec.fileName}');
        await File(rec.path).copy(dest.path);
        final int size = await dest.length();
        return AudioAttachment(
            fileName: rec.fileName, sizeBytes: size, durationSec: rec.durationSec);
      } catch (_) {
        return null;
      }
    }
    final int? size = await audio.upload(hostAddress, hostPort, rec);
    if (size == null) return null;
    return AudioAttachment(
        fileName: rec.fileName, sizeBytes: size, durationSec: rec.durationSec);
  }

  /// URL/путь для воспроизведения вложения.
  String audioLocation(String fileName) {
    if (isHost && _server != null) {
      return '${_server!.audioDir.path}${Platform.pathSeparator}$fileName';
    }
    return 'http://$hostAddress:$hostPort/audio/$fileName';
  }

  // ---------- Фото к заявке ----------

  /// Прикрепить выбранное фото (копирование на хосте / HTTP-загрузка
  /// с клиента). Тот же транспорт, что и у аудио.
  Future<PhotoAttachment?> attachPhoto(PickedPhoto photo) async {
    if (isHost && _server != null) {
      try {
        final File dest = File(
            '${_server!.audioDir.path}${Platform.pathSeparator}${photo.fileName}');
        await File(photo.path).copy(dest.path);
        final int size = await dest.length();
        return PhotoAttachment(fileName: photo.fileName, sizeBytes: size);
      } catch (_) {
        return null;
      }
    }
    final int? size =
        await audio.uploadFile(hostAddress, hostPort, photo.fileName, File(photo.path));
    if (size == null) return null;
    return PhotoAttachment(fileName: photo.fileName, sizeBytes: size);
  }

  // ---------- Выборки для UI ----------

  /// Список заявок: фильтры + сортировка.
  ///
  /// Без запроса: закреплённые мной — сверху (если включено), далее по дате.
  /// С запросом: глобальный поиск по всем данным (текст, автор, исполнитель,
  /// статус, приоритет, теги, контакт, ТЕЛЕФОН, расшифровка аудио, дедлайн)
  /// с сортировкой по позиции вхождения — как в 1С (чем раньше совпадение,
  /// тем выше результат).
  List<Note> listNotes({
    bool mineOnly = false,
    String query = '',
    NoteStatus? status,
    bool archive = false,
  }) {
    final String? uid = currentUser?.id;
    Iterable<Note> list = notes;
    if (archive) {
      // Архив: финальные статусы.
      list = list.where(
          (n) => n.status == NoteStatus.done || n.status == NoteStatus.rejected);
    } else if (status != null) {
      list = list.where((n) => n.status == status);
    } else {
      // Основной список — без архивных («Выполнена»/«Отклонена» уходят в архив).
      list = list.where(
          (n) => n.status != NoteStatus.done && n.status != NoteStatus.rejected);
    }
    if (mineOnly && uid != null) {
      list = list.where((n) => n.authorId == uid || n.assigneeId == uid);
    }

    final String q = query.trim().toLowerCase();
    if (q.isNotEmpty) {
      final String qDigits = q.replaceAll(RegExp(r'\D'), '');
      final List<MapEntry<Note, int>> scored = [];
      for (final Note n in list) {
        final String corpus = _searchCorpus(n);
        int pos = corpus.indexOf(q);
        // Телефонный поиск: цифры без пробелов/скобок («912345» найдёт «+7 912 345-…»).
        if (pos < 0 && qDigits.length >= 3) pos = corpus.indexOf(qDigits);
        if (pos >= 0) scored.add(MapEntry(n, pos));
      }
      scored.sort((a, b) {
        if (a.value != b.value) return a.value.compareTo(b.value);
        return b.key.updatedAt.compareTo(a.key.updatedAt);
      });
      return scored.map((e) => e.key).toList();
    }

    final List<Note> result = list.toList();
    final Map<String, int> pinPos = {
      for (final Pin p in (uid == null ? const <Pin>[] : myPins)) p.noteId: p.orderIndex
    };
    final bool pinnedTop = ls.showPinnedTop;
    result.sort((a, b) {
      if (pinnedTop) {
        final int? pa = pinPos[a.id];
        final int? pb = pinPos[b.id];
        if (pa != null && pb != null) return pa.compareTo(pb);
        if (pa != null) return -1;
        if (pb != null) return 1;
      }
      return b.updatedAt.compareTo(a.updatedAt);
    });
    return result;
  }

  /// «Корпус» для поиска по заявке: все значимые поля одной строкой (lower-case).
  /// Порядок полей важен: совпадение в тексте ценится выше совпадения в телефоне.
  String _searchCorpus(Note n) {
    final StringBuffer sb = StringBuffer();
    void add(String? s) {
      if (s != null && s.isNotEmpty) {
        sb.write(s.toLowerCase());
        sb.write('\n');
      }
    }

    add(n.text);
    add(userName(n.authorId));
    add(n.assigneeId != null ? userName(n.assigneeId!) : null);
    add(n.status.label);
    add(n.priority?.label);
    for (final String t in n.tags) {
      add(t);
    }
    final Contact? c = n.contactId == null
        ? null
        : contacts.firstWhereOrNull((x) => x.id == n.contactId);
    if (c != null) {
      add(c.name);
      add(c.phone);
      add(c.phone.replaceAll(RegExp(r'\D'), '')); // телефон только цифрами
      add(c.comment);
    }
    if (n.deadline != null) add(formatDateTime(n.deadline!));
    add(n.audio?.transcript);
    return sb.toString();
  }

  List<Note> get pinnedNotes {
    final List<Note> result = [];
    for (final Pin p in myPins) {
      final Note? n = noteById(p.noteId);
      if (n != null) result.add(n);
    }
    return result;
  }

  DaySummary get summary => DaySummary.compute(notes);

  List<AuditEntry> auditForNote(String noteId) =>
      audit.where((e) => e.noteId == noteId).toList().reversed.toList();

  // ---------- Завершение ----------

  Future<void> shutdown() async {
    // Пометить пользователя хоста оффлайн до остановки сервера.
    if (isHost && _db != null && _server != null) {
      final String? uid = prefs.getString(_kUserId);
      if (uid != null) {
        final AppUser? u = _db!.users[uid];
        if (u != null && u.online) {
          u.online = false;
          u.lastSeen = DateTime.now().toUtc();
          _db!.saveUsers();
          _server!.broadcast({
            'type': MsgType.presence,
            'userId': uid,
            'online': false,
            'lastSeen': u.lastSeen?.toIso8601String(),
          });
        }
      }
    }
    _jobs?.stop();
    _announcer?.stop();
    await _client?.stop();
    await _server?.stop();
    await _db?.flush();
    await _cache?.flush();
  }

  @override
  void dispose() {
    unawaited(shutdown());
    audio.dispose();
    super.dispose();
  }
}
