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
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.itemsIndexed
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material.icons.automirrored.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.vectorResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.lifecycle.viewmodel.compose.viewModel
import com.ct106.difangke.data.model.TimelineItem
import com.ct106.difangke.service.LocationTrackingService
import com.ct106.difangke.ui.components.*
import com.ct106.difangke.viewmodel.MainViewModel
import com.ct106.difangke.service.OpenAIService
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.*
import androidx.compose.animation.*
import androidx.compose.animation.core.*

@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
fun MainScreen(
    viewModel: MainViewModel = androidx.lifecycle.viewmodel.compose.viewModel(),
    onNavigateToHistory: () -> Unit,
    onNavigateToStatistics: () -> Unit,
    onNavigateToSettings: () -> Unit,
    onNavigateToMap: (Date?) -> Unit,
    onNavigateToDetail: (String) -> Unit
) {
    val items by viewModel.timelineItems.collectAsState()
    val dailyInsight by viewModel.dailyInsight.collectAsState()
    val totalMileage by viewModel.totalMileage.collectAsState()
    val totalPoints by viewModel.totalPoints.collectAsState()
    val trackingState by viewModel.trackingState.collectAsState()
    val availableDates by viewModel.availableDates.collectAsState()
    val currentDate by viewModel.currentDate.collectAsState()
    
    val scope = rememberCoroutineScope()
    val context = LocalContext.current

    val pagerState = rememberPagerState(
        initialPage = availableDates.indexOfFirst { it.time == currentDate.time }.coerceAtLeast(0), 
        pageCount = { availableDates.size }
    )
    
    // 同步 Pager 到当前日期
    LaunchedEffect(currentDate, availableDates) {
        val index = availableDates.indexOfFirst { it.time == currentDate.time }
        if (index >= 0 && index != pagerState.currentPage) {
            pagerState.animateScrollToPage(index)
        }
    }
    
    // 同步当前日期到 Pager
    LaunchedEffect(pagerState.currentPage, availableDates) {
        if (availableDates.isNotEmpty()) {
            val dateAtPage = availableDates[pagerState.currentPage]
            if (dateAtPage.time != currentDate.time) {
                viewModel.setDate(dateAtPage)
            }
        }
    }
    
    val today = Calendar.getInstance().apply {
        set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
    }.time
    val yesterday = Calendar.getInstance().apply { time = today; add(Calendar.DAY_OF_YEAR, -1) }.time
    val tomorrow = Calendar.getInstance().apply { time = today; add(Calendar.DAY_OF_YEAR, 1) }.time
    val dayBeforeYesterday = Calendar.getInstance().apply { time = today; add(Calendar.DAY_OF_YEAR, -2) }.time

    val primaryFormat = SimpleDateFormat("M月d日", Locale.CHINA)
    val secondaryFormat = SimpleDateFormat("M月d日 EEEE", Locale.CHINA)
    val weekdayFormat = SimpleDateFormat("EEEE", Locale.CHINA)

    val dateHeader = remember(currentDate) {
        when {
            currentDate.time == today.time -> "今天"
            currentDate.time == yesterday.time -> "昨天"
            currentDate.time == tomorrow.time -> "明天"
            currentDate.time == dayBeforeYesterday.time -> "前天"
            else -> primaryFormat.format(currentDate)
        }
    }

    val secondaryHeaderLabel = remember(currentDate) {
        val isRelative = currentDate.time == today.time || currentDate.time == yesterday.time || 
                        currentDate.time == tomorrow.time || currentDate.time == dayBeforeYesterday.time
        if (isRelative) secondaryFormat.format(currentDate) else weekdayFormat.format(currentDate)
    }

    val isFarFromToday = remember(currentDate) {
        val diff = (today.time - currentDate.time) / (1000 * 60 * 60 * 24)
        diff >= 5
    }

    // 日历弹窗逻辑
    var showMiniCalendar by remember { mutableStateOf(false) }
    var showNativeDatePicker by remember { mutableStateOf(false) }

    if (showNativeDatePicker) {
        val datePickerState = rememberDatePickerState(
            initialSelectedDateMillis = currentDate.time,
            selectableDates = object : SelectableDates {
                override fun isSelectableDate(utcTimeMillis: Long): Boolean {
                    // 不能选明日之后的日期 (补偿 1 天是为了保持时区兼容性的宽裕，但核心是当前系统时间)
                    return utcTimeMillis <= System.currentTimeMillis()
                }
            }
        )
        DatePickerDialog(
            onDismissRequest = { showNativeDatePicker = false },
            confirmButton = {
                TextButton(onClick = {
                    datePickerState.selectedDateMillis?.let { viewModel.setDate(Date(it)) }
                    showNativeDatePicker = false
                }) { Text("确定") }
            },
            dismissButton = {
                TextButton(onClick = { showNativeDatePicker = false }) { Text("取消") }
            }
        ) {
            DatePicker(state = datePickerState)
        }
    }
    
    Scaffold(
        containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.2f),
        topBar = {
            TopAppBar(
                title = { 
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("地方客", fontWeight = FontWeight.ExtraBold, style = MaterialTheme.typography.headlineMedium)
                        if (OpenAIService.shared.isNetworkRequesting) {
                            Spacer(Modifier.width(12.dp))
                            CircularProgressIndicator(
                                modifier = Modifier.size(18.dp),
                                strokeWidth = 2.5.dp,
                                color = MaterialTheme.colorScheme.primary
                            )
                        }
                    }
                },
                actions = {
                    IconButton(onClick = onNavigateToHistory) {
                        Icon(Icons.Default.History, contentDescription = "历史")
                    }
                    IconButton(onClick = { showNativeDatePicker = true }) {
                        Icon(Icons.Default.CalendarMonth, contentDescription = "日历")
                    }
                    IconButton(onClick = onNavigateToStatistics) {
                        Icon(Icons.Default.BarChart, contentDescription = "统计")
                    }
                    IconButton(onClick = onNavigateToSettings) {
                        Icon(Icons.Default.Settings, contentDescription = "设置")
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = Color.Transparent,
                    scrolledContainerColor = MaterialTheme.colorScheme.surface
                )
            )
        }
    ) { padding ->
        Box(modifier = Modifier
            .fillMaxSize()
            .background(
                brush = androidx.compose.ui.graphics.Brush.verticalGradient(
                    colors = listOf(
                        MaterialTheme.colorScheme.background,
                        MaterialTheme.colorScheme.primary.copy(alpha = 0.1f)
                    )
                )
            )
        ) {
            Column(modifier = Modifier.padding(padding)) {
                
                // --- 日期导航器 (对齐 iOS 逻辑: 两端箭头 + 智能回归) ---
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 8.dp, vertical = 4.dp),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    val isAtStart = pagerState.currentPage == 0
                    val isAtToday = currentDate.time == today.time
                    val todayIndex = availableDates.indexOfFirst { it.time == today.time }
                    
                    IconButton(
                        onClick = { scope.launch { pagerState.animateScrollToPage(pagerState.currentPage - 1) } },
                        enabled = !isAtStart
                    ) {
                        Icon(
                            androidx.compose.material.icons.Icons.AutoMirrored.Filled.ArrowBack, 
                            contentDescription = "前一天",
                            tint = if (!isAtStart) MaterialTheme.colorScheme.primary else Color.Gray.copy(alpha = 0.3f)
                        )
                    }

                    Column(
                        horizontalAlignment = Alignment.CenterHorizontally,
                        modifier = Modifier
                            .clip(RoundedCornerShape(8.dp))
                            .clickable { showMiniCalendar = true }
                            .padding(8.dp)
                    ) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(
                                text = dateHeader, 
                                fontWeight = FontWeight.Bold, 
                                style = MaterialTheme.typography.titleLarge,
                                color = MaterialTheme.colorScheme.onBackground
                            )
                            Spacer(Modifier.width(4.dp))
                            Icon(
                                Icons.Default.KeyboardArrowDown, 
                                contentDescription = null, 
                                modifier = Modifier.size(16.dp),
                                tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.5f)
                            )
                        }
                        Text(
                            text = secondaryHeaderLabel, 
                            style = MaterialTheme.typography.labelMedium, 
                            color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f)
                        )
                    }

                    val isAtEnd = pagerState.currentPage == availableDates.size - 1
                    IconButton(
                        onClick = {
                            if (pagerState.currentPage < availableDates.size - 1) {
                                scope.launch { pagerState.animateScrollToPage(pagerState.currentPage + 1) }
                            }
                        },
                        enabled = !isAtEnd
                    ) {
                        Icon(
                            androidx.compose.material.icons.Icons.AutoMirrored.Filled.ArrowForward, 
                            contentDescription = "下一天",
                            tint = if (!isAtEnd) MaterialTheme.colorScheme.primary else Color.Gray.copy(alpha = 0.3f)
                        )
                    }
                }

                if (showMiniCalendar) {
                    MiniCalendarDialog(
                        selectedDate = currentDate,
                        availableDates = availableDates.toSet(),
                        onDateSelected = { 
                            viewModel.setDate(it)
                            showMiniCalendar = false
                        },
                        onDismiss = { showMiniCalendar = false }
                    )
                }
                
                // --- 横向滑动页面 ---
                val pagerDates = availableDates
                HorizontalPager(
                    state = pagerState,
                    modifier = Modifier.fillMaxSize()
                ) { page ->
                    // 监听滑动成功，更新提示状态
                    LaunchedEffect(pagerState.currentPage) {
                        val initialP = availableDates.size - 1
                        if (pagerState.currentPage != initialP) {
                            viewModel.markHasSwiped()
                        }
                    }
                    val pageDate = if (page < pagerDates.size) pagerDates[page] else today
                    val isTodayPage = pageDate.time == today.time
                    val isFuturePage = pageDate.time > today.time
                    
                    Box(modifier = Modifier.fillMaxSize()) {
                        LazyColumn(
                            modifier = Modifier.fillMaxSize(),
                            contentPadding = PaddingValues(top = 16.dp, bottom = 100.dp)
                        ) {
                            if (isFuturePage) {
                                item { FuturePlaceholderView() }
                            } else {
                                item {
                                    val trajectory by viewModel.dailyTrajectory.collectAsState()
                                    val markers by viewModel.dailyMarkers.collectAsState()
                                    if (isTodayPage) {
                                        RecordingStatusCard(
                                            trackingState = trackingState,
                                            isTracking = trackingState !is LocationTrackingService.TrackingState.Idle,
                                            footprintCount = items.size,
                                            onNavigateToMap = { onNavigateToMap(null) },
                                            hasLocationPermission = true,
                                            onRequestPermission = { }
                                        )
                                    } else {
                                        DaySummaryCard(
                                            footprintCount = items.size,
                                            mileage = totalMileage,
                                            pointCount = totalPoints,
                                            summary = dailyInsight?.content,
                                            pointsJson = trajectory,
                                            markersJson = markers,
                                            onNavigateToMap = { onNavigateToMap(currentDate) }
                                        )

                                        // --- Swipe Hint ---
                                        val hasSwiped by viewModel.hasSwiped.collectAsState(initial = true)
                                        if (!hasSwiped && page == availableDates.size - 1) {
                                            SwipeHintFooter()
                                        }
                                    }
                                }

                                dailyInsight?.let { insight ->
                                    if (!insight.content.isNullOrEmpty()) {
                                        item {
                                            DailyInsightView(content = insight.content!!)
                                        }
                                    }
                                }
                                
                                if (items.isEmpty() && !isFuturePage) {
                                    if (isTodayPage) {
                                        item { PlaceholderFootprintCard(trackingState) }
                                    } else {
                                        item {
                                            Box(
                                                modifier = Modifier
                                                    .fillMaxWidth()
                                                    .padding(top = 40.dp, bottom = 40.dp),
                                                contentAlignment = Alignment.Center
                                            ) {
                                                Text(
                                                    "这一天，你似乎没有留下足迹",
                                                    color = Color.Gray.copy(alpha = 0.5f),
                                                    style = MaterialTheme.typography.bodyMedium
                                                )
                                            }
                                        }
                                    }
                                }

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

                        // 顶部遮罩渐变 (与 iOS 一致)
                        Box(
                            modifier = Modifier
                                .fillMaxWidth()
                                .height(32.dp)
                                .background(
                                    brush = androidx.compose.ui.graphics.Brush.verticalGradient(
                                        colors = listOf(
                                            MaterialTheme.colorScheme.background,
                                            Color.Transparent
                                        )
                                    )
                                )
                        )
                    }
                }
            }
        }
    }
}

