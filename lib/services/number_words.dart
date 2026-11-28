/// Преобразование русских числительных в цифры после распознавания речи
/// (настройка «Числа цифрами»). Полностью офлайн, чистый Dart.
///
/// Покрывает:
///  - количественные до миллионов: «двадцать пять» → «25»,
///    «две тысячи триста пятьдесят» → «2350»;
///  - «полтора/полторы» → «1,5»;
///  - десятичные: «тридцать целых пять десятых» → «30,5»,
///    «ноль целых двадцать пять сотых» → «0,25»;
///  - телефоны слитно: «восемь девятьсот двенадцать триста сорок пять
///    шестьдесят семь восемьдесят девять» → «89123456789», по одной цифре:
///    «восемь девять ноль ноль один два три четыре пять шесть» → «8900123456»
///    (также «семь …» и «плюс семь …»);
///  - порядковые («первый», «пятое») и идиомы («один момент») не трогаем.
library;

/// Слова-единицы → значение.
const Map<String, int> _units = {
  'ноль': 0, 'нуль': 0,
  'один': 1, 'одна': 1, 'одну': 1, 'одно': 1,
  'два': 2, 'две': 2,
  'три': 3, 'четыре': 4, 'пять': 5, 'шесть': 6,
  'семь': 7, 'восемь': 8, 'девять': 9,
};

const Map<String, int> _teens = {
  'десять': 10, 'одиннадцать': 11, 'двенадцать': 12, 'тринадцать': 13,
  'четырнадцать': 14, 'пятнадцать': 15, 'шестнадцать': 16,
  'семнадцать': 17, 'восемнадцать': 18, 'девятнадцать': 19,
};

const Map<String, int> _tens = {
  'двадцать': 20, 'тридцать': 30, 'сорок': 40, 'пятьдесят': 50,
  'шестьдесят': 60, 'семьдесят': 70, 'восемьдесят': 80, 'девяносто': 90,
};

const Map<String, int> _hundreds = {
  'сто': 100, 'двести': 200, 'триста': 300, 'четыреста': 400,
  'пятьсот': 500, 'шестьсот': 600, 'семьсот': 700, 'восемьсот': 800,
  'девятьсот': 900,
};

const Set<String> _thousand = {'тысяча', 'тысячи', 'тысяч', 'тысячу'};
const Set<String> _million = {'миллион', 'миллиона', 'миллионов', 'миллионе'};

/// Множители дробной части.
const Map<String, int> _fracScale = {
  'десятых': 10, 'десятой': 10,
  'сотых': 100, 'сотой': 100,
  'тысячных': 1000, 'тысячной': 1000,
};

/// Маркеры десятичной дроби.
const Set<String> _wholeMark = {'целых', 'целая', 'запятая'};

/// Идиомы после одинокого «один/одна/одну», где цифра неуместна.
const Set<String> _oneIdioms = {
  'момент', 'моментик', 'минутку', 'секунду', 'секундочку', 'раз',
};

bool _isNumWord(String w) =>
    _units.containsKey(w) ||
    _teens.containsKey(w) ||
    _tens.containsKey(w) ||
    _hundreds.containsKey(w) ||
    _thousand.contains(w) ||
    _million.contains(w);

/// Парсер непрерывной цепочки числительных с позиции [i] → значение.
/// Возвращает (значение, индекс после цепочки) или null.
({int value, int next})? _parseNumber(List<String> w, int i) {
  int total = 0;
  int cur = 0;
  int j = i;
  bool any = false;
  while (j < w.length) {
    final String t = w[j];
    final int? u = _units[t] ?? _teens[t] ?? _tens[t] ?? _hundreds[t];
    if (u != null) {
      cur += u;
      any = true;
      j++;
    } else if (_thousand.contains(t)) {
      total += (cur == 0 ? 1 : cur) * 1000;
      cur = 0;
      any = true;
      j++;
    } else if (_million.contains(t)) {
      total += (cur == 0 ? 1 : cur) * 1000000;
      cur = 0;
      any = true;
      j++;
    } else {
      break;
    }
  }
  if (!any) return null;
  return (value: total + cur, next: j);
}

/// Попытка распознать телефонный номер с позиции [i]:
/// «восемь …» / «семь …» / «плюс семь …» + цепочка групп = 11 цифр.
({String phone, int next})? _parsePhone(List<String> w, int i) {
  if (w[i] == 'плюс' && i + 1 < w.length && w[i + 1] == 'семь') {
    return _parsePhoneTail(w, i + 2, '+7');
  }
  if (w[i] == 'восемь' || w[i] == 'семь') {
    return _parsePhoneTail(w, i + 1, w[i] == 'восемь' ? '8' : '7');
  }
  return null;
}

/// Ранг «ступени» числительного: внутри одного русского числа порядок
/// строго нисходящий (сотни → десятки → единицы). Слово той же или
/// большей ступени — уже НОВАЯ группа (следующий разряд номера).
int _rank(String w) {
  if (_hundreds.containsKey(w)) return 3;
  if (_tens.containsKey(w)) return 2;
  if (_units.containsKey(w) || _teens.containsKey(w)) return 1;
  return 0; // тысяча/миллион — разрыв телефонной цепочки
}

