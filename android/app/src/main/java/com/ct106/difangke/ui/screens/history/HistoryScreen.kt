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
import com.ct106.difangke.data.db.entity.FootprintEntity
import com.ct106.difangke.data.db.entity.ActivityTypeEntity
import com.ct106.difangke.data.db.entity.PlaceEntity
import com.ct106.difangke.viewmodel.HistoryViewModel
import com.ct106.difangke.ui.components.FootprintCardView
import com.ct106.difangke.ui.components.getIconForName
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
    val favoriteFootprints by viewModel.favoriteFootprints.collectAsState()
    val activityTypes by viewModel.activityTypes.collectAsState()
    val allPlaces by viewModel.allPlaces.collectAsState()
    
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
                    2 -> HistoryFavoritesView(
                        favorites = favoriteFootprints,
                        activityTypes = activityTypes,
                        allPlaces = allPlaces,
                        onNavigateToDetail = { onNavigateToDetail("f_$it") }
                    )
                }
            }
        }
    }
}

@Composable
fun HistoryFavoritesView(
    favorites: List<FootprintEntity>,
    activityTypes: List<ActivityTypeEntity>,
    allPlaces: List<PlaceEntity>,
    onNavigateToDetail: (String) -> Unit
) {
    val groupedFavorites = favorites.groupBy { fp ->
        Calendar.getInstance().apply {
            time = fp.startTime
            set(Calendar.HOUR_OF_DAY, 0)
            set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
        }.time
    }
    val sortedDates = groupedFavorites.keys.sortedDescending()
    
    if (favorites.isEmpty()) {
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Text("暂无收藏的精彩瞬间", color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha=0.5f))
        }
    } else {
        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(vertical = 16.dp)
        ) {
            sortedDates.forEach { date ->
                item {
                    Text(
                        text = SimpleDateFormat("yyyy年M月d日", Locale.CHINA).format(date),
                        style = MaterialTheme.typography.titleSmall,
                        fontWeight = FontWeight.Bold,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(horizontal = 24.dp, vertical = 8.dp)
                    )
                }
                
                val dailyFavorites = groupedFavorites[date] ?: emptyList()
                items(dailyFavorites) { fp ->
                    FootprintCardView(
                        footprint = fp,
                        activityTypes = activityTypes,
                        allPlaces = allPlaces,
                        isFirst = true,
                        isLast = true,
                        showTimeline = false,
                        onClick = { onNavigateToDetail(fp.footprintID) }
                    )
                }
                
                item { Spacer(Modifier.height(16.dp)) }
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
            set(Calendar.HOUR_OF_DAY, 0)
            set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
        }.time
    }
    val sortedWeekStarts = groupedByWeek.keys.sortedDescending()

    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(horizontal = 20.dp, vertical = 10.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp)
    ) {
        sortedWeekStarts.forEach { weekStart ->
            val dates = groupedByWeek[weekStart] ?: return@forEach
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
    val months = remember {
        val cal = Calendar.getInstance()
        (0..11).map {
            val date = cal.time
            cal.add(Calendar.MONTH, -1)
            date
        }
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
    val firstDayOfWeek = (cal.get(Calendar.DAY_OF_WEEK) - 1) // 0-Sun
    
    val days = (1..daysInMonth).map { day ->
        val d = cal.clone() as Calendar
        d.set(Calendar.DAY_OF_MONTH, day)
        d.set(Calendar.HOUR_OF_DAY, 0)
        d.set(Calendar.MINUTE, 0)
        d.set(Calendar.SECOND, 0)
        d.set(Calendar.MILLISECOND, 0)
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
            modifier = Modifier.height(300.dp), 
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
    val isToday = isSameDay(date, Date())
    
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

private fun isSameDay(d1: Date, d2: Date): Boolean {
    val c1 = java.util.Calendar.getInstance().apply { time = d1 }
    val c2 = java.util.Calendar.getInstance().apply { time = d2 }
    return c1.get(java.util.Calendar.YEAR) == c2.get(java.util.Calendar.YEAR) &&
           c1.get(java.util.Calendar.DAY_OF_YEAR) == c2.get(java.util.Calendar.DAY_OF_YEAR)
}
