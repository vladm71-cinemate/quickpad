import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_to_text.dart';

import 'offline_stt.dart';

/// Диктовка в текст (ТЗ 4.1): распознавание речи.
///
/// Android — через speech_to_text. Два режима:
///  - [start] с `continuous: false` — один фрагмент (голосовые команды);
///  - `continuous: true` — диктовка: после паузы/ошибки распознавание
///    перезапускается автоматически, текст накапливается, пока пользователь
///    сам не нажмёт «стоп» (решает «быстро отключается»).
///
/// `onDevice: true` просит системный on-device распознаватель — он работает
/// без приложения Google и без интернета там, где система его предоставляет
/// (тот же механизм, что у голосового ввода на клавиатуре).
///
/// Инициализация ленивая: разрешение микрофона запрашивается при первом
/// нажатии кнопки. Причина последней ошибки — в [lastError]:
/// 'permission', 'permission_permanent', 'no_recognizer', 'error:…'.
class SttService {
  final SpeechToText _stt = SpeechToText();
  final OfflineSttService _offline = OfflineSttService();
  bool _available = false; // системный распознаватель
  bool _offlineActive = false; // встроенный автономный движок

  /// Причина, по которой распознавание недоступно ('' — всё в порядке).
  String lastError = '';

  OfflineSttService get offline => _offline;

  bool get isListening => _stt.isListening || _sessionActive || _offline.isDictating;

  /// Диктовка поддерживается везде: где нет системного распознавателя,
  /// работает встроенный автономный (модель скачивается один раз, ~23 МБ).
  /// Windows/Linux — системная диктовка (Win+H), но не встроенная: нет
  /// собранных библиотек sherpa-onnx под десктоп в пакете.
  bool get isSupported => !kIsWeb;

  /// Можно ли диктовать прямо сейчас (системный или встроенный движок).
  bool get isAvailable => _available || _offlineActive;

  /// Идёт ли распознавание через встроенный автономный движок.
  bool get usingOffline => _offlineActive;

  /// Нужно скачать модель (системного распознавателя нет, модели нет,
  /// платформа поддерживает встроенный движок).
  bool get needsModel =>
      !_available && !_offlineActive && _offline.platformOk;

  /// Скачана ли автономная модель.
  Future<bool> modelReady() => _offline.modelReady();

  /// Скачать модель (~23 МБ, один раз). null = успех, иначе текст ошибки.
  Future<String?> downloadModel({void Function(int received, int total)? onProgress}) =>
      _offline.downloadModel(onProgress: onProgress);

  /// Запросить разрешение и инициализировать движок. Безопасно вызывать
  /// повторно после отказа. ПРЕДПОЧТИТЕЛЕН встроенный автономный движок
  /// (если модель скачана): он одинаково работает на любых телефонах,
  /// без Google и без интернета. Системный — запасной вариант.
  Future<bool> init() async {
    if (kIsWeb) return false;
    if (Platform.isAndroid || Platform.isIOS) {
      PermissionStatus mic;
      try {
        mic = await Permission.microphone.request();
      } catch (_) {
        mic = PermissionStatus.denied;
      }
      if (!mic.isGranted) {
        lastError = mic.isPermanentlyDenied ? 'permission_permanent' : 'permission';
        return false; // без микрофона не работает ни один движок
      }
      // 1) Встроенный автономный движок (модель уже скачана).
      if (await _offline.init()) {
        _offlineActive = true;
        lastError = '';
        return true;
      }
      // 2) Системный распознаватель — запасной вариант.
      try {
        _available = await _stt.initialize(
          onError: (error) => lastError = 'error: ${error.errorMsg}',
        );
      } catch (_) {
        _available = false;
      }
      if (_available) {
        lastError = '';
        return true;
      }
      if (lastError.isEmpty) lastError = 'no_recognizer'; // UI предложит модель
      return false;
    }
    if (await _offline.init()) {
      _offlineActive = true;
      lastError = '';
      return true;
    }
    if (lastError.isEmpty || lastError == 'no_recognizer') {
      lastError = 'no_recognizer';
    }
    return false;
  }

  /// Открыть системные настройки приложения (когда разрешение запрещено навсегда).
  Future<void> openSystemSettings() => openAppSettings();

  // ---------- Непрерывная диктовка ----------

  bool _sessionActive = false;
  String _committed = ''; // уже завершённые фрагменты текущей диктовки

  /// Начать распознавание. [localeId] вида «ru-RU» или «ru_RU».
  ///
  /// В непрерывном режиме [onResult] получает ПОЛНЫЙ накопленный текст
  /// (все фрагменты с начала диктовки); [onDone] — когда движок остановился
  /// окончательно (только для одиночного режима; в непрерывном — после stop()).
  Future<bool> start({
    required String localeId,
    required void Function(String text, bool isFinal) onResult,
    void Function(String status)? onStatus,
    bool continuous = false,
  }) async {
    if (!isAvailable) return false;
    // Встроенный автономный движок — основной, когда модель скачана:
    // одинаковое поведение на любом телефоне, без Google и интернета.
    if (_offlineActive) {
      return _offline.startDictation(
        onResult: onResult,
        onError: (String e) => onStatus?.call('error:$e'),
      );
    }
    if (continuous) {
      _sessionActive = true;
      _committed = '';
      unawaited(_listenLoop(localeId, onResult, onStatus));
      return true;
    }
    return _listenOnce(localeId, onResult, onStatus);
  }

