package com.quickpad.quickpad

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Точка входа. Пробрасывает в Dart нажатие виджета «Быстрая заметка»
 * через MethodChannel quickpad/intents → openQuickAdd (ТЗ 4.13, 6.11),
 * и принимает от Dart данные для виджета через quickpad/widget.
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

        // Канал обновления виджета: Dart → SharedPreferences → RemoteViews.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "quickpad/widget")
            .setMethodCallHandler { call, result ->
                if (call.method == "update") {
                    val prefs = getSharedPreferences(
                        QuickAddWidgetProvider.prefsName, MODE_PRIVATE
                    )
                    prefs.edit()
                        .putString("note_status", call.argument<String>("status") ?: "")
                        .putString("note_text", call.argument<String>("text") ?: "")
                        .putString("note_meta", call.argument<String>("meta") ?: "")
                        .apply()
                    QuickAddWidgetProvider.updateAll(this)
                    result.success(null)
                } else {
                    result.notImplemented()
                }
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
