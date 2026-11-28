package com.quickpad.quickpad

import android.app.Application
import android.content.Intent
import android.net.Uri
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.GeneratedPluginRegistrant

/**
 * Application: движок Flutter создаётся один раз и кэшируется — он продолжает
 * работать после закрытия окна (вместе с [SyncService] это даёт уведомления
 * при выгруженном из «недавних» приложении). Здесь же живут MethodChannel'ы:
 *  - quickpad/widget  — обновление виджета рабочего стола;
 *  - quickpad/bg      — включить/выключить фоновую связь;
 *  - quickpad/system  — исключение из оптимизации батареи.
 */
class App : Application() {

    companion object {
        const val engineId = "quickpad_engine"
    }

    override fun onCreate() {
        super.onCreate()

        // Движок сразу выполняет main(): приложение работает и без окна.
        val engine = FlutterEngine(this)
        GeneratedPluginRegistrant.registerWith(engine)
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        FlutterEngineCache.getInstance().put(engineId, engine)

        val messenger = engine.dartExecutor.binaryMessenger

        // Канал обновления виджета.
        MethodChannel(messenger, "quickpad/widget").setMethodCallHandler { call, result ->
            if (call.method == "update") {
                getSharedPreferences(QuickAddWidgetProvider.prefsName, MODE_PRIVATE)
                    .edit()
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

        // Фоновая связь (foreground service).
        MethodChannel(messenger, "quickpad/bg").setMethodCallHandler { call, result ->
            when (call.method) {
                "setEnabled" -> {
                    SyncService.setEnabled(this, call.argument<Boolean>("enabled") ?: true)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        // Системные настройки батареи.
        MethodChannel(messenger, "quickpad/system").setMethodCallHandler { call, result ->
            when (call.method) {
                "isIgnoringBatteryOptimizations" -> {
                    val pm = getSystemService(POWER_SERVICE) as PowerManager
                    result.success(pm.isIgnoringBatteryOptimizations(packageName))
                }
                "requestIgnoreBatteryOptimizations" -> {
                    try {
                        val intent = Intent(
                            Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                            Uri.parse("package:$packageName"),
                        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        startActivity(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                else -> result.notImplemented()
            }
        }

        // Запустить фоновую связь, если не выключена в настройках.
        SyncService.startIfEnabled(this)
    }
}
