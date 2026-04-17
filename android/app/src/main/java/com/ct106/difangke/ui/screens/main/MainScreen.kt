package com.ct106.difangke.ui.screens.main

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.isSystemInDarkTheme
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
import androidx.compose.foundation.pager.PagerState
import androidx.compose.ui.text.style.TextAlign

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
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    
    var showCalendar by remember { mutableStateOf(false) }
    val availableDates by viewModel.availableDates.collectAsState()
    val currentDate by viewModel.currentDate.collectAsState()
    val activityTypes by viewModel.activityTypes.collectAsState()
    val allPlaces by viewModel.allPlaces.collectAsState()
    val trackingState by viewModel.trackingState.collectAsState()
    
    val pagerState = rememberPagerState(
        initialPage = availableDates.indexOfFirst { it.time == currentDate.time }.coerceAtLeast(0), 
        pageCount = { availableDates.size }
    )
    
    // 同步 Pager 到当前日期 (Date -> Pager)
    LaunchedEffect(currentDate, availableDates) {
        val index = availableDates.indexOfFirst { it.time == currentDate.time }
        if (index >= 0 && index != pagerState.currentPage && !pagerState.isScrollInProgress) {
            pagerState.scrollToPage(index)
        }
    }
    
    // 同步 Pager 到时间 (Pager -> Date)
    LaunchedEffect(pagerState.settledPage) {
        if (availableDates.isNotEmpty() && !pagerState.isScrollInProgress) {
            val dateAtPage = availableDates[pagerState.settledPage.coerceIn(availableDates.indices)]
            if (dateAtPage.time != currentDate.time) {
                viewModel.setDate(dateAtPage)
            }
        }
    }

    val today = remember {
        Calendar.getInstance().apply {
            set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
        }.time
    }
    
    val isDark = isSystemInDarkTheme()
    val bgColor = if (isDark) Color.Black else Color(0xFFF2F2F7)

    Scaffold(
        containerColor = bgColor,
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
                    IconButton(onClick = onNavigateToStatistics) {
                        Icon(Icons.Default.BarChart, contentDescription = "统计")
                    }
                    IconButton(onClick = onNavigateToSettings) {
                        Icon(Icons.Default.Settings, contentDescription = "设置")
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = bgColor,
                    scrolledContainerColor = bgColor
                )
            )
        }
    ) { padding ->
        Box(modifier = Modifier
            .fillMaxSize()
            .background(bgColor)
        ) {
            Column(modifier = Modifier.padding(padding)) {
                DateNavigator(
                    currentDate = currentDate,
                    canGoBack = pagerState.currentPage > 0,
                    canGoForward = pagerState.currentPage < availableDates.size - 1,
                    onPrevClick = {
                        if (pagerState.currentPage > 0) {
                            scope.launch { pagerState.animateScrollToPage(pagerState.currentPage - 1) }
                        }
                    },
                    onNextClick = {
                        if (pagerState.currentPage < availableDates.size - 1) {
                            scope.launch { pagerState.animateScrollToPage(pagerState.currentPage + 1) }
                        }
                    },
                    onCalendarClick = { showCalendar = true }
                )

                HorizontalPager(
                    state = pagerState,
                    modifier = Modifier.weight(1f),
                    beyondBoundsPageCount = 1,
                ) { pageIndex ->
                    val dateAtPage = availableDates[pageIndex]
                    
                    // 每个页面管理自己的数据观察，确保滑动时数据互不干扰
                    TimelinePage(
                        date = dateAtPage,
                        viewModel = viewModel,
                        trackingState = trackingState,
                        activityTypes = activityTypes,
                        allPlaces = allPlaces,
                        isFirstPage = pageIndex == 0,
                        isLastPage = pageIndex == availableDates.size - 1,
                        onItemClick = onNavigateToDetail,
                        onMapClick = { onNavigateToMap(dateAtPage) }
                    )
                }
            }

            // 返回今天按钮 (浮动)
            TodayFloatingButton(
                isVisible = currentDate.time != today.time,
                onClick = { 
                    val todayIndex = availableDates.indexOfFirst { it.time == today.time }
                    if (todayIndex >= 0) {
                        scope.launch { pagerState.animateScrollToPage(todayIndex) }
                    }
                }
            )
            
            if (showCalendar) {
                CalendarSelectionDialog(
                    selectedDate = currentDate,
                    availableDates = availableDates,
                    onDateSelected = { date ->
                        viewModel.setDate(date)
                        showCalendar = false
                    },
                    onDismiss = { showCalendar = false }
                )
            }
        }
    }
}

