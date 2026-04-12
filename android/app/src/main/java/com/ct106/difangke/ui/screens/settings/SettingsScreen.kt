package com.ct106.difangke.ui.screens.settings

import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowBack
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.ct106.difangke.data.prefs.AppPreferences
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(onBack: () -> Unit) {
    val context = LocalContext.current
    val prefs = remember { AppPreferences(context) }
    val scope = rememberCoroutineScope()
    
    val isTrackingEnabled by prefs.isTrackingEnabled.collectAsState(initial = false)
    val isAiEnabled by prefs.isAiEnabled.collectAsState(initial = true)

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("设置") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.Default.ArrowBack, contentDescription = "返回")
                    }
                }
            )
        }
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .padding(16.dp)
        ) {
            Text("核心功能", style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.primary)
            Spacer(modifier = Modifier.height(8.dp))
            ListItem(
                headlineContent = { Text("后台位置记录") },
                supportingContent = { Text("保持开启以自动记录足迹") },
                trailingContent = {
                    Switch(
                        checked = isTrackingEnabled,
                        onCheckedChange = { 
                            scope.launch { prefs.setTrackingEnabled(it) }
                            // TODO: 同步启停 Service
                        }
                    )
                }
            )
            
            Spacer(modifier = Modifier.height(24.dp))
            
            Text("AI 助手", style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.primary)
            Spacer(modifier = Modifier.height(8.dp))
            ListItem(
                headlineContent = { Text("智能分析足迹") },
                supportingContent = { Text("使用 AI 为您的足迹生成标题和感悟") },
                trailingContent = {
                    Switch(
                        checked = isAiEnabled,
                        onCheckedChange = { 
                            scope.launch { prefs.setAiEnabled(it) }
                        }
                    )
                }
            )
        }
    }
}
