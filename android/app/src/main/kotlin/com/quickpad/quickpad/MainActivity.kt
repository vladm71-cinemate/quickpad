package com.quickpad.quickpad

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel

/**
 * Точка входа. Использует кэшированный движок из [App] — он не умирает
 * при закрытии окна, поэтому уведомления продолжают приходить.
 * Пробрасывает в Dart нажатие виджета «+» через quickpad/intents → openQuickAdd.
 */
class MainActivity : FlutterActivity() {

    override fun getCachedEngineId(): String = App.engineId

    private fun channel(): MethodChannel? {
        val engine = FlutterEngineCache.getInstance().get(App.engineId) ?: return null
        return MethodChannel(engine.dartExecutor.binaryMessenger, "quickpad/intents")
    }

    override fun onResume() {
        super.onResume()
        // Холодный старт по нажатию виджета.
        if (intent?.getBooleanExtra("quick_add", false) == true) {
            channel()?.invokeMethod("openQuickAdd", null)
            intent?.removeExtra("quick_add")
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        // Повторное нажатие виджета, когда приложение уже открыто.
        if (intent.getBooleanExtra("quick_add", false)) {
            channel()?.invokeMethod("openQuickAdd", null)
            intent.removeExtra("quick_add")
        }
    }
}
