package com.ct106.difangke

import android.app.Application
import android.app.NotificationChannel
import android.app.NotificationManager
import android.os.Build
import com.ct106.difangke.data.db.AppDatabase
import com.ct106.difangke.data.prefs.AppPreferences
import com.ct106.difangke.service.NotificationHelper

class DiFangKeApp : Application() {

    companion object {
        lateinit var instance: DiFangKeApp
            private set
    }

    // 延迟初始化数据库（避免在 Application.onCreate 卡主线程）
    val database: AppDatabase by lazy { AppDatabase.getInstance(this) }
    val preferences: AppPreferences by lazy { AppPreferences(this) }

    override fun onCreate() {
        super.onCreate()
        instance = this
        
        // 高德隐私合规初始化（完整 3D 版 SDK 必须在所有高德接口调用前执行）
        com.amap.api.maps.MapsInitializer.updatePrivacyShow(this, true, true)
        com.amap.api.maps.MapsInitializer.updatePrivacyAgree(this, true)
        com.amap.api.location.AMapLocationClient.updatePrivacyShow(this, true, true)
        com.amap.api.location.AMapLocationClient.updatePrivacyAgree(this, true)
        
        createNotificationChannels()
    }

    private fun createNotificationChannels() {
        val notificationManager = getSystemService(NotificationManager::class.java)

        // 位置追踪常驻通知频道
        notificationManager.createNotificationChannel(
            NotificationChannel(
                NotificationHelper.CHANNEL_TRACKING,
                "位置记录",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "地方客正在后台记录您的足迹"
                setShowBadge(false)
            }
        )

        // 每日足迹摘要推送频道
        notificationManager.createNotificationChannel(
            NotificationChannel(
                NotificationHelper.CHANNEL_DAILY_SUMMARY,
                "每日足迹摘要",
                NotificationManager.IMPORTANCE_DEFAULT
            ).apply {
                description = "每天晚上推送今日足迹回顾"
            }
        )

        // 精彩足迹高亮提醒频道
        notificationManager.createNotificationChannel(
            NotificationChannel(
                NotificationHelper.CHANNEL_HIGHLIGHT,
                "精彩足迹提醒",
                NotificationManager.IMPORTANCE_DEFAULT
            ).apply {
                description = "当发现高价值足迹时提醒您"
            }
        )
    }
}