@Composable
fun TimelinePage(
    date: Date,
    viewModel: MainViewModel,
    trackingState: LocationTrackingService.TrackingState,
    activityTypes: List<com.ct106.difangke.data.db.entity.ActivityTypeEntity>,
    allPlaces: List<com.ct106.difangke.data.db.entity.PlaceEntity>,
    isFirstPage: Boolean,
    isLastPage: Boolean,
    onItemClick: (String) -> Unit,
    onMapClick: () -> Unit
) {
    val items by viewModel.getTimelineItems(date).collectAsState(initial = emptyList())
    val dailyInsight by viewModel.getDailyInsight(date).collectAsState(initial = null)
    val mileage by viewModel.getMileage(date).collectAsState(initial = 0.0)
    val points by viewModel.getPointsCount(date).collectAsState(initial = 0)
    
    val today = remember {
        Calendar.getInstance().apply {
            set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
        }.time
    }
    val isToday = date.time == today.time
    val isFuture = date.time > today.time

    if (isFuture) {
        FuturePlaceholderView()
    } else if (isFirstPage && items.isEmpty()) {
        PastPlaceholderView()
    } else {
        TimelineContent(
            items = items,
            dailyInsight = dailyInsight?.content,
            totalMileage = mileage,
            totalPoints = points,
            trackingState = trackingState,
            activityTypes = activityTypes,
            allPlaces = allPlaces,
            isToday = isToday,
            isRefreshing = viewModel.isRefreshing.collectAsState().value,
            onItemClick = onItemClick,
            onMapClick = onMapClick,
            onRefresh = { viewModel.refresh() },
            dailyMarkers = viewModel.dailyMarkers.collectAsState().value,
            dailyPoints = viewModel.dailyTrajectory.collectAsState().value
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TimelineContent(
    items: List<TimelineItem>,
    dailyInsight: String?,
    totalMileage: Double,
    totalPoints: Int,
    trackingState: LocationTrackingService.TrackingState,
    activityTypes: List<com.ct106.difangke.data.db.entity.ActivityTypeEntity>,
    allPlaces: List<com.ct106.difangke.data.db.entity.PlaceEntity>,
    isToday: Boolean,
    isRefreshing: Boolean,
    onItemClick: (String) -> Unit,
    onMapClick: () -> Unit,
    onRefresh: () -> Unit,
    dailyPoints: String? = null,
    dailyMarkers: String? = null
) {
    // 过滤掉与当前正在进行的实时停留重合的足迹 (iOS Parity)
    val filteredItems = remember(items, trackingState, isToday) {
        if (!isToday || trackingState !is LocationTrackingService.TrackingState.OngoingStay) items
        else {
            val ongoing = trackingState
            items.filter { item ->
                when (item) {
                    is TimelineItem.FootprintItem -> {
                        // 如果地点相近且时间重合，隐藏
                        val dist = haversine(item.latitude, item.longitude, ongoing.lat, ongoing.lon)
                        val isOverlap = item.footprint.endTime.time > ongoing.since.time - 60000
                        !(dist < 200 && isOverlap)
                    }
                    is TimelineItem.TransportItem -> {
                        // 移除在当前停留开始之后结束的交通段
                        item.transport.endTime.time < ongoing.since.time + 30000
                    }
                }
            }
        }
    }

    Box(modifier = Modifier.fillMaxSize()) {
        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(bottom = 120.dp)
        ) {
            // 统计概览 / 记录状态 (iOS 风格：今日合并，历史显示快照)
            item {
                if (isToday) {
                    RecordingStatusCard(
                        trackingState = trackingState,
                        isTracking = trackingState !is LocationTrackingService.TrackingState.Idle,
                        footprintCount = items.filterIsInstance<TimelineItem.FootprintItem>().size,
                        mileage = totalMileage,
                        pointCount = totalPoints,
                        summary = dailyInsight,
                        pointsJson = dailyPoints,
                        markersJson = dailyMarkers,
                        onNavigateToMap = onMapClick,
                        onRequestPermission = {},
                        hasLocationPermission = true
                    )
                } else {
                    DaySummaryCard(
                        footprintCount = filteredItems.filterIsInstance<TimelineItem.FootprintItem>().size,
                        mileage = totalMileage,
                        pointCount = totalPoints,
                        summary = dailyInsight,
                        pointsJson = dailyPoints,
                        markersJson = dailyMarkers,
                        onNavigateToMap = onMapClick
                    )
                }
            }

            // 时间轴列表
            if (filteredItems.isEmpty()) {
                item {
                    PlaceholderFootprintCard(trackingState = trackingState)
                }
            } else {
                itemsIndexed(filteredItems) { index, item ->
                    TimelineRow(
                        item = item,
                        isFirst = index == 0,
                        isLast = index == filteredItems.size - 1,
                        activityTypes = activityTypes,
                        allPlaces = allPlaces,
                        onClick = { onItemClick(item.id) }
                    )
                }
            }
        }
    }
}

@Composable
fun DateNavigator(
    currentDate: Date,
    canGoBack: Boolean,
    canGoForward: Boolean,
    onPrevClick: () -> Unit,
    onNextClick: () -> Unit,
    onCalendarClick: () -> Unit
) {
    val primaryColor = Color(0xFF00A0AC)
    
    val calendar = Calendar.getInstance().apply { time = currentDate }
    val isToday = isToday(currentDate)
    val isYesterday = isYesterday(currentDate)
    val isDby = isDayBeforeYesterday(currentDate)

    val dateHeader = when {
        isToday -> "今天"
        isYesterday -> "昨天"
        isDby -> "前天"
        else -> {
            val currentYear = Calendar.getInstance().get(Calendar.YEAR)
            val displayYear = calendar.get(Calendar.YEAR)
            if (currentYear == displayYear) SimpleDateFormat("M月d日", Locale.CHINA).format(currentDate)
            else SimpleDateFormat("yyyy年M月d日", Locale.CHINA).format(currentDate)
        }
    }
    
    val secondaryHeader = if (isToday || isYesterday || isDby) {
        val sdf = SimpleDateFormat("M月d日 EEEE", Locale.CHINA)
        sdf.format(currentDate)
    } else {
        SimpleDateFormat("EEEE", Locale.CHINA).format(currentDate)
    }

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 8.dp)
            .background(
                if (androidx.compose.foundation.isSystemInDarkTheme()) Color.White.copy(alpha = 0.05f)
                else MaterialTheme.colorScheme.primary.copy(alpha = 0.05f), 
                RoundedCornerShape(16.dp)
            )
            .padding(vertical = 4.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically
    ) {
        IconButton(
            onClick = onPrevClick,
            enabled = canGoBack
        ) {
            Icon(
                Icons.Default.KeyboardArrowLeft, 
                contentDescription = "Previous", 
                tint = if (canGoBack) primaryColor else Color.Gray.copy(alpha = 0.3f)
            )
        }

        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            modifier = Modifier.clickable { onCalendarClick() }
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    text = dateHeader,
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.Bold,
                    color = MaterialTheme.colorScheme.onSurface
                )
                Spacer(modifier = Modifier.width(4.dp))
                Icon(
                    imageVector = Icons.Default.KeyboardArrowDown,
                    contentDescription = null,
                    modifier = Modifier.size(10.dp),
                    tint = Color.Gray.copy(alpha = 0.5f)
                )
            }
            Text(
                text = secondaryHeader,
                style = MaterialTheme.typography.labelSmall,
                color = Color.Gray
            )
        }

        IconButton(
            onClick = onNextClick,
            enabled = canGoForward
        ) {
            Icon(
                Icons.Default.KeyboardArrowRight, 
                contentDescription = "Next", 
                tint = if (canGoForward) primaryColor else Color.Gray.copy(alpha = 0.3f)
            )
        }
    }
}

