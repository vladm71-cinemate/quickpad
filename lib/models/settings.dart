/// Настройки приложения (раздел 6 ТЗ).
///
/// [HostSettings] — глобальные, хранятся и меняются только на хосте,
/// транслируются всем клиентам.
/// [LocalSettings] — на каждом устройстве, хранятся в SharedPreferences.
library;

/// Хостовые настройки: аудио/хранение, эскалация, журнал, резервное копирование.
class HostSettings {
  HostSettings();

  // 6.4 Аудио и хранение
  bool storeAudio = true; // Хранить аудиофайлы
  bool cleanupOnDone = true; // Автоочистка аудио при «Выполнена»
  bool cleanupOnRejected = false; // Автоочистка при «Отклонена/Отложена»
  int audioKeepDays = 0; // Срок хранения аудио, дней (0 — не ограничен)
  bool auditEnabled = true; // Хранить журнал аудита

  // 6.5 Эскалация и напоминания
  bool escalationEnabled = true; // Эскалация включена
  int escalationMinutes = 30; // N минут до эскалации (глобально)
  bool escalateNew = true; // Эскалация при «Новая»
  bool escalateInProgress = false; // Эскалация при «В работе» (просрочка)
  bool remindersEnabled = true; // Напоминания по времени
  bool recurringRemindersEnabled = false; // Повторяющиеся напоминания
  bool escalationWorkHoursOnly = false; // Эскалация только в рабочие часы
  int workDayStart = 9; // Начало рабочего дня (час)
  int workDayEnd = 19; // Конец рабочего дня (час)

  // 6.9 Резервное копирование
  bool backupAuto = true; // Автосохранение базы
  bool backupOnChanges = true; // Периодичность: при изменениях (иначе — раз в час)
  bool backupRotation = true; // Ротация копий
  int backupKeep = 5; // Число хранимых копий
  bool backupIncludeAudit = true; // Экспорт журнала вместе с базой

  Map<String, dynamic> toJson() => {
        'storeAudio': storeAudio,
        'cleanupOnDone': cleanupOnDone,
        'cleanupOnRejected': cleanupOnRejected,
        'audioKeepDays': audioKeepDays,
        'auditEnabled': auditEnabled,
        'escalationEnabled': escalationEnabled,
        'escalationMinutes': escalationMinutes,
        'escalateNew': escalateNew,
        'escalateInProgress': escalateInProgress,
        'remindersEnabled': remindersEnabled,
        'recurringRemindersEnabled': recurringRemindersEnabled,
        'escalationWorkHoursOnly': escalationWorkHoursOnly,
        'workDayStart': workDayStart,
        'workDayEnd': workDayEnd,
        'backupAuto': backupAuto,
        'backupOnChanges': backupOnChanges,
        'backupRotation': backupRotation,
        'backupKeep': backupKeep,
        'backupIncludeAudit': backupIncludeAudit,
      };

  void applyJson(Map<String, dynamic> j) {
    bool b(String k, bool cur) => j[k] as bool? ?? cur;
    int n(String k, int cur) => (j[k] as num?)?.toInt() ?? cur;
    storeAudio = b('storeAudio', storeAudio);
    cleanupOnDone = b('cleanupOnDone', cleanupOnDone);
    cleanupOnRejected = b('cleanupOnRejected', cleanupOnRejected);
    audioKeepDays = n('audioKeepDays', audioKeepDays);
    auditEnabled = b('auditEnabled', auditEnabled);
    escalationEnabled = b('escalationEnabled', escalationEnabled);
    escalationMinutes = n('escalationMinutes', escalationMinutes);
    escalateNew = b('escalateNew', escalateNew);
    escalateInProgress = b('escalateInProgress', escalateInProgress);
    remindersEnabled = b('remindersEnabled', remindersEnabled);
    recurringRemindersEnabled = b('recurringRemindersEnabled', recurringRemindersEnabled);
    escalationWorkHoursOnly = b('escalationWorkHoursOnly', escalationWorkHoursOnly);
    workDayStart = n('workDayStart', workDayStart);
    workDayEnd = n('workDayEnd', workDayEnd);
    backupAuto = b('backupAuto', backupAuto);
    backupOnChanges = b('backupOnChanges', backupOnChanges);
    backupRotation = b('backupRotation', backupRotation);
    backupKeep = n('backupKeep', backupKeep);
    backupIncludeAudit = b('backupIncludeAudit', backupIncludeAudit);
  }

  factory HostSettings.fromJson(Map<String, dynamic> j) => HostSettings()..applyJson(j);

