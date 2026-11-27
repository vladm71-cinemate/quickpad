/// Контакт из библиотеки адресов.
library;

class Contact {
  Contact({
    required this.id,
    required this.name,
    this.phone = '',
    this.comment = '',
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? DateTime.now().toUtc();

  final String id;
  String name;
  String phone;
  String comment;
  DateTime updatedAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'phone': phone,
        'comment': comment,
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory Contact.fromJson(Map<String, dynamic> j) => Contact(
        id: j['id'] as String,
        name: j['name'] as String? ?? '',
        phone: j['phone'] as String? ?? '',
        comment: j['comment'] as String? ?? '',
        updatedAt: DateTime.tryParse(j['updatedAt'] as String? ?? '') ?? DateTime.now().toUtc(),
      );

  Contact copy() => Contact.fromJson(toJson());
}
