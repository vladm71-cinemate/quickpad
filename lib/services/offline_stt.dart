import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

/// Автономное распознавание речи (sherpa-onnx, русская модель Zipformer).
///
/// Работает ПОЛНОСТЬЮ оффлайн: без приложения «Google», без интернета.
/// Модель (~23 МБ) скачивается один раз при первом использовании и лежит
/// в данных приложения. Распознавание потоковое: текст появляется по ходу речи.
///
/// Используется, когда системный распознаватель недоступен (или как основной
/// движок — см. [SttService]).
class OfflineSttService {
  static const String modelUrl =
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/'
      'sherpa-onnx-streaming-zipformer-small-ru-vosk-int8-2025-08-16.tar.bz2';

  /// Файлы, необходимые движку.
  static const List<String> modelFiles = [
    'encoder.int8.onnx',
    'decoder.onnx',
    'joiner.int8.onnx',
    'tokens.txt',
  ];

  sherpa.OnlineRecognizer? _recognizer;
  final AudioRecorder _mic = AudioRecorder();
  StreamSubscription<Uint8List>? _micSub;
  bool _dictating = false;

  // Состояние текущей диктовки (для корректной финализации при остановке).
  sherpa.OnlineStream? _stream;
  String _committed = '';
  void Function(String text, bool isFinal)? _onResult;

  // Гибридная запись: одновременно с распознаванием пишем WAV-файл.
  IOSink? _wavSink;
  String? _wavPath;
  int _wavBytes = 0;

  // Диагностика микрофонного потока.
  int _rxBytes = 0; // байт получено с микрофона за текущую диктовку
  Timer? _micWatchdog;

  /// Сколько байт звука реально пришло с микрофона (0 — микрофон молчит).
  int get rxBytes => _rxBytes;

  /// Причина последней ошибки ('' — всё в порядке). Для диагностики.
  String lastError = '';

  bool get engineReady => _recognizer != null;
  bool get isDictating => _dictating;

  Future<Directory> _modelDir() async {
    final Directory support = await getApplicationSupportDirectory();
    return Directory('${support.path}${Platform.pathSeparator}quickpad'
        '${Platform.pathSeparator}stt_model_ru');
  }

