import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// Диктовка в текст (ТЗ 4.1): онлайн-распознавание речи.
///
/// Android — через speech_to_text (Google Speech, нужен интернет).
/// Windows — системная диктовка Win+H (встроена в ОС), плагин не требуется:
/// [isSupported] вернёт false, UI покажет подсказку.
class SttService {
  final SpeechToText _stt = SpeechToText();
  bool _available = false;

  bool get isListening => _stt.isListening;
  bool get isSupported => !kIsWeb && (Platform.isAndroid || Platform.isIOS);
  bool get isAvailable => isSupported && _available;

  Future<bool> init() async {
    if (!isSupported) return false;
    final PermissionStatus mic = await Permission.microphone.request();
    if (!mic.isGranted) return false;
    try {
      _available = await _stt.initialize();
    } catch (_) {
      _available = false;
    }
    return _available;
  }

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
