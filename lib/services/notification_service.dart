import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:local_notifier/local_notifier.dart';

import '../models/enums.dart';
import '../models/settings.dart';

/// Локальные уведомления (ТЗ 4.4, 6.2): Android — push со звуком/вибрацией,
/// Windows — всплывающие. Учитывает «не беспокоить», рабочие часы,
/// раздельные звуки для новых заявок и напоминаний/эскалации.
class NotificationService {
  NotificationService();

  final FlutterLocalNotificationsPlugin _fln = FlutterLocalNotificationsPlugin();
  bool _androidReady = false;
  bool _windowsReady = false;
  bool _inited = false;

  static const String _chSound = 'qp_sound';
  static const String _chSilent = 'qp_silent';

  /// Идемпотентная инициализация: повторные вызовы безопасны.
  Future<void> init() async {
    if (_inited) return;
    _inited = true;
    if (kIsWeb) return;
    if (Platform.isAndroid) {
      const AndroidInitializationSettings androidInit =
          AndroidInitializationSettings('@mipmap/ic_launcher');
      const InitializationSettings settings = InitializationSettings(android: androidInit);
      await _fln.initialize(settings);
      final AndroidFlutterLocalNotificationsPlugin? android = _fln
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      await android?.requestNotificationsPermission();
      await android?.createNotificationChannel(const AndroidNotificationChannel(
          _chSound, 'Заявки (со звуком)',
          description: 'Уведомления со звуком', importance: Importance.high));
      await android?.createNotificationChannel(const AndroidNotificationChannel(
          _chSilent, 'Заявки (без звука)',
          description: 'Тихие уведомления', importance: Importance.defaultImportance));
      _androidReady = true;
    } else if (Platform.isWindows) {
      try {
        await localNotifier.setup(appName: 'QuickPad');
        _windowsReady = true;
      } catch (_) {}
    }
  }

  int _nextId = 1;

  /// Показать уведомление, пришедшее от хоста, с учётом локальных настроек.
  Future<void> showFromHost(Map<String, dynamic> msg, LocalSettings s) async {
    final NotifyKind kind = NotifyKind.fromWire(msg['kind'] as String?);
    final String title = msg['title'] as String? ?? 'Уведомление';
    final String body = msg['body'] as String? ?? '';

    // Рабочие часы: при включённой настройке — только в интервале.
    if (s.workHoursEnabled) {
      final int h = DateTime.now().hour;
      if (h < s.workStart || h >= s.workEnd) return;
    }

    // Виды уведомлений — отключаемые (ТЗ 6.2).
    switch (kind) {
      case NotifyKind.newNote:
        if (!s.notifNew) return;
        break;
      case NotifyKind.noteChanged:
      case NotifyKind.audioDeleted:
        if (!s.notifChanges) return;
        break;
      case NotifyKind.reminder:
        if (!s.notifReminders) return;
        break;
      case NotifyKind.chat:
        if (!s.notifChat) return;
        break;
      case NotifyKind.escalation:
        if (!s.notifEscalation) return;
        break;
      case NotifyKind.conflict:
        if (!s.conflictNotify) return;
        break;
    }

    // Звук: общий + раздельные переключатели + «не беспокоить» + тихие часы.
    bool sound = s.notifSound && !s.dnd;
    if (kind == NotifyKind.newNote && !s.soundNew) sound = false;
    if ((kind == NotifyKind.reminder || kind == NotifyKind.escalation) && !s.soundReminder) {
      sound = false;
    }
    if (sound && s.quietHoursEnabled) {
      final int h = DateTime.now().hour;
      // Интервал может переходить через полночь (например, 20 → 8).
      final bool quiet = s.quietStart <= s.quietEnd
          ? (h >= s.quietStart && h < s.quietEnd)
          : (h >= s.quietStart || h < s.quietEnd);
      if (quiet) sound = false;
    }
    final bool vibration = s.vibration && sound;

    if (Platform.isAndroid && _androidReady) {
      final AndroidNotificationDetails details = AndroidNotificationDetails(
        sound ? _chSound : _chSilent,
        sound ? 'Заявки (со звуком)' : 'Заявки (без звука)',
        importance: sound ? Importance.high : Importance.defaultImportance,
        priority: sound ? Priority.high : Priority.defaultPriority,
        playSound: sound,
        enableVibration: vibration,
      );
      await _fln.show(_nextId++, title, body, NotificationDetails(android: details));
    } else if (Platform.isWindows && _windowsReady) {
      final LocalNotification n =
          LocalNotification(identifier: 'qp_${_nextId++}', title: title, body: body);
      // Ограничение local_notifier: системный звук Windows управляется ОС.
      unawaited(n.show());
    }
  }

  /// Немедленное локальное уведомление (например, «конфликт» при оффлайн-правке).
  Future<void> showLocal(String title, String body, LocalSettings s) {
    return showFromHost({'kind': NotifyKind.noteChanged.wire, 'title': title, 'body': body}, s);
  }
}