  HostSettings copy() => HostSettings.fromJson(toJson());
}

/// Локальные настройки устройства (SharedPreferences).
class LocalSettings {
  // 6.1 Общие
  bool darkTheme = false; // Тёмная тема (по умолч. светлая)
  bool notifSound = true; // Звук уведомлений
  bool vibration = true; // Вибрация (Android)
  bool showDaySummary = true; // Показывать сводку дня
  String language = 'ru'; // Язык интерфейса

  // 6.2 Уведомления
  bool notifNew = true; // Уведомления о новых заявках
  bool notifChanges = true; // Уведомления об изменениях чужих заявок
  bool notifReminders = true; // Уведомления о напоминаниях
  bool notifEscalation = true; // Уведомления об эскалации
  bool soundNew = true; // Звук для новых заявок
  bool soundReminder = true; // Звук для напоминаний/эскалации
  bool dnd = false; // «Не беспокоить»
  bool workHoursEnabled = false; // Рабочие часы для уведомлений
  int workStart = 9;
  int workEnd = 19;

  // 6.3 Голосовой ввод
  bool sttEnabled = true; // Диктовка в текст
  bool recordEnabled = true; // Запись голоса
  bool hybridEnabled = true; // Гибридный режим
  bool autoTranscribe = true; // Автоматическая расшифровка аудио
  bool voiceCommandsEnabled = true; // Голосовые команды
  String sttLocale = 'ru-RU'; // Язык распознавания

  // 6.6 Заявки и отображение
  bool showPinnedTop = true; // Показывать закреплённые вверху
  bool showColors = true; // Показывать цветовые метки
  bool showPriority = true; // Показывать приоритет
  bool showContactInList = true; // Показывать контакт в списке
  bool showPresence = true; // Показывать индикатор присутствия
  bool highlightOverdue = true; // Подсветка просроченных
  bool myByDefault = false; // «Мои заявки» по умолчанию
  bool realtime = true; // Автообновление списка в реальном времени

  // 6.7 Контакты
  bool showContacts = true; // Показывать библиотеку адресов
  bool callFromCard = true; // Разрешить звонок из карточки
  bool contactLinkEnabled = true; // Связь контакта с заявкой

  // 6.8 Синхронизация и оффлайн
  bool offlineMode = true; // Оффлайн-режим (кэш)
  bool autoSync = true; // Автосинхронизация при возврате в сеть
  bool showConnIndicator = true; // Показывать индикатор онлайн/оффлайн
  bool conflictNotify = true; // Уведомление о конфликте синхронизации

  // 6.10 Пользователи и устройство
  bool userBinding = true; // Привязка пользователя к устройству
  bool showOnlineUsers = true; // Показывать список онлайн-пользователей
  // По умолчанию ВЫКЛ: вход только в «свой» профиль (привязанный к этому
  // устройству), чтобы журнал изменений всегда показывал реального автора.
  bool allowUserSwitch = false; // Разрешить смену пользователя на устройстве

  // 6.11 Виджет и быстрые действия (Android)
  bool widgetEnabled = true; // Виджет быстрой заметки
  bool quickLine = true; // Быстрое создание в одну строку
  bool voiceButton = true; // Голосовая кнопка на главном

  /// Установить булеву настройку по ключу.
  void setFlag(String key, bool v) {
    _boolSetters()[key]?.call(this, v);
  }

  /// Все булевы настройки — ключи для SharedPreferences.
  Map<String, bool> toJson() {
    final Map<String, bool Function(LocalSettings)> g = _boolGetters();
    return {for (final e in g.entries) e.key: e.value(this)};
  }

  void applyJson(Map<String, dynamic> j) {
    darkTheme = j['darkTheme'] as bool? ?? darkTheme;
    language = j['language'] as String? ?? language;
    sttLocale = j['sttLocale'] as String? ?? sttLocale;
    workStart = (j['workStart'] as num?)?.toInt() ?? workStart;
    workEnd = (j['workEnd'] as num?)?.toInt() ?? workEnd;
    for (final e in _boolSetters().entries) {
      final Object? v = j[e.key];
      if (v is bool) e.value(this, v);
    }
  }

