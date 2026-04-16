package com.ct106.difangke.ui.screens.history

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.ct106.difangke.data.model.DaySummary
import com.ct106.difangke.viewmodel.HistoryViewModel
import java.text.SimpleDateFormat
import java.util.*
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HistoryScreen(
    onBack: () -> Unit,
    onNavigateToDetail: (String) -> Unit,
    onDateSelected: (Date) -> Unit, // 跳向主页特定日期
    viewModel: HistoryViewModel = viewModel()
) {
    val summaries by viewModel.summaries.collectAsState()
    val scope = rememberCoroutineScope()
    val pagerState = rememberPagerState(pageCount = { 3 })
    
    val tabs = listOf("周", "月", "收藏")

    val isDark = isSystemInDarkTheme()
    val bgColor = if (isDark) Color.Black else Color(0xFFF2F2F7)

    Scaffold(
        containerColor = bgColor,
        topBar = {
            CenterAlignedTopAppBar(
                title = { Text("往昔足迹", fontWeight = FontWeight.Bold) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "返回")
                    }
                },
                colors = TopAppBarDefaults.centerAlignedTopAppBarColors(
                    containerColor = MaterialTheme.colorScheme.background
                )
            )
        }
    ) { padding ->
        Column(modifier = Modifier.padding(padding).fillMaxSize()) {
            // Tab Picker (Android 原生风格)
            PrimaryTabRow(
                selectedTabIndex = pagerState.currentPage,
                containerColor = Color.Transparent,
                divider = {},
                indicator = {
                    TabRowDefaults.PrimaryIndicator(
                        modifier = Modifier.tabIndicatorOffset(pagerState.currentPage),
                        width = 64.dp,
                        shape = CircleShape
                    )
                }
            ) {
                tabs.forEachIndexed { index, title ->
                    Tab(
                        selected = pagerState.currentPage == index,
                        onClick = {
                            scope.launch { pagerState.animateScrollToPage(index) }
                        },
                        text = {
                            Text(
                                text = title,
                                style = MaterialTheme.typography.titleSmall,
                                fontWeight = if (pagerState.currentPage == index) FontWeight.Bold else FontWeight.Normal
                            )
                        }
                    )
                }
            }

            HorizontalPager(
                state = pagerState,
                modifier = Modifier.weight(1f),
                verticalAlignment = Alignment.Top
            ) { page ->
                when (page) {
                    0 -> HistoryWeekView(summaries, onDateSelected)
                    1 -> HistoryMonthView(summaries, onDateSelected)
                    2 -> HistoryFavoritesView(summaries, onNavigateToDetail)
                }
            }
        }
    }
}

@Composable
fun HistoryFavoritesView(summaries: Map<Date, DaySummary>, onNavigateToDetail: (String) -> Unit) {
    val favorites = summaries.values.filter { it.highlightCount > 0 }.sortedByDescending { it.date }
    
    if (favorites.isEmpty()) {
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Text("暂无收藏的精彩瞬间", color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha=0.5f))
        }
    } else {
        LazyColumn(contentPadding = PaddingValues(20.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            items(favorites) { summary ->
                ElevatedCard(
                    modifier = Modifier.fillMaxWidth().clickable { /* 应该跳到详情，但摘要存的是天 */ },
                    shape = RoundedCornerShape(16.dp)
                ) {
                    Column(modifier = Modifier.padding(16.dp)) {
                        Text(SimpleDateFormat("yyyy年M月d日", Locale.CHINA).format(summary.date), style = MaterialTheme.typography.labelSmall)
                        Spacer(Modifier.height(4.dp))
                        Text(summary.highlightTitle ?: "未命名精彩", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
                    }
                }
            }
        }
    }
}

@Composable
fun HistoryWeekView(summaries: Map<Date, DaySummary>, onDateSelected: (Date) -> Unit) {
    val sortedDates = summaries.keys.sortedDescending()
    val groupedByWeek = sortedDates.groupBy { date ->
        Calendar.getInstance().apply {
            time = date
            set(Calendar.DAY_OF_WEEK, Calendar.MONDAY)
        }.time
    }

    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(horizontal = 20.dp, vertical = 10.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp)
    ) {
        groupedByWeek.forEach { (weekStart, dates) ->
            item {
                val cal = Calendar.getInstance().apply { time = weekStart }
                Text(
                    text = "${cal.get(Calendar.YEAR)}年 第${cal.get(Calendar.WEEK_OF_YEAR)}周",
                    style = MaterialTheme.typography.titleSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    fontWeight = FontWeight.Bold,
                    modifier = Modifier.padding(vertical = 8.dp)
                )
            }
            
            items(dates) { date ->
                val summary = summaries[date] ?: return@items
                HistoryDayRow(date, summary, onClick = { onDateSelected(date) })
            }
        }
    }
}

