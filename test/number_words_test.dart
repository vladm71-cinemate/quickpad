import 'package:flutter_test/flutter_test.dart';
import 'package:quickpad/services/number_words.dart';

void main() {
  group('Числительные → цифры', () {
    test('простые числа', () {
      expect(numberWordsToDigits('тридцать килограмм'), '30 килограмм');
      expect(numberWordsToDigits('купить двадцать пять мешков'),
          'купить 25 мешков');
      expect(numberWordsToDigits('сто сорок метров'), '140 метров');
      expect(numberWordsToDigits('две тысячи триста пятьдесят'), '2350');
      expect(numberWordsToDigits('пять'), '5');
    });

    test('десятичные дроби', () {
      expect(numberWordsToDigits('тридцать целых пять десятых килограмм'),
          '30,5 килограмм');
      expect(numberWordsToDigits('ноль целых двадцать пять сотых'), '0,25');
      expect(numberWordsToDigits('полтора килограмма'), '1,5 килограмма');
      expect(numberWordsToDigits('полторы тонны'), '1,5 тонны');
    });

    test('телефоны слитно', () {
      expect(
          numberWordsToDigits(
              'восемь девятьсот двенадцать триста сорок пять шестьдесят семь восемьдесят девять'),
          '89123456789');
      expect(
          numberWordsToDigits(
              'звонить семь девятьсот двенадцать триста сорок пять шестьдесят семь восемьдесят девять'),
          'звонить 79123456789');
      expect(
          numberWordsToDigits(
              'плюс семь девятьсот двенадцать триста сорок пять шестьдесят семь восемьдесят девять'),
          '+79123456789');
      // С кодом «круглые сотни»: 8-900-123-45-67.
      expect(
          numberWordsToDigits(
              'восемь девятьсот сто двадцать три сорок пять шестьдесят семь'),
          '89001234567');
      // «восемь мешков» — не телефон, просто число.
      expect(numberWordsToDigits('восемь мешков'), '8 мешков');
    });

    test('не числа — не трогаем', () {
      expect(numberWordsToDigits('первый этаж'), 'первый этаж');
      expect(numberWordsToDigits('пятое марта'), 'пятое марта');
      expect(numberWordsToDigits('один момент'), 'один момент');
      expect(numberWordsToDigits('один мешок'), '1 мешок');
      // «восемь» не телефон (короткая цепочка) — просто число.
      expect(numberWordsToDigits('восемь мешков'), '8 мешков');
    });

    test('пунктуация и регистр сохраняются', () {
      expect(numberWordsToDigits('Нужно пять штук.'), 'Нужно 5 штук.');
      expect(numberWordsToDigits('примерно двадцать пять, не больше'),
          'примерно 25, не больше');
    });
  });
}
