import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// Текст заявки с автоматически выделенными телефонными номерами:
/// номер подсвечивается, нажатие открывает звонилку (tel:) — напрямую,
/// без занесения в контакты (для разовых клиентов).
class PhoneText extends StatefulWidget {
  const PhoneText(this.text, {super.key, this.style});

  final String text;
  final TextStyle? style;

  /// Кандидат в номер: начинается с цифры или +, содержит цифры/пробелы/скобки/тире.
  static final RegExp _candidateRe = RegExp(r'\+?[\d][\d\s().\-]{5,}\d');

  /// Допустимое число цифр в номере (городской/мобильный/международный).
  static bool isPhone(String candidate) {
    final String digits = candidate.replaceAll(RegExp(r'\D'), '');
    return digits.length >= 7 && digits.length <= 15;
  }

  /// Нормализация для tel:: оставляем цифры и ведущий «+».
  static String toTel(String raw) {
    final bool plus = raw.trimLeft().startsWith('+');
    final String digits = raw.replaceAll(RegExp(r'\D'), '');
    return plus ? '+$digits' : digits;
  }

  @override
  State<PhoneText> createState() => _PhoneTextState();
}

class _PhoneTextState extends State<PhoneText> {
  final List<TapGestureRecognizer> _recognizers = [];

  @override
  void dispose() {
    for (final TapGestureRecognizer r in _recognizers) {
      r.dispose();
    }
    super.dispose();
  }

  Future<void> _call(String phone) async {
    final Uri uri = Uri.parse('tel:$phone');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    } else if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Позвонить: $phone')));
    }
  }

  @override
  Widget build(BuildContext context) {
    for (final TapGestureRecognizer r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();

    final TextStyle base = widget.style ?? DefaultTextStyle.of(context).style;
    final TextStyle phoneStyle = base.copyWith(
      color: Theme.of(context).colorScheme.primary,
      fontWeight: FontWeight.bold,
      decoration: TextDecoration.underline,
    );

    final List<TextSpan> spans = [];
    int pos = 0;
    for (final RegExpMatch m in PhoneText._candidateRe.allMatches(widget.text)) {
      final String candidate = m.group(0)!;
      if (!PhoneText.isPhone(candidate)) continue;
      if (m.start > pos) {
        spans.add(TextSpan(text: widget.text.substring(pos, m.start), style: base));
      }
      final String tel = PhoneText.toTel(candidate);
      final TapGestureRecognizer rec = TapGestureRecognizer()..onTap = () => _call(tel);
      _recognizers.add(rec);
      spans.add(TextSpan(text: candidate, style: phoneStyle, recognizer: rec));
      pos = m.end;
    }
    if (pos < widget.text.length) {
      spans.add(TextSpan(text: widget.text.substring(pos), style: base));
    }
    if (spans.isEmpty) {
      return Text(widget.text, style: base);
    }
    return RichText(text: TextSpan(children: spans, style: base));
  }
}
