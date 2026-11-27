import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'state/app_state.dart';
import 'state/settings_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  final SettingsController settingsCtl = SettingsController(prefs);
  final AppState appState = AppState(prefs: prefs, settingsCtl: settingsCtl);
  await appState.init();

  // Быстрый запуск создания заметки из виджета Android (ТЗ 4.13, 6.11).
  const MethodChannel intents = MethodChannel('quickpad/intents');
  intents.setMethodCallHandler((MethodCall call) async {
    if (call.method == 'openQuickAdd' && appState.ls.widgetEnabled) {
      QuickPadApp.navKey.currentState?.pushNamed('/edit');
    }
  });

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<SettingsController>.value(value: settingsCtl),
        ChangeNotifierProvider<AppState>.value(value: appState),
      ],
      child: const QuickPadApp(),
    ),
  );
}
