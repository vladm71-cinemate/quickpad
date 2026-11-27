import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// Диктовка в текст (ТЗ 4.1): онлайн-распознавание речи.
///
/// Android — через speech_to_text (Google Speech, нужен интернет).
/// Windows — системная диктовка Win+H (встроена в ОС), плагин не требуется.
///
/// Инициализация ленивая: разрешение микрофона запрашивается при первом
/// нажатии кнопки, а не при старте приложения. Причина последней ошибки — в
/// [lastError]: 'permission', 'permission_permanent', 'no_recognizer', 'error:…'.
class SttService {
  final SpeechToText _stt = SpeechToText();
  bool _available = false;

  /// Причина, по которой распознавание недоступно ('' — всё в порядке).
  String lastError = '';

  bool get isListening => _stt.isListening;
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

  /// Начать распознавание. [localeId] вида «ru-RU» или «ru_RU».
  Future<bool> start({
    required String localeId,
    required void Function(String text, bool isFinal) onResult,
    void Function(String status)? onStatus,
  }) async {
    if (!isAvailable) return false;
    final String locale = localeId.replaceAll('-', '_');
    try {
      await _stt.listen(
        onResult: (result) => onResult(result.recognizedWords, result.finalResult),
        onSoundLevelChange: null,
        listenOptions: SpeechListenOptions(
          localeId: locale,
          listenFor: const Duration(minutes: 2),
          pauseFor: const Duration(seconds: 4),
          partialResults: true,
          cancelOnError: true,
        ),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> stop() async {
    if (!isSupported) return;
    try {
      await _stt.stop();
    } catch (_) {}
  }
}
