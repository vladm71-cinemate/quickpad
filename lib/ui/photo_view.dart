import 'dart:io';

import 'package:flutter/material.dart';

import '../state/app_state.dart';

/// Миниатюра фотографии заявки. Источник: файл на хосте / HTTP с хоста.
Widget photoThumb(
  BuildContext context,
  AppState app,
  String fileName, {
  double size = 72,
  VoidCallback? onRemove,
}) {
  final Widget image = app.isHost
      ? Image.file(File(app.audioLocation(fileName)),
          width: size, height: size, fit: BoxFit.cover)
      : Image.network(app.audioLocation(fileName),
          width: size, height: size, fit: BoxFit.cover);
  return Stack(
    children: [
      GestureDetector(
        onTap: () => showPhotoFullscreen(context, app, fileName),
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
void showPhotoFullscreen(BuildContext context, AppState app, String fileName) {
  final Widget image = app.isHost
      ? Image.file(File(app.audioLocation(fileName)))
      : Image.network(app.audioLocation(fileName));
  showDialog<void>(
    context: context,
    builder: (BuildContext ctx) => Dialog(
      insetPadding: const EdgeInsets.all(12),
      child: Stack(
        children: [
          InteractiveViewer(
            maxScale: 5,
            child: Center(child: image),
          ),
          Positioned(
            top: 4,
            right: 4,
            child: IconButton(
              icon: const Icon(Icons.close),
              onPressed: () => Navigator.pop(ctx),
            ),
          ),
        ],
      ),
    ),
  );
}
