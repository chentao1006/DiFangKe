package com.ct106.difangke

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import com.ct106.difangke.ui.NavGraph
import com.ct106.difangke.ui.theme.DiFangKeTheme
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        // 安装 Splash Screen（系统级 Splash）
        installSplashScreen()
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        
        // 强制开启定位开启状态（全自动模式）
        val prefs = (application as DiFangKeApp).preferences
        lifecycleScope.launch {
            prefs.setTrackingEnabled(true)
        }
        
        setContent {
            DiFangKeTheme {
                NavGraph()
            }
        }
    }
}
