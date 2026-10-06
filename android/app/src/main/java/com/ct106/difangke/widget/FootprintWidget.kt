package com.ct106.difangke.widget

import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.datastore.preferences.core.intPreferencesKey
import androidx.datastore.preferences.core.longPreferencesKey
import androidx.glance.ColorFilter
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.Image
import androidx.glance.ImageProvider
import androidx.glance.LocalContext
import androidx.glance.LocalSize
import androidx.glance.action.ActionParameters
import androidx.glance.action.actionParametersOf
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.SizeMode
import androidx.glance.appwidget.action.ActionCallback
import androidx.glance.appwidget.action.actionRunCallback
import androidx.glance.appwidget.action.actionStartActivity
import androidx.glance.appwidget.appWidgetBackground
import androidx.glance.appwidget.cornerRadius
import androidx.glance.appwidget.provideContent
import androidx.glance.appwidget.state.getAppWidgetState
import androidx.glance.appwidget.state.updateAppWidgetState
import androidx.glance.background
import androidx.glance.color.ColorProvider
import androidx.glance.currentState
import androidx.glance.layout.Alignment
import androidx.glance.layout.Box
import androidx.glance.layout.Column
import androidx.glance.layout.ContentScale
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.layout.size
import androidx.glance.layout.width
import androidx.glance.state.GlanceStateDefinition
import androidx.glance.state.PreferencesGlanceStateDefinition
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import com.ct106.difangke.MainActivity
import com.ct106.difangke.R

/**
 * 主屏小组件「今日足迹」（对应 iOS DFKFootprintWidget）。
 *
 * - 2×2 / 4×2 / 4×4 响应式布局
 * - ◀ ▶ 在 0..-6 天之间切换（Glance state），右上角刷新
 * - 点击打开 MainActivity，并携带 [EXTRA_DATE]（当天 00:00 的毫秒时间戳）
 */
class FootprintWidget : GlanceAppWidget() {

    companion object {
        /** Long extra (epoch millis of the day's start) passed to MainActivity on tap. */
        const val EXTRA_DATE = "date"

        const val MIN_OFFSET = -6

        val KEY_DAY_OFFSET = intPreferencesKey("widget_day_offset")
        val KEY_REFRESH_TICK = longPreferencesKey("widget_refresh_tick")

        private val SMALL = DpSize(110.dp, 110.dp)
        private val MEDIUM = DpSize(250.dp, 110.dp)
        private val LARGE = DpSize(250.dp, 250.dp)
    }

    override val sizeMode: SizeMode = SizeMode.Responsive(setOf(SMALL, MEDIUM, LARGE))

    override val stateDefinition: GlanceStateDefinition<*> = PreferencesGlanceStateDefinition

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val state = getAppWidgetState(context, PreferencesGlanceStateDefinition, id)
        val initialOffset = state[KEY_DAY_OFFSET] ?: 0
        val preloaded = WidgetDataLoader.load(context, initialOffset)

        provideContent {
            val offset = (currentState(KEY_DAY_OFFSET) ?: 0).coerceIn(MIN_OFFSET, 0)
            val tick = currentState(KEY_REFRESH_TICK) ?: 0L
            val data by produceState(
                initialValue = preloaded.takeIf { it.dayOffset == offset },
                offset, tick
            ) {
                value = WidgetDataLoader.load(context, offset)
            }
            WidgetContent(data, offset)
        }
    }
}

class FootprintWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = FootprintWidget()

    override fun onEnabled(context: Context) {
        super.onEnabled(context)
        FootprintWidgetUpdater.schedulePeriodic(context)
    }

    override fun onDisabled(context: Context) {
        super.onDisabled(context)
        FootprintWidgetUpdater.cancelPeriodic(context)
    }
}

// ── Actions ──────────────────────────────────────────────────────────

private val OffsetDeltaKey = ActionParameters.Key<Int>("delta")

class ShiftDayAction : ActionCallback {
    override suspend fun onAction(context: Context, glanceId: GlanceId, parameters: ActionParameters) {
        val delta = parameters[OffsetDeltaKey] ?: 0
        updateAppWidgetState(context, glanceId) { prefs ->
            val current = prefs[FootprintWidget.KEY_DAY_OFFSET] ?: 0
            prefs[FootprintWidget.KEY_DAY_OFFSET] = (current + delta).coerceIn(FootprintWidget.MIN_OFFSET, 0)
        }
        FootprintWidget().update(context, glanceId)
    }
}

class RefreshWidgetAction : ActionCallback {
    override suspend fun onAction(context: Context, glanceId: GlanceId, parameters: ActionParameters) {
        updateAppWidgetState(context, glanceId) { prefs ->
            prefs[FootprintWidget.KEY_REFRESH_TICK] = System.currentTimeMillis()
        }
        FootprintWidget().update(context, glanceId)
    }
}

