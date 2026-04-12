package com.ct106.difangke.ui.screens.statistics

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowBack
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.ct106.difangke.data.model.TransportType

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun StatisticsScreen(
    onBack: () -> Unit,
    viewModel: StatisticsViewModel = viewModel()
) {
    val barData by viewModel.last7DaysData.collectAsState()
    val transportDist by viewModel.transportDistribution.collectAsState()

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("足迹统计") },
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
            verticalArrangement = Arrangement.spacedBy(24.dp)
        ) {
            item {
                Text(
                    text = "近7天停留时长 (小时)",
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.Bold
                )
                Spacer(modifier = Modifier.height(16.dp))
                if (barData.isNotEmpty()) {
                    BarChartCanvas(barData)
                } else {
                    Box(Modifier.height(200.dp).fillMaxWidth(), contentAlignment = androidx.compose.ui.Alignment.Center) {
                        Text("暂无数据", color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }

            item {
                Text(
                    text = "交通里程分布",
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.Bold
                )
                Spacer(modifier = Modifier.height(16.dp))
                if (transportDist.isNotEmpty()) {
                    PieChartCanvas(transportDist)
                } else {
                    Box(Modifier.height(200.dp).fillMaxWidth(), contentAlignment = androidx.compose.ui.Alignment.Center) {
                        Text("暂无数据", color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
        }
    }
}

@Composable
fun BarChartCanvas(data: List<Float>) {
    val barColor = MaterialTheme.colorScheme.primary
    val labelColor = MaterialTheme.colorScheme.onSurfaceVariant

    Canvas(
        modifier = Modifier
            .fillMaxWidth()
            .height(200.dp)
    ) {
        val width = size.width
        val height = size.height
        val maxData = data.maxOrNull()?.coerceAtLeast(1f) ?: 1f
        val barSpacing = width / (data.size * 1.5f)
        val barWidth = barSpacing * 0.8f

        data.forEachIndexed { index, value ->
            val barHeight = (value / maxData) * height
            val startX = index * barSpacing + (barSpacing - barWidth) / 2
            
            drawRoundRect(
                color = barColor,
                topLeft = Offset(startX, height - barHeight),
                size = Size(barWidth, barHeight),
                cornerRadius = CornerRadius(12f, 12f)
            )
        }
    }
}

@Composable
fun PieChartCanvas(data: Map<TransportType, Float>) {
    val colors = listOf(Color(0xFF34C759), Color(0xFF007AFF), Color(0xFFFF9500), Color(0xFFFF2D55), Color(0xFF5856D6))
    val sortedData = data.values.toList()
    val total = sortedData.sum()

    Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(16.dp)) {
        Canvas(
            modifier = Modifier
                .size(180.dp)
        ) {
            val radius = size.minDimension / 2f
            val center = Offset(size.width / 2f, size.height / 2f)

            var startAngle = -90f

            data.values.forEachIndexed { index, value ->
                val sweepAngle = (value / total) * 360f
                
                drawArc(
                    color = colors[index % colors.size],
                    startAngle = startAngle,
                    sweepAngle = sweepAngle,
                    useCenter = false,
                    topLeft = Offset(center.x - radius + 20f, center.y - radius + 20f),
                    size = Size(radius * 2 - 40f, radius * 2 - 40f),
                    style = Stroke(width = 40f)
                )
                
                startAngle += sweepAngle
            }
        }
        
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            data.keys.forEachIndexed { index, type ->
                Row(verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
                    Box(Modifier.size(12.dp).background(colors[index % colors.size], CircleShape))
                    Spacer(Modifier.width(8.dp))
                    Text(type.localizedName, style = MaterialTheme.typography.bodySmall)
                }
            }
        }
    }
}
