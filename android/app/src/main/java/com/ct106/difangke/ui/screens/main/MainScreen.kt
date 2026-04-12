package com.ct106.difangke.ui.screens.main

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.lifecycle.viewmodel.compose.viewModel
import com.ct106.difangke.data.model.TimelineItem
import com.ct106.difangke.service.LocationTrackingService
import com.ct106.difangke.ui.components.FootprintCardView
import com.ct106.difangke.ui.components.TransportCardView
import com.ct106.difangke.ui.components.AISummaryCard
import com.ct106.difangke.ui.components.RecordingStatusCard
import com.ct106.difangke.ui.components.DaySummaryCard
import com.ct106.difangke.viewmodel.MainViewModel
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.*

@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
fun MainScreen(
    viewModel: MainViewModel = viewModel(),
    onNavigateToHistory: () -> Unit,
    onNavigateToSettings: () -> Unit,
    onNavigateToMap: () -> Unit,
    onNavigateToDetail: (String) -> Unit
) {
    val items by viewModel.timelineItems.collectAsState()
    val dailyInsight by viewModel.dailyInsight.collectAsState()
    val trackingState by viewModel.trackingState.collectAsState()
    val scope = rememberCoroutineScope()
    val context = LocalContext.current

    // --- 权限请求逻辑 ---
    var hasLocationPermission by remember {
        mutableStateOf(
            ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
        )
    }

    val permissionLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.RequestMultiplePermissions()
    ) { permissions ->
        hasLocationPermission = permissions[Manifest.permission.ACCESS_FINE_LOCATION] == true || permissions[Manifest.permission.ACCESS_COARSE_LOCATION] == true
        if (hasLocationPermission) {
            viewModel.toggleTracking()
        }
    }

    val handleToggleTracking = {
        if (!hasLocationPermission) {
            val permissionsToRequest = mutableListOf(
                Manifest.permission.ACCESS_FINE_LOCATION,
                Manifest.permission.ACCESS_COARSE_LOCATION
            )
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                permissionsToRequest.add(Manifest.permission.POST_NOTIFICATIONS)
            }
            permissionLauncher.launch(permissionsToRequest.toTypedArray())
        } else {
            viewModel.toggleTracking()
        }
    }

    LaunchedEffect(Unit) {
        if (!hasLocationPermission) {
            val permissionsToRequest = mutableListOf(
                Manifest.permission.ACCESS_FINE_LOCATION,
                Manifest.permission.ACCESS_COARSE_LOCATION
            )
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                permissionsToRequest.add(Manifest.permission.POST_NOTIFICATIONS)
            }
            permissionLauncher.launch(permissionsToRequest.toTypedArray())
        }
    }
    
    // 模拟的水平日期数据 (从今天倒推7天)
    val dates = remember {
        val cal = Calendar.getInstance()
        (0..7).map {
            val d = cal.time
            cal.add(Calendar.DAY_OF_YEAR, -1)
            d
        }.reversed()
    }
    
    val pagerState = rememberPagerState(initialPage = dates.size - 1, pageCount = { dates.size })
    
    val todayDate = dates[pagerState.currentPage]
    val titleFormat = SimpleDateFormat("M月d日 EEEE", Locale.CHINA)
    
    Scaffold(
        topBar = {
            TopAppBar(
                title = { 
                    Text("地方客", fontWeight = FontWeight.Bold)
                },
                actions = {
                    IconButton(onClick = onNavigateToHistory) {
                        Icon(Icons.Default.History, contentDescription = "历史")
                    }
                    IconButton(onClick = onNavigateToSettings) {
                        Icon(Icons.Default.Settings, contentDescription = "设置")
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = Color.Transparent,
                    scrolledContainerColor = Color.Transparent
                )
            )
        }
    ) { padding ->
        Box(modifier = Modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
        ) {
            Column(modifier = Modifier.padding(padding)) {
                
                // --- 日期切换卡片 (对齐 iOS 风格) ---
                Card(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp, vertical = 12.dp),
                    shape = RoundedCornerShape(16.dp),
                    colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
                    elevation = CardDefaults.cardElevation(defaultElevation = 2.dp)
                ) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(vertical = 4.dp),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        IconButton(onClick = {
                            if (pagerState.currentPage > 0) {
                                scope.launch { pagerState.animateScrollToPage(pagerState.currentPage - 1) }
                            }
                        }) {
                            Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "前一天", modifier = Modifier.size(20.dp))
                        }
                        
                        Column(horizontalAlignment = Alignment.CenterHorizontally) {
                            val isToday = pagerState.currentPage == dates.size - 1
                            Text(
                                text = if (isToday) "今天" else "过去记录", 
                                fontWeight = FontWeight.Bold, 
                                style = MaterialTheme.typography.titleMedium, 
                                color = MaterialTheme.colorScheme.onSurface
                            )
                            Text(
                                text = titleFormat.format(dates[pagerState.currentPage]), 
                                style = MaterialTheme.typography.bodySmall, 
                                color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f)
                            )
                        }
                        
                        IconButton(onClick = {
                            if (pagerState.currentPage < dates.size - 1) {
                                scope.launch { pagerState.animateScrollToPage(pagerState.currentPage + 1) }
                            }
                        }) {
                            Icon(Icons.AutoMirrored.Filled.ArrowForward, contentDescription = "后一天", modifier = Modifier.size(20.dp))
                        }
                    }
                }
                
                // --- iOS 风格的滑动时间轴页面 ---
                HorizontalPager(
                    state = pagerState,
                    modifier = Modifier.fillMaxSize()
                ) { page ->
                    LazyColumn(
                        modifier = Modifier.fillMaxSize(),
                        contentPadding = PaddingValues(top = 16.dp, bottom = 100.dp)
                    ) {
                        // 顶部摘要卡片
                        item {
                            val isToday = pagerState.currentPage == dates.size - 1
                            if (isToday) {
                                RecordingStatusCard(
                                    trackingState = trackingState,
                                    isTracking = trackingState !is LocationTrackingService.TrackingState.Idle,
                                    footprintCount = items.size,
                                    onNavigateToMap = onNavigateToMap,
                                    hasLocationPermission = hasLocationPermission,
                                    onRequestPermission = {
                                        val permissionsToRequest = mutableListOf(
                                            Manifest.permission.ACCESS_FINE_LOCATION,
                                            Manifest.permission.ACCESS_COARSE_LOCATION
                                        )
                                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                                            permissionsToRequest.add(Manifest.permission.POST_NOTIFICATIONS)
                                        }
                                        permissionLauncher.launch(permissionsToRequest.toTypedArray())
                                    }
                                )
                            } else {
                                DaySummaryCard(
                                    footprintCount = items.size,
                                    onNavigateToMap = onNavigateToMap
                                )
                            }
                        }

                        // AI 总结卡片
                        dailyInsight?.let { insight ->
                            if (!insight.content.isNullOrEmpty()) {
                                item {
                                    AISummaryCard(content = insight.content!!)
                                }
                            }
                        }
                        
                        // 瀑布流元素
                        itemsIndexed(items) { index, item ->
                            when (item) {
                                is TimelineItem.FootprintItem -> {
                                    FootprintCardView(
                                        footprint = item.footprint,
                                        isFirst = index == 0,
                                        isLast = index == items.size - 1,
                                        onClick = { onNavigateToDetail(item.footprint.footprintID) }
                                    )
                                }
                                is TimelineItem.TransportItem -> {
                                    TransportCardView(
                                        transport = item.transport,
                                        isFirst = index == 0,
                                        isLast = index == items.size - 1
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
