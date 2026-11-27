/// Перечисления модели данных с проводными (JSON) значениями.
library;

/// Статус заявки: Новая → В работе → Выполнена / Отклонена / Отложена.
enum NoteStatus {
  fresh('new', 'Новая'),
  inProgress('in_progress', 'В работе'),
  done('done', 'Выполнена'),
  rejected('rejected', 'Отклонена'),
  postponed('postponed', 'Отложена');

  const NoteStatus(this.wire, this.label);
  final String wire;
  final String label;

  static NoteStatus fromWire(String? v) =>
      NoteStatus.values.firstWhere((e) => e.wire == v, orElse: () => NoteStatus.fresh);
}

/// Приоритет заявки (опционально).
enum NotePriority {
  low('low', 'Низкий'),
  normal('normal', 'Обычный'),
  high('high', 'Высокий');

  const NotePriority(this.wire, this.label);
  final String wire;
  final String label;

  static NotePriority? fromWire(String? v) {
    if (v == null || v.isEmpty) return null;
    for (final e in NotePriority.values) {
      if (e.wire == v) return e;
    }
    return null;
  }
}

/// Получатели напоминания.
enum ReminderRecipients {
  all('all', 'Всем'),
  author('author', 'Автору'),
  assignee('assignee', 'Исполнителю');

  const ReminderRecipients(this.wire, this.label);
  final String wire;
  final String label;

  static ReminderRecipients fromWire(String? v) =>
      ReminderRecipients.values.firstWhere((e) => e.wire == v, orElse: () => ReminderRecipients.all);
}

/// Тип события журнала аудита.
enum AuditType {
  create('create', 'Создание'),
  update('update', 'Изменение'),
  pin('pin', 'Закрепление'),
  unpin('unpin', 'Открепление'),
  escalation('escalation', 'Требует внимания'),
  reminderFired('reminder_fired', 'Напоминание'),
  audioDeleted('audio_deleted', 'Удаление аудио'),
  contactChange('contact_change', 'Контакты'),
  userChange('user_change', 'Пользователи'),
  conflict('conflict', 'Конфликт синхронизации');

  const AuditType(this.wire, this.label);
  final String wire;
  final String label;

  static AuditType fromWire(String? v) =>
      AuditType.values.firstWhere((e) => e.wire == v, orElse: () => AuditType.update);
}

/// Вид уведомления.
enum NotifyKind {
  newNote('new_note'),
  noteChanged('note_changed'),
  reminder('reminder'),
  escalation('escalation'),
  conflict('conflict'),
  audioDeleted('audio_deleted');

  const NotifyKind(this.wire);
  final String wire;

  static NotifyKind fromWire(String? v) =>
      NotifyKind.values.firstWhere((e) => e.wire == v, orElse: () => NotifyKind.noteChanged);
}

/// Состояние подключения клиента к хосту.
enum ConnState { online, offline, syncing }

/// Роль устройства: хост (Windows) или клиент.
enum DeviceRole { host, client }

/// Имена полей заявки для журнала аудита («старое → новое»).
class NoteFields {
  static const String text = 'text';
  static const String status = 'status';
  static const String assignee = 'assignee';
  static const String priority = 'priority';
  static const String deadline = 'deadline';
  static const String reminder = 'reminder';
  static const String tags = 'tags';
  static const String color = 'color';
  static const String contact = 'contact';
  static const String audio = 'audio';
  static const String transcript = 'transcript';

  /// Человекочитаемые названия полей для истории.
  static const Map<String, String> labels = {
    text: 'Текст',
    status: 'Статус',
    assignee: 'Исполнитель',
    priority: 'Приоритет',
    deadline: 'Срок исполнения',
    reminder: 'Напоминание',
    tags: 'Теги',
    color: 'Метка',
    contact: 'Контакт',
    audio: 'Аудио',
    transcript: 'Расшифровка',
  };
}