private fun isToday(date: Date): Boolean {
    return isSameDay(date, Date())
}

private fun isYesterday(date: Date): Boolean {
    val cal = Calendar.getInstance()
    cal.add(Calendar.DAY_OF_YEAR, -1)
    return isSameDay(date, cal.time)
}

private fun isDayBeforeYesterday(date: Date): Boolean {
    val cal = Calendar.getInstance()
    cal.add(Calendar.DAY_OF_YEAR, -2)
    return isSameDay(date, cal.time)
}

private fun isSameDay(d1: Date, d2: Date): Boolean {
    val c1 = Calendar.getInstance().apply { time = d1 }
    val c2 = Calendar.getInstance().apply { time = d2 }
    return c1.get(Calendar.YEAR) == c2.get(Calendar.YEAR) && c1.get(Calendar.DAY_OF_YEAR) == c2.get(Calendar.DAY_OF_YEAR)
}

@Composable
fun CalendarSelectionDialog(
    selectedDate: Date,
    availableDates: List<Date>,
    onDateSelected: (Date) -> Unit,
    onDismiss: () -> Unit
) {
    androidx.compose.ui.window.Dialog(
        onDismissRequest = onDismiss
    ) {
        Box(
            modifier = Modifier
                .fillMaxWidth(),
            contentAlignment = Alignment.Center
        ) {
            MiniCalendarView(
                selectedDate = selectedDate,
                availableDates = availableDates.toSet(),
                onDateSelected = onDateSelected
            )
        }
    }
}

