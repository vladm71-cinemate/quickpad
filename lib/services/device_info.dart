import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/ids.dart';

/// Идентификатор и имя устройства (ТЗ, раздел 3: привязка пользователя к устройству).
class DeviceIdentity {
  DeviceIdentity({required this.deviceId, required this.deviceName, required this.platform});

  final String deviceId;
  final String deviceName;
  final String platform;
}

Future<DeviceIdentity> loadDeviceIdentity(SharedPreferences prefs) async {
  String? deviceId = prefs.getString('deviceId');
  if (deviceId == null || deviceId.isEmpty) {
    deviceId = newDeviceId();
    await prefs.setString('deviceId', deviceId);
  }

  String platform = 'unknown';
  String deviceName = 'Устройство';
  try {
    if (Platform.isAndroid) {
      platform = 'android';
      final AndroidDeviceInfo info = await DeviceInfoPlugin().androidInfo;
      deviceName = info.model.isNotEmpty ? info.model : 'Android';
    } else if (Platform.isWindows) {
      platform = 'windows';
      final WindowsDeviceInfo info = await DeviceInfoPlugin().windowsInfo;
      deviceName = info.computerName.isNotEmpty ? info.computerName : 'Windows-ПК';
    } else if (Platform.isLinux) {
      platform = 'linux';
      deviceName = Platform.localHostname;
    } else if (Platform.isMacOS) {
      platform = 'macos';
      deviceName = Platform.localHostname;
    } else {
      deviceName = Platform.localHostname;
    }
  } catch (_) {
    try {
      deviceName = Platform.localHostname;
    } catch (_) {}
  }
  if (kIsWeb) {
    platform = 'web';
    deviceName = 'Браузер';
  }
  return DeviceIdentity(deviceId: deviceId, deviceName: deviceName, platform: platform);
}
