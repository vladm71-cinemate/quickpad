/// Персональное закрепление заявки: отдельная сущность (пользователь + заявка).
library;

class Pin {
  Pin({
    required this.userId,
    required this.noteId,
    required this.pinnedAt,
    this.orderIndex = 0,
  });

  final String userId;
  final String noteId;
  final DateTime pinnedAt;

  /// Порядок ручной сортировки (меньше — выше). Синхронизируется между
  /// устройствами пользователя (решение по открытому вопросу №2).
  int orderIndex;

  String get key => '$userId:$noteId';

  Map<String, dynamic> toJson() => {
        'userId': userId,
        'noteId': noteId,
        'pinnedAt': pinnedAt.toIso8601String(),
        'orderIndex': orderIndex,
      };

  factory Pin.fromJson(Map<String, dynamic> j) => Pin(
        userId: j['userId'] as String,
        noteId: j['noteId'] as String,
        pinnedAt: DateTime.tryParse(j['pinnedAt'] as String? ?? '') ?? DateTime.now().toUtc(),
        orderIndex: (j['orderIndex'] as num?)?.toInt() ?? 0,
      );
}
