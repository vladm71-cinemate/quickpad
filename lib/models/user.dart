/// Пользователь приложения. Привязан к одному или нескольким устройствам.
library;

class AppUser {
  AppUser({
    required this.id,
    required this.name,
    List<String>? deviceIds,
    this.lastSeen,
    this.online = false,
    DateTime? createdAt,
    this.role = 'worker',
  })  : deviceIds = deviceIds ?? <String>[],
        createdAt = createdAt ?? DateTime.now().toUtc();

  final String id;
  String name;

  /// Роль: 'manager' (руководитель) или 'worker' (работник).
  /// Назначается на хосте в настройках пользователей.
  String role;
  bool get isManager => role == 'manager';

  /// Устройства, с которых входил пользователь.
  final List<String> deviceIds;

  /// Время последней активности (вычисляет хост).
  DateTime? lastSeen;

  /// Онлайн-статус (вычисляется хостом, не хранится в заявках).
  bool online;
  final DateTime createdAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'deviceIds': deviceIds,
        'lastSeen': lastSeen?.toIso8601String(),
        'online': online,
        'createdAt': createdAt.toIso8601String(),
        'role': role,
      };

  factory AppUser.fromJson(Map<String, dynamic> j) => AppUser(
        id: j['id'] as String,
        name: j['name'] as String? ?? 'Без имени',
        deviceIds: (j['deviceIds'] as List?)?.map((e) => e.toString()).toList() ?? [],
        lastSeen: j['lastSeen'] != null ? DateTime.tryParse(j['lastSeen'] as String) : null,
        online: j['online'] as bool? ?? false,
        createdAt: DateTime.tryParse(j['createdAt'] as String? ?? '') ?? DateTime.now().toUtc(),
        role: j['role'] as String? ?? 'worker',
      );

  AppUser copy() => AppUser.fromJson(toJson());
}
