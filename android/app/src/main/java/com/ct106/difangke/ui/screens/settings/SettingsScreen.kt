package com.ct106.difangke.ui.screens.settings

import android.app.TimePickerDialog
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.viewmodel.compose.viewModel

import com.ct106.difangke.ui.components.*

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(
    onBack: () -> Unit,
    onNavigate: (String) -> Unit,
    viewModel: SettingsViewModel = viewModel()
) {
    val context = LocalContext.current
    val isTrackingEnabled by viewModel.isTrackingEnabled.collectAsState()
    val isAiEnabled by viewModel.isAiEnabled.collectAsState()
    val isAutoPhotoLinkEnabled by viewModel.isAutoPhotoLinkEnabled.collectAsState()
    val isDailyNotificationEnabled by viewModel.isDailyNotificationEnabled.collectAsState()
    val notificationHour by viewModel.notificationHour.collectAsState()
    val notificationMinute by viewModel.notificationMinute.collectAsState()
    val isHighlightNotificationEnabled by viewModel.isHighlightNotificationEnabled.collectAsState()
    
    val importantPlacesCount by viewModel.importantPlacesCount.collectAsState()
    val savedPlacesCount by viewModel.savedPlacesCount.collectAsState()
    val ignoredPlacesCount by viewModel.ignoredPlacesCount.collectAsState()
    val activitiesCount by viewModel.activitiesCount.collectAsState()
    val aiServiceType by viewModel.aiServiceType.collectAsState()
    
    val updateInfo by viewModel.updateInfo.collectAsState()
    val isCheckingUpdate by viewModel.isCheckingUpdate.collectAsState()
    
    val packageInfo = remember {
        try {
            context.packageManager.getPackageInfo(context.packageName, 0)
        } catch (e: Exception) {
            null
        }
    }
    val versionName = packageInfo?.versionName ?: "1.0.0"
    val versionCode = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.P) {
        packageInfo?.longVersionCode ?: 0L
    } else {
        @Suppress("DEPRECATION")
        packageInfo?.versionCode?.toLong() ?: 0L
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("设置", fontWeight = FontWeight.Bold) },
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
            contentPadding = PaddingValues(vertical = 8.dp)
        ) {
            // ── 隐私与记录 ──────────────────────────────────────────
            item { SettingsHeader("隐私与记录") }
            item {
                SettingsToggleItem(
                    title = "开启定位记录",
                    subtitle = "应用将自动记录您的行踪并在时间轴展示",
                    checked = isTrackingEnabled,
                    onCheckedChange = { viewModel.setTrackingEnabled(it) }
                )
            }
            item {
                SettingsToggleItem(
                    title = "自动关联照片",
                    subtitle = "根据拍摄时间将系统相册照片关联至足迹",
                    checked = isAutoPhotoLinkEnabled,
                    onCheckedChange = { viewModel.setAutoPhotoLinkEnabled(it) }
                )
            }

            // ── 地点管理 ──────────────────────────────────────────────
            item { SettingsHeader("地点管理") }
            item {
                SettingsNavigationItem(
                    title = "重要地点",
                    icon = Icons.Default.Place,
                    iconColor = Color(0xFFFF9500),
                    badge = importantPlacesCount.toString(),
                    onClick = { onNavigate("settings/places") }
                )
            }
            item {
                SettingsNavigationItem(
                    title = "已保存地点",
                    icon = Icons.Default.History,
                    iconColor = Color(0xFF007AFF),
                    badge = savedPlacesCount.toString(),
                    onClick = { onNavigate("settings/saved_places") }
                )
            }
            item {
                SettingsNavigationItem(
                    title = "已忽略地点",
                    icon = Icons.Default.LocationOff,
                    iconColor = Color.Gray,
                    badge = ignoredPlacesCount.toString(),
                    onClick = { onNavigate("settings/ignored_places") }
                )
            }
            item {
                SettingsNavigationItem(
                    title = "活动类型",
                    icon = Icons.Default.Label,
                    iconColor = Color(0xFF34C759),
                    badge = activitiesCount.toString(),
                    onClick = { onNavigate("settings/activities") }
                )
            }

            // ── 推送通知 ──────────────────────────────────────────────
            item { SettingsHeader("推送通知") }
            item {
                SettingsToggleItem(
                    title = "每日足迹汇总",
                    subtitle = "每日晚间为您推送当天的生活总结",
                    checked = isDailyNotificationEnabled,
                    onCheckedChange = { viewModel.setDailyNotificationEnabled(it) }
                )
            }
            if (isDailyNotificationEnabled) {
                item {
                    SettingsNavigationItem(
                        title = "通知时间",
                        badge = String.format("%02d:%02d", notificationHour, notificationMinute),
                        onClick = {
                            TimePickerDialog(context, { _, hour, minute ->
                                viewModel.setNotificationTime(hour, minute)
                            }, notificationHour, notificationMinute, true).show()
                        }
                    )
                }
            }
            item {
                SettingsToggleItem(
                    title = "精彩足迹提醒",
                    subtitle = "发现值得纪念的瞬间时给予提醒",
                    checked = isHighlightNotificationEnabled,
                    onCheckedChange = { viewModel.setHighlightNotificationEnabled(it) }
                )
            }

            // ── 系统配置 ──────────────────────────────────────────────
            item { SettingsHeader("系统配置") }
            item {
                SettingsToggleItem(
                    title = "AI 智能辅助",
                    subtitle = "使用 AI 自动生成足迹标题与感悟",
                    checked = isAiEnabled,
                    onCheckedChange = { viewModel.setAiEnabled(it) }
                )
            }
            if (isAiEnabled) {
                item {
                    SettingsNavigationItem(
                        title = "AI 服务配置",
                        badge = if (aiServiceType == "custom") "自定义" else "公共服务",
                        onClick = { onNavigate("settings/ai") }
                    )
                }
            }
            item {
                SettingsNavigationItem(
                    title = "检查更新",
                    badge = if (isCheckingUpdate) "检查中..." else "",
                    onClick = { if (!isCheckingUpdate) viewModel.checkUpdate() }
                )
            }

            // ── 数据管理 ──────────────────────────────────────────────
            item { SettingsHeader("数据管理") }
            item {
                SettingsNavigationItem(
                    title = "数据备份与清理",
                    onClick = { onNavigate("settings/data") }
                )
            }

            item {
                Spacer(modifier = Modifier.height(32.dp))
                Column(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalAlignment = Alignment.CenterHorizontally
                ) {
                    Text(
                        text = "地方客 for Android",
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha=0.6f)
                    )
                    Text(
                        text = "Version $versionName (Build $versionCode)",
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha=0.4f)
                    )
                }
                Spacer(modifier = Modifier.height(32.dp))
            }
        }
    }

    // ── 更新提示对话框 ──────────────────────────────────────────────
    if (updateInfo != null) {
        val info = updateInfo!!
        val isNew = viewModel.isNewVersionAvailable(info.versionCode)
        
        AlertDialog(
            onDismissRequest = { viewModel.clearUpdateInfo() },
            title = { Text(if (isNew) "发现新版本 ${info.versionName}" else "当前已是最新版本") },
            text = {
                Column {
                    if (isNew) {
                        Text(info.releaseNotes)
                    } else {
                        Text("您的应用已是最新。")
                        Spacer(modifier = Modifier.height(8.dp))
                        Text(
                            text = "当前版本: $versionName (Build $versionCode)\n最新版本: ${info.versionName} (Build ${info.versionCode})",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }
            },
            confirmButton = {
                if (isNew) {
                    Button(
                        colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.primary),
                        onClick = {
                            viewModel.startUpdate(info.downloadUrl)
                            viewModel.clearUpdateInfo()
                        }
                    ) {
                        Text("立即更新")
                    }
                } else {
                    TextButton(onClick = { viewModel.clearUpdateInfo() }) {
                        Text("好的")
                    }
                }
            },
            dismissButton = {
                if (isNew) {
                    TextButton(onClick = { viewModel.clearUpdateInfo() }) {
                        Text("稍后再说")
                    }
                }
            }
        )
    }
}

