import 'package:intl/intl.dart';

final DateFormat _dateTimeFmt = DateFormat('dd.MM.yyyy HH:mm');
final DateFormat _timeFmt = DateFormat('HH:mm');
final DateFormat _dateFmt = DateFormat('dd.MM.yyyy');

/// Склонение русских существительных: plural(5, 'минуту', 'минуты', 'минут').
String plural(int n, String one, String few, String many) {
  final int mod100 = n % 100;
  final int mod10 = n % 10;
  if (mod100 >= 11 && mod100 <= 14) return many;
  if (mod10 == 1) return one;
  if (mod10 >= 2 && mod10 <= 4) return few;
  return many;
}

/// «dd.MM.yyyy HH:mm» в локальном времени.
String formatDateTime(DateTime dt) => _dateTimeFmt.format(dt.toLocal());

/// «HH:mm» в локальном времени.
String formatTime(DateTime dt) => _timeFmt.format(dt.toLocal());

/// «dd.MM.yyyy» в локальном времени.
String formatDate(DateTime dt) => _dateFmt.format(dt.toLocal());

/// Относительное время: «только что», «5 мин назад», «2 ч назад», «вчера», дата.
String formatRelative(DateTime dt, {DateTime? now}) {
  final DateTime n = now ?? DateTime.now();
  final Duration diff = n.difference(dt.toLocal());
  if (diff.isNegative || diff.inSeconds < 45) return 'только что';
  if (diff.inMinutes < 1) return 'меньше минуты назад';
  if (diff.inMinutes < 60) {
    return '${diff.inMinutes} ${plural(diff.inMinutes, 'минуту', 'минуты', 'минут')} назад';
  }
  if (diff.inHours < 24) {
    return '${diff.inHours} ${plural(diff.inHours, 'час', 'часа', 'часов')} назад';
  }
  final DateTime dLocal = dt.toLocal();
  final DateTime yesterday = DateTime(n.year, n.month, n.day).subtract(const Duration(days: 1));
  if (DateTime(dLocal.year, dLocal.month, dLocal.day) == yesterday) return 'вчера';
  if (diff.inDays < 7) {
    return '${diff.inDays} ${plural(diff.inDays, 'день', 'дня', 'дней')} назад';
  }
  return formatDate(dLocal);
}

/// Человекочитаемая длительность до дедлайна/напоминания: «через 30 мин», «просрочено на 2 ч».
String formatDeadline(DateTime dt, {DateTime? now}) {
  final DateTime n = now ?? DateTime.now();
  final Duration diff = dt.toLocal().difference(n);
  final bool overdue = diff.isNegative;
  final Duration a = diff.abs();
  String text;
  if (a.inMinutes < 1) {
    text = 'меньше минуты';
  } else if (a.inMinutes < 60) {
    text = '${a.inMinutes} ${plural(a.inMinutes, 'минута', 'минуты', 'минут')}';
  } else if (a.inHours < 24) {
    text = '${a.inHours} ${plural(a.inHours, 'час', 'часа', 'часов')}';
  } else {
    text = '${a.inDays} ${plural(a.inDays, 'день', 'дня', 'дней')}';
  }
  return overdue ? 'просрочено на $text' : 'через $text';
}

/// Компактное представление длительности для эскалации: «30 мин», «1 ч», «2 ч 30 мин».
String formatDurationShort(Duration d) {
  if (d.inMinutes < 60) return '${d.inMinutes} мин';
  final int h = d.inHours;
  final int m = d.inMinutes % 60;
  if (m == 0) return '$h ${plural(h, 'час', 'часа', 'часов')}';
  return '$h ч $m мин';
}
