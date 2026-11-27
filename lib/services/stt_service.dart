import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_to_text.dart';

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
  bool _available = false;

  /// Причина, по которой распознавание недоступно ('' — всё в порядке).
  String lastError = '';

  bool get isListening => _stt.isListening || _sessionActive;
  bool get isSupported => !kIsWeb && (Platform.isAndroid || Platform.isIOS);
  bool get isAvailable => isSupported && _available;

  /// Запросить разрешение и инициализировать движок. Безопасно вызывать
  /// повторно после отказа.
  Future<bool> init() async {
    if (!isSupported) return false;
    PermissionStatus mic;
    try {
      mic = await Permission.microphone.request();
    } catch (_) {
      mic = PermissionStatus.denied;
    }
    if (!mic.isGranted) {
      lastError = mic.isPermanentlyDenied ? 'permission_permanent' : 'permission';
      return false;
    }
    try {
      _available = await _stt.initialize(
        onError: (error) => lastError = 'error: ${error.errorMsg}',
      );
    } catch (_) {
      _available = false;
    }
    if (!_available && lastError.isEmpty) {
      lastError = 'no_recognizer';
    }
    if (_available) lastError = '';
    return _available;
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
    try {
      final Object? started = await _stt.listen(
        onResult: (result) => onResult(result.recognizedWords, result.finalResult),
        listenFor: const Duration(minutes: 2),
        pauseFor: const Duration(seconds: 8),
        localeId: locale,
        listenOptions: SpeechListenOptions(
          partialResults: true,
          cancelOnError: false,
          onDevice: true, // системный on-device распознаватель, если есть
          listenMode: ListenMode.confirmation,
        ),
      );
      return started == true;
    } catch (_) {
      return false;
    }
  }

  /// Цикл непрерывной диктовки: перезапуск после паузы/ошибки.
  Future<void> _listenLoop(
    String localeId,
    void Function(String text, bool isFinal) onResult,
    void Function(String status)? onStatus,
  ) async {
    while (_sessionActive && isAvailable) {
      final String locale = localeId.replaceAll('-', '_');
      try {
        await _stt.listen(
          onResult: (result) {
            final String full = _committed.isEmpty
                ? result.recognizedWords
                : '$_committed ${result.recognizedWords}';
            onResult(full, result.finalResult);
            if (result.finalResult) {
              _committed = full;
            }
          },
          listenFor: const Duration(minutes: 2),
          pauseFor: const Duration(seconds: 30),
          localeId: locale,
          listenOptions: SpeechListenOptions(
            partialResults: true,
            cancelOnError: false,
            onDevice: true,
            listenMode: ListenMode.dictation,
          ),
        );
        // Ждём конца фрагмента (тишина 30 c, ошибка сети и т.п.).
        while (_sessionActive && _stt.isListening) {
          await Future<void>.delayed(const Duration(milliseconds: 300));
        }
      } catch (_) {
        // Ошибка запуска — попробуем ещё раз после паузы.
      }
      if (!_sessionActive) break;
      // Фрагмент закончился паузой — текст уже в _committed; перезапускаемся.
      onStatus?.call('restart');
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    onStatus?.call('done');
  }

  Future<void> stop() async {
    _sessionActive = false;
    if (!isSupported) return;
    try {
      await _stt.stop();
    } catch (_) {}
  }
}
