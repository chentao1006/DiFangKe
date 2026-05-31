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
        
        val app = (application as DiFangKeApp)
        val prefs = app.preferences
        val db = app.database
        lifecycleScope.launch {
            com.ct106.difangke.data.db.DefaultDataSeeder.seedIfNeeded(db, prefs)
        }
        
        val deepLinkDate = intent.getLongExtra("date", -1L).let { if (it == -1L) null else it }
        
        setContent {
            DiFangKeTheme {
                NavGraph(initialDate = deepLinkDate)
            }
        }
    }
}
