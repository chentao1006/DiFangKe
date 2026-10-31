package com.ct106.difangke.ui.screens.history

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.DirectionsWalk
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.ct106.difangke.ui.screens.statistics.reviewDetailCard
import com.ct106.difangke.ui.screens.statistics.reviewMaterial
import com.ct106.difangke.ui.theme.DfkAccent

private val iosOrange = Color(0xFFFF9500)
private val iosPurple = Color(0xFFAF52DE)
private val iosBlue = Color(0xFF007AFF)
private val iosGreen = Color(0xFF34C759)

/** iOS ReviewIntroductionView: shown once, cannot be swiped away. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ReviewIntroductionDialog(onFinish: () -> Unit) {
    Dialog(onDismissRequest = {}, properties = DialogProperties(usePlatformDefaultWidth = false, dismissOnBackPress = false, dismissOnClickOutside = false)) {
        Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
            Column(Modifier.fillMaxSize()) {
                CenterAlignedTopAppBar(title = { Text("认识回顾", fontWeight = FontWeight.Bold, fontSize = 17.sp) })
                Column(
                    Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(top = 12.dp, bottom = 24.dp),
                    verticalArrangement = Arrangement.spacedBy(20.dp),
                    horizontalAlignment = Alignment.CenterHorizontally
                ) {
                    Column(Modifier.padding(horizontal = 12.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        Box(Modifier.size(82.dp).clip(CircleShape).background(DfkAccent.copy(alpha = 0.12f)), contentAlignment = Alignment.Center) {
                            Icon(Icons.Default.BarChart, null, tint = DfkAccent, modifier = Modifier.size(42.dp))
                        }
                        Text("看见你的生活轨迹", fontSize = 22.sp, fontWeight = FontWeight.Bold)
                        Text(
                            "在生活地图回看去过的地点与交通轨迹，从真实停留中找到值得记住的片段，再用图表看懂活动和出行方式。",
                            fontSize = 17.sp,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            textAlign = TextAlign.Center
                        )
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        SampleCard("足迹节奏", Icons.Default.GridOn, Modifier.weight(1f)) { SampleBarChart() }
                        SampleCard("活动构成", Icons.Default.PieChart, Modifier.weight(1f)) { SampleDonutChart() }
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        SampleCard("生活地图", Icons.Default.Map, Modifier.weight(1f)) { SampleMapPreview() }
                        SampleCard("常用交通", Icons.Default.DirectionsCar, Modifier.weight(1f)) { SampleTransportPreview() }
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(18.dp)) {
                        listOf(Icons.Default.Map to "生活地图", Icons.Default.AutoAwesome to "值得记住", Icons.Default.BarChart to "数据故事").forEach { (icon, label) ->
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Icon(icon, null, tint = DfkAccent, modifier = Modifier.size(14.dp))
                                Spacer(Modifier.width(4.dp))
                                Text(label, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = DfkAccent, maxLines = 1)
                            }
                        }
                    }
                }
                Surface(tonalElevation = 3.dp) {
                    Button(
                        onClick = onFinish,
                        modifier = Modifier.fillMaxWidth().navigationBarsPadding().padding(horizontal = 20.dp, vertical = 10.dp).height(50.dp)
                    ) { Text("开始回顾", fontSize = 17.sp, fontWeight = FontWeight.SemiBold) }
                }
            }
        }
    }
}

@Composable
private fun SampleCard(title: String, icon: ImageVector, modifier: Modifier, content: @Composable () -> Unit) {
    val shape = RoundedCornerShape(20.dp)
    Column(
        modifier
            .clip(shape)
            .background(reviewMaterial())
            .border(0.5.dp, MaterialTheme.colorScheme.onSurface.copy(alpha = 0.08f), shape)
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(icon, null, modifier = Modifier.size(15.dp))
            Spacer(Modifier.width(6.dp))
            Text(title, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, maxLines = 1)
        }
        Box(Modifier.fillMaxWidth().height(76.dp)) { content() }
    }
}

@Composable
private fun SampleBarChart() {
    val values = listOf(0.35f, 0.62f, 0.48f, 0.82f, 0.56f, 0.95f, 0.72f)
    Row(Modifier.fillMaxSize(), horizontalArrangement = Arrangement.spacedBy(5.dp), verticalAlignment = Alignment.Bottom) {
        values.forEachIndexed { index, value ->
            Box(
                Modifier.weight(1f).height((68 * value).dp).clip(RoundedCornerShape(3.dp))
                    .background(DfkAccent.copy(alpha = 0.4f + index * 0.07f))
            )
        }
    }
}

@Composable
private fun SampleDonutChart() {
    val track = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.12f)
    Box(Modifier.fillMaxSize().padding(4.dp), contentAlignment = Alignment.Center) {
        Canvas(Modifier.aspectRatio(1f).fillMaxHeight()) {
            val stroke = 13.dp.toPx()
            val inset = stroke / 2
            val arcSize = androidx.compose.ui.geometry.Size(size.width - stroke, size.height - stroke)
            drawArc(track, 0f, 360f, false, Offset(inset, inset), arcSize, style = Stroke(stroke))
            listOf(Triple(0f, 0.48f, DfkAccent), Triple(0.53f, 0.78f, iosOrange), Triple(0.83f, 0.96f, iosPurple)).forEach { (from, to, color) ->
                drawArc(color, -90f + from * 360, (to - from) * 360, false, Offset(inset, inset), arcSize,
                    style = Stroke(stroke, cap = StrokeCap.Round))
            }
        }
        Icon(Icons.AutoMirrored.Filled.DirectionsWalk, null, tint = DfkAccent, modifier = Modifier.size(18.dp))
    }
}

@Composable
private fun SampleMapPreview() {
    val points = listOf(Offset(0.06f, 0.72f), Offset(0.28f, 0.42f), Offset(0.52f, 0.62f), Offset(0.78f, 0.24f), Offset(0.94f, 0.4f))
    val badge = reviewDetailCard()
    BoxWithConstraints(Modifier.fillMaxSize()) {
        Canvas(Modifier.fillMaxSize()) {
            val path = Path()
            points.forEachIndexed { index, point ->
                val x = point.x * size.width
                val y = point.y * size.height
                if (index == 0) path.moveTo(x, y) else path.lineTo(x, y)
            }
            drawPath(path, DfkAccent, style = Stroke(
                3.dp.toPx(), cap = StrokeCap.Round, join = StrokeJoin.Round,
                pathEffect = PathEffect.dashPathEffect(floatArrayOf(6.dp.toPx(), 4.dp.toPx()))
            ))
        }
        points.forEachIndexed { index, point ->
            val icon = when (index) {
                1 -> Icons.Default.Restaurant
                3 -> Icons.Default.AccountBalance
                else -> Icons.Default.Place
            }
            Box(
                Modifier
                    .offset(x = maxWidth * point.x - 10.dp, y = maxHeight * point.y - 10.dp)
                    .size(20.dp)
                    .clip(CircleShape)
                    .background(badge),
                contentAlignment = Alignment.Center
            ) {
                Icon(icon, null, tint = if (index == 1) iosOrange else DfkAccent, modifier = Modifier.size(12.dp))
            }
        }
    }
}

@Composable
private fun SampleTransportPreview() {
    val items = listOf(Triple(Icons.Default.DirectionsCar, "18次", iosBlue), Triple(Icons.AutoMirrored.Filled.DirectionsWalk, "12次", DfkAccent), Triple(Icons.Default.Tram, "5次", iosGreen))
    Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(7.dp, Alignment.CenterVertically)) {
        items.forEach { (icon, value, color) ->
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(icon, null, tint = color, modifier = Modifier.width(18.dp).size(16.dp))
                Spacer(Modifier.width(7.dp))
                Box(Modifier.weight(1f).height(7.dp).clip(RoundedCornerShape(50)).background(color.copy(alpha = 0.8f)))
                Spacer(Modifier.width(7.dp))
                Text(value, fontSize = 11.sp, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}

/** iOS ReviewPhotoImportSuggestionView: offered once to users with few footprints. */
@Composable
fun ReviewPhotoImportSuggestionDialog(onStartImport: () -> Unit, onSkip: () -> Unit) {
    AlertDialog(
        onDismissRequest = {},
        properties = DialogProperties(dismissOnBackPress = false, dismissOnClickOutside = false),
        icon = {
            Box(Modifier.size(92.dp).clip(CircleShape).background(DfkAccent.copy(alpha = 0.12f)), contentAlignment = Alignment.Center) {
                Icon(Icons.Default.PhotoLibrary, null, tint = DfkAccent, modifier = Modifier.size(50.dp))
            }
        },
        title = { Text("把过去也补进回顾", fontWeight = FontWeight.Bold) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                Text(
                    "如果相册中的照片带有拍摄地点，可以把过去去过的地方整理成足迹，让回顾更完整。导入前可以先预览并选择。",
                    textAlign = TextAlign.Center,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
                Spacer(Modifier.height(8.dp))
                Button(onClick = onStartImport, modifier = Modifier.fillMaxWidth().height(50.dp)) {
                    Text("开始导入", fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
                }
                TextButton(onClick = onSkip, modifier = Modifier.heightIn(min = 36.dp)) {
                    Text("暂时跳过", fontWeight = FontWeight.SemiBold)
                }
            }
        },
        confirmButton = {}
    )
}