  Map<String, bool Function(LocalSettings)> _boolGetters() => {
        'notifSound': (s) => s.notifSound,
        'vibration': (s) => s.vibration,
        'showDaySummary': (s) => s.showDaySummary,
        'notifNew': (s) => s.notifNew,
        'notifChanges': (s) => s.notifChanges,
        'notifReminders': (s) => s.notifReminders,
        'notifEscalation': (s) => s.notifEscalation,
        'soundNew': (s) => s.soundNew,
        'soundReminder': (s) => s.soundReminder,
        'dnd': (s) => s.dnd,
        'workHoursEnabled': (s) => s.workHoursEnabled,
        'sttEnabled': (s) => s.sttEnabled,
        'recordEnabled': (s) => s.recordEnabled,
        'hybridEnabled': (s) => s.hybridEnabled,
        'autoTranscribe': (s) => s.autoTranscribe,
        'voiceCommandsEnabled': (s) => s.voiceCommandsEnabled,
        'showPinnedTop': (s) => s.showPinnedTop,
        'showColors': (s) => s.showColors,
        'showPriority': (s) => s.showPriority,
        'showContactInList': (s) => s.showContactInList,
        'showPresence': (s) => s.showPresence,
        'highlightOverdue': (s) => s.highlightOverdue,
        'myByDefault': (s) => s.myByDefault,
        'realtime': (s) => s.realtime,
        'showContacts': (s) => s.showContacts,
        'callFromCard': (s) => s.callFromCard,
        'contactLinkEnabled': (s) => s.contactLinkEnabled,
        'offlineMode': (s) => s.offlineMode,
        'autoSync': (s) => s.autoSync,
        'showConnIndicator': (s) => s.showConnIndicator,
        'conflictNotify': (s) => s.conflictNotify,
        'userBinding': (s) => s.userBinding,
        'showOnlineUsers': (s) => s.showOnlineUsers,
        'allowUserSwitch': (s) => s.allowUserSwitch,
        'widgetEnabled': (s) => s.widgetEnabled,
        'quickLine': (s) => s.quickLine,
        'voiceButton': (s) => s.voiceButton,
      };

  Map<String, void Function(LocalSettings, bool)> _boolSetters() => {
        'notifSound': (s, v) => s.notifSound = v,
        'vibration': (s, v) => s.vibration = v,
        'showDaySummary': (s, v) => s.showDaySummary = v,
        'notifNew': (s, v) => s.notifNew = v,
        'notifChanges': (s, v) => s.notifChanges = v,
        'notifReminders': (s, v) => s.notifReminders = v,
        'notifEscalation': (s, v) => s.notifEscalation = v,
        'soundNew': (s, v) => s.soundNew = v,
        'soundReminder': (s, v) => s.soundReminder = v,
        'dnd': (s, v) => s.dnd = v,
        'workHoursEnabled': (s, v) => s.workHoursEnabled = v,
        'sttEnabled': (s, v) => s.sttEnabled = v,
        'recordEnabled': (s, v) => s.recordEnabled = v,
        'hybridEnabled': (s, v) => s.hybridEnabled = v,
        'autoTranscribe': (s, v) => s.autoTranscribe = v,
        'voiceCommandsEnabled': (s, v) => s.voiceCommandsEnabled = v,
        'showPinnedTop': (s, v) => s.showPinnedTop = v,
        'showColors': (s, v) => s.showColors = v,
        'showPriority': (s, v) => s.showPriority = v,
        'showContactInList': (s, v) => s.showContactInList = v,
        'showPresence': (s, v) => s.showPresence = v,
        'highlightOverdue': (s, v) => s.highlightOverdue = v,
        'myByDefault': (s, v) => s.myByDefault = v,
        'realtime': (s, v) => s.realtime = v,
        'showContacts': (s, v) => s.showContacts = v,
        'callFromCard': (s, v) => s.callFromCard = v,
        'contactLinkEnabled': (s, v) => s.contactLinkEnabled = v,
        'offlineMode': (s, v) => s.offlineMode = v,
        'autoSync': (s, v) => s.autoSync = v,
        'showConnIndicator': (s, v) => s.showConnIndicator = v,
        'conflictNotify': (s, v) => s.conflictNotify = v,
        'userBinding': (s, v) => s.userBinding = v,
        'showOnlineUsers': (s, v) => s.showOnlineUsers = v,
        'allowUserSwitch': (s, v) => s.allowUserSwitch = v,
        'widgetEnabled': (s, v) => s.widgetEnabled = v,
        'quickLine': (s, v) => s.quickLine = v,
        'voiceButton': (s, v) => s.voiceButton = v,
      };

  Map<String, dynamic> toFullJson() => {
        ...toJson(),
        'darkTheme': darkTheme,
        'language': language,
        'sttLocale': sttLocale,
        'workStart': workStart,
        'workEnd': workEnd,
      };
}