// ── UI ───────────────────────────────────────────────────────────────

private val Accent = Color(0xFF00A0AC)
private val bgColor = ColorProvider(day = Color(0xFFF7F7F2), night = Color(0xFF161819))
private val pillColor = ColorProvider(day = Color(0xD9FFFFFF), night = Color(0xB32C2C2E))
private val mainColor = ColorProvider(day = Accent, night = Color.White)
private val primaryText = ColorProvider(day = Color(0xD9000000), night = Color(0xF2FFFFFF))
private val secondaryText = ColorProvider(day = Color(0x8C000000), night = Color(0x99FFFFFF))

private enum class WidgetLayout { SMALL, MEDIUM, LARGE }

@Composable
private fun WidgetContent(data: WidgetDayData?, offset: Int) {
    val context = LocalContext.current
    val size = LocalSize.current
    val layout = when {
        size.width >= 240.dp && size.height >= 240.dp -> WidgetLayout.LARGE
        size.width >= 240.dp -> WidgetLayout.MEDIUM
        else -> WidgetLayout.SMALL
    }
    val isSmall = layout == WidgetLayout.SMALL
    val dayStart = data?.dayStartMillis ?: WidgetDataLoader.dayStart(offset)
    val title = data?.title ?: WidgetDataLoader.titleFor(offset, dayStart)

    val openIntent = Intent(context, MainActivity::class.java).apply {
        flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        putExtra(FootprintWidget.EXTRA_DATE, dayStart)
    }

    Box(
        modifier = GlanceModifier
            .fillMaxSize()
            .appWidgetBackground()
            .cornerRadius(20.dp)
            .background(bgColor)
            .clickable(actionStartActivity(openIntent))
    ) {
        when (layout) {
            WidgetLayout.SMALL -> {
                TrackArea(data, GlanceModifier.fillMaxSize(), size.width, size.height, isSmall = true)
                Column(modifier = GlanceModifier.fillMaxSize().padding(10.dp)) {
                    TopBar(title, isSmall = true)
                    Spacer(GlanceModifier.defaultWeight())
                    Row(modifier = GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                        NavButton(offset, back = true, isSmall = true)
                        Box(modifier = GlanceModifier.defaultWeight(), contentAlignment = Alignment.Center) {
                            if (data != null && !data.isEmpty) {
                                Text(
                                    "${data.placeCount} 个地点",
                                    style = TextStyle(color = secondaryText, fontSize = 11.sp, fontWeight = FontWeight.Medium)
                                )
                            }
                        }
                        NavButton(offset, back = false, isSmall = true)
                    }
                }
            }
            WidgetLayout.MEDIUM -> {
                Row(modifier = GlanceModifier.fillMaxSize()) {
                    Column(modifier = GlanceModifier.width(size.width * 0.45f).padding(12.dp)) {
                        TitlePill(title, isSmall = false)
                        Spacer(GlanceModifier.height(6.dp))
                        Stats(data, compact = true)
                        Spacer(GlanceModifier.defaultWeight())
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            NavButton(offset, back = true, isSmall = false)
                            Spacer(GlanceModifier.width(8.dp))
                            NavButton(offset, back = false, isSmall = false)
                        }
                    }
                    Box(modifier = GlanceModifier.defaultWeight().fillMaxSize()) {
                        TrackArea(data, GlanceModifier.fillMaxSize(), size.width * 0.55f, size.height, isSmall = false)
                        Box(modifier = GlanceModifier.fillMaxSize().padding(10.dp), contentAlignment = Alignment.TopEnd) {
                            RefreshButton()
                        }
                    }
                }
            }
            WidgetLayout.LARGE -> {
                Column(modifier = GlanceModifier.fillMaxSize().padding(12.dp)) {
                    TopBar(title, isSmall = false)
                    Spacer(GlanceModifier.height(6.dp))
                    Stats(data, compact = false)
                    Box(modifier = GlanceModifier.defaultWeight().fillMaxWidth()) {
                        TrackArea(data, GlanceModifier.fillMaxSize(), size.width - 24.dp, size.height - 140.dp, isSmall = false)
                    }
                    Row(modifier = GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                        NavButton(offset, back = true, isSmall = false)
                        Box(modifier = GlanceModifier.defaultWeight(), contentAlignment = Alignment.Center) {
                            val latest = data?.latestPlaceName
                            if (latest != null) {
                                Text(
                                    "最近：$latest",
                                    maxLines = 1,
                                    style = TextStyle(color = secondaryText, fontSize = 12.sp)
                                )
                            }
                        }
                        NavButton(offset, back = false, isSmall = false)
                    }
                }
            }
        }
    }
}

