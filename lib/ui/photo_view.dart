import 'dart:io';

import 'package:flutter/material.dart';

import '../state/app_state.dart';

/// Миниатюра фотографии заявки. Источник: файл на хосте / HTTP с хоста.
/// Если передан [allPhotos], полноэкранный просмотр открывается галереей
/// с листанием, начиная с [initialIndex].
Widget photoThumb(
  BuildContext context,
  AppState app,
  String fileName, {
  double size = 72,
  VoidCallback? onRemove,
  List<String>? allPhotos,
  int initialIndex = 0,
}) {
  final Widget image = app.isHost
      ? Image.file(File(app.audioLocation(fileName)),
          width: size, height: size, fit: BoxFit.cover)
      : Image.network(app.audioLocation(fileName),
          width: size, height: size, fit: BoxFit.cover);
  return Stack(
    children: [
      GestureDetector(
        onTap: () => showPhotoFullscreen(context, app, fileName,
            allPhotos: allPhotos, initialIndex: initialIndex),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: image,
        ),
      ),
      if (onRemove != null)
        Positioned(
          top: 0,
          right: 0,
          child: GestureDetector(
            onTap: onRemove,
            child: Container(
              decoration: const BoxDecoration(
                  color: Colors.black54, shape: BoxShape.circle),
              child: const Icon(Icons.close, size: 18, color: Colors.white),
            ),
          ),
        ),
    ],
  );
}

/// Полноэкранный просмотр с зумом (щипок/колесо мыши).
/// При нескольких фото — листание свайпом/стрелками.
void showPhotoFullscreen(BuildContext context, AppState app, String fileName,
    {List<String>? allPhotos, int initialIndex = 0}) {
  final List<String> photos =
      (allPhotos != null && allPhotos.isNotEmpty) ? allPhotos : [fileName];
  final int start =
      (initialIndex >= 0 && initialIndex < photos.length) ? initialIndex : 0;
  showDialog<void>(
    context: context,
    builder: (BuildContext ctx) => Dialog(
      insetPadding: const EdgeInsets.all(12),
      child: _PhotoGallery(app: app, photos: photos, initialIndex: start),
    ),
  );
}

class _PhotoGallery extends StatefulWidget {
  const _PhotoGallery(
      {required this.app, required this.photos, required this.initialIndex});

  final AppState app;
  final List<String> photos;
  final int initialIndex;

  @override
  State<_PhotoGallery> createState() => _PhotoGalleryState();
}

class _PhotoGalleryState extends State<_PhotoGallery> {
  late final PageController _ctl =
      PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final List<String> photos = widget.photos;
    return Stack(
      children: [
        PageView.builder(
          controller: _ctl,
          itemCount: photos.length,
          onPageChanged: (int i) => setState(() => _index = i),
          itemBuilder: (BuildContext ctx, int i) {
            final Widget image = widget.app.isHost
                ? Image.file(File(widget.app.audioLocation(photos[i])))
                : Image.network(widget.app.audioLocation(photos[i]));
            return InteractiveViewer(maxScale: 5, child: Center(child: image));
          },
        ),
        Positioned(
          top: 4,
          right: 4,
          child: IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.pop(context),
          ),
        ),
        if (photos.length > 1)
          Positioned(
            bottom: 8,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(12)),
                child: Text('${_index + 1} / ${photos.length}',
                    style: const TextStyle(color: Colors.white)),
              ),
            ),
          ),
        if (photos.length > 1 && _index > 0)
          Positioned(
            left: 4,
            top: 0,
            bottom: 0,
            child: Center(
              child: IconButton(
                icon: const Icon(Icons.chevron_left,
                    size: 36, color: Colors.white70),
                onPressed: () => _ctl.previousPage(
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeOut),
              ),
            ),
          ),
        if (photos.length > 1 && _index < photos.length - 1)
          Positioned(
            right: 4,
            top: 0,
            bottom: 0,
            child: Center(
              child: IconButton(
                icon: const Icon(Icons.chevron_right,
                    size: 36, color: Colors.white70),
                onPressed: () => _ctl.nextPage(
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeOut),
              ),
            ),
          ),
      ],
    );
  }
}
