import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../core/timefmt.dart';
import '../models/note.dart';
import '../state/app_state.dart';

/// Экспорт заявок в CSV (открывается в Excel; разделитель «;», кириллица
/// с BOM — двойной клик по файлу сразу показывает таблицу по-русски).
class ExportService {
  /// Сформировать CSV-текст по списку заявок.
  static String buildCsv(List<Note> notes, AppState app) {
    String cell(String? v) {
      final String s = (v ?? '').replaceAll('"', '""');
      return '"$s"';
    }

    final StringBuffer b = StringBuffer();
    b.writeln('Дата создания;Текст;Статус;Автор;Исполнитель;Приоритет;'
        'Срок исполнения;Теги;Контакт;Телефон;Расшифровка аудио');
    for (final Note n in notes) {
      String contact = '';
      String phone = '';
      if (n.contactId != null) {
        for (final c in app.contacts) {
          if (c.id == n.contactId) {
            contact = c.name;
            phone = c.phone;
            break;
          }
        }
      }
      b.writeln([
        formatDateTime(n.createdAt),
        n.text,
        n.status.label,
        app.userName(n.authorId),
        n.assigneeId == null ? '' : app.userName(n.assigneeId!),
        n.priority?.label ?? '',
        n.deadline == null ? '' : formatDateTime(n.deadline!),
        n.tags.join(', '),
        contact,
        phone,
        n.audio?.transcript ?? '',
      ].map(cell).join(';'));
    }
    return b.toString();
  }

  /// Сохранить/поделиться CSV. Возвращает описание результата для тоста.
  static Future<String?> exportCsv(List<Note> notes, AppState app) async {
    // BOM нужен, чтобы Excel сразу открыл кириллицу правильно.
    final String csv = '\uFEFF${buildCsv(notes, app)}';
    final List<int> bytes = csv.codeUnits;
    final String fileName =
        'quickpad_export_${DateTime.now().toLocal().toString().substring(0, 16).replaceAll(':', '-').replaceAll(' ', '_')}.csv';
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      final String? path = await FilePicker.platform.saveFile(
        dialogTitle: 'Экспорт заявок в CSV',
        fileName: fileName,
        type: FileType.custom,
        allowedExtensions: ['csv'],
      );
      if (path == null) return null;
      await File(path).writeAsBytes(bytes, flush: true);
      return 'Экспортировано: $path';
    }
    // Телефон: сохраняем во временную папку и предлагаем «Поделиться».
    final Directory tmp = await getTemporaryDirectory();
    final File f = File('${tmp.path}${Platform.pathSeparator}$fileName');
    await f.writeAsBytes(bytes, flush: true);
    await Share.shareXFiles([XFile(f.path)], text: 'Экспорт заявок QuickPad');
    return 'Файл готов к отправке';
  }
}
