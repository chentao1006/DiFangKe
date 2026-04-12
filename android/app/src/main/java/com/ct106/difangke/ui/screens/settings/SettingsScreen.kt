package com.ct106.difangke.ui.screens.settings

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowBack
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(
    onBack: () -> Unit,
    viewModel: SettingsViewModel = viewModel()
) {
    val isTrackingEnabled by viewModel.isTrackingEnabled.collectAsState()
    val isAiEnabled by viewModel.isAiEnabled.collectAsState()

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
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding),
            contentPadding = PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            item {
                Text("记录设置", style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.primary)
                Spacer(modifier = Modifier.height(8.dp))
                ListItem(
                    headlineContent = { Text("后台位置记录") },
                    supportingContent = { Text("保持开启以自动记录您的足迹，关闭后将停止追踪。") },
                    trailingContent = {
                        Switch(
                            checked = isTrackingEnabled,
                            onCheckedChange = { viewModel.setTrackingEnabled(it) }
                        )
                    }
                )
            }

            item {
                Divider()
                Spacer(modifier = Modifier.height(16.dp))
                Text("AI 助手", style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.primary)
                Spacer(modifier = Modifier.height(8.dp))
                ListItem(
                    headlineContent = { Text("智能分析足迹") },
                    supportingContent = { Text("使用 OpenAI 为足迹生成精美标题和生活感悟。") },
                    trailingContent = {
                        Switch(
                            checked = isAiEnabled,
                            onCheckedChange = { viewModel.setAiEnabled(it) }
                        )
                    }
                )
            }
            
            // TODO: Add more settings like AI Config, Data Management, About, etc.
            // Matching iOS SettingsView functionality
            
            item {
                Spacer(modifier = Modifier.height(24.dp))
                Text("版本信息", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Text("地方客 for Android v1.0.0 Stable", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha=0.6f))
            }
        }
    }
}