  /// Один цикл распознавания (голосовые команды): запускаем и сразу выходим,
  /// результат приходит в [onResult]; UI сам останавливает по таймеру.
  Future<bool> _listenOnce(
    String localeId,
    void Function(String text, bool isFinal) onResult,
    void Function(String status)? onStatus,
  ) async {
    final String locale = localeId.replaceAll('-', '_');
    // Сначала on-device (без Google/интернета); если недоступен — обычный.
    for (final bool onDevice in const [true, false]) {
      try {
        final Object? started = await _stt.listen(
          onResult: (result) => onResult(result.recognizedWords, result.finalResult),
          listenFor: const Duration(minutes: 2),
          pauseFor: const Duration(seconds: 8),
          localeId: locale,
          listenOptions: SpeechListenOptions(
            partialResults: true,
            cancelOnError: false,
            onDevice: onDevice,
            listenMode: ListenMode.confirmation,
          ),
        );
        if (started == true) return true;
      } catch (_) {
        // попробуем следующий вариант
      }
    }
    return false;
  }

  /// Цикл непрерывной диктовки: перезапуск после паузы/ошибки.
  Future<void> _listenLoop(
    String localeId,
    void Function(String text, bool isFinal) onResult,
    void Function(String status)? onStatus,
  ) async {
    bool onDevice = true; // сначала пробуем on-device (без Google и интернета)
    int failures = 0;
    int emptyFragments = 0; // фрагменты, в которых движок не распознал ни слова
    while (_sessionActive && isAvailable) {
      final String locale = localeId.replaceAll('-', '_');
      String fragment = '';
      bool fragmentFinal = false;
      try {
        final Object? started = await _stt.listen(
          onResult: (result) {
            fragment = result.recognizedWords;
            final String full =
                _committed.isEmpty ? fragment : '$_committed $fragment';
            onResult(full, result.finalResult);
            if (result.finalResult) {
              _committed = full;
              fragmentFinal = true;
            }
          },
          listenFor: const Duration(minutes: 5),
          pauseFor: const Duration(seconds: 30),
          localeId: locale,
          listenOptions: SpeechListenOptions(
            partialResults: true,
            cancelOnError: false,
            onDevice: onDevice,
            listenMode: ListenMode.dictation,
          ),
        );
        if (started != true) {
          // On-device недоступен на этом устройстве — дальше без него.
          if (onDevice) {
            onDevice = false;
            continue;
          }
          failures++;
          if (failures >= 3) {
            // Системный распознаватель не заводится (нет сервиса Google
            // и т.п.) — переключаемся на встроенный автономный движок.
            _sessionActive = false;
            await _fallbackToOffline(onResult, onStatus);
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 600));
          continue;
        }
        failures = 0;
        // ВАЖНО: движок стартует асинхронно — ждём, пока реально начнёт слушать,
        // иначе цикл завершался мгновенно и диктовка «записывала пару слов и всё».
        for (int i = 0; i < 30 && _sessionActive && !_stt.isListening; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        // Ждём конца фрагмента (тишина 30 c, ошибка сети и т.п.).
        while (_sessionActive && _stt.isListening) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
        // Если движок закончил БЕЗ финального результата — не теряем
        // последний кусок: фиксируем то, что успел распознать.
        if (!fragmentFinal && fragment.isNotEmpty) {
          _committed =
              _committed.isEmpty ? fragment : '$_committed $fragment';
          onResult(_committed, true);
        }
        // Движок «прослушал» фрагмент, но не распознал ни слова —
        // признак сломанного системного распознавателя.
        if (fragment.trim().isEmpty) {
          emptyFragments++;
          if (emptyFragments >= 3) {
            _sessionActive = false;
            await _fallbackToOffline(onResult, onStatus);
            break;
          }
        } else {
          emptyFragments = 0;
        }
      } catch (_) {
        // Ошибка запуска — попробуем ещё раз после паузы.
      }
      if (!_sessionActive) break;
      // Фрагмент закончился паузой — текст уже в _committed; перезапускаемся.
      onStatus?.call('restart');
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    onStatus?.call('done');
  }

  /// Системный распознаватель не завёлся или молчит: переключаемся на
  /// встроенный автономный движок, если модель скачана.
  /// true = диктовка продолжается на встроенном движке.
  Future<bool> _fallbackToOffline(
    void Function(String text, bool isFinal) onResult,
    void Function(String status)? onStatus,
  ) async {
    try {
      await _stt.stop();
    } catch (_) {}
    if (_offline.platformOk &&
        await _offline.modelReady() &&
        await _offline.init()) {
      _available = false;
      _offlineActive = true;
      onStatus?.call('offline');
      return _offline.startDictation(onResult: onResult);
    }
    lastError = 'no_text';
    onStatus?.call('error');
    return false;
  }

  Future<void> stop() async {
    _sessionActive = false;
    if (kIsWeb) return;
    try {
      await _stt.stop();
    } catch (_) {}
    if (_offlineActive) {
      await _offline.stopDictation();
    }
  }
}
