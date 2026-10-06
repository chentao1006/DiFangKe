package com.ct106.difangke.ui.share

import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.rememberTransformableState
import androidx.compose.foundation.gestures.transformable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Share
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.core.content.FileProvider
import com.ct106.difangke.DiFangKeApp
import com.ct106.difangke.service.OpenAIService
import com.ct106.difangke.ui.theme.DfkAccent
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.io.FileOutputStream
import java.util.UUID

private val shareTitleStyles = listOf("轻松口语", "有画面感", "俏皮有梗", "简洁有力", "温暖治愈", "旅行感")

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun ShareCardPreviewScreen(request: ShareCardRequest, onDismiss: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val prefs = remember { DiFangKeApp.instance.preferences }
    val isAiEnabled by prefs.isAiEnabled.collectAsState(initial = false)

    var payload by remember(request) { mutableStateOf<SharePayload?>(null) }
    var loadFailed by remember(request) { mutableStateOf(false) }
    var theme by remember { mutableStateOf(ShareCardTheme.LIGHT) }
    var rendered by remember { mutableStateOf<Bitmap?>(null) }
    var isRendering by remember { mutableStateOf(false) }
    var titleWasEdited by remember(request) { mutableStateOf(false) }
    var isGeneratingTitle by remember { mutableStateOf(false) }
    var hasRequestedAutoTitle by remember(request) { mutableStateOf(false) }
    var showAiAlert by remember { mutableStateOf(false) }
    var pendingApplyDirectly by remember { mutableStateOf<Boolean?>(null) }
    var showTextEditor by remember { mutableStateOf(false) }
    var editingText by remember { mutableStateOf("") }

    LaunchedEffect(request) {
        val loaded = runCatching { ShareCardFactory.load(context.applicationContext, request) }.getOrNull()
        if (loaded == null) loadFailed = true else payload = loaded
    }

    // Re-render whenever content or theme change; rendering is pure CPU work.
    LaunchedEffect(payload, theme) {
        val current = payload ?: return@LaunchedEffect
        rendered = withContext(Dispatchers.Default) {
            runCatching { ShareCardRenderer.render(context.applicationContext, current, theme) }.getOrNull()
        }
    }

    // iOS refreshSelectedMap: re-frame the map around the included places.
    val includedKey = payload?.takeIf { it.kind == ShareCardKind.TIMELINE }?.entries?.map { it.isIncluded }
    var hasToggled by remember(request) { mutableStateOf(false) }
    LaunchedEffect(includedKey) {
        val current = payload ?: return@LaunchedEffect
        if (!hasToggled || current.kind != ShareCardKind.TIMELINE) return@LaunchedEffect
        delay(350)
        val map = ShareCardFactory.refreshedTimelineMap(current)
        payload = payload?.copy(
            contentMap = map,
            backgroundMap = map,
            coordinates = current.includedEntries.mapNotNull { it.coordinate }
        )
    }

    fun generateTitle(applyDirectly: Boolean) {
        val current = payload ?: return
        if (!isAiEnabled) {
            pendingApplyDirectly = applyDirectly
            showAiAlert = true
            return
        }
        if (isGeneratingTitle) return
        isGeneratingTitle = true
        val prompt = shareTitlePrompt(current)
        scope.launch {
            val title = OpenAIService.shared.getCustomSummary(prompt)
            isGeneratingTitle = false
            val single = title?.lines()?.joinToString("")?.trim().orEmpty()
            if (single.isEmpty()) return@launch
            if (applyDirectly) {
                titleWasEdited = true
                payload = payload?.copy(title = single)
            } else {
                editingText = single
            }
        }
    }

    LaunchedEffect(payload != null, isAiEnabled) {
        if (payload != null && isAiEnabled && !hasRequestedAutoTitle) {
            hasRequestedAutoTitle = true
            generateTitle(applyDirectly = true)
        }
    }

    fun toggleEntry(id: String, included: Boolean) {
        val current = payload ?: return
        hasToggled = true
        val entries = current.entries.map { if (it.id == id) it.copy(isIncluded = included) else it }
        var updated = current.copy(entries = entries)
        if (!titleWasEdited) {
            val count = entries.count { it.isIncluded }
            updated = updated.copy(title = if (count == 0) "这段时间还没有足迹" else "这段时间去了 $count 个地方")
        }
        payload = updated
    }

    fun share() {
        val current = payload ?: return
        isRendering = true
        scope.launch {
            val uri = withContext(Dispatchers.IO) {
                runCatching {
                    val bitmap = ShareCardRenderer.render(context.applicationContext, current, theme)
                    writeShareImage(context, bitmap)
                }.getOrNull()
            }
            isRendering = false
            if (uri != null) {
                val intent = Intent(Intent.ACTION_SEND).apply {
                    type = "image/jpeg"
                    putExtra(Intent.EXTRA_STREAM, uri)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }
                context.startActivity(Intent.createChooser(intent, "分享给朋友"))
            }
        }
    }

    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)
    ) {
        Scaffold(
            topBar = {
                CenterAlignedTopAppBar(
                    title = { Text("分享预览", fontWeight = FontWeight.SemiBold) },
                    actions = {
                        IconButton(onClick = onDismiss) { Icon(Icons.Default.Close, contentDescription = "关闭") }
                    }
                )
            }
        ) { padding ->
            Column(Modifier.padding(padding).fillMaxSize()) {
                Box(
                    Modifier.weight(1f).fillMaxWidth().background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f)),
                    contentAlignment = Alignment.TopCenter
                ) {
                    val bitmap = rendered
                    when {
                        loadFailed -> Text("无法生成分享卡片", Modifier.align(Alignment.Center), color = MaterialTheme.colorScheme.onSurfaceVariant)
                        payload == null || bitmap == null -> Column(
                            Modifier.align(Alignment.Center),
                            horizontalAlignment = Alignment.CenterHorizontally
                        ) {
                            CircularProgressIndicator()
                            Spacer(Modifier.height(12.dp))
                            Text("正在生成分享卡片...", color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                        else -> ZoomableCardPreview(bitmap)
                    }
                }
                val current = payload
                if (current != null) {
                    Surface(tonalElevation = 2.dp) {
                        Column(Modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                            TitleEditorRow(
                                title = current.title,
                                isGenerating = isGeneratingTitle,
                                onEdit = { editingText = current.title; showTextEditor = true },
                                onGenerate = { generateTitle(applyDirectly = true) }
                            )
                            if (current.kind == ShareCardKind.TIMELINE && current.entries.isNotEmpty()) {
                                LazyColumn(Modifier.heightIn(max = 156.dp)) {
                                    items(current.entries, key = { it.id }) { entry ->
                                        Row(
                                            Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 4.dp),
                                            verticalAlignment = Alignment.CenterVertically
                                        ) {
                                            Column(Modifier.weight(1f)) {
                                                Text(entry.title, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                                Text(entry.time, fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                            }
                                            Switch(checked = entry.isIncluded, onCheckedChange = { toggleEntry(entry.id, it) })
                                        }
                                    }
                                }
                            }
                            SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                                ShareCardTheme.entries.forEachIndexed { index, option ->
                                    SegmentedButton(
                                        selected = theme == option,
                                        onClick = { theme = option },
                                        shape = SegmentedButtonDefaults.itemShape(index, ShareCardTheme.entries.size)
                                    ) { Text(option.title) }
                                }
                            }
                            Button(
                                onClick = ::share,
                                enabled = !isRendering,
                                modifier = Modifier.fillMaxWidth(),
                                colors = ButtonDefaults.buttonColors(containerColor = DfkAccent)
                            ) {
                                Icon(Icons.Default.Share, null, Modifier.size(18.dp))
                                Spacer(Modifier.width(8.dp))
                                Text(if (isRendering) "生成中..." else "分享给朋友")
                            }
                        }
                    }
                }
            }
        }
    }

    if (showTextEditor) {
        AlertDialog(
            onDismissRequest = { showTextEditor = false },
            title = { Text("修改文字") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    OutlinedTextField(value = editingText, onValueChange = { editingText = it }, modifier = Modifier.fillMaxWidth())
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                        OutlinedButton(onClick = { generateTitle(applyDirectly = false) }, enabled = !isGeneratingTitle) {
                            Icon(Icons.Default.AutoAwesome, null, Modifier.size(16.dp))
                            Spacer(Modifier.width(6.dp))
                            Text(if (isGeneratingTitle) "生成中..." else "AI 生成")
                        }
                    }
                }
            },
            dismissButton = { TextButton(onClick = { showTextEditor = false }) { Text("取消") } },
            confirmButton = {
                TextButton(onClick = {
                    val trimmed = editingText.trim()
                    if (trimmed.isNotEmpty()) {
                        titleWasEdited = true
                        payload = payload?.copy(title = trimmed)
                        showTextEditor = false
                    }
                }) { Text("保存") }
            }
        )
    }

    if (showAiAlert) {
        AlertDialog(
            onDismissRequest = { showAiAlert = false; pendingApplyDirectly = null },
            title = { Text("开启 AI 智能助手") },
            text = { Text("请先在设置中开启 AI 智能辅助，才能生成分享标题。") },
            confirmButton = {
                TextButton(onClick = {
                    showAiAlert = false
                    val apply = pendingApplyDirectly ?: true
                    pendingApplyDirectly = null
                    scope.launch {
                        prefs.setAiEnabled(true)
                        // The collected flag updates asynchronously; call through directly.
                        val current = payload ?: return@launch
                        isGeneratingTitle = true
                        val title = OpenAIService.shared.getCustomSummary(shareTitlePrompt(current))
                        isGeneratingTitle = false
                        val single = title?.lines()?.joinToString("")?.trim().orEmpty()
                        if (single.isNotEmpty()) {
                            if (apply) { titleWasEdited = true; payload = payload?.copy(title = single) } else editingText = single
                        }
                    }
                }) { Text("立刻开启") }
            },
            dismissButton = { TextButton(onClick = { showAiAlert = false; pendingApplyDirectly = null }) { Text("暂时不用") } }
        )
    }
}

