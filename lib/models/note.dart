import 'enums.dart';

/// Напоминание по времени: когда, кому, повтор.
class Reminder {
  Reminder({
    required this.at,
    this.recipients = ReminderRecipients.all,
    this.repeat = false,
    this.repeatInterval,
    this.firedAt,
  });

  /// Когда напомнить (UTC).
  DateTime at;

  /// Кому: всем / автору / исполнителю.
  ReminderRecipients recipients;

  /// Повторяющееся ли.
  bool repeat;

  /// Интервал повтора (если [repeat]).
  Duration? repeatInterval;

  /// Когда последний раз сработало (хост).
  DateTime? firedAt;

  Map<String, dynamic> toJson() => {
        'at': at.toIso8601String(),
        'recipients': recipients.wire,
        'repeat': repeat,
        'repeatMinutes': repeatInterval?.inMinutes,
        'firedAt': firedAt?.toIso8601String(),
      };

  factory Reminder.fromJson(Map<String, dynamic> j) => Reminder(
        at: DateTime.parse(j['at'] as String),
        recipients: ReminderRecipients.fromWire(j['recipients'] as String?),
        repeat: j['repeat'] as bool? ?? false,
        repeatInterval: (j['repeatMinutes'] as num?) != null
            ? Duration(minutes: (j['repeatMinutes'] as num).toInt())
            : null,
        firedAt: j['firedAt'] != null ? DateTime.tryParse(j['firedAt'] as String) : null,
      );

  /// Краткое описание для списка/карточки.
  String describe() {
    final String base = 'Напоминание (${recipients.label.toLowerCase()})';
    if (repeat && repeatInterval != null) {
      final int m = repeatInterval!.inMinutes;
      if (m % 1440 == 0) return '$base, каждые ${m ~/ 1440} дн.';
      if (m % 60 == 0) return '$base, каждые ${m ~/ 60} ч';
      return '$base, каждые $m мин';
    }
    return base;
  }
}

/// Аудиовложение заявки (опционально).
class AudioAttachment {
  AudioAttachment({
    required this.fileName,
    this.sizeBytes = 0,
    this.transcript,
    this.deleted = false,
    this.durationSec = 0,
  });

  /// Имя файла на хосте.
  final String fileName;
  final int sizeBytes;

  /// Автоматическая расшифровка (если включена).
  String? transcript;

  /// Аудио удалено автоочисткой (расшифровка остаётся).
  bool deleted;

  final int durationSec;

  Map<String, dynamic> toJson() => {
        'fileName': fileName,
        'sizeBytes': sizeBytes,
        'transcript': transcript,
        'deleted': deleted,
        'durationSec': durationSec,
      };

  factory AudioAttachment.fromJson(Map<String, dynamic> j) => AudioAttachment(
        fileName: j['fileName'] as String,
        sizeBytes: (j['sizeBytes'] as num?)?.toInt() ?? 0,
        transcript: j['transcript'] as String?,
        deleted: j['deleted'] as bool? ?? false,
        durationSec: (j['durationSec'] as num?)?.toInt() ?? 0,
      );
}

/// Заявка / заметка.
class Note {
  Note({
    required this.id,
    required this.text,
    required this.authorId,
    required this.createdAt,
    this.status = NoteStatus.fresh,
    this.assigneeId,
    this.priority,
    this.deadline,
    this.reminder,
    List<String>? tags,
    this.colorValue,
    this.contactId,
    this.audio,
    DateTime? updatedAt,
    this.version = 1,
    this.escalated = false,
    this.escalatedAt,
  })  : tags = tags ?? <String>[],
        updatedAt = updatedAt ?? createdAt;

  final String id;
  String text;

  /// Автор проставляется хостом из сессии, а не из полей клиента.
  String authorId;
  DateTime createdAt;
  NoteStatus status;
  String? assigneeId;
  NotePriority? priority;
  DateTime? deadline;
  Reminder? reminder;
  List<String> tags;

