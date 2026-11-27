import 'enums.dart';

/// Запись журнала аудита. Не редактируется и не удаляется пользователями.
class AuditEntry {
  AuditEntry({
    required this.id,
    required this.at,
    required this.userId,
    required this.deviceId,
    required this.type,
    this.noteId,
    this.field,
    this.oldValue,
    this.newValue,
    this.details,
  });

  final String id;

  /// Время фиксирует хост.
  final DateTime at;
  final String userId;
  final String deviceId;
  final AuditType type;

  /// Заявка, к которой относится событие (null для контактов/пользователей).
  final String? noteId;

  /// Изменённое поле (для update) — см. [NoteFields].
  final String? field;
  final String? oldValue;
  final String? newValue;

  /// Доп. описание (например, кому ушла эскалация).
  final String? details;

  Map<String, dynamic> toJson() => {
        'id': id,
        'at': at.toIso8601String(),
        'userId': userId,
        'deviceId': deviceId,
        'type': type.wire,
        'noteId': noteId,
        'field': field,
        'oldValue': oldValue,
        'newValue': newValue,
        'details': details,
      };

  factory AuditEntry.fromJson(Map<String, dynamic> j) => AuditEntry(
        id: j['id'] as String,
        at: DateTime.tryParse(j['at'] as String? ?? '') ?? DateTime.now().toUtc(),
        userId: j['userId'] as String? ?? '',
        deviceId: j['deviceId'] as String? ?? '',
        type: AuditType.fromWire(j['type'] as String?),
        noteId: j['noteId'] as String?,
        field: j['field'] as String?,
        oldValue: j['oldValue'] as String?,
        newValue: j['newValue'] as String?,
        details: j['details'] as String?,
      );

  /// Однострочное описание события.
  String describe(String Function(String userId) userName) {
    final String who = userName(userId);
    switch (type) {
      case AuditType.create:
        return '$who создал(а) заявку';
      case AuditType.update:
        final String f = NoteFields.labels[field] ?? field ?? '';
        return '$who: $f: «${oldValue ?? '—'}» → «${newValue ?? '—'}»';
      case AuditType.pin:
        return '$who закрепил(а) заявку';
      case AuditType.unpin:
        return '$who открепил(а) заявку';
      case AuditType.escalation:
        return 'Эскалация: ${details ?? ''}';
      case AuditType.reminderFired:
        return 'Сработало напоминание (${details ?? ''})';
      case AuditType.audioDeleted:
        return 'Аудио удалено автоматически (${details ?? ''})';
      case AuditType.contactChange:
        return '$who: контакт — ${details ?? ''}';
      case AuditType.userChange:
        return '$who: пользователь — ${details ?? ''}';
      case AuditType.conflict:
        return 'Конфликт синхронизации: ${details ?? ''}';
    }
  }
}
