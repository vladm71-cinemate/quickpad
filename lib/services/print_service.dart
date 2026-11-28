import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../core/timefmt.dart';
import '../models/note.dart';
import '../state/app_state.dart';

/// Печать заявок (ТЗ: одну или несколько на листе). Генерируем PDF со
/// встроенным шрифтом DejaVu (кириллица, работает без интернета) и отдаём
/// в системный диалог печати/«Сохранить как PDF».
class PrintService {
  static pw.Font? _regular;
  static pw.Font? _bold;

  static Future<void> _loadFonts() async {
    _regular ??=
        pw.Font.ttf(await rootBundle.load('assets/fonts/DejaVuSans.ttf'));
    _bold ??=
        pw.Font.ttf(await rootBundle.load('assets/fonts/DejaVuSans-Bold.ttf'));
  }

  static pw.Text _t(String text, {bool bold = false, double size = 11}) =>
      pw.Text(text,
          style: pw.TextStyle(
              font: bold ? _bold : _regular,
              fontSize: size,
              fontWeight: bold ? pw.FontWeight.bold : null));

  /// Блок одной заявки.
  static pw.Widget _noteBlock(Note n, AppState app) {
    final List<String> meta = [
      'Статус: ${n.status.label}',
      'Автор: ${app.userName(n.authorId)}',
      if (n.assigneeId != null) 'Исполнитель: ${app.userName(n.assigneeId!)}',
      if (n.priority != null) 'Приоритет: ${n.priority!.label}',
      if (n.deadline != null) 'Срок: ${formatDateTime(n.deadline!)}',
      if (n.tags.isNotEmpty) 'Теги: ${n.tags.join(", ")}',
    ];
    String contactLine = '';
    if (n.contactId != null) {
      for (final c in app.contacts) {
        if (c.id == n.contactId) {
          contactLine =
              'Контакт: ${c.name}${c.phone.isEmpty ? '' : ' · ${c.phone}'}';
          break;
        }
      }
    }
    return pw.Container(
      margin: const pw.EdgeInsets.only(bottom: 10),
      padding: const pw.EdgeInsets.all(10),
      decoration: pw.BoxDecoration(
        border: pw.Border.all(color: PdfColors.grey700, width: 0.8),
        borderRadius: const pw.BorderRadius.all(pw.Radius.circular(6)),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              _t('Заявка от ${formatDateTime(n.createdAt)}',
                  bold: true, size: 10),
              if (n.priority != null) _t(n.priority!.label, bold: true),
            ],
          ),
          pw.SizedBox(height: 6),
          _t(n.text, size: 12),
          pw.SizedBox(height: 6),
          _t(meta.join(' · '), size: 9),
          if (contactLine.isNotEmpty) _t(contactLine, size: 9),
          if (n.audio?.transcript != null)
            _t('Расшифровка: ${n.audio!.transcript}', size: 9),
        ],
      ),
    );
  }

  /// Напечатать список заявок (несколько на листе) или одну.
  static Future<void> printNotes(List<Note> notes, AppState app,
      {String title = 'Заявки QuickPad'}) async {
    if (notes.isEmpty) return;
    await _loadFonts();
    final pw.Document doc = pw.Document();
    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(32),
        build: (pw.Context ctx) => [
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              _t(title, bold: true, size: 16),
              _t(formatDateTime(DateTime.now()), size: 9),
            ],
          ),
          pw.SizedBox(height: 4),
          _t('Всего: ${notes.length}', size: 10),
          pw.SizedBox(height: 12),
          ...notes.map((Note n) => _noteBlock(n, app)),
        ],
      ),
    );
    await Printing.layoutPdf(
        onLayout: (PdfPageFormat format) async => doc.save(), name: title);
  }

  /// Напечатать одну заявку.
  static Future<void> printNote(Note note, AppState app) =>
      printNotes([note], app, title: 'Заявка QuickPad');
}