  /// Цветовая метка (ARGB). null — «нет метки». Свойство заявки, видна всем.
  int? colorValue;
  String? contactId;
  AudioAttachment? audio;

  /// Время последнего изменения на хосте и номер версии (для конфликтов).
  DateTime updatedAt;
  int version;

  /// Эскалация уже сработала.
  bool escalated;
  DateTime? escalatedAt;

  bool get hasDeadline => deadline != null;

  /// Просрочена ли по дедлайну (для активных статусов).
  bool isOverdue([DateTime? now]) {
    if (deadline == null) return false;
    if (status == NoteStatus.done || status == NoteStatus.rejected) return false;
    return (now ?? DateTime.now().toUtc()).isAfter(deadline!);
  }

  bool get isActive => status == NoteStatus.fresh || status == NoteStatus.inProgress;

  Map<String, dynamic> toJson() => {
        'id': id,
        'text': text,
        'authorId': authorId,
        'createdAt': createdAt.toIso8601String(),
        'status': status.wire,
        'assigneeId': assigneeId,
        'priority': priority?.wire,
        'deadline': deadline?.toIso8601String(),
        'reminder': reminder?.toJson(),
        'tags': tags,
        'colorValue': colorValue,
        'contactId': contactId,
        'audio': audio?.toJson(),
        'updatedAt': updatedAt.toIso8601String(),
        'version': version,
        'escalated': escalated,
        'escalatedAt': escalatedAt?.toIso8601String(),
      };

  factory Note.fromJson(Map<String, dynamic> j) => Note(
        id: j['id'] as String,
        text: j['text'] as String? ?? '',
        authorId: j['authorId'] as String? ?? '',
        createdAt: DateTime.tryParse(j['createdAt'] as String? ?? '') ?? DateTime.now().toUtc(),
        status: NoteStatus.fromWire(j['status'] as String?),
        assigneeId: j['assigneeId'] as String?,
        priority: NotePriority.fromWire(j['priority'] as String?),
        deadline: j['deadline'] != null ? DateTime.tryParse(j['deadline'] as String) : null,
        reminder: j['reminder'] != null ? Reminder.fromJson(j['reminder'] as Map<String, dynamic>) : null,
        tags: (j['tags'] as List?)?.map((e) => e.toString()).toList() ?? [],
        colorValue: (j['colorValue'] as num?)?.toInt(),
        contactId: j['contactId'] as String?,
        audio: j['audio'] != null ? AudioAttachment.fromJson(j['audio'] as Map<String, dynamic>) : null,
        updatedAt: DateTime.tryParse(j['updatedAt'] as String? ?? '') ?? DateTime.now().toUtc(),
        version: (j['version'] as num?)?.toInt() ?? 1,
        escalated: j['escalated'] as bool? ?? false,
        escalatedAt: j['escalatedAt'] != null ? DateTime.tryParse(j['escalatedAt'] as String) : null,
      );

  Note copy() => Note.fromJson(toJson());

  /// Снимок значений полей для сравнения («старое → новое»).
  Map<String, String?> fieldSnapshot({String Function(String userId)? userName}) {
    String uname(String? id) {
      if (id == null || id.isEmpty) return '—';
      return userName?.call(id) ?? id;
    }

    return {
      'text': text,
      'status': status.label,
      'assignee': uname(assigneeId),
      'priority': priority?.label ?? '—',
      'deadline': deadline?.toLocal().toString().substring(0, 16) ?? '—',
      'reminder': reminder == null ? '—' : '${reminder!.at.toLocal().toString().substring(0, 16)} (${reminder!.recipients.label})',
      'tags': tags.isEmpty ? '—' : tags.join(', '),
      'color': colorValue == null ? 'нет метки' : '#${colorValue!.toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}',
      'contact': contactId ?? '—',
      'audio': audio == null ? '—' : (audio!.deleted ? 'удалено' : audio!.fileName),
      'transcript': audio?.transcript ?? '—',
    };
  }
}
