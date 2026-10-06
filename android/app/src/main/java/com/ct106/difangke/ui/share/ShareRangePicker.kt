package com.ct106.difangke.ui.share

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowLeft
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.ct106.difangke.ui.theme.DfkAccent
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale

/** iOS DFKTimelineShareRangePicker + DFKShareDateRangeCalendar. */
@Composable
internal fun ShareRangePickerContent(initialDate: Date, onPick: (Date, Date) -> Unit, onDismiss: () -> Unit) {
    val today = remember { ShareFormat.startOfDay(Date()) }
    var startDate by remember { mutableStateOf<Date?>(null) }
    var endDate by remember { mutableStateOf<Date?>(null) }
    var displayedMonth by remember {
        mutableStateOf(Calendar.getInstance().apply {
            time = ShareFormat.startOfDay(minOf(initialDate, Date())); set(Calendar.DAY_OF_MONTH, 1)
        }.time)
    }
    val monthFormatter = remember { SimpleDateFormat("yyyy年M月", Locale.SIMPLIFIED_CHINESE) }
    val dayFormatter = remember { SimpleDateFormat("M月d日", Locale.SIMPLIFIED_CHINESE) }

    fun select(day: Date) {
        val start = startDate
        when {
            start == null || endDate != null -> { startDate = day; endDate = null }
            day.before(start) -> startDate = day
            else -> endDate = day
        }
    }
    fun moveMonth(delta: Int) {
        val next = Calendar.getInstance().apply { time = displayedMonth; add(Calendar.MONTH, delta) }.time
        if (delta > 0 && next.after(today)) return
        displayedMonth = next
    }

    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(Modifier.fillMaxWidth(0.94f), shape = RoundedCornerShape(24.dp)) {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    IconButton(onClick = onDismiss) { Icon(Icons.Default.Close, contentDescription = "关闭") }
                    Text("选择分享日期", Modifier.weight(1f), fontWeight = FontWeight.SemiBold, fontSize = 17.sp,
                        textAlign = androidx.compose.ui.text.style.TextAlign.Center)
                    IconButton(
                        onClick = {
                            val start = startDate ?: return@IconButton
                            onPick(start, endDate ?: start)
                            onDismiss()
                        },
                        enabled = startDate != null
                    ) { Icon(Icons.Default.Check, contentDescription = "确定", tint = if (startDate != null) DfkAccent else Color.Gray) }
                }
                Row(
                    Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp))
                        .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.6f)).padding(vertical = 10.dp)
                ) {
                    listOf("起始日期" to startDate, "结束日期" to endDate).forEach { (label, date) ->
                        Column(Modifier.weight(1f).padding(horizontal = 14.dp)) {
                            Text(label, fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            Text(
                                date?.let(dayFormatter::format) ?: "请选择",
                                fontSize = 15.sp,
                                fontWeight = FontWeight.SemiBold,
                                color = if (date == null) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.onSurface
                            )
                        }
                    }
                }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    IconButton(onClick = { moveMonth(-1) }) { Icon(Icons.AutoMirrored.Filled.KeyboardArrowLeft, null) }
                    Text(monthFormatter.format(displayedMonth), Modifier.weight(1f), fontWeight = FontWeight.SemiBold,
                        textAlign = androidx.compose.ui.text.style.TextAlign.Center)
                    val canNext = Calendar.getInstance().apply { time = displayedMonth; add(Calendar.MONTH, 1) }.time.let { !it.after(today) }
                    IconButton(onClick = { moveMonth(1) }, enabled = canNext) { Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null) }
                }
                Row {
                    listOf("日", "一", "二", "三", "四", "五", "六").forEach {
                        Text(it, Modifier.weight(1f), fontSize = 12.sp, fontWeight = FontWeight.Medium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = androidx.compose.ui.text.style.TextAlign.Center)
                    }
                }
                val cells = remember(displayedMonth) {
                    val cal = Calendar.getInstance().apply { time = displayedMonth }
                    val leading = cal.get(Calendar.DAY_OF_WEEK) - 1
                    val days = cal.getActualMaximum(Calendar.DAY_OF_MONTH)
                    val list = MutableList<Date?>(leading) { null }
                    for (d in 1..days) list += Calendar.getInstance().apply { time = displayedMonth; set(Calendar.DAY_OF_MONTH, d) }.time
                    while (list.size % 7 != 0) list += null
                    list
                }
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    cells.chunked(7).forEach { week ->
                        Row {
                            week.forEach { day ->
                                Box(Modifier.weight(1f).height(38.dp), contentAlignment = Alignment.Center) {
                                    if (day != null) {
                                        val disabled = day.after(today)
                                        val isStart = startDate == day
                                        val isEnd = endDate == day
                                        val inRange = startDate != null && endDate != null && !day.before(startDate) && !day.after(endDate)
                                        if (inRange) {
                                            val highlight = DfkAccent.copy(alpha = 0.22f)
                                            Row(Modifier.fillMaxSize()) {
                                                Box(Modifier.weight(1f).fillMaxHeight().background(if (isStart && !isEnd) Color.Transparent else highlight))
                                                Box(Modifier.weight(1f).fillMaxHeight().background(if (isEnd && !isStart) Color.Transparent else highlight))
                                            }
                                        }
                                        Box(
                                            Modifier.size(38.dp).clip(CircleShape)
                                                .background(if (isStart || isEnd) DfkAccent else Color.Transparent)
                                                .clickable(enabled = !disabled) { select(day) },
                                            contentAlignment = Alignment.Center
                                        ) {
                                            Text(
                                                Calendar.getInstance().apply { time = day }.get(Calendar.DAY_OF_MONTH).toString(),
                                                fontSize = 15.sp,
                                                fontWeight = if (isStart || isEnd) FontWeight.Bold else FontWeight.Normal,
                                                color = when {
                                                    isStart || isEnd -> Color.White
                                                    disabled -> MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.35f)
                                                    else -> MaterialTheme.colorScheme.onSurface
                                                }
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                Text(
                    if (startDate == null) "先选起始日期；若不选结束日期，将只分享当天足迹。" else "分享会包含所选日期范围内的全部足迹。",
                    fontSize = 12.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }
    }
}
