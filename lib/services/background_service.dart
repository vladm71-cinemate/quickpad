import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Фоновая связь с хостом (foreground service) и системные настройки батареи.
/// На не-Android — тихий no-op.
class BackgroundService {
  static const MethodChannel _bg = MethodChannel('quickpad/bg');
  static const MethodChannel _sys = MethodChannel('quickpad/system');

  /// Включить/выключить удержание связи в фоне.
  Future<void> setEnabled(bool enabled) async {
    if (!Platform.isAndroid) return;
    try {
      await _bg.invokeMethod<void>('setEnabled', {'enabled': enabled});
    } catch (_) {}
  }

  /// true, если система уже не «душит» приложение оптимизацией батареи.
  Future<bool> isIgnoringBatteryOptimizations() async {
    if (!Platform.isAndroid) return true;
    try {
      return await _sys.invokeMethod<bool>('isIgnoringBatteryOptimizations') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Открыть системный диалог «Разрешить работу в фоне».
  Future<bool> requestIgnoreBatteryOptimizations() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _sys.invokeMethod<bool>('requestIgnoreBatteryOptimizations') ?? false;
    } catch (_) {
      return false;
    }
  }
}