@Composable
private fun TitleEditorRow(title: String, isGenerating: Boolean, onEdit: () -> Unit, onGenerate: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.6f))
            .padding(horizontal = 12.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Column(Modifier.weight(1f).clickable(onClick = onEdit)) {
            Text("标题", fontSize = 12.sp, fontWeight = FontWeight.Medium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Text(
                title.ifEmpty { "修改标题" },
                fontSize = 16.sp,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.alpha(if (isGenerating) 0.42f else 1f)
            )
        }
        if (isGenerating) {
            CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp, color = DfkAccent)
        } else {
            IconButton(onClick = onGenerate) { Icon(Icons.Default.AutoAwesome, contentDescription = "AI 生成", tint = DfkAccent) }
        }
    }
}

/** Fit-to-height by default; pinch or tap to expand to full width (iOS preview zoom). */
@Composable
private fun ZoomableCardPreview(bitmap: Bitmap) {
    BoxWithConstraints(Modifier.fillMaxSize().padding(horizontal = 14.dp, vertical = 6.dp)) {
        val density = LocalDensity.current
        val availableWidth = maxWidth
        val availableHeight = maxHeight
        val aspect = bitmap.height.toFloat() / bitmap.width
        val fitZoom = remember(bitmap.width, bitmap.height, availableWidth, availableHeight) {
            with(density) { (availableHeight.toPx() / (availableWidth.toPx() * aspect)).coerceAtMost(1f) }
        }
        var zoom by remember(fitZoom) { mutableFloatStateOf(fitZoom) }
        val transform = rememberTransformableState { zoomChange, _, _ ->
            zoom = (zoom * zoomChange).coerceIn(fitZoom, 1f)
        }
        val image = remember(bitmap) { bitmap.asImageBitmap() }
        Box(
            Modifier.fillMaxSize()
                .transformable(transform)
                .verticalScroll(rememberScrollState())
                .pointerInput(fitZoom) {
                    detectTapGestures { zoom = if (kotlin.math.abs(zoom - 1f) >= 0.02f) 1f else fitZoom }
                },
            contentAlignment = Alignment.TopCenter
        ) {
            Image(
                bitmap = image,
                contentDescription = "分享卡片预览",
                contentScale = ContentScale.FillWidth,
                modifier = Modifier
                    .width(availableWidth * zoom)
                    .aspectRatio(1f / aspect)
                    .shadow(10.dp)
            )
        }
    }
}

