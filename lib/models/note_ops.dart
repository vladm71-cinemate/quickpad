import 'enums.dart';
import 'note.dart';

/// Применение патча полей к заявке без побочных эффектов.
/// Используется хостом (с последующими эффектами) и клиентом (оптимистично).
void applyPatchToNote(Note note, Map<String, dynamic> patch) {
  patch.forEach((String field, dynamic value) {
    switch (field) {
      case NoteFields.text:
        note.text = (value as String?) ?? note.text;
        break;
      case NoteFields.status:
        note.status = NoteStatus.fromWire(value as String?);
        break;
      case NoteFields.assignee:
        note.assigneeId = value as String?;
        break;
      case NoteFields.priority:
        note.priority = NotePriority.fromWire(value as String?);
        break;
      case NoteFields.deadline:
        note.deadline = value != null ? DateTime.tryParse(value as String) : null;
        break;
      case NoteFields.reminder:
        note.reminder =
            value != null ? Reminder.fromJson((value as Map).cast<String, dynamic>()) : null;
        break;
      case NoteFields.tags:
        note.tags = (value as List?)?.map((e) => e.toString()).toList() ?? [];
        break;
      case NoteFields.color:
        note.colorValue = (value as num?)?.toInt();
        break;
      case NoteFields.contact:
        note.contactId = value as String?;
        break;
      case NoteFields.audio:
        note.audio = value != null
            ? AudioAttachment.fromJson((value as Map).cast<String, dynamic>())
            : null;
        break;
      case NoteFields.transcript:
        note.audio?.transcript = value as String?;
        break;
    }
  });
}