@Composable
fun HistoryDayRow(date: Date, summary: DaySummary, onClick: () -> Unit) {
    val isToday = java.util.Calendar.getInstance().apply { time = date }.get(java.util.Calendar.DAY_OF_YEAR) == 
                 java.util.Calendar.getInstance().get(java.util.Calendar.DAY_OF_YEAR)
    
    ElevatedCard(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 4.dp)
            .clickable(onClick = onClick),
        shape = RoundedCornerShape(16.dp),
        colors = CardDefaults.elevatedCardColors(
            containerColor = if (androidx.compose.foundation.isSystemInDarkTheme()) Color(0xFF1C1C1E) else Color.White
        ),
        elevation = CardDefaults.elevatedCardElevation(defaultElevation = 2.dp)
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(16.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Column(modifier = Modifier.width(70.dp)) {
                Text(
                    text = SimpleDateFormat("EEE", Locale.CHINA).format(date),
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f)
                )
                Text(
                    text = SimpleDateFormat("M月d日", Locale.CHINA).format(date),
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.Bold
                )
            }
            
            Spacer(modifier = Modifier.width(20.dp))
            
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                // Stats line
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    StatSmallItem(Icons.Default.Place, "${summary.footprintCount}")
                    StatSmallItem(Icons.Default.Route, String.format("%.1fkm", summary.mileage / 1000.0))
                }
                
                // Icons line
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    summary.timelineIcons.take(8).forEach { item ->
                        Icon(
                            imageVector = getIconForName(item.icon),
                            contentDescription = null,
                            modifier = Modifier.size(14.dp),
                            tint = if (item.isTransport) MaterialTheme.colorScheme.primary else Color(android.graphics.Color.parseColor(item.colorHex))
                        )
                    }
                }
            }
        }
    }
}

