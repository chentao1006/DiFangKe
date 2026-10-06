package com.ct106.difangke.service

import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import com.ct106.difangke.MainActivity

object NotificationHelper {

    const val CHANNEL_TRACKING = "channel_tracking"
    const val CHANNEL_DAILY_SUMMARY = "channel_daily_summary"
    const val CHANNEL_PAST_MEMORIES = "channel_highlight"
    const val CHANNEL_NEW_PLACE = "channel_new_place_footprint"
    /** Removed with future trips (iOS dropped them); deleted on startup. */
    private const val LEGACY_CHANNEL_FUTURE_TRIP = "channel_future_trip"

    const val TRACKING_NOTIFICATION_ID = 1001
    const val DAILY_SUMMARY_NOTIFICATION_ID = 1002
    private const val PAST_MEMORIES_NOTIFICATION_ID_BASE = 2000
    private const val NEW_PLACE_NOTIFICATION_ID_BASE = 3000

    /** Intent extra telling MainActivity which in-app action a notification asked for. */
    const val EXTRA_NOTIFICATION_ACTION = "notificationAction"
    /** Open the footprint detail and present the activity-type picker (iOS "dfk.chooseActivity"). */
    const val ACTION_CHOOSE_ACTIVITY = "chooseActivity"

    /**
     * Live Activity analog shown in the tracking foreground notification.
     */
    data class LiveStatus(
        val isMoving: Boolean,
        /** Start of the current stay or trip; drives the chronometer. */
        val sinceMs: Long?,
        val placeName: String? = null,
        val transportTypeName: String? = null,
        val todayPlaceCount: Int = 0,
        val todayMileageMeters: Double = 0.0,
        val isLowPower: Boolean = false
    )

    /** Deletes channels for removed features. Safe to call repeatedly. */
    fun cleanupLegacyChannels(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        runCatching { nm.deleteNotificationChannel(LEGACY_CHANNEL_FUTURE_TRIP) }
    }

    private fun mainActivityIntent(context: Context, requestCode: Int = 0, extras: Intent.() -> Unit = {}): PendingIntent {
        val intent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            extras()
        }
        return PendingIntent.getActivity(
            context, requestCode, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }

    fun buildTrackingNotification(context: Context, status: String = "正在记录位置"): Notification =
        NotificationCompat.Builder(context, CHANNEL_TRACKING)
            .setSmallIcon(android.R.drawable.ic_menu_mylocation)
            .setContentTitle("地方客")
            .setContentText(status)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(mainActivityIntent(context))
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .build()

    fun formatMileage(meters: Double): String =
        if (meters < 1000) "${meters.toInt()}m" else String.format(java.util.Locale.US, "%.1fkm", meters / 1000.0)

    /**
     * Rich ongoing notification: title is the current place (or the moving /
     * transport state), the chronometer counts from the stay/trip start, and
     * the text summarises today. While moving it offers "我已到达".
     */
    fun buildLiveTrackingNotification(
        context: Context,
        status: LiveStatus,
        arrivalAction: PendingIntent?
    ): Notification {
        val title = if (status.isMoving) {
            status.transportTypeName?.takeIf { it.isNotBlank() }?.let { "交通中 · $it" } ?: "正在移动"
        } else {
            status.placeName?.takeIf { it.isNotBlank() } ?: "正在停留"
        }
        val text = "今日停留 ${status.todayPlaceCount} 个地点 · 里程 ${formatMileage(status.todayMileageMeters)}"
        val builder = NotificationCompat.Builder(context, CHANNEL_TRACKING)
            .setSmallIcon(
                if (status.isMoving) android.R.drawable.ic_menu_directions
                else android.R.drawable.ic_menu_mylocation
            )
            .setContentTitle(title)
            .setContentText(text)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .setContentIntent(mainActivityIntent(context))
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
        val since = status.sinceMs
        if (since != null && since > 0) {
            builder.setWhen(since).setShowWhen(true).setUsesChronometer(true)
        } else {
            builder.setShowWhen(false)
        }
        if (status.isMoving && arrivalAction != null) {
            builder.addAction(android.R.drawable.ic_menu_mylocation, "我已到达", arrivalAction)
        }
        return builder.build()
    }

    fun updateTrackingNotification(context: Context, status: String) {
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(TRACKING_NOTIFICATION_ID, buildTrackingNotification(context, status))
    }

    fun postTrackingNotification(context: Context, notification: Notification) {
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        runCatching { nm.notify(TRACKING_NOTIFICATION_ID, notification) }
    }

    fun sendDailySummary(context: Context, title: String, body: String) {
        val notification = NotificationCompat.Builder(context, CHANNEL_DAILY_SUMMARY)
            .setSmallIcon(android.R.drawable.ic_menu_mapmode)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setAutoCancel(true)
            .setContentIntent(mainActivityIntent(context))
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .build()

        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(DAILY_SUMMARY_NOTIFICATION_ID, notification)
    }

    fun sendPastMemoriesNotification(context: Context, title: String, body: String, notifId: Int, timestamp: Long? = null) {
        val pi = mainActivityIntent(context, notifId) {
            if (timestamp != null) putExtra("date", timestamp)
        }
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

    /**
     * iOS `sendNewFootprintActivityNotification`: tapping opens the footprint;
     * the "选择活动类型" action opens it with the activity picker requested.
     */
    fun sendNewPlaceNotification(context: Context, placeName: String, footprintId: String, startTimeMs: Long? = null) {
        val requestCode = footprintId.hashCode()
        val open = mainActivityIntent(context, requestCode) {
            putExtra("footprintID", footprintId)
            if (startTimeMs != null) putExtra("date", startTimeMs)
        }
        val choose = mainActivityIntent(context, requestCode xor 0x5A5A) {
            putExtra("footprintID", footprintId)
            putExtra(EXTRA_NOTIFICATION_ACTION, ACTION_CHOOSE_ACTIVITY)
            if (startTimeMs != null) putExtra("date", startTimeMs)
        }
        val body = "你第一次在「$placeName」留下足迹。 点此选择这次的活动类型。"
        val notification = NotificationCompat.Builder(context, CHANNEL_NEW_PLACE)
            .setSmallIcon(android.R.drawable.ic_menu_mylocation)
            .setContentTitle("新地点足迹")
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setAutoCancel(true)
            .setContentIntent(open)
            .addAction(android.R.drawable.ic_menu_edit, "选择活动类型", choose)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .build()

        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(NEW_PLACE_NOTIFICATION_ID_BASE + kotlin.math.abs(requestCode % 1000), notification)
    }
}