@Composable
private fun TopBar(title: String, isSmall: Boolean) {
    Row(modifier = GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        TitlePill(title, isSmall)
        Spacer(GlanceModifier.defaultWeight())
        RefreshButton()
    }
}

@Composable
private fun TitlePill(title: String, isSmall: Boolean) {
    Box(
        modifier = GlanceModifier
            .background(pillColor)
            .cornerRadius(10.dp)
            .padding(horizontal = 10.dp, vertical = 6.dp)
    ) {
        Text(
            title,
            maxLines = 1,
            style = TextStyle(color = mainColor, fontSize = if (isSmall) 13.sp else 15.sp, fontWeight = FontWeight.Bold)
        )
    }
}

@Composable
private fun Stats(data: WidgetDayData?, compact: Boolean) {
    if (data == null) {
        Text("加载中…", style = TextStyle(color = secondaryText, fontSize = 12.sp))
        return
    }
    Column {
        Row(verticalAlignment = Alignment.Bottom) {
            Text(
                "${data.placeCount}",
                style = TextStyle(color = primaryText, fontSize = if (compact) 22.sp else 26.sp, fontWeight = FontWeight.Bold)
            )
            Text(" 个地点  ", style = TextStyle(color = secondaryText, fontSize = 12.sp))
            if (!compact) {
                Text(
                    "里程 ${data.mileageText}",
                    style = TextStyle(color = secondaryText, fontSize = 12.sp)
                )
            }
        }
        if (compact) {
            Text("里程 ${data.mileageText}", maxLines = 1, style = TextStyle(color = secondaryText, fontSize = 12.sp))
            data.latestPlaceName?.let {
                Text(it, maxLines = 1, style = TextStyle(color = primaryText, fontSize = 12.sp, fontWeight = FontWeight.Medium))
            }
        }
    }
}

@Composable
private fun TrackArea(
    data: WidgetDayData?,
    modifier: GlanceModifier,
    widthDp: androidx.compose.ui.unit.Dp,
    heightDp: androidx.compose.ui.unit.Dp,
    isSmall: Boolean
) {
    val context = LocalContext.current
    val isDark = (context.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) ==
        Configuration.UI_MODE_NIGHT_YES
    val density = context.resources.displayMetrics.density
    // Keep the bitmap well under the RemoteViews memory budget.
    val scale = min(density, 2f)
    val wPx = (widthDp.value * scale).toInt()
    val hPx = (heightDp.value * scale).toInt()
    val bitmap = remember(data, wPx, hPx, isDark) {
        data?.let { WidgetDataLoader.renderTrack(context, it, wPx, hPx, isDark) }
    }
    Box(modifier = modifier, contentAlignment = Alignment.Center) {
        if (bitmap != null) {
            Image(
                provider = ImageProvider(bitmap),
                contentDescription = "足迹轨迹",
                contentScale = ContentScale.Fit,
                modifier = GlanceModifier.fillMaxSize()
            )
        } else if (data != null) {
            Text(
                if (data.dayOffset == 0) "今天还没有足迹" else "这一天没有足迹",
                style = TextStyle(color = secondaryText, fontSize = if (isSmall) 10.sp else 12.sp)
            )
        }
    }
}

private fun min(a: Float, b: Float) = if (a < b) a else b

@Composable
private fun NavButton(offset: Int, back: Boolean, isSmall: Boolean) {
    val visible = if (back) offset > FootprintWidget.MIN_OFFSET else offset < 0
    val dim = if (isSmall) 28.dp else 32.dp
    if (!visible) {
        Spacer(GlanceModifier.size(dim))
        return
    }
    Box(
        modifier = GlanceModifier
            .size(dim)
            .background(pillColor)
            .cornerRadius(dim / 2)
            .clickable(
                actionRunCallback<ShiftDayAction>(
                    actionParametersOf(OffsetDeltaKey to if (back) -1 else 1)
                )
            ),
        contentAlignment = Alignment.Center
    ) {
        Image(
            provider = ImageProvider(if (back) R.drawable.ic_widget_chevron_left else R.drawable.ic_widget_chevron_right),
            contentDescription = if (back) "前一天" else "后一天",
            colorFilter = ColorFilter.tint(mainColor),
            modifier = GlanceModifier.size(if (isSmall) 14.dp else 16.dp)
        )
    }
}

@Composable
private fun RefreshButton() {
    Box(
        modifier = GlanceModifier
            .size(28.dp)
            .background(pillColor)
            .cornerRadius(14.dp)
            .clickable(actionRunCallback<RefreshWidgetAction>()),
        contentAlignment = Alignment.Center
    ) {
        Image(
            provider = ImageProvider(R.drawable.ic_widget_refresh),
            contentDescription = "刷新",
            colorFilter = ColorFilter.tint(mainColor),
            modifier = GlanceModifier.size(14.dp)
        )
    }
}