  /// Модель уже скачана и распакована?
  Future<bool> modelReady() async {
    try {
      final Directory dir = await _modelDir();
      for (final String f in modelFiles) {
        if (!await File('${dir.path}${Platform.pathSeparator}$f').exists()) {
          return false;
        }
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Скачать и распаковать модель. [onProgress] — (скачано байт, всего байт;
  /// total == -1 означает стадию «распаковка»).
  /// Возвращает null при успехе, иначе текст ошибки.
  Future<String?> downloadModel(
      {void Function(int received, int total)? onProgress}) async {
    File? tmp;
    try {
      final Directory dir = await _modelDir();
      await dir.create(recursive: true);

      // 1) Скачивание СРАЗУ В ФАЙЛ (не держим архив в памяти).
      final http.Client client = http.Client();
      final http.Request req = http.Request('GET', Uri.parse(modelUrl));
      final http.StreamedResponse resp = await client
          .send(req)
          .timeout(const Duration(minutes: 3));
      if (resp.statusCode != 200) {
        client.close();
        return 'Сервер вернул код ${resp.statusCode}';
      }
      final int total = resp.contentLength ?? 0;
      tmp = File('${dir.path}${Platform.pathSeparator}model.tar.bz2');
      final IOSink sink = tmp.openWrite();
      int received = 0;
      await for (final List<int> chunk in resp.stream) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
      await sink.close();
      client.close();

      // 2) Распаковка tar.bz2 (чистый Dart, без внешних утилит).
      onProgress?.call(0, -1); // сигнал UI: «распаковка…»
      final List<int> tarBytes =
          BZip2Decoder().decodeBytes(await tmp.readAsBytes());
      final Archive tar = TarDecoder().decodeBytes(tarBytes);
      for (final ArchiveFile entry in tar.files) {
        final String name = entry.name.split('/').last;
        if (!modelFiles.contains(name)) continue;
        final File out = File('${dir.path}${Platform.pathSeparator}$name');
        await out.writeAsBytes(entry.content as List<int>, flush: true);
      }
      try {
        await tmp.delete();
      } catch (_) {}
      tmp = null;
      return await modelReady() ? null : 'Модель распакована не полностью';
    } catch (e) {
      try {
        await tmp?.delete();
      } catch (_) {}
      return 'Ошибка загрузки: $e';
    }
  }

  /// Информация о файлах модели: имя → размер в байтах (0 — файла нет).
  /// Для диагностики («Проверка распознавания» в настройках).
  Future<Map<String, int>> modelFilesInfo() async {
    final Map<String, int> out = <String, int>{};
    try {
      final Directory dir = await _modelDir();
      for (final String f in modelFiles) {
        final File file = File('${dir.path}${Platform.pathSeparator}$f');
        out[f] = await file.exists() ? await file.length() : 0;
      }
    } catch (_) {}
    return out;
  }

  /// Тест микрофона: слушаем поток [seconds] секунд и считаем байты.
  /// 0 — микрофон молчит (нет разрешения, занят другим приложением,
  /// аппаратная проблема). Для диагностики.
  Future<int> micTest({int seconds = 2}) async {
    int bytes = 0;
    StreamSubscription<Uint8List>? sub;
    try {
      final Stream<Uint8List> audio = await _mic.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
        ),
      );
      sub = audio.listen((Uint8List d) => bytes += d.length);
      await Future<void>.delayed(Duration(seconds: seconds));
    } catch (e) {
      lastError = 'mic_test: $e';
    } finally {
      try {
        await sub?.cancel();
      } catch (_) {}
      try {
        await _mic.stop();
      } catch (_) {}
    }
    return bytes;
  }

  /// Удалить модель (освободить место).
  Future<void> deleteModel() async {
    try {
      _recognizer?.free();
      _recognizer = null;
      final Directory dir = await _modelDir();
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
  }

  /// Встроенный движок собран только под Android/iOS.
  bool get platformOk => Platform.isAndroid || Platform.isIOS;

  /// Создать движок распознавания (если модель на месте).
  Future<bool> init() async {
    if (!platformOk) return false;
    if (_recognizer != null) return true;
    if (!await modelReady()) return false;
    try {
      sherpa.initBindings();
      final Directory dir = await _modelDir();
      final String p = dir.path + Platform.pathSeparator;
      final sherpa.OnlineRecognizer recognizer = sherpa.OnlineRecognizer(
        sherpa.OnlineRecognizerConfig(
          model: sherpa.OnlineModelConfig(
            transducer: sherpa.OnlineTransducerModelConfig(
              encoder: '${p}encoder.int8.onnx',
              decoder: '${p}decoder.onnx',
              joiner: '${p}joiner.int8.onnx',
            ),
            tokens: '${p}tokens.txt',
            // Пустая строка = автоопределение из метаданных модели.
            // ВАЖНО: у этой русской модели тип НЕ zipformer2 — с явным типом
            // конструктор падает с ошибкой метаданных (проверено тестом
            // на реальных test_wavs из архива модели).
            modelType: '',
            numThreads: 2,
            provider: 'cpu',
            debug: false,
          ),
          feat: const sherpa.FeatureConfig(sampleRate: 16000),
        ),
      );
      _recognizer = recognizer;
      // Самопроверка: прогоняем тишину через движок. Если нативная
      // библиотека не загрузилась или модель не подошла — упадём здесь
      // с понятной ошибкой, а не будем молча «диктовать в никуда».
      final sherpa.OnlineStream test = recognizer.createStream();
      try {
        test.acceptWaveform(samples: Float32List(8000), sampleRate: 16000);
        while (recognizer.isReady(test)) {
          recognizer.decode(test);
        }
        recognizer.getResult(test);
      } finally {
        test.free();
      }
      lastError = '';
      return true;
    } catch (e) {
      _recognizer = null;
      lastError = '$e';
      return false;
    }
  }

  /// Начать потоковую диктовку. [onResult] получает ПОЛНЫЙ накопленный текст
  /// (isFinal=false — промежуточный, true — завершён окончательно).
  /// [onError] — критическая ошибка по ходу (например, микрофон молчит).
  ///
  /// Если передан [saveWavPath], одновременно пишет микрофон в WAV-файл
  /// (16 кГц моно PCM) — гибридный режим «аудио + текст» без системного
  /// распознавателя.
  Future<bool> startDictation({
    required void Function(String text, bool isFinal) onResult,
    void Function(String error)? onError,
    String? saveWavPath,
  }) async {
    if (_dictating) return true;
    if (!await init()) return false;
    final sherpa.OnlineRecognizer recognizer = _recognizer!;
    try {
      final PermissionStatus mic = await Permission.microphone.request();
      if (!mic.isGranted) {
        lastError = 'нет разрешения на микрофон';
        return false;
      }
    } catch (_) {}

    // Параллельная запись в WAV (гибридный режим).
    if (saveWavPath != null) {
      try {
        final File f = File(saveWavPath);
        _wavSink = f.openWrite();
        _wavSink!.add(_wavHeader(0)); // заглушка, размер впишем при стопе
        _wavPath = saveWavPath;
        _wavBytes = 0;
      } catch (e) {
        lastError = 'wav: $e';
      }
    }

    final sherpa.OnlineStream stream = recognizer.createStream();
    _stream = stream;
    _committed = '';
    _onResult = onResult;
    String current = '';
    _dictating = true;

    void pump() {
      while (recognizer.isReady(stream)) {
        recognizer.decode(stream);
      }
      current = recognizer.getResult(stream).text.trim();
      final String full =
          _committed.isEmpty ? current : '$_committed $current'.trim();
      if (full.isNotEmpty) onResult(full, false);
      // Конец фразы (тишина) — фиксируем и начинаем новый фрагмент.
      if (recognizer.isEndpoint(stream)) {
        if (current.isNotEmpty) {
          _committed =
              _committed.isEmpty ? current : '$_committed $current';
          onResult(_committed, false);
        }
        recognizer.reset(stream);
        current = '';
      }
    }

    try {
      final Stream<Uint8List> audio = await _mic.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
        ),
      );
      _rxBytes = 0;
      _micSub = audio.listen(
        (Uint8List data) {
          if (!_dictating) return;
          _rxBytes += data.length;
          // Параллельная запись в файл (сырые PCM-байты как есть).
          if (_wavSink != null) {
            try {
              _wavSink!.add(data);
              _wavBytes += data.length;
            } catch (_) {}
          }
          // PCM16 little-endian → float32 [-1, 1].
          // Int16List.view требует чётного смещения — при нечётном
          // копируем в выровненный буфер, иначе был бы RangeError.
          final Uint8List chunk = data.offsetInBytes.isOdd
              ? Uint8List.fromList(data)
              : data;
          final Int16List pcm = Int16List.view(
              chunk.buffer, chunk.offsetInBytes, chunk.lengthInBytes ~/ 2);
          final Float32List samples = Float32List(pcm.length);
          for (int i = 0; i < pcm.length; i++) {
            samples[i] = pcm[i] / 32768.0;
          }
          stream.acceptWaveform(samples: samples, sampleRate: 16000);
          pump();
        },
        onError: (Object e) {
          // Ошибку микрофона/движка не прячем: видна в диагностике.
          lastError = 'микрофон: $e';
          onError?.call(lastError);
        },
      );
      // Сторожевой таймер: если за 4 секунды с микрофона не пришло
      // ни байта — поток мёртв (разрешение, занятость, драйвер).
      _micWatchdog?.cancel();
      _micWatchdog = Timer(const Duration(seconds: 4), () {
        if (_dictating && _rxBytes == 0) {
          lastError = 'микрофон не передаёт звук (0 байт за 4 с)';
          onError?.call(lastError);
        }
      });
      return true;
    } catch (e) {
      lastError = '$e';
      _dictating = false;
      _stream = null;
      stream.free();
      await _closeWav();
      return false;
    }
  }

  /// Остановить диктовку и дораспознать «хвост» — итог придёт
  /// в onResult с isFinal=true.
  Future<String> stopDictation() async => (await stopDictationFull()).text;

  /// Как [stopDictation], но возвращает ещё и путь к WAV-файлу
  /// (если диктовка шла с параллельной записью).
  Future<({String text, String? wavPath})> stopDictationFull() async {
    _dictating = false;
    _micWatchdog?.cancel();
    _micWatchdog = null;
    try {
      await _micSub?.cancel();
      _micSub = null;
      await _mic.stop();
    } catch (_) {}
    final sherpa.OnlineRecognizer? recognizer = _recognizer;
    final sherpa.OnlineStream? stream = _stream;
    _stream = null;
    if (recognizer != null && stream != null) {
      try {
        stream.inputFinished();
        while (recognizer.isReady(stream)) {
          recognizer.decode(stream);
        }
        final String tail = recognizer.getResult(stream).text.trim();
        if (tail.isNotEmpty) {
          _committed =
              _committed.isEmpty ? tail : '$_committed $tail';
        }
      } catch (_) {}
      try {
        stream.free();
      } catch (_) {}
    }
    await _closeWav();
    final String result = _committed;
    _onResult?.call(result, true);
    _onResult = null;
    return (text: result, wavPath: _wavPath);
  }

  /// Закрыть WAV-файл и вписать реальный размер данных в заголовок.
  Future<void> _closeWav() async {
    final IOSink? sink = _wavSink;
    _wavSink = null;
    if (sink == null) return;
    try {
      await sink.flush();
      await sink.close();
      final String? p = _wavPath;
      if (p != null && _wavBytes > 0) {
        final RandomAccessFile raf =
            await File(p).open(mode: FileMode.writeOnlyAppend);
        try {
          await raf.setPosition(0);
          await raf.writeFrom(_wavHeader(_wavBytes));
        } finally {
          await raf.close();
        }
      }
    } catch (_) {}
  }

  /// Заголовок WAV: PCM16, моно, 16 кГц.
  static Uint8List _wavHeader(int dataBytes) {
    final ByteData b = ByteData(44);
    void tag(int off, String s) {
      for (int i = 0; i < 4; i++) {
        b.setUint8(off + i, s.codeUnitAt(i));
      }
    }

    tag(0, 'RIFF');
    b.setUint32(4, 36 + dataBytes, Endian.little);
    tag(8, 'WAVE');
    tag(12, 'fmt ');
    b.setUint32(16, 16, Endian.little); // размер fmt-чанка
    b.setUint16(20, 1, Endian.little); // PCM
    b.setUint16(22, 1, Endian.little); // моно
    b.setUint32(24, 16000, Endian.little); // частота
    b.setUint32(28, 32000, Endian.little); // байт/сек
    b.setUint16(32, 2, Endian.little); // байт на сэмпл-фрейм
    b.setUint16(34, 16, Endian.little); // битность
    tag(36, 'data');
    b.setUint32(40, dataBytes, Endian.little);
    return b.buffer.asUint8List();
  }

  /// Расшифровать готовый WAV-файл (16 кГц моно) — для гибридного режима.
  Future<String?> transcribeWav(String path) async {
    if (!await init()) return null;
    final sherpa.OnlineRecognizer recognizer = _recognizer!;
    sherpa.OnlineStream? stream;
    try {
      final sherpa.WaveData wave = sherpa.readWave(path);
      stream = recognizer.createStream();
      // Кормим кусками, чтобы не блокировать надолго.
      const int chunk = 16000; // ~1 секунда
      final Float32List all = wave.samples;
      int pos = 0;
      while (pos < all.length) {
        final int end =
            (pos + chunk > all.length) ? all.length : pos + chunk;
        stream.acceptWaveform(
            samples: all.sublist(pos, end), sampleRate: wave.sampleRate);
        while (recognizer.isReady(stream)) {
          recognizer.decode(stream);
        }
        pos = end;
        await Future<void>.delayed(Duration.zero); // отдать кадр UI
      }
      stream.inputFinished();
      while (recognizer.isReady(stream)) {
        recognizer.decode(stream);
      }
      final String text = recognizer.getResult(stream).text.trim();
      return text.isEmpty ? null : text;
    } catch (_) {
      return null;
    } finally {
      stream?.free();
    }
  }

  void dispose() {
    unawaited(stopDictation());
    unawaited(_mic.dispose());
  }
}
