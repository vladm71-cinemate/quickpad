import 'dart:async';
import 'dart:io' show Platform, exit;

import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../state/settings_controller.dart';

/// Значок в системном трее Windows и автозапуск вместе с системой (ТЗ: хост
/// на ПК не должен «умирать» при закрытии окна — телефоны потеряют связь).
///
/// Поведение:
///  - закрытие окна крестиком — сворачивает в трей (если включено в настройках);
///  - клик по значку — открывает окно;
///  - правая кнопка — меню: «Открыть», «Выйти полностью»;
///  - автозапуск — запись в реестре Windows (HKCU\\...\\Run).
class TrayService with WindowListener, TrayListener {
  TrayService._();

  static final TrayService instance = TrayService._();

  SettingsController? _sc;
  bool _inited = false;

  bool get _trayEnabled => _sc?.settings.trayEnabled ?? true;

  /// Инициализация при старте приложения (только Windows).
  Future<void> init(SettingsController sc) async {
    if (_inited || !Platform.isWindows) return;
    _inited = true;
    _sc = sc;

    await windowManager.ensureInitialized();
    windowManager.addListener(this);
    // Перехватываем закрытие окна — решение принимает onWindowClose().
    await windowManager.setPreventClose(true);

    // Автозапуск: подтягиваем фактическое состояние (после переустановки
    // приложения запись в реестре могла исчезнуть или указывать не туда).
    launchAtStartup.setup(
      appName: 'QuickPad',
      appPath: Platform.resolvedExecutable,
    );
    try {
      final bool enabled = await launchAtStartup.isEnabled();
      final bool want = sc.settings.autoStartWindows;
      if (enabled != want) {
        if (want) {
          await launchAtStartup.enable();
        } else {
          await launchAtStartup.disable();
        }
      }
    } catch (_) {}

    await _setupTray();
  }

  Future<void> _setupTray() async {
    try {
      await trayManager.setIcon('assets/app_icon.ico');
      await trayManager.setToolTip('QuickPad — хост заявок');
      await trayManager.setContextMenu(Menu(items: [
        MenuItem(key: 'open', label: 'Открыть'),
        MenuItem.separator(),
        MenuItem(key: 'exit', label: 'Выйти полностью'),
      ]));
      trayManager.addListener(this);
    } catch (_) {}
  }

  /// Включить/выключить автозапуск вместе с Windows.
  Future<void> setAutoStart(bool v) async {
    if (!Platform.isWindows) return;
    try {
      if (v) {
        await launchAtStartup.enable();
      } else {
        await launchAtStartup.disable();
      }
    } catch (_) {}
  }

  // ---------- WindowListener ----------

  @override
  void onWindowClose() async {
    if (_trayEnabled) {
      // Сворачиваем в трей: хост продолжает принимать подключения.
      await windowManager.hide();
    } else {
      // Трей выключен — «закрыть» означает полный выход.
      await _quit();
    }
  }

  // ---------- TrayListener ----------

  @override
  void onTrayIconMouseDown() {
    windowManager.show();
    windowManager.focus();
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem item) async {
    switch (item.key) {
      case 'open':
        await windowManager.show();
        await windowManager.focus();
        break;
      case 'exit':
        await _quit();
        break;
    }
  }

  /// Полный выход: снимаем перехват закрытия, убираем значок трея,
  /// уничтожаем окно. Если процесс всё равно висит (открытые сокеты
  /// хоста, таймеры, нативные плагины) — через 900 мс завершаем его
  /// принудительно. Задержка даёт время сбросить отложенные записи
  /// настроек/базы (дебаунс 800 мс).
  Future<void> _quit() async {
    try {
      await windowManager.setPreventClose(false);
    } catch (_) {}
    try {
      await trayManager.destroy();
    } catch (_) {}
    try {
      await windowManager.destroy();
    } catch (_) {}
    Timer(const Duration(milliseconds: 900), () => exit(0));
  }
}
