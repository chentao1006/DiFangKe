package com.ct106.difangke.ui.screens.statistics

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowBack
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun StatisticsScreen(onBack: () -> Unit) {
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
                    text = "近7天活动时长",
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.Bold
                )
                Spacer(modifier = Modifier.height(16.dp))
                BarChartCanvas()
            }

            item {
                Text(
                    text = "交通方式占比",
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.Bold
                )
                Spacer(modifier = Modifier.height(16.dp))
                PieChartCanvas()
            }
        }
    }
}

@Composable
fun BarChartCanvas() {
    val barColor = MaterialTheme.colorScheme.primary
    val data = listOf(2f, 4f, 3f, 7f, 1f, 5f, 6f) // 小时数占位

    Canvas(
        modifier = Modifier
            .fillMaxWidth()
            .height(200.dp)
    ) {
        val width = size.width
        val height = size.height
        val maxData = data.maxOrNull() ?: 1f
        val barWidth = width / (data.size * 2f)

        data.forEachIndexed { index, value ->
            val barHeight = (value / maxData) * height
            val startX = index * 2 * barWidth + barWidth / 2
            
            drawRoundRect(
                color = barColor,
                topLeft = Offset(startX, height - barHeight),
                size = Size(barWidth, barHeight),
                cornerRadius = CornerRadius(8f, 8f)
            )
        }
    }
}

@Composable
fun PieChartCanvas() {
    val colors = listOf(Color(0xFF34C759), Color(0xFF007AFF), Color(0xFFFF9500), Color(0xFFFF2D55))
    val data = listOf(40f, 30f, 20f, 10f)

    Canvas(
        modifier = Modifier
            .fillMaxWidth()
            .height(200.dp)
    ) {
        val width = size.width
        val height = size.height
        val radius = height.coerceAtMost(width) / 2f
        val center = Offset(width / 2f, height / 2f)

        var startAngle = -90f
        val total = data.sum()

        data.forEachIndexed { index, value ->
            val sweepAngle = (value / total) * 360f
            
            drawArc(
                color = colors[index % colors.size],
                startAngle = startAngle,
                sweepAngle = sweepAngle,
                useCenter = false,
                topLeft = Offset(center.x - radius, center.y - radius),
                size = Size(radius * 2, radius * 2),
                style = Stroke(width = 60f)
            )
            
            startAngle += sweepAngle
        }
    }
}