private fun writeShareImage(context: Context, bitmap: Bitmap): android.net.Uri {
    val directory = File(context.cacheDir, "share").apply { mkdirs() }
    directory.listFiles()?.filter { System.currentTimeMillis() - it.lastModified() > 24 * 3600_000L }?.forEach { it.delete() }
    val file = File(directory, "difangke-share-${UUID.randomUUID()}.jpg")
    FileOutputStream(file).use { bitmap.compress(Bitmap.CompressFormat.JPEG, 88, it) }
    return FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
}

// ── AI share title (iOS generateShareTitle, prompt verbatim) ─────────────────

private fun shareTitlePrompt(payload: SharePayload): String {
    val facts = payload.includedEntries.joinToString("\n") { entry ->
        listOf(entry.time, entry.title, entry.tag, entry.detail)
            .mapNotNull { it?.trim() }
            .filter { it.isNotEmpty() }
            .joinToString("｜")
    }
    val transports = ShareCardFactory.transportFacts(payload.mapTransports)
    val plans = ""
    return """
为一张地方客分享卡片写一个适合传播的中文标题。
请随机采用“${shareTitleStyles.random()}”风格，标题要自然、有记忆点，控制在 8 到 22 个字，只输出标题本身，不要引号、解释、标签或换行。标题绝对不要包含日期、年份、月份、几号、星期、今天、昨天、明天等任何日期表达。
必须以提供的时间、地点、活动、交通等事实为依据；交通信息若没有明确提供，绝不能虚构交通方式或行程。不要编造心情、人物、事件或具体细节。不要罗列地点名称，要提炼行程或计划的主线，用一句话概括重点。

标题场景要求：
${shareTitleScenarioInstruction(payload.kind)}

分享类型：${shareKindName(payload.kind)}
时间范围：${payload.rangeText}
时间语境：${shareDurationDescription(payload)}
足迹与活动：
${facts.ifEmpty { "无" }}
交通：
${transports.ifEmpty { "无" }}
计划：
${plans.ifEmpty { "无" }}
""".trimIndent()
}

