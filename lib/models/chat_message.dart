import '../core/ids.dart';

/// Личное сообщение между пользователями (локальный мессенджер).
///
/// Хранится на хосте; клиенту присылаются только сообщения, где он —
/// участник (отправитель или получатель). Текст и/или голосовое сообщение
/// (аудиофайл лежит на хосте рядом с аудио заявок, раздаётся по HTTP).
class ChatMessage {
  ChatMessage({
    String? id,
    required this.fromId,
    required this.toId,
    this.text = '',
    this.audioFileName,
    this.audioDurationSec,
    DateTime? createdAt,
    this.readAt,
  })  : id = id ?? newId(),
        createdAt = createdAt ?? DateTime.now().toUtc();

  final String id;
  final String fromId;
  final String toId;
  String text;
  String? audioFileName;
  int? audioDurationSec;
  DateTime createdAt;
  DateTime? readAt;

  bool get hasAudio => audioFileName != null && audioFileName!.isNotEmpty;

  Map<String, dynamic> toJson() => {
        'id': id,
        'fromId': fromId,
        'toId': toId,
        'text': text,
        'audioFileName': audioFileName,
        'audioDurationSec': audioDurationSec,
        'createdAt': createdAt.toIso8601String(),
        'readAt': readAt?.toIso8601String(),
      };

  factory ChatMessage.fromJson(Map<String, dynamic> j) => ChatMessage(
        id: j['id'] as String,
        fromId: j['fromId'] as String? ?? '',
        toId: j['toId'] as String? ?? '',
        text: j['text'] as String? ?? '',
        audioFileName: j['audioFileName'] as String?,
        audioDurationSec: (j['audioDurationSec'] as num?)?.toInt(),
        createdAt: DateTime.tryParse(j['createdAt'] as String? ?? '')?.toUtc() ??
            DateTime.now().toUtc(),
        readAt: j['readAt'] == null
            ? null
            : DateTime.tryParse(j['readAt'] as String)?.toUtc(),
      );
}
