package com.quickpad.quickpad

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder

/**
 * Фоновая служба «держим связь с хостом» (Вариант 1).
 *
 * Пока служба жива, Android не выгружает процесс приложения — WebSocket
 * продолжает слушать хост и уведомления приходят даже когда окно закрыто
 * (смахнуто из «недавних»). Показывает тихое постоянное уведомление —
 * это требование Android к foreground-сервисам.
 */
class SyncService : Service() {

    companion object {
        const val channelId = "qp_bg"
        const val notificationId = 47650
        const val prefsName = "quickpad_bg"
        const val prefEnabled = "enabled"

        fun isEnabled(context: Context): Boolean =
            context.getSharedPreferences(prefsName, Context.MODE_PRIVATE)
                .getBoolean(prefEnabled, true) // по умолчанию включено

        fun setEnabled(context: Context, enabled: Boolean) {
            context.getSharedPreferences(prefsName, Context.MODE_PRIVATE)
                .edit().putBoolean(prefEnabled, enabled).apply()
            val intent = Intent(context, SyncService::class.java)
            if (enabled) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } else {
                context.stopService(intent)
            }
        }

        fun startIfEnabled(context: Context) {
            if (isEnabled(context)) setEnabled(context, true)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForeground(notificationId, buildNotification())
        return START_STICKY
    }

    private fun buildNotification(): Notification {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val mgr = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            mgr.createNotificationChannel(
                NotificationChannel(
                    channelId,
                    "Связь с хостом",
                    NotificationManager.IMPORTANCE_MIN, // тихо, без звука и значка в статус-баре
                ).apply { description = "Держит подключение, чтобы приходили уведомления" }
            )
        }
        val openIntent = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) Notification.Builder(this, channelId)
            else Notification.Builder(this)
        return builder
            .setContentTitle("Блокнот заявок")
            .setContentText("Связь с хостом активна — уведомления приходят")
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentIntent(openIntent)
            .setOngoing(true)
            .build()
    }
}
