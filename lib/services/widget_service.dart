import 'dart:async';

import 'package:flutter/services.dart';

/// Обновление виджета рабочего стола Android: текст последней/закреплённой
/// заявки. На не-Android платформах — тихий no-op.
class WidgetService {
  static const MethodChannel _ch = MethodChannel('quickpad/widget');

  Future<void> update({
    required String status,
    required String text,
    required String meta,
  }) async {
    try {
      await _ch.invokeMethod<void>('update', {
        'status': status,
        'text': text,
        'meta': meta,
      });
    } catch (_) {
      // Не Android / нет канала — игнорируем.
    }
  }
}
