package com.ct106.difangke.ui.screens.history

import androidx.compose.foundation.background
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.List
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.lifecycle.viewmodel.compose.viewModel
import com.ct106.difangke.viewmodel.MainViewModel
import com.ct106.difangke.ui.screens.main.TimelinePage
import java.text.SimpleDateFormat
import java.util.*

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DailyTimelineScreen(
    date: Date,
    onBack: () -> Unit,
    onNavigateToDetail: (String) -> Unit,
    onNavigateToMap: (Date) -> Unit,
    onNavigateToRawPoints: (Date) -> Unit,
    viewModel: MainViewModel = viewModel()
) {
    val trackingState by viewModel.trackingState.collectAsState()
    val activityTypes by viewModel.activityTypes.collectAsState()
    val allPlaces by viewModel.allPlaces.collectAsState()
    
    val isDark = isSystemInDarkTheme()
    val bgColor = if (isDark) Color.Black else Color(0xFFF2F2F7)
    
    val dateTitle = SimpleDateFormat("yyyy年M月d日", Locale.CHINA).format(date)
    var showRebuildConfirm by remember { mutableStateOf(false) }

    if (showRebuildConfirm) {
        AlertDialog(
            onDismissRequest = { showRebuildConfirm = false },
            title = { Text("重新生成数据") },
            text = { Text("确定要重新生成这一天的足迹和交通吗？这会覆盖已有的候选数据。") },
            confirmButton = {
                TextButton(onClick = {
                    viewModel.rebuildTimeline(date)
                    showRebuildConfirm = false
                }) { Text("确定", color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = {
                TextButton(onClick = { showRebuildConfirm = false }) { Text("取消") }
            }
        )
    }

    Scaffold(
        containerColor = Color.Transparent,
        topBar = {
            CenterAlignedTopAppBar(
                title = { Text(dateTitle, fontWeight = FontWeight.Bold) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "返回")
                    }
                },
                actions = {
                    var showMenu by remember { mutableStateOf(false) }
                    Box {
                        IconButton(onClick = { showMenu = true }) {
                            Icon(Icons.Default.MoreVert, contentDescription = "更多")
                        }
                        DropdownMenu(
                            expanded = showMenu,
                            onDismissRequest = { showMenu = false }
                        ) {
                            DropdownMenuItem(
                                text = { Text("查看所有轨迹点") },
                                onClick = {
                                    showMenu = false
                                    onNavigateToRawPoints(date)
                                },
                                leadingIcon = { Icon(Icons.AutoMirrored.Filled.List, null) }
                            )
                            DropdownMenuItem(
                                text = { Text("重新生成本日数据") },
                                onClick = {
                                    showMenu = false
                                    showRebuildConfirm = true
                                },
                                leadingIcon = { Icon(Icons.Default.Refresh, null) }
                            )
                        }
                    }
                },
                colors = TopAppBarDefaults.centerAlignedTopAppBarColors(
                    containerColor = Color.Transparent
                )
            )
        }
    ) { padding ->
        Box(modifier = Modifier
            .fillMaxSize()
            .background(
                Brush.verticalGradient(
                    colors = listOf(
                        bgColor,
                        com.ct106.difangke.ui.theme.DfkAccent.copy(alpha = 0.1f)
                    )
                )
            )
            .padding(padding)
        ) {
            TimelinePage(
                date = date,
                viewModel = viewModel,
                trackingState = trackingState,
                activityTypes = activityTypes,
                allPlaces = allPlaces,
                isFirstPage = false,
                isLastPage = false,
                hasLocationPermission = true,
                hasNotificationPermission = true,
                isNotificationGuideDismissed = true,
                onRequestPermission = { },
                onRequestNotification = { },
                onDismissNotificationGuide = { },
                onItemClick = onNavigateToDetail,
                onMapClick = { onNavigateToMap(date) },
                allowAutoRebuild = false
            )
        }
    }
}
