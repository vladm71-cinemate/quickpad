import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

import '../core/constants.dart';
import '../core/ids.dart';

/// Результат записи голоса.
class RecordedAudio {
  RecordedAudio({required this.path, required this.fileName, required this.durationSec});

  final String path;
  final String fileName;
  final int durationSec;
}

/// Запись, загрузка на хост и воспроизведение аудиовложений (ТЗ 4.1).
class AudioService {
  final AudioRecorder _recorder = AudioRecorder();
  final AudioPlayer _player = AudioPlayer();
  DateTime? _startedAt;
  String? _currentPath;

  bool get isPlaying => _player.state == PlayerState.playing;

  Future<bool> ensureMicPermission() async {
    // На десктопе (Windows/Linux) рантайм-разрешения микрофона нет.
    if (!Platform.isAndroid && !Platform.isIOS && !Platform.isMacOS) return true;
    try {
      final PermissionStatus mic = await Permission.microphone.request();
      return mic.isGranted;
    } catch (_) {
      return true;
    }
  }

  /// Начать запись (m4a/aac). Возвращает false, если нет разрешения.
  Future<bool> startRecording() async {
    if (!await ensureMicPermission()) return false;
    final Directory dir = await getTemporaryDirectory();
    final String fileName = '${newId()}$kAudioExt';
    final String path = '${dir.path}${Platform.pathSeparator}$fileName';
    try {
      await _recorder.start(const RecordConfig(encoder: AudioEncoder.aacLc), path: path);
      _startedAt = DateTime.now();
      _currentPath = path;
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> get isRecording async {
    try {
      return await _recorder.isRecording();
    } catch (_) {
      return false;
    }
  }

  /// Остановить запись.
  Future<RecordedAudio?> stopRecording() async {
    try {
      final String? path = await _recorder.stop();
      final String? p = path ?? _currentPath;
      if (p == null) return null;
      final int secs =
          _startedAt != null ? DateTime.now().difference(_startedAt!).inSeconds : 0;
      _currentPath = null;
      _startedAt = null;
      return RecordedAudio(
        path: p,
        fileName: p.split(Platform.pathSeparator).last,
        durationSec: secs,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> cancelRecording() async {
    try {
      await _recorder.stop();
    } catch (_) {}
    _currentPath = null;
    _startedAt = null;
  }

  /// Загрузить файл на хост. Возвращает размер в байтах или null при ошибке.
  Future<int?> upload(String host, int port, RecordedAudio audio) async {
    try {
      final Uri uri = Uri.parse('http://$host:$port/audio/${audio.fileName}');
      final List<int> bytes = await File(audio.path).readAsBytes();
      final http.Response res = await http
          .post(uri, body: bytes, headers: {'content-type': 'application/octet-stream'})
          .timeout(const Duration(seconds: 30));
      if (res.statusCode == 200) return bytes.length;
      return null;
    } catch (_) {
      return null;
    }
  }

  /// URL для потокового воспроизведения с хоста.
  String audioUrl(String host, int port, String fileName) => 'http://$host:$port/audio/$fileName';

  Future<void> play(String url) async {
    await _player.stop();
    await _player.play(UrlSource(url));
  }

  Future<void> playLocal(String path) async {
    await _player.stop();
    await _player.play(DeviceFileSource(path));
  }

  Future<void> stopPlay() async {
    try {
      await _player.stop();
    } catch (_) {}
  }

  /// Колбэк окончания воспроизведения.
  void onComplete(void Function() cb) {
    _player.onPlayerComplete.listen((_) => cb());
  }

  /// Удалить временные файлы записей старше суток (локальный след аудио на
  /// устройстве; сами вложения хранятся на хосте и удаляются по настройке
  /// «Срок хранения аудио» — тогда прослушивание отключается на всех устройствах).
  Future<void> cleanupTemp() async {
    try {
      final Directory dir = await getTemporaryDirectory();
      await for (final FileSystemEntity e in dir.list()) {
        if (e is File && e.path.endsWith(kAudioExt)) {
          final FileStat stat = await e.stat();
          if (DateTime.now().difference(stat.modified) > const Duration(days: 1)) {
            await e.delete();
          }
        }
      }
    } catch (_) {}
  }

  void dispose() {
    unawaited(_recorder.dispose());
    unawaited(_player.dispose());
  }
}