private fun shareKindName(kind: ShareCardKind): String = when (kind) {
    ShareCardKind.MOMENT -> "单次足迹"
    ShareCardKind.TIMELINE -> "时间线"
    ShareCardKind.STATS -> "生活统计"
}

private fun shareTitleScenarioInstruction(kind: ShareCardKind): String = when (kind) {
    ShareCardKind.STATS -> "这是一个统计时间区间内的生活总结，不是单日行程。必须基于所给时间范围概括整个统计周期，严禁写成“一日盘点”“一天”“今日”“当日”或任何单日叙事。"
    ShareCardKind.MOMENT, ShareCardKind.TIMELINE -> "这是已经发生的足迹或生活记录。标题应基于已提供的事实概括经历，不要虚构未发生的安排。"
}

private fun shareDurationDescription(payload: SharePayload): String {
    val range = payload.rangeText
    if (payload.kind == ShareCardKind.STATS) {
        return "统计周期为“$range”，应概括该时间区间的整体生活状态，不能按单日行程理解。"
    }
    val isDateRange = range.contains(" - ") || range.contains("至") || range.contains("~")
    if (!isDateRange) {
        return "单日行程。标题必须围绕当天的主线，禁止使用“这段时间”“近期”“一段旅程”等跨日措辞。"
    }
    return "多日行程。标题应概括整段行程的主线，不能逐日或逐地点罗列。"
}
