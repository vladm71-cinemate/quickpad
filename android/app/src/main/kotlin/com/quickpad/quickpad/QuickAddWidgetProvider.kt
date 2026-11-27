package com.quickpad.quickpad

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews

/**
 * Виджет рабочего стола: показывает закреплённую заявку (а если закреплённых
 * нет — последнюю по времени) и кнопку «+» для быстрого создания.
 * Размер меняется (горизонтально и вертикально).
 *
 * Тексты приходят из Flutter через MethodChannel quickpad/widget и лежат в
 * SharedPreferences(prefsName): note_status, note_text, note_meta.
 */
class QuickAddWidgetProvider : AppWidgetProvider() {

    override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray) {
        for (appWidgetId in appWidgetIds) {
            updateOne(context, appWidgetManager, appWidgetId)
        }
    }

    companion object {
        const val prefsName = "quickpad_widget"

        /** Обновить все экземпляры виджета из сохранённых настроек. */
        fun updateAll(context: Context) {
            val mgr = AppWidgetManager.getInstance(context)
            val ids = mgr.getAppWidgetIds(ComponentName(context, QuickAddWidgetProvider::class.java))
            for (id in ids) updateOne(context, mgr, id)
        }

        private fun updateOne(context: Context, mgr: AppWidgetManager, id: Int) {
            val prefs = context.getSharedPreferences(prefsName, Context.MODE_PRIVATE)
            val status = prefs.getString("note_status", "") ?: ""
            val text = prefs.getString("note_text", null)
                ?: context.getString(R.string.widget_empty)
            val meta = prefs.getString("note_meta", "") ?: ""

            val views = RemoteViews(context.packageName, R.layout.widget_quick_add)
            views.setTextViewText(R.id.widget_note_status, status)
            views.setTextViewText(R.id.widget_note_text, text)
            views.setTextViewText(R.id.widget_note_meta, meta)

            // Кнопка «+» — сразу создание заявки.
            val addIntent = Intent(context, MainActivity::class.java)
                .putExtra("quick_add", true)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            val addPending = PendingIntent.getActivity(
                context, 1, addIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            views.setOnClickPendingIntent(R.id.widget_add_button, addPending)

            // Нажатие на тело виджета — просто открыть приложение.
            val openIntent = Intent(context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            val openPending = PendingIntent.getActivity(
                context, 2, openIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            views.setOnClickPendingIntent(R.id.widget_note_text, openPending)
            views.setOnClickPendingIntent(R.id.widget_note_status, openPending)
            views.setOnClickPendingIntent(R.id.widget_note_meta, openPending)
            views.setOnClickPendingIntent(R.id.widget_title, openPending)

            mgr.updateAppWidget(id, views)
        }
    }
}