@Composable
fun MiniCalendarView(
    selectedDate: Date,
    availableDates: Set<Date>,
    onDateSelected: (Date) -> Unit
) {
    val calendar = remember { Calendar.getInstance() }
    var currentMonth by remember { 
        mutableStateOf(Calendar.getInstance().apply { 
            time = selectedDate
            set(Calendar.DAY_OF_MONTH, 1)
        }.time) 
    }
    
    val weekDays = listOf("日", "一", "二", "三", "四", "五", "六")
    val isDark = isSystemInDarkTheme()
    val primaryColor = Color(0xFF00A0AC)

    Column(
        modifier = Modifier
            .width(320.dp)
            .clip(RoundedCornerShape(28.dp))
            .background(if (isDark) Color(0xFF1C1C1E) else Color.White)
            .padding(20.dp),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        // Header
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            IconButton(
                onClick = {
                    val cal = Calendar.getInstance().apply { time = currentMonth; add(Calendar.MONTH, -1) }
                    currentMonth = cal.time
                },
                modifier = Modifier.size(32.dp).background(Color.Gray.copy(alpha = 0.1f), CircleShape)
            ) {
                Icon(Icons.Default.ChevronLeft, null, modifier = Modifier.size(16.dp), tint = Color.Gray)
            }

            Text(
                text = SimpleDateFormat("yyyy年M月", Locale.CHINA).format(currentMonth),
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.Bold
            )

            IconButton(
                onClick = {
                    val cal = Calendar.getInstance().apply { time = currentMonth; add(Calendar.MONTH, 1) }
                    currentMonth = cal.time
                },
                modifier = Modifier.size(32.dp).background(Color.Gray.copy(alpha = 0.1f), CircleShape)
            ) {
                Icon(Icons.Default.ChevronRight, null, modifier = Modifier.size(16.dp), tint = Color.Gray)
            }
        }

        Spacer(modifier = Modifier.height(16.dp))

        // Weekdays
        Row(modifier = Modifier.fillMaxWidth()) {
            weekDays.forEach { day ->
                Text(
                    text = day,
                    modifier = Modifier.weight(1f),
                    textAlign = TextAlign.Center,
                    style = MaterialTheme.typography.labelSmall,
                    color = Color.Gray.copy(alpha = 0.6f),
                    fontWeight = FontWeight.Bold
                )
            }
        }

        Spacer(modifier = Modifier.height(8.dp))

        // Days Grid
        val days = remember(currentMonth) { getDaysInMonth(currentMonth) }
        val rows = days.chunked(7)

        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            rows.forEach { row ->
                Row(modifier = Modifier.fillMaxWidth()) {
                    row.forEach { date ->
                        if (date == null) {
                            Spacer(modifier = Modifier.weight(1f))
                        } else {
                            val isSelected = isSameDay(date, selectedDate)
                            val isToday = isSameDay(date, Date())
                            val hasData = availableDates.any { isSameDay(it, date) }
                            val isCurrentMonth = isSameMonth(date, currentMonth)
                            val isFuture = date.time > System.currentTimeMillis() + 60000

                            Box(
                                modifier = Modifier
                                    .weight(1f)
                                    .aspectRatio(1f)
                                    .clip(CircleShape)
                                    .background(if (isSelected) primaryColor else Color.Transparent)
                                    .clickable(enabled = (hasData || isToday) && !isFuture) { 
                                        onDateSelected(date) 
                                    },
                                contentAlignment = Alignment.Center
                            ) {
                                Text(
                                    text = Calendar.getInstance().apply { time = date }.get(Calendar.DAY_OF_MONTH).toString(),
                                    color = when {
                                        isSelected -> Color.White
                                        isFuture -> Color.Gray.copy(alpha = 0.3f)
                                        !isCurrentMonth -> Color.Gray.copy(alpha = 0.3f)
                                        isToday -> primaryColor
                                        hasData -> if (isDark) Color.White else Color.Black
                                        else -> Color.Gray.copy(alpha = 0.5f)
                                    },
                                    style = MaterialTheme.typography.bodyMedium,
                                    fontWeight = if (isSelected || isToday) FontWeight.Bold else FontWeight.Medium
                                )
                                
                                if (hasData && !isSelected) {
                                    Box(
                                        modifier = Modifier
                                            .align(Alignment.BottomCenter)
                                            .padding(bottom = 4.dp)
                                            .size(3.dp)
                                            .background(if (isToday) primaryColor else Color.Gray.copy(alpha = 0.5f), CircleShape)
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

private fun getDaysInMonth(monthDate: Date): List<Date?> {
    val calendar = Calendar.getInstance().apply {
        time = monthDate
        set(Calendar.DAY_OF_MONTH, 1)
    }
    val daysInMonth = calendar.getActualMaximum(Calendar.DAY_OF_MONTH)
    val firstDayOfWeek = calendar.get(Calendar.DAY_OF_WEEK) - 1 // 0-based
    
    val result = mutableListOf<Date?>()
    for (i in 0 until firstDayOfWeek) {
        result.add(null)
    }
    for (i in 1..daysInMonth) {
        val date = calendar.time
        result.add(date)
        calendar.add(Calendar.DAY_OF_MONTH, 1)
    }
    
    // Fill until 42 to keep grid consistent (6 rows)
    while (result.size < 42) {
        result.add(null)
    }
    return result
}

private fun isSameMonth(d1: Date, d2: Date): Boolean {
    val c1 = Calendar.getInstance().apply { time = d1 }
    val c2 = Calendar.getInstance().apply { time = d2 }
    return c1.get(Calendar.YEAR) == c2.get(Calendar.YEAR) && c1.get(Calendar.MONTH) == c2.get(Calendar.MONTH)
}

@Composable
fun TodayFloatingButton(isVisible: Boolean, onClick: () -> Unit) {
    AnimatedVisibility(
        visible = isVisible,
        enter = fadeIn() + slideInVertically { it },
        exit = fadeOut() + slideOutVertically { it },
        modifier = Modifier.fillMaxSize()
    ) {
        Box(contentAlignment = Alignment.BottomCenter, modifier = Modifier.padding(bottom = 32.dp)) {
            Button(
                onClick = onClick,
                elevation = ButtonDefaults.buttonElevation(defaultElevation = 6.dp),
                shape = RoundedCornerShape(24.dp)
            ) {
                Icon(Icons.Default.Today, null, Modifier.size(18.dp))
                Spacer(Modifier.width(8.dp))
                Text("回到今天", fontWeight = FontWeight.Bold)
            }
        }
    }
}

@Composable
fun FuturePlaceholderView() {
    Column(
        modifier = Modifier.fillMaxSize().padding(horizontal = 24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        Icon(Icons.Default.AutoAwesome, null, modifier = Modifier.size(60.dp), tint = MaterialTheme.colorScheme.primary.copy(alpha = 0.6f))
        Spacer(Modifier.height(16.dp))
        Text("明天是个未拆的礼物", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
        Text("愿明天的你，能在平凡中发现惊喜。", style = MaterialTheme.typography.bodyMedium, color = Color.Gray, textAlign = TextAlign.Center)
    }
}

@Composable
fun PastPlaceholderView() {
    Column(
        modifier = Modifier.fillMaxSize().padding(horizontal = 24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        Icon(Icons.Default.Timer, null, modifier = Modifier.size(60.dp), tint = Color.Gray.copy(alpha = 0.6f))
        Spacer(Modifier.height(16.dp))
        Text("真希望能早点遇到你", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
        Text("要是早点遇见，就能记录更多精彩了。", style = MaterialTheme.typography.bodyMedium, color = Color.Gray, textAlign = TextAlign.Center)
    }
}

private fun haversine(lat1: Double, lon1: Double, lat2: Double, lon2: Double): Double {
    val R = 6371000.0
    val dLat = Math.toRadians(lat2 - lat1)
    val dLon = Math.toRadians(lon2 - lon1)
    val a = Math.sin(dLat / 2) * Math.sin(dLat / 2) +
            Math.cos(Math.toRadians(lat1)) * Math.cos(Math.toRadians(lat2)) *
            Math.sin(dLon / 2) * Math.sin(dLon / 2)
    val c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a))
    return R * c
}