@Composable
fun NavigationArrow(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    enabled: Boolean,
    onClick: () -> Unit
) {
    Box(
        modifier = Modifier
            .size(32.dp)
            .background(
                color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.1f),
                shape = CircleShape
            )
            .clip(CircleShape)
            .clickable(enabled = enabled, onClick = onClick),
        contentAlignment = Alignment.Center
    ) {
        Icon(
            icon, 
            contentDescription = null, 
            modifier = Modifier.size(16.dp),
            tint = if (enabled) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurface.copy(alpha = 0.3f)
        )
    }
}

@Composable
fun FuturePlaceholderView() {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(top = 100.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(30.dp)
    ) {
        Icon(
            Icons.Default.AutoAwesome, 
            contentDescription = null, 
            modifier = Modifier.size(70.dp),
            tint = Color(0xFFFFD700)
        )
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text("明天是个未拆的礼物", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
            Text("愿明天的你，能在平凡中发现惊喜。", style = MaterialTheme.typography.bodyMedium, color = Color.Gray)
        }
    }
}

@Composable
fun SwipeHintFooter() {
    val infiniteTransition = rememberInfiniteTransition(label = "hint")
    val offset by infiniteTransition.animateFloat(
        initialValue = -8f,
        targetValue = 8f,
        animationSpec = infiniteRepeatable(
            animation = tween(1000, easing = LinearOutSlowInEasing),
            repeatMode = RepeatMode.Reverse
        ),
        label = "offset"
    )

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(top = 40.dp, bottom = 60.dp),
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically
    ) {
        Icon(
            androidx.compose.material.icons.Icons.AutoMirrored.Filled.ArrowBack, 
            contentDescription = null, 
            modifier = Modifier.size(14.dp).offset(x = offset.dp),
            tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.5f)
        )
        Spacer(Modifier.width(12.dp))
        Text(
            "左右滑动切换日期", 
            style = MaterialTheme.typography.labelMedium, 
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.5f)
        )
        Spacer(Modifier.width(12.dp))
        Icon(
            androidx.compose.material.icons.Icons.AutoMirrored.Filled.ArrowForward, 
            contentDescription = null, 
            modifier = Modifier.size(14.dp).offset(x = (-offset).dp),
            tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.5f)
        )
    }
}

