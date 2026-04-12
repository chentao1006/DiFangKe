package com.ct106.difangke.service

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.ct106.difangke.data.prefs.AppPreferences
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

/** 开机自启动 Receiver，恢复位置追踪服务 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED ||
            intent.action == Intent.ACTION_MY_PACKAGE_REPLACED) {
            CoroutineScope(Dispatchers.IO).launch {
                val prefs = AppPreferences(context)
                val isTracking = prefs.isTrackingEnabled.first()
                if (isTracking) {
                    LocationTrackingService.start(context)
                }
            }
        }
    }
}
