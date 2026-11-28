import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../core/ids.dart';

/// Выбранное и подготовленное фото (сжатое).
class PickedPhoto {
  PickedPhoto({required this.path, required this.fileName, required this.size});

  final String path;
  final String fileName;
  final int size;
}

/// Выбор и подготовка фотографий к заявке: камера/галерея на телефоне,
/// диалог выбора файла на ПК. Снимок ужимается до 1600 px JPEG (качество 80)
/// — достаточно для экрана, файл получается маленьким.
class PhotoService {
  final ImagePicker _picker = ImagePicker();

  /// Телефон: предлагаем камеру или галерею (выбор делает UI).
  Future<PickedPhoto?> pickFromCamera() => _pickMobile(ImageSource.camera);
  Future<PickedPhoto?> pickFromGallery() => _pickMobile(ImageSource.gallery);

  /// ПК: системный диалог выбора файла.
  Future<PickedPhoto?> pickFromFile() async {
    final FilePickerResult? res = await FilePicker.platform.pickFiles(
      type: FileType.image,
      withData: false,
    );
    final String? path = res?.files.single.path;
    if (path == null) return null;
    return _shrink(File(path));
  }

  Future<PickedPhoto?> _pickMobile(ImageSource source) async {
    try {
      final XFile? x = await _picker.pickImage(source: source);
      if (x == null) return null;
      return _shrink(File(x.path));
    } catch (_) {
      return null;
    }
  }

  /// Ужать до 1600 px по длинной стороне, сохранить как JPEG во временную
  /// папку. Если файл не распознался как картинка — берём как есть.
  Future<PickedPhoto?> _shrink(File src) async {
    try {
      final Uint8List bytes = await src.readAsBytes();
      final img.Image? decoded = img.decodeImage(bytes);
      if (decoded == null) {
        return await _copyAsIs(src);
      }
      img.Image out = decoded;
      if (out.width > 1600 || out.height > 1600) {
        out = img.copyResize(
          out,
          width: out.width >= out.height ? 1600 : null,
          height: out.height > out.width ? 1600 : null,
        );
      }
      // Учитываем EXIF-поворот с камеры телефона.
      out = img.bakeOrientation(out);
      final List<int> jpg = img.encodeJpg(out, quality: 80);
      final Directory tmp = await getTemporaryDirectory();
      final String fileName = '${newId()}.jpg';
      final File f =
          File('${tmp.path}${Platform.pathSeparator}$fileName');
      await f.writeAsBytes(jpg, flush: true);
      return PickedPhoto(path: f.path, fileName: fileName, size: jpg.length);
    } catch (_) {
      return _copyAsIs(src);
    }
  }

  Future<PickedPhoto?> _copyAsIs(File src) async {
    try {
      final Directory tmp = await getTemporaryDirectory();
      final String ext = src.path.contains('.')
          ? src.path.substring(src.path.lastIndexOf('.'))
          : '.jpg';
      final String fileName = '${newId()}$ext';
      final File f =
          await src.copy('${tmp.path}${Platform.pathSeparator}$fileName');
      return PickedPhoto(
          path: f.path, fileName: fileName, size: await f.length());
    } catch (_) {
      return null;
    }
  }
}