@Composable
fun MiniCalendarDialog(
    selectedDate: Date,
    availableDates: Set<Date>,
    onDateSelected: (Date) -> Unit,
    onDismiss: () -> Unit
) {
    androidx.compose.ui.window.Dialog(onDismissRequest = onDismiss) {
        Surface(
            shape = RoundedCornerShape(26.dp),
            color = MaterialTheme.colorScheme.surface,
            tonalElevation = 6.dp,
            modifier = Modifier.width(300.dp)
        ) {
            Column(
                modifier = Modifier.padding(20.dp),
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
                // Header (Month Year)
                val sdf = SimpleDateFormat("yyyy年M月", Locale.CHINA)
                Text(
                    text = sdf.format(selectedDate),
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.Bold,
                    color = MaterialTheme.colorScheme.onSurface
                )
                
                Spacer(modifier = Modifier.height(16.dp))
                
                // Days of week
                Row(modifier = Modifier.fillMaxWidth()) {
                    listOf("日", "一", "二", "三", "四", "五", "六").forEach {
                        Text(
                            text = it,
                            modifier = Modifier.weight(1f),
                            textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.5f),
                            fontWeight = FontWeight.Bold
                        )
                    }
                }
                
                Spacer(modifier = Modifier.height(8.dp))
                
                // Calendar Grid
                val days = remember(selectedDate) { getDaysInMonth(selectedDate) }
                val startOfDay = { d: Date -> 
                    Calendar.getInstance().apply { 
                        time = d; set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
                    }.time
                }

                val availableStartOfDays = remember(availableDates) {
                    availableDates.map { startOfDay(it) }.toSet()
                }

                LazyVerticalGrid(
                    columns = GridCells.Fixed(7),
                    modifier = Modifier.height(240.dp)
                ) {
                    itemsIndexed(days) { _, date ->
                        if (date != null) {
                            val isSelected = startOfDay(date).time == startOfDay(selectedDate).time
                            val isAvailable = availableStartOfDays.contains(startOfDay(date))
                            val isToday = startOfDay(date).time == startOfDay(Date()).time
                            
                            Box(
                                modifier = Modifier
                                    .aspectRatio(1f)
                                    .padding(2.dp)
                                    .clip(CircleShape)
                                    .background(if (isSelected) MaterialTheme.colorScheme.primary else Color.Transparent)
                                    .clickable(enabled = isAvailable) {
                                        onDateSelected(date)
                                    },
                                contentAlignment = Alignment.Center
                            ) {
                                Text(
                                    text = Calendar.getInstance().apply { time = date }.get(Calendar.DAY_OF_MONTH).toString(),
                                    style = MaterialTheme.typography.bodyMedium,
                                    fontWeight = if (isSelected) FontWeight.Bold else FontWeight.Medium,
                                    color = when {
                                        isSelected -> Color.White
                                        isAvailable -> if (isToday) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface
                                        else -> MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.3f)
                                    }
                                )
                            }
                        } else {
                            Spacer(modifier = Modifier.aspectRatio(1f))
                        }
                    }
                }
            }
        }
    }
}

private fun getDaysInMonth(date: Date): List<Date?> {
    val cal = Calendar.getInstance().apply {
        time = date
        set(Calendar.DAY_OF_MONTH, 1)
    }
    val firstDayOfWeek = cal.get(Calendar.DAY_OF_WEEK) - 1 // 0-indexed
    val daysInMonth = cal.getActualMaximum(Calendar.DAY_OF_MONTH)
    
    val result = mutableListOf<Date?>()
    for (i in 0 until firstDayOfWeek) {
        result.add(null)
    }
    
    val tempCal = cal.clone() as Calendar
    for (i in 1..daysInMonth) {
        result.add(tempCal.time)
        tempCal.add(Calendar.DAY_OF_MONTH, 1)
    }
    
    return result
}
