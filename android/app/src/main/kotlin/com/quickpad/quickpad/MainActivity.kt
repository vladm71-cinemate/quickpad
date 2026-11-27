package com.quickpad.quickpad

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Точка входа. Пробрасывает в Dart нажатие виджета «Быстрая заметка»
 * через MethodChannel quickpad/intents → openQuickAdd (ТЗ 4.13, 6.11).
 */
class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "quickpad/intents")
        // Холодный старт по нажатию виджета.
        if (intent?.getBooleanExtra("quick_add", false) == true) {
            channel?.invokeMethod("openQuickAdd", null)
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        // Повторное нажатие виджета, когда приложение уже открыто.
        if (intent.getBooleanExtra("quick_add", false)) {
            channel?.invokeMethod("openQuickAdd", null)
        }
    }
}