@Composable
fun StatSmallItem(icon: androidx.compose.ui.graphics.vector.ImageVector, value: String) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        Icon(icon, null, modifier = Modifier.size(10.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.5f))
        Text(value, style = MaterialTheme.typography.labelSmall, fontWeight = FontWeight.Bold, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
fun HistoryMonthView(summaries: Map<Date, DaySummary>, onDateSelected: (Date) -> Unit) {
    // 简易月份视图：列出最近 12 个月
    val cal = Calendar.getInstance()
    val months = (0..11).map {
        val date = cal.time
        cal.add(Calendar.MONTH, -1)
        date
    }

    LazyColumn(contentPadding = PaddingValues(20.dp), verticalArrangement = Arrangement.spacedBy(24.dp)) {
        items(months) { monthDate ->
            MonthGridSection(monthDate, summaries, onDateSelected)
        }
    }
}

@Composable
fun MonthGridSection(monthDate: Date, summaries: Map<Date, DaySummary>, onDateSelected: (Date) -> Unit) {
    val cal = Calendar.getInstance().apply { time = monthDate; set(Calendar.DAY_OF_MONTH, 1) }
    val monthTitle = SimpleDateFormat("yyyy年 M月", Locale.CHINA).format(monthDate)
    val daysInMonth = cal.getActualMaximum(Calendar.DAY_OF_MONTH)
    val firstDayOfWeek = cal.get(Calendar.DAY_OF_WEEK) - 1 // 0-Sun
    
    val days = (1..daysInMonth).map { day ->
        val d = cal.clone() as Calendar
        d.set(Calendar.DAY_OF_MONTH, day)
        d.time
    }

    Column {
        Text(
            text = monthTitle,
            style = MaterialTheme.typography.titleMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            fontWeight = FontWeight.Bold,
            modifier = Modifier.padding(bottom = 12.dp)
        )
        
        LazyVerticalGrid(
            columns = GridCells.Fixed(7),
            modifier = Modifier.height(300.dp), // 使用固定高度或适当计算
            userScrollEnabled = false
        ) {
            items(firstDayOfWeek) { Spacer(Modifier.fillMaxSize()) }
            items(days) { date ->
                val summary = summaries.entries.find { isSameDay(it.key, date) }?.value
                MonthDayCell(date, summary, onClick = { onDateSelected(date) })
            }
        }
    }
}

@Composable
fun MonthDayCell(date: Date, summary: DaySummary?, onClick: () -> Unit) {
    val hasData = summary != null && summary.footprintCount > 0
    val todayCal = java.util.Calendar.getInstance()
    val isToday = isSameDay(date, todayCal.time)
    
    Column(
        modifier = Modifier
            .aspectRatio(1f)
            .padding(2.dp)
            .clip(RoundedCornerShape(8.dp))
            .background(if (isToday) MaterialTheme.colorScheme.primary.copy(alpha = 0.1f) else Color.Transparent)
            .clickable(enabled = hasData, onClick = onClick),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        Text(
            text = Calendar.getInstance().apply { time = date }.get(Calendar.DAY_OF_MONTH).toString(),
            style = MaterialTheme.typography.bodySmall,
            fontWeight = if (hasData) FontWeight.Bold else FontWeight.Normal,
            color = if (hasData) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurface.copy(alpha = 0.2f)
        )
        if (hasData) {
            Box(Modifier.size(4.dp).clip(CircleShape).background(MaterialTheme.colorScheme.primary))
        }
    }
}

@Composable
fun HistoryStatisticsView(summaries: Map<Date, DaySummary>) {
    val totalMileage = summaries.values.sumOf { it.mileage }
    val totalFootprints = summaries.values.sumOf { it.footprintCount }
    val activeDays = summaries.values.count { it.footprintCount > 0 }

    Column(modifier = Modifier.fillMaxSize().padding(24.dp), verticalArrangement = Arrangement.spacedBy(20.dp)) {
        Text("数据总览", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold)
        
        StatCard("总里程", String.format("%.2f km", totalMileage / 1000.0), Icons.Default.Route)
        StatCard("足迹总数", "$totalFootprints", Icons.Default.Place)
        StatCard("活跃天数", "$activeDays", Icons.Default.CalendarToday)
    }
}

@Composable
fun StatCard(label: String, value: String, icon: androidx.compose.ui.graphics.vector.ImageVector) {
    ElevatedCard(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(20.dp),
        colors = CardDefaults.elevatedCardColors(
            containerColor = if (androidx.compose.foundation.isSystemInDarkTheme()) Color(0xFF1C1C1E) else Color.White
        ),
        elevation = CardDefaults.elevatedCardElevation(defaultElevation = 4.dp)
    ) {
        Row(modifier = Modifier.padding(20.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(icon, null, modifier = Modifier.size(32.dp), tint = MaterialTheme.colorScheme.primary)
            Spacer(modifier = Modifier.width(20.dp))
            Column {
                Text(label, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Text(value, style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.Bold)
            }
        }
    }
}

private fun getIconForName(name: String): androidx.compose.ui.graphics.vector.ImageVector {
    return when(name) {
        "home" -> Icons.Default.Home
        "work" -> Icons.Default.Work
        "restaurant" -> Icons.Default.Restaurant
        "shopping_bag" -> Icons.Default.ShoppingBag
        "directions_run" -> Icons.Default.DirectionsRun
        "directions_bus" -> Icons.Default.DirectionsBus
        else -> Icons.Default.Place
    }
}

private fun Color.withAlpha(alpha: Float): Color = copy(alpha = alpha)

private fun isSameDay(d1: Date, d2: Date): Boolean {
    val c1 = java.util.Calendar.getInstance().apply { time = d1 }
    val c2 = java.util.Calendar.getInstance().apply { time = d2 }
    return c1.get(java.util.Calendar.YEAR) == c2.get(java.util.Calendar.YEAR) &&
           c1.get(java.util.Calendar.DAY_OF_YEAR) == c2.get(java.util.Calendar.DAY_OF_YEAR)
}
