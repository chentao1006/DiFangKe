package com.ct106.difangke.ui.screens.statistics

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.viewmodel.compose.viewModel
import java.util.*

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun StatisticsScreen(
    onBack: () -> Unit,
    viewModel: StatisticsViewModel = viewModel()
) {
    val selectedRange by viewModel.selectedRange.collectAsState()
    val heatmapPoints by viewModel.heatmapPoints.collectAsState()
    val activityRank by viewModel.activityRank.collectAsState()
    val trendData by viewModel.trendData.collectAsState()
    val aiSummary by viewModel.aiSummary.collectAsState()
    val isGeneratingSummary by viewModel.isGeneratingSummary.collectAsState()

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("统计洞察") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.Default.ArrowBack, contentDescription = "返回")
                    }
                }
            )
        }
    ) { paddingValues ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(paddingValues)
                .verticalScroll(rememberScrollState())
                .padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(24.dp)
        ) {
            // 1. Range Picker
            RangePickerRow(
                selectedRange = selectedRange,
                onRangeSelected = { viewModel.setRange(it) }
            )

            // 2. AI Summary Card
            AiSummaryCard(summary = aiSummary, isGenerating = isGeneratingSummary)

            // 3. Activity Rank
            ActivityRankCard(items = activityRank)

            // 4. Trend Chart (Simplified placeholder)
            TrendChartCard(points = trendData)
            
            Spacer(modifier = Modifier.height(80.dp))
        }
    }
}

@Composable
fun RangePickerRow(
    selectedRange: StatisticsRange,
    onRangeSelected: (StatisticsRange) -> Unit
) {
    var showYearMenu by remember { mutableStateOf(false) }
    val currentYear = Calendar.getInstance().get(Calendar.YEAR)
    val years = (currentYear downTo currentYear - 5).toList()

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f))
            .padding(4.dp),
        horizontalArrangement = Arrangement.SpaceEvenly,
        verticalAlignment = Alignment.CenterVertically
    ) {
        listOf(
            StatisticsRange.LAST_7_DAYS, 
            StatisticsRange.LAST_30_DAYS, 
            StatisticsRange.LAST_90_DAYS, 
            StatisticsRange.LAST_YEAR
        ).forEach { range ->
            val isSelected = selectedRange == range
            Box(
                modifier = Modifier
                    .weight(1f)
                    .clip(RoundedCornerShape(8.dp))
                    .background(if (isSelected) MaterialTheme.colorScheme.primary else Color.Transparent)
                    .clickable { onRangeSelected(range) }
                    .padding(vertical = 8.dp),
                contentAlignment = Alignment.Center
            ) {
                Text(
                    range.label,
                    style = MaterialTheme.typography.labelMedium,
                    color = if (isSelected) Color.White else MaterialTheme.colorScheme.onSurfaceVariant,
                    fontWeight = if (isSelected) FontWeight.Bold else FontWeight.Normal
                )
            }
        }
        
        // Year Selector
        val isCustomOrAll = selectedRange is StatisticsRange.CUSTOM_YEAR || selectedRange == StatisticsRange.ALL
        Box(
            modifier = Modifier
                .weight(1f)
                .clip(RoundedCornerShape(8.dp))
                .background(if (isCustomOrAll) MaterialTheme.colorScheme.primary else Color.Transparent)
                .clickable { showYearMenu = true }
                .padding(vertical = 8.dp),
            contentAlignment = Alignment.Center
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                val label = when (val range = selectedRange) {
                    is StatisticsRange.CUSTOM_YEAR -> "${range.year}"
                    StatisticsRange.ALL -> "全部"
                    else -> "年份"
                }
                Text(
                    label,
                    style = MaterialTheme.typography.labelMedium,
                    color = if (isCustomOrAll) Color.White else MaterialTheme.colorScheme.onSurfaceVariant
                )
                Icon(
                    Icons.Default.KeyboardArrowDown, 
                    null, 
                    Modifier.size(12.dp),
                    tint = if (isCustomOrAll) Color.White else MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            
            DropdownMenu(expanded = showYearMenu, onDismissRequest = { showYearMenu = false }) {
                DropdownMenuItem(
                    text = { Text("全部时间") },
                    onClick = { onRangeSelected(StatisticsRange.ALL); showYearMenu = false }
                )
                years.forEach { year ->
                    DropdownMenuItem(
                        text = { Text("$year") },
                        onClick = { onRangeSelected(StatisticsRange.CUSTOM_YEAR(year)); showYearMenu = false }
                    )
                }
            }
        }
    }
}

@Composable
fun AiSummaryCard(summary: String?, isGenerating: Boolean) {
    Column(modifier = Modifier.fillMaxWidth()) {
        LabelWithIcon("生活洞察", Icons.Default.AutoAwesome)
        Spacer(Modifier.height(12.dp))
        
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(24.dp))
                .background(MaterialTheme.colorScheme.surface)
                .padding(20.dp)
        ) {
            if (isGenerating) {
                CircularProgressIndicator(modifier = Modifier.size(24.dp).align(Alignment.Center))
            } else {
                Text(
                    summary ?: "还没有足够的足迹数据来生成洞察，继续探索吧！",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.8f),
                    lineHeight = 22.sp
                )
            }
        }
    }
}

@Composable
fun ActivityRankCard(items: List<ActivityRankItem>) {
    Column(modifier = Modifier.fillMaxWidth()) {
        LabelWithIcon("活动分布", Icons.Default.BarChart)
        Spacer(Modifier.height(12.dp))
        
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(24.dp))
                .background(MaterialTheme.colorScheme.surface)
                .padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            if (items.isEmpty()) {
                Text("暂无数据", style = MaterialTheme.typography.bodyMedium, color = Color.Gray)
            } else {
                items.take(5).forEach { item ->
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Box(
                            modifier = Modifier
                                .size(32.dp)
                                .clip(RoundedCornerShape(8.dp))
                                .background(Color(android.graphics.Color.parseColor(item.colorHex)).copy(alpha = 0.2f)),
                            contentAlignment = Alignment.Center
                        ) {
                            // Icon placeholder
                            Icon(Icons.Default.Place, null, modifier = Modifier.size(16.dp), tint = Color(android.graphics.Color.parseColor(item.colorHex)))
                        }
                        Spacer(Modifier.width(12.dp))
                        Text(item.name, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.weight(1f))
                        Text("${item.count}次", style = MaterialTheme.typography.labelLarge, fontWeight = FontWeight.Bold)
                    }
                }
            }
        }
    }
}

@Composable
fun TrendChartCard(points: List<TrendPoint>) {
    Column(modifier = Modifier.fillMaxWidth()) {
        LabelWithIcon("活跃趋势", Icons.Default.Timeline)
        Spacer(Modifier.height(12.dp))
        
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(180.dp)
                .clip(RoundedCornerShape(24.dp))
                .background(MaterialTheme.colorScheme.surface)
                .padding(20.dp),
            contentAlignment = Alignment.Center
        ) {
            Text("趋势图表开发中...", color = Color.Gray, style = MaterialTheme.typography.bodySmall)
        }
    }
}

@Composable
fun LabelWithIcon(label: String, icon: ImageVector) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, null, modifier = Modifier.size(18.dp), tint = MaterialTheme.colorScheme.primary)
        Spacer(Modifier.width(8.dp))
        Text(label, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Bold)
    }
}