/// Хвост телефона: цепочка числительных превращается в поток цифр.
/// Разряды режутся по правилу нисходящего порядка («девятьсот двенадцать»
/// — один разряд 912, а следующая «триста» — уже новый), каждый разряд
/// даёт свои цифры как есть. Поэтому работают оба стиля диктовки номера:
/// группами («…девятьсот двенадцать триста сорок пять шестьдесят семь
/// восемьдесят девять» → 9123456789) и по одной цифре («…девять ноль
/// ноль один два три четыре пять шесть» → 900123456).
/// После «восемь/семь/+7» должно остаться ровно 10 цифр (полный номер)
/// или 9 (короткая форма 8-900-12-34-56) — иначе это не телефон.
({String phone, int next})? _parsePhoneTail(
    List<String> w, int i, String head) {
  final StringBuffer digits = StringBuffer();
  int j = i;
  int cur = 0;
  int lastRank = 99;
  bool any = false;
  while (j < w.length) {
    final String t = w[j];
    final int r = _rank(t);
    if (r == 0) break; // «тысяча» и т.п. — разрыв телефонной цепочки
    final int v = _units[t] ?? _teens[t] ?? _tens[t] ?? _hundreds[t]!;
    if (any && r >= lastRank) {
      digits.write(cur); // новая ступень → закрываем разряд
      cur = 0;
    }
    cur += v;
    lastRank = r;
    any = true;
    j++;
  }
  if (any) digits.write(cur);
  if (digits.length != 10 && digits.length != 9) return null;
  return (phone: head + digits.toString(), next: j);
}

/// Десятичная дробь: [i] — маркер («целых»/«запятая»), [whole] — целая часть.
({String text, int next})? _parseDecimal(List<String> w, int i, int whole) {
  int j = i + 1;
  if (j >= w.length) return null;
  final ({int value, int next})? frac = _parseNumber(w, j);
  if (frac == null) return null;
  j = frac.next;
  int scale;
  if (j < w.length && _fracScale.containsKey(w[j])) {
    scale = _fracScale[w[j]]!;
    j++;
  } else if (w[i] == 'запятая') {
    scale = frac.value >= 100 ? 1000 : (frac.value >= 10 ? 100 : 10);
  } else {
    return null; // «целых» без долей — не дробь
  }
  final int digits = scale == 10 ? 1 : (scale == 100 ? 2 : 3);
  return (text: '$whole,${frac.value.toString().padLeft(digits, '0')}', next: j);
}

/// Основная функция: заменить в тексте числительные цифрами.
String numberWordsToDigits(String input) {
  if (input.trim().isEmpty) return input;

  // Токены: слова и пробелы вперемешку (Dart split не хранит разделители,
  // поэтому используем splitMapJoin и собираем токены вручную).
  final List<String> tokens = <String>[];
  input.splitMapJoin(
    RegExp(r'\s+'),
    onMatch: (Match m) {
      tokens.add(m[0]!);
      return '';
    },
    onNonMatch: (String s) {
      if (s.isNotEmpty) tokens.add(s);
      return '';
    },
  );

  // Слова без пунктуации по краям, в нижнем регистре + маппинг на токены.
  String core(String t) => t
      .toLowerCase()
      .replaceAll(RegExp(r'^[^\p{L}]+|[^\p{L}]+$', unicode: true), '');
  final List<int> tokIdx = <int>[]; // позиция слова → индекс токена
  final List<String> words = <String>[];
  for (int k = 0; k < tokens.length; k++) {
    if (RegExp(r'^\s+$').hasMatch(tokens[k])) continue;
    tokIdx.add(k);
    words.add(core(tokens[k]));
  }

  final List<String> out = List<String>.from(tokens);

  /// Заменить слова [wFrom]..[wTo) одним текстом: первый токен получает
  /// текст (с пунктуацией вокруг), остальные токены диапазона схлопываются,
  /// внутренние пробелы убираются, завершающая пунктуация сохраняется.
  void replaceWords(int wFrom, int wTo, String text) {
    final int tFirst = tokIdx[wFrom];
    final int tLast = tokIdx[wTo - 1];
    final RegExp edge =
        RegExp(r'^([^\p{L}]*)(.*?)([^\p{L}]*)$', unicode: true);
    final RegExpMatch? m1 = edge.firstMatch(out[tFirst]);
    final RegExpMatch? m2 = edge.firstMatch(out[tLast]);
    out[tFirst] = '${m1?.group(1) ?? ''}$text${m2?.group(3) ?? ''}';
    for (int k = tFirst + 1; k <= tLast; k++) {
      out[k] = '';
    }
  }

  int i = 0;
  while (i < words.length) {
    final String w = words[i];
    if (w.isEmpty) {
      i++;
      continue;
    }
    // 1) Телефон: «восемь…» / «семь…» / «плюс семь…».
    if (w == 'восемь' ||
        w == 'семь' ||
        (w == 'плюс' && i + 1 < words.length && words[i + 1] == 'семь')) {
      final ({String phone, int next})? ph = _parsePhone(words, i);
      if (ph != null) {
        replaceWords(i, ph.next, ph.phone);
        i = ph.next;
        continue;
      }
    }
    // 2) «полтора/полторы/полутора» → 1,5.
    if (w == 'полтора' || w == 'полторы' || w == 'полутора') {
      replaceWords(i, i + 1, '1,5');
      i++;
      continue;
    }
    // 3) Число (+ возможная десятичная дробь).
    if (_isNumWord(w)) {
      final ({int value, int next})? num = _parseNumber(words, i);
      if (num != null) {
        // Идиомы: одинокая единица перед «момент/раз…» — оставляем словом.
        if (num.next == i + 1 &&
            _units[w] == 1 &&
            num.next < words.length &&
            _oneIdioms.contains(words[num.next])) {
          i = num.next;
          continue;
        }
        // Десятичная дробь: «тридцать целых пять десятых».
        if (num.next < words.length && _wholeMark.contains(words[num.next])) {
          final ({String text, int next})? dec =
              _parseDecimal(words, num.next, num.value);
          if (dec != null) {
            replaceWords(i, dec.next, dec.text);
            i = dec.next;
            continue;
          }
        }
        replaceWords(i, num.next, '${num.value}');
        i = num.next;
        continue;
      }
    }
    i++;
  }
  return out.join();
}
