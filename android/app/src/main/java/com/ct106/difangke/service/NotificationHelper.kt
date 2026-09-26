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
    const val CHANNEL_PAST_MEMORIES = "channel_highlight"
    const val CHANNEL_NEW_PLACE = "channel_new_place_footprint"
    const val CHANNEL_FUTURE_TRIP = "channel_future_trip"

    const val TRACKING_NOTIFICATION_ID = 1001
    const val DAILY_SUMMARY_NOTIFICATION_ID = 1002
    private const val PAST_MEMORIES_NOTIFICATION_ID_BASE = 2000
    private const val NEW_PLACE_NOTIFICATION_ID_BASE = 3000
    private const val FUTURE_TRIP_NOTIFICATION_ID_BASE = 4000

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

    fun sendPastMemoriesNotification(context: Context, title: String, body: String, notifId: Int, timestamp: Long? = null) {
        val intent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            if (timestamp != null) putExtra("date", timestamp)
        }
        val pi = PendingIntent.getActivity(
            context, notifId, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val notification = NotificationCompat.Builder(context, CHANNEL_PAST_MEMORIES)
            .setSmallIcon(android.R.drawable.ic_menu_gallery)
            .setContentTitle("✨ $title")
            .setContentText(body)
            .setAutoCancel(true)
            .setContentIntent(pi)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .build()

        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(PAST_MEMORIES_NOTIFICATION_ID_BASE + notifId, notification)
    }

    fun sendNewPlaceNotification(context: Context, placeName: String, footprintId: String) {
        val requestCode = footprintId.hashCode()
        val intent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra("footprintID", footprintId)
        }
        val pi = PendingIntent.getActivity(
            context, requestCode, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val body = "你第一次在「$placeName」留下足迹。点此选择这次的活动类型。"
        val notification = NotificationCompat.Builder(context, CHANNEL_NEW_PLACE)
            .setSmallIcon(android.R.drawable.ic_menu_mylocation)
            .setContentTitle("新地点足迹")
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setAutoCancel(true)
            .setContentIntent(pi)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .build()

        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(NEW_PLACE_NOTIFICATION_ID_BASE + kotlin.math.abs(requestCode % 1000), notification)
    }

    fun sendFutureTripReminder(context: Context, tripID: String, title: String, body: String) {
        val requestCode = tripID.hashCode()
        val intent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra("futureTripID", tripID)
        }
        val pi = PendingIntent.getActivity(
            context, requestCode, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val notification = NotificationCompat.Builder(context, CHANNEL_FUTURE_TRIP)
            .setSmallIcon(android.R.drawable.ic_menu_mylocation)
            .setContentTitle(title)
            .setContentText(body)
            .setAutoCancel(true)
            .setContentIntent(pi)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .build()

        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(FUTURE_TRIP_NOTIFICATION_ID_BASE + kotlin.math.abs(requestCode % 1000), notification)
    }
}
