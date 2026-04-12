package com.ct106.difangke.service

import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import androidx.core.app.NotificationCompat
import com.ct106.difangke.MainActivity
import com.ct106.difangke.R

object NotificationHelper {

    const val CHANNEL_TRACKING = "channel_tracking"
    const val CHANNEL_DAILY_SUMMARY = "channel_daily_summary"
    const val CHANNEL_HIGHLIGHT = "channel_highlight"

    const val TRACKING_NOTIFICATION_ID = 1001
    const val DAILY_SUMMARY_NOTIFICATION_ID = 1002
    private const val HIGHLIGHT_NOTIFICATION_ID_BASE = 2000

    fun buildTrackingNotification(context: Context, status: String = "正在记录位置"): Notification {
        val intent = Intent(context, MainActivity::class.java)
        val pi = PendingIntent.getActivity(
            context, 0, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        return NotificationCompat.Builder(context, CHANNEL_TRACKING)
            .setSmallIcon(android.R.drawable.ic_menu_mylocation)
            .setContentTitle("地方客")
            .setContentText(status)
            .setOngoing(true)
            .setContentIntent(pi)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
    }

    fun updateTrackingNotification(context: Context, status: String) {
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(TRACKING_NOTIFICATION_ID, buildTrackingNotification(context, status))
    }

    fun sendDailySummary(context: Context, title: String, body: String) {
        val intent = Intent(context, MainActivity::class.java)
        val pi = PendingIntent.getActivity(
            context, 0, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val notification = NotificationCompat.Builder(context, CHANNEL_DAILY_SUMMARY)
            .setSmallIcon(android.R.drawable.ic_menu_mapmode)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setAutoCancel(true)
            .setContentIntent(pi)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .build()

        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(DAILY_SUMMARY_NOTIFICATION_ID, notification)
    }

    fun sendHighlightNotification(context: Context, title: String, body: String, notifId: Int) {
        val intent = Intent(context, MainActivity::class.java)
        val pi = PendingIntent.getActivity(
            context, notifId, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val notification = NotificationCompat.Builder(context, CHANNEL_HIGHLIGHT)
            .setSmallIcon(android.R.drawable.ic_menu_gallery)
            .setContentTitle("✨ $title")
            .setContentText(body)
            .setAutoCancel(true)
            .setContentIntent(pi)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .build()

        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(HIGHLIGHT_NOTIFICATION_ID_BASE + notifId, notification)
    }
}
