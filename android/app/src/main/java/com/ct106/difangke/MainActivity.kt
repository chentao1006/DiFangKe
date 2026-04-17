package com.ct106.difangke

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import com.ct106.difangke.ui.NavGraph
import com.ct106.difangke.ui.theme.DiFangKeTheme
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.PowerManager
import android.provider.Settings
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        // 安装 Splash Screen（系统级 Splash）
        installSplashScreen()
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        
        // 强制开启定位开启状态（全自动模式）
        val app = (application as DiFangKeApp)
        val prefs = app.preferences
        val db = app.database
        lifecycleScope.launch {
            prefs.setTrackingEnabled(true)
            com.ct106.difangke.data.db.DefaultDataSeeder.seedIfNeeded(db, prefs)
            
            // 检查电池优化
            requestIgnoreBatteryOptimizations()
        }
        
        setContent {
            DiFangKeTheme {
                NavGraph()
            }
        }
    }

    private fun requestIgnoreBatteryOptimizations() {
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        if (!pm.isIgnoringBatteryOptimizations(packageName)) {
            try {
                val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                    data = Uri.parse("package:$packageName")
                }
                startActivity(intent)
            } catch (e: Exception) {
                // 部分机型可能不支持该直接意图，跳转至设置页面
                try {
                    val intent = Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
                    startActivity(intent)
                } catch (e2: Exception) {}
            }
        }
    }
}
