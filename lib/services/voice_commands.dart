import '../models/enums.dart';

/// Тип распознанной голосовой команды.
enum VoiceIntentType {
  newNote,
  showMine,
  showAll,
  summary,
  setStatus,
  pin,
  unpin,
  remind,
  callContact,
  unknown,
}

/// Результат разбора голосовой команды.
class VoiceIntent {
  const VoiceIntent({
    required this.type,
    this.confidence = 1.0,
    this.status,
    this.remindIn,
    this.contactQuery,
    this.candidates = const [],
  });

  final VoiceIntentType type;
  final double confidence;
  final NoteStatus? status;
  final Duration? remindIn;
  final String? contactQuery;

  /// Варианты действий при неуверенности (ТЗ 4.1: предложение выбрать вручную).
  final List<String> candidates;
}

/// Голосовые команды (ТЗ 4.1, расширенный набор):
/// «новая заявка», «покажи мои», «покажи все», «сводка»,
/// «сменить статус на …», «закрепить/открепить»,
/// «напомни через N минут/часов/дней», «позвонить контакту …».
///
/// Список фиксированный, расширяемый — добавить команду = добавить правило.
class VoiceCommands {
  static const List<String> allDescriptions = [
    '«Новая заявка» — создать заявку',
    '«Покажи мои» — мои заявки',
    '«Покажи все» — все заявки',
    '«Сводка» — сводка дня',
    '«Сменить статус на …» — в работе / выполнена / отклонена / отложена / новая',
    '«Закрепить» / «Открепить» — закрепление текущей заявки',
    '«Напомни через 30 минут» — напоминание',
    '«Позвонить контакту Иван» — звонок из библиотеки',
  ];

  static VoiceIntent parse(String raw) {
    final String t = raw.toLowerCase().trim();
    if (t.isEmpty) return const VoiceIntent(type: VoiceIntentType.unknown, confidence: 0);

    // Позвонить контакту
    if (_hasAny(t, ['позвони', 'позвонить', 'набери', 'звонок'])) {
      final String q = t
          .replaceAll(RegExp(r'(позвони(ть)?|набери|звонок|контакту|контакт)'), ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      return VoiceIntent(
          type: VoiceIntentType.callContact, contactQuery: q, confidence: q.isEmpty ? 0.6 : 0.9);
    }

    // Напомни через N минут/часов/дней
    if (_hasAny(t, ['напомни', 'напоминание'])) {
      final RegExp re = RegExp(r'(\d+)\s*(минут[а-я]*|мин\.?|час[а-я]*|ч\.?|дн[а-я]*|день|дня|дней)');
      final RegExpMatch? m = re.firstMatch(t);
      if (m != null) {
        final int n = int.parse(m.group(1)!);
        final String unit = m.group(2)!;
        Duration d;
        if (unit.startsWith('д')) {
          d = Duration(days: n);
        } else if (unit.startsWith('ч')) {
          d = Duration(hours: n);
        } else {
          d = Duration(minutes: n);
        }
        return VoiceIntent(type: VoiceIntentType.remind, remindIn: d, confidence: 0.9);
      }
      return const VoiceIntent(
          type: VoiceIntentType.remind, confidence: 0.5, candidates: ['Напомни через 30 минут', 'Напомни через 2 часа']);
    }

    // Сменить статус
    if (_hasAny(t, ['статус', 'переведи', 'перевести'])) {
      final NoteStatus? st = _parseStatus(t);
      if (st != null) {
        return VoiceIntent(type: VoiceIntentType.setStatus, status: st, confidence: 0.9);
      }
      return const VoiceIntent(
          type: VoiceIntentType.setStatus,
          confidence: 0.5,
          candidates: ['в работе', 'выполнена', 'отклонена', 'отложена', 'новая']);
    }

    // Закрепить / открепить
    if (t.contains('откреп')) return const VoiceIntent(type: VoiceIntentType.unpin, confidence: 0.9);
    if (t.contains('закреп')) return const VoiceIntent(type: VoiceIntentType.pin, confidence: 0.9);

    // Новая заявка
    if (_hasAny(t, ['новая заявка', 'создай заявку', 'создать заявку', 'добавь заявку', 'новая заметка', 'создай заметку'])) {
      return const VoiceIntent(type: VoiceIntentType.newNote, confidence: 0.95);
    }

    // Покажи мои / все
    if (_hasAny(t, ['покажи мои', 'мои заявки', 'покажи моё', 'мои заметки'])) {
      return const VoiceIntent(type: VoiceIntentType.showMine, confidence: 0.95);
    }
    if (_hasAny(t, ['покажи все', 'все заявки', 'покажи всё', 'весь список'])) {
      return const VoiceIntent(type: VoiceIntentType.showAll, confidence: 0.95);
    }

    // Сводка
    if (_hasAny(t, ['сводка', 'итоги', 'статистика', 'что нового'])) {
      return const VoiceIntent(type: VoiceIntentType.summary, confidence: 0.9);
    }

    return const VoiceIntent(
        type: VoiceIntentType.unknown, confidence: 0, candidates: allDescriptions);
  }

  static NoteStatus? _parseStatus(String t) {
    if (t.contains('в работ')) return NoteStatus.inProgress;
    if (t.contains('выполн')) return NoteStatus.done;
    if (t.contains('отклон')) return NoteStatus.rejected;
    if (t.contains('отлож')) return NoteStatus.postponed;
    if (t.contains('нов')) return NoteStatus.fresh;
    return null;
  }

  static bool _hasAny(String t, List<String> phrases) => phrases.any(t.contains);
}
