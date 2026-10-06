package com.ct106.difangke.ui.screens.detail

import android.Manifest
import android.content.ContentValues
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import android.util.Size
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.CallMerge
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.core.content.ContextCompat
import androidx.lifecycle.viewmodel.compose.viewModel
import com.ct106.difangke.DiFangKeApp
import com.ct106.difangke.data.db.entity.ActivityTypeEntity
import com.ct106.difangke.data.db.entity.FootprintEntity
import com.ct106.difangke.data.db.entity.PlaceEntity
import com.ct106.difangke.data.prefs.AppPreferences
import com.ct106.difangke.service.PhotoAutoLinker
import com.ct106.difangke.ui.components.NearbyPlacePickerSheet
import com.ct106.difangke.ui.components.addFootprintMarkers
import com.ct106.difangke.ui.components.addImportantPlaceCircles
import com.ct106.difangke.ui.components.buildFootprintMapMarkers
import com.ct106.difangke.ui.components.getIconForName
import com.ct106.difangke.ui.screens.settings.ActivityTypeEditorDialog
import com.ct106.difangke.ui.share.ShareCardPreviewDialog
import com.ct106.difangke.ui.share.ShareCardRequest
import com.ct106.difangke.ui.shared.TimelineEditActions
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import java.text.SimpleDateFormat
import java.util.*

/** Full-screen route (NavGraph "footprint_detail/{id}") wrapping [FootprintDetailContent]. */
@Composable
fun FootprintDetailScreen(
    footprintId: String,
    onBack: () -> Unit
) {
    Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
        FootprintDetailContent(
            footprintId = footprintId,
            onDismiss = onBack,
            modifier = Modifier.fillMaxSize().statusBarsPadding(),
            showMap = true
        )
    }
}

/**
 * Reusable footprint detail (iOS FootprintModalView). Can be hosted full screen or inside a
 * ModalBottomSheet over the main map (pass [showMap] = false there). Every edit saves immediately.
 * [onDismiss] is also called after delete / ignore-place.
 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class, ExperimentalLayoutApi::class)
@Composable
fun FootprintDetailContent(
    footprintId: String,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier,
    showMap: Boolean = false,
    viewModel: FootprintDetailViewModel = viewModel(key = "footprint_detail_$footprintId")
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val footprint by viewModel.footprint.collectAsState()
    val isGone by viewModel.isGone.collectAsState()
    val activityTypes by viewModel.activityTypes.collectAsState()
    val allPlaces by viewModel.allPlaces.collectAsState()
    val suggested by viewModel.suggestedActivities.collectAsState()
    val mergePartner by viewModel.mergePartner.collectAsState()
    val isUpdatingAddress by viewModel.isUpdatingAddress.collectAsState()
    val autoLinkEnabled by remember { AppPreferences(context).isAutoPhotoLinkEnabled }.collectAsState(initial = true)

    var showPlacePicker by remember { mutableStateOf(false) }
    var showActivityPicker by remember { mutableStateOf(false) }
    var showActivityEditor by remember { mutableStateOf(false) }
    var showTimeAdjust by remember { mutableStateOf(false) }
    var showSplit by remember { mutableStateOf(false) }
    var showMergeAlert by remember { mutableStateOf(false) }
    var showIgnoreAlert by remember { mutableStateOf(false) }
    var showDeleteAlert by remember { mutableStateOf(false) }
    var showAddPlace by remember { mutableStateOf(false) }
    var showAddPhotoDialog by remember { mutableStateOf(false) }
    var photoToDelete by remember { mutableStateOf<String?>(null) }
    var viewerIndex by remember { mutableStateOf<Int?>(null) }
    var shareRequest by remember { mutableStateOf<ShareCardRequest?>(null) }
    var showFullMap by remember { mutableStateOf(false) }
    var hasGalleryAccess by remember { mutableStateOf(PhotoAutoLinker.hasGalleryAccess(context)) }

    LaunchedEffect(footprintId) { viewModel.loadFootprint(footprintId) }
    LaunchedEffect(isGone) { if (isGone && footprint != null) onDismiss() }
    LaunchedEffect(footprint?.footprintID, autoLinkEnabled) {
        if (footprint != null && autoLinkEnabled) viewModel.autoLinkPhotosIfEnabled()
    }

    // ── Photo pickers ──
    val galleryPicker = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris ->
        if (uris.isNotEmpty()) {
            uris.forEach { runCatching { context.contentResolver.takePersistableUriPermission(it, Intent.FLAG_GRANT_READ_URI_PERMISSION) } }
            viewModel.addPhotos(uris.map { it.toString() })
        }
    }
    var pendingCameraUri by remember { mutableStateOf<Uri?>(null) }
    val cameraLauncher = rememberLauncherForActivityResult(ActivityResultContracts.TakePicture()) { ok ->
        val uri = pendingCameraUri
        pendingCameraUri = null
        if (uri != null) {
            if (ok) viewModel.addPhotos(listOf(uri.toString()))
            else runCatching { context.contentResolver.delete(uri, null, null) }
        }
    }
    fun launchCamera() {
        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, "DFK_${System.currentTimeMillis()}.jpg")
            put(MediaStore.Images.Media.MIME_TYPE, "image/jpeg")
            put(MediaStore.Images.Media.DATE_TAKEN, System.currentTimeMillis())
        }
        val uri = runCatching { context.contentResolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values) }.getOrNull() ?: return
        pendingCameraUri = uri
        runCatching { cameraLauncher.launch(uri) }.onFailure { pendingCameraUri = null }
    }
    val writePermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted -> if (granted) launchCamera() }
    fun startCamera() {
        if (Build.VERSION.SDK_INT < 29 &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.WRITE_EXTERNAL_STORAGE) != android.content.pm.PackageManager.PERMISSION_GRANTED
        ) writePermission.launch(Manifest.permission.WRITE_EXTERNAL_STORAGE) else launchCamera()
    }
    val galleryPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        hasGalleryAccess = PhotoAutoLinker.hasGalleryAccess(context)
        if (hasGalleryAccess) viewModel.autoLinkPhotosIfEnabled().also {
            scope.launch {
                footprint?.let { fp -> PhotoAutoLinker.linkPhotos(context, DiFangKeApp.instance.database, fp) }
                viewModel.refresh()
            }
        }
    }

    val fp = footprint
    Column(modifier) {
        // ── Toolbar (iOS: star leading; share + close trailing) ──
        Row(Modifier.fillMaxWidth().padding(horizontal = 4.dp, vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            val highlighted = fp?.isHighlight == true
            IconButton(onClick = { viewModel.toggleHighlight() }, enabled = fp != null) {
                Icon(
                    if (highlighted) Icons.Default.Star else Icons.Default.StarBorder,
                    contentDescription = if (highlighted) "取消收藏" else "收藏",
                    tint = if (highlighted) Color(0xFFFFCC00) else MaterialTheme.colorScheme.onSurface
                )
            }
            Text("足迹详情", fontWeight = FontWeight.Bold, fontSize = 17.sp, textAlign = TextAlign.Center, modifier = Modifier.weight(1f))
            IconButton(onClick = { fp?.let { shareRequest = ShareCardRequest.Moment(it.footprintID) } }, enabled = fp != null) {
                Icon(Icons.Default.IosShare, contentDescription = "分享")
            }
            Box {
                var menu by remember { mutableStateOf(false) }
                IconButton(onClick = { menu = true }, enabled = fp != null) { Icon(Icons.Default.MoreHoriz, contentDescription = "更多") }
                DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                    DropdownMenuItem(text = { Text("调整时间") }, leadingIcon = { Icon(Icons.Default.Schedule, null) }, onClick = { menu = false; showTimeAdjust = true })
                    DropdownMenuItem(text = { Text("拆分足迹") }, leadingIcon = { Icon(Icons.Default.ContentCut, null) }, onClick = { menu = false; showSplit = true })
                    if (mergePartner != null) {
                        DropdownMenuItem(text = { Text("合并相邻足迹") }, leadingIcon = { Icon(Icons.AutoMirrored.Filled.CallMerge, null) }, onClick = { menu = false; showMergeAlert = true })
                    }
                    DropdownMenuItem(text = { Text("添加为重要地点") }, leadingIcon = { Icon(Icons.Default.StarOutline, null) }, onClick = { menu = false; showAddPlace = true })
                    DropdownMenuItem(text = { Text("忽略地点") }, leadingIcon = { Icon(Icons.Default.LocationOff, null) }, onClick = { menu = false; showIgnoreAlert = true })
                    DropdownMenuItem(
                        text = { Text("删除", color = MaterialTheme.colorScheme.error) },
                        leadingIcon = { Icon(Icons.Default.Delete, null, tint = MaterialTheme.colorScheme.error) },
                        onClick = { menu = false; showDeleteAlert = true }
                    )
                }
            }
            IconButton(onClick = onDismiss) { Icon(Icons.Default.Close, contentDescription = "关闭") }
        }

        if (fp == null) {
            Box(Modifier.fillMaxWidth().height(200.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
            return@Column
        }

        val activity = activityTypes.firstOrNull { it.id == fp.activityTypeValue }
        val matchedPlace = remember(fp, allPlaces) { matchedPlaceByAddress(fp, allPlaces) }
        val displayPlace = matchedPlace?.name ?: fp.address ?: "未知地点"

        Column(
            Modifier.fillMaxWidth().weight(1f, fill = false).verticalScroll(rememberScrollState()).padding(bottom = 30.dp)
        ) {
            // ── Address section ──
            Column(
                Modifier.fillMaxWidth().padding(horizontal = 24.dp).padding(top = 16.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                Icon(
                    imageVector = activity?.let { getIconForName(it.icon) } ?: Icons.Default.HelpOutline,
                    contentDescription = activity?.name ?: "选择活动类型",
                    tint = activity?.let { parseHexColor(it.colorHex) } ?: MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.size(50.dp).clip(RoundedCornerShape(12.dp)).clickable { showActivityPicker = true }
                )
                val geo = listOfNotNull(
                    fp.countryName?.trim()?.takeIf { it.isNotEmpty() },
                    fp.cityName?.trim()?.takeIf { it.isNotEmpty() }
                ).joinToString("·")
                if (geo.isNotEmpty()) Text(geo, fontSize = 13.sp, fontWeight = FontWeight.Medium, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)

                val placeText = if (isUpdatingAddress) "正在重新获取地址..." else displayPlace
                Row(
                    Modifier.clip(RoundedCornerShape(8.dp)).clickable { showPlacePicker = true }.padding(horizontal = 6.dp, vertical = 2.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text(
                        placeText,
                        fontSize = when (placeText.length) { in 0..10 -> 20.sp; in 11..16 -> 18.sp; in 17..24 -> 16.sp; else -> 15.sp },
                        fontWeight = if (placeText.length <= 16) FontWeight.Bold else FontWeight.SemiBold,
                        color = when {
                            isUpdatingAddress -> MaterialTheme.colorScheme.onSurface.copy(alpha = 0.5f)
                            matchedPlace != null -> Color(0xFFFF9500)
                            else -> MaterialTheme.colorScheme.onSurface
                        },
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                        textAlign = TextAlign.Center,
                        modifier = Modifier.weight(1f, fill = false)
                    )
                    Spacer(Modifier.width(6.dp))
                    Icon(Icons.Default.Edit, "修改地点", Modifier.size(13.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.42f))
                }

                Column(
                    Modifier.fillMaxWidth().clip(RoundedCornerShape(8.dp)).clickable { showTimeAdjust = true }.padding(vertical = 2.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(4.dp)
                ) {
                    Text(SimpleDateFormat("yyyy年M月d日 EEEE", Locale.CHINA).format(fp.date), fontSize = 15.sp, fontWeight = FontWeight.Medium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(footprintTimeRangeText(fp), fontSize = 20.sp, fontWeight = FontWeight.Bold)
                        Spacer(Modifier.width(6.dp))
                        Icon(Icons.Default.Edit, "调整足迹时间", Modifier.size(13.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.42f))
                    }
                    Text("停留 ${stayDurationText(fp.endTime.time - fp.startTime.time)}", fontSize = 15.sp, fontWeight = FontWeight.Medium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    val health = buildList {
                        fp.stepCount?.takeIf { it > 0 }?.let { add("$it 步") }
                        fp.walkingDistance?.takeIf { it > 0 }?.let { add(if (it >= 1000) String.format(Locale.CHINA, "%.1f 公里步行", it / 1000) else "${it.toInt()} 米步行") }
                        fp.floorsAscended?.takeIf { it > 0 }?.let { add("$it 层") }
                    }
                    if (health.isNotEmpty()) Text(health.joinToString(" · "), fontSize = 13.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }

            if (showMap) {
                Box(
                    Modifier.padding(horizontal = 24.dp).padding(top = 20.dp).fillMaxWidth().height(220.dp)
                        .clip(RoundedCornerShape(16.dp)).background(MaterialTheme.colorScheme.surfaceVariant)
                ) {
                    DetailMapView(fp, allPlaces, activityTypes)
                    FilledTonalIconButton(onClick = { showFullMap = true }, modifier = Modifier.align(Alignment.TopEnd).padding(10.dp)) {
                        Icon(Icons.Default.Fullscreen, contentDescription = "打开完整足迹地图")
                    }
                }
            }

            // ── Note ──
            Column(Modifier.padding(horizontal = 24.dp).padding(top = 20.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text("足迹备注", fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.fillMaxWidth(), textAlign = TextAlign.Center)
                ReasonEditor(fp.footprintID, fp.reason ?: "", onCommit = viewModel::saveReason)
            }

            // ── Photos ──
            val photos = footprintPhotoUris(fp)
            Column(Modifier.padding(horizontal = 24.dp).padding(top = 16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Row(Modifier.padding(start = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text("记录瞬间", fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Spacer(Modifier.weight(1f))
                    TextButton(onClick = { showAddPhotoDialog = true }, contentPadding = PaddingValues(horizontal = 8.dp)) {
                        Icon(Icons.Default.AddPhotoAlternate, null, Modifier.size(16.dp), tint = DfkAccent)
                        Spacer(Modifier.width(4.dp))
                        Text("添加", fontSize = 12.sp, fontWeight = FontWeight.Bold, color = DfkAccent)
                    }
                }
                if (photos.isEmpty()) {
                    if (autoLinkEnabled && !hasGalleryAccess) {
                        Column(
                            Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp)).background(Color(0xFF007AFF).copy(alpha = 0.06f))
                                .clickable { galleryPermission.launch(PhotoAutoLinker.requiredPermissions()) }.padding(16.dp),
                            verticalArrangement = Arrangement.spacedBy(10.dp)
                        ) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Icon(Icons.Default.PhotoLibrary, null, tint = Color(0xFF007AFF))
                                Spacer(Modifier.width(8.dp))
                                Text("开启自动关联照片", fontSize = 15.sp, fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f))
                                Icon(Icons.Default.ChevronRight, null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                            Text("授权相册后，地方客能自动识别并展示您在该时段和地点拍摄的照片。", fontSize = 13.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 2)
                        }
                    } else {
                        val outline = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.2f)
                        Box(
                            Modifier.fillMaxWidth().height(100.dp).clip(RoundedCornerShape(16.dp))
                                .clickable { showAddPhotoDialog = true }
                                .drawDashedBorder(outline),
                            contentAlignment = Alignment.Center
                        ) {
                            Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
                                Icon(Icons.Default.AddPhotoAlternate, null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
                                Text("拍摄或选择照片", fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                        }
                    }
                } else {
                    val ordered = rememberPhotosByDate(photos)
                    ordered.chunked(3).forEach { row ->
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            row.forEach { (uri, taken) ->
                                Box(
                                    Modifier.weight(1f).aspectRatio(1f).clip(RoundedCornerShape(10.dp))
                                        .combinedClickable(
                                            onClick = { viewerIndex = ordered.indexOfFirst { it.first == uri } },
                                            onLongClick = { photoToDelete = uri }
                                        )
                                ) {
                                    AsyncPhotoThumb(uri, Modifier.fillMaxSize())
                                    taken?.let {
                                        Text(
                                            hmText(it), color = Color.White, fontSize = 10.sp, fontWeight = FontWeight.SemiBold,
                                            modifier = Modifier.align(Alignment.BottomEnd).padding(4.dp)
                                                .background(Color.Black.copy(alpha = 0.4f), RoundedCornerShape(4.dp)).padding(horizontal = 4.dp, vertical = 1.dp)
                                        )
                                    }
                                }
                            }
                            repeat(3 - row.size) { Spacer(Modifier.weight(1f)) }
                        }
                    }
                }
            }
        }

        // ── Sheets & dialogs ──
        if (showPlacePicker) {
            val coord = TimelineEditActions.representativeCoordinate(fp)
            if (coord != null) {
                NearbyPlacePickerSheet(
                    latitude = coord.first,
                    longitude = coord.second,
                    savedPlaces = allPlaces,
                    onDismiss = { showPlacePicker = false },
                    onSelect = { showPlacePicker = false; viewModel.selectPlace(it) }
                )
            } else showPlacePicker = false
        }
        if (showActivityPicker) {
            ActivityPickerSheet(
                suggested = suggested,
                all = activityTypes,
                selectedId = fp.activityTypeValue,
                onDismiss = { showActivityPicker = false },
                onSelect = { viewModel.setActivity(it) },
                onAdd = { showActivityEditor = true }
            )
        }
        if (showActivityEditor) {
            ActivityTypeEditorDialog(
                activity = null,
                onDismiss = { showActivityEditor = false },
                onSave = { name, icon, color ->
                    showActivityEditor = false
                    scope.launch {
                        val dao = DiFangKeApp.instance.database.activityTypeDao()
                        val order = (dao.getAll().maxOfOrNull { it.sortOrder } ?: -1) + 1
                        dao.insert(ActivityTypeEntity(name = name, icon = icon, colorHex = color, sortOrder = order, isSystem = false))
                    }
                }
            )
        }
        if (showTimeAdjust) {
            FootprintTimeAdjustSheet(fp, onDismiss = { showTimeAdjust = false }) { s, e ->
                viewModel.adjustTime(s, e) { showTimeAdjust = false }
            }
        }
        if (showSplit) {
            FootprintSplitSheet(fp, activityTypes, onDismiss = { showSplit = false }) { split, a1, a2 ->
                viewModel.splitFootprint(split, a1, a2) { showSplit = false }
            }
        }
        if (showMergeAlert) {
            val partner = mergePartner
            AlertDialog(
                onDismissRequest = { showMergeAlert = false },
                title = { Text("合并相邻足迹？") },
                text = { Text(if (partner != null) TimelineEditActions.footprintMergeMessage(fp, partner, allPlaces) else "合并后会保留较早的足迹，并删除另一条相邻足迹。") },
                confirmButton = { TextButton(enabled = partner != null, onClick = { showMergeAlert = false; viewModel.mergeAdjacent() }) { Text("合并") } },
                dismissButton = { TextButton(onClick = { showMergeAlert = false }) { Text("取消") } }
            )
        }
        if (showIgnoreAlert) {
            AlertDialog(
                onDismissRequest = { showIgnoreAlert = false },
                title = { Text("忽略并删除在此地点的足迹？") },
                text = { Text("添加为忽略地点后，以后将不再记录此处的足迹，且现有的同地点足迹也将被隐藏。") },
                confirmButton = {
                    TextButton(onClick = { showIgnoreAlert = false; viewModel.ignoreLocation() }, colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.error)) { Text("忽略并删除") }
                },
                dismissButton = { TextButton(onClick = { showIgnoreAlert = false }) { Text("取消") } }
            )
        }
        if (showDeleteAlert) {
            AlertDialog(
                onDismissRequest = { showDeleteAlert = false },
                title = { Text("确认删除足迹？") },
                text = { Text("删除后，该足迹将不再出现在时间轴上。") },
                confirmButton = {
                    TextButton(onClick = { showDeleteAlert = false; viewModel.deleteFootprint() }, colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.error)) { Text("删除") }
                },
                dismissButton = { TextButton(onClick = { showDeleteAlert = false }) { Text("取消") } }
            )
        }
        if (showAddPlace) {
            AddImportantPlaceSheet(fp, onDismiss = { showAddPlace = false }) { name, lat, lon, radius, address ->
                viewModel.addAsImportantPlace(name, lat, lon, radius, address) { showAddPlace = false }
            }
        }
        if (showAddPhotoDialog) {
            AlertDialog(
                onDismissRequest = { showAddPhotoDialog = false },
                title = { Text("添加照片") },
                text = {
                    Column {
                        ListItem(headlineContent = { Text("拍摄照片") }, leadingContent = { Icon(Icons.Default.PhotoCamera, null) },
                            modifier = Modifier.clickable { showAddPhotoDialog = false; startCamera() })
                        ListItem(headlineContent = { Text("从相册选择") }, leadingContent = { Icon(Icons.Default.PhotoLibrary, null) },
                            modifier = Modifier.clickable { showAddPhotoDialog = false; galleryPicker.launch(arrayOf("image/*")) })
                    }
                },
                confirmButton = {},
                dismissButton = { TextButton(onClick = { showAddPhotoDialog = false }) { Text("取消") } }
            )
        }
        photoToDelete?.let { uri ->
            AlertDialog(
                onDismissRequest = { photoToDelete = null },
                title = { Text("确认移除照片？") },
                text = { Text("这张照片将从该足迹中移除。") },
                confirmButton = {
                    TextButton(onClick = { viewModel.removePhoto(uri); photoToDelete = null }, colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.error)) { Text("移除") }
                },
                dismissButton = { TextButton(onClick = { photoToDelete = null }) { Text("取消") } }
            )
        }
        viewerIndex?.let { index ->
            val ordered = rememberPhotosByDate(footprintPhotoUris(fp)).map { it.first }
            PhotoPagerViewer(ordered, index) { viewerIndex = null }
        }
        shareRequest?.let { ShareCardPreviewDialog(it, onDismiss = { shareRequest = null }) }
        if (showFullMap) {
            Dialog(onDismissRequest = { showFullMap = false }, properties = DialogProperties(usePlatformDefaultWidth = false)) {
                Surface(Modifier.fillMaxSize()) {
                    Box {
                        DetailMapView(fp, allPlaces, activityTypes)
                        Row(Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.surface.copy(alpha = 0.94f)).statusBarsPadding().padding(8.dp), verticalAlignment = Alignment.CenterVertically) {
                            IconButton(onClick = { showFullMap = false }) { Icon(Icons.Default.Close, "关闭完整足迹地图") }
                            Text("足迹地图", fontWeight = FontWeight.Bold, fontSize = 17.sp)
                        }
                    }
                }
            }
        }
    }
}

/** iOS matchedPlaceByAddress: user-defined place linked by id, or whose name/address equals the footprint address. */
private fun matchedPlaceByAddress(fp: FootprintEntity, places: List<PlaceEntity>): PlaceEntity? = places.firstOrNull { place ->
    if (place.placeID == fp.placeID && place.isUserDefined) return@firstOrNull true
    if (!place.isUserDefined) return@firstOrNull false
    val addr = fp.address?.trim().orEmpty()
    addr.isNotEmpty() && (place.name.trim() == addr || place.address?.trim() == addr)
}

/** iOS timeRangeString with 昨日/次日 prefixes for cross-midnight stays (C8). */
internal fun footprintTimeRangeText(fp: FootprintEntity): String {
    val day = TimelineEditActions.startOfDay(fp.date)
    val startSame = TimelineEditActions.startOfDay(fp.startTime) == day
    val endSame = TimelineEditActions.startOfDay(fp.endTime) == day
    val s = hmText(fp.startTime)
    val e = hmText(fp.endTime)
    return when {
        startSame && endSame -> "$s-$e"
        !startSame && endSame -> "昨日$s-$e"
        startSame && !endSame -> "$s-次日$e"
        else -> {
            val f = SimpleDateFormat("M月d日 HH:mm", Locale.CHINA)
            "${f.format(fp.startTime)}-${f.format(fp.endTime)}"
        }
    }
}

/** Note editor: saves on focus loss, after 800 ms idle, and when leaving. */
@Composable
private fun ReasonEditor(key: String, initial: String, onCommit: (String) -> Unit) {
    var text by remember(key) { mutableStateOf(initial) }
    var lastCommitted by remember(key) { mutableStateOf(initial) }
    val latest by rememberUpdatedState(text)
    LaunchedEffect(key, initial) { if (initial != lastCommitted) { text = initial; lastCommitted = initial } }
    LaunchedEffect(text) {
        if (text == lastCommitted) return@LaunchedEffect
        delay(800)
        lastCommitted = text
        onCommit(text)
    }
    DisposableEffect(key) { onDispose { if (latest != lastCommitted) onCommit(latest) } }
    TextField(
        value = text,
        onValueChange = { text = it },
        placeholder = { Text("输入备注...") },
        modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).onFocusChanged {
            if (!it.isFocused && text != lastCommitted) { lastCommitted = text; onCommit(text) }
        },
        minLines = 1,
        maxLines = 6,
        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Default),
        colors = TextFieldDefaults.colors(
            focusedIndicatorColor = Color.Transparent,
            unfocusedIndicatorColor = Color.Transparent,
            focusedContainerColor = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.06f),
            unfocusedContainerColor = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.06f)
        )
    )
}

private fun Modifier.drawDashedBorder(color: Color): Modifier = this.then(
    Modifier.drawWithDashedRoundRect(color)
)

private fun Modifier.drawWithDashedRoundRect(color: Color): Modifier = drawBehind {
    drawRoundRect(
        color = color,
        style = Stroke(width = 1.dp.toPx(), pathEffect = PathEffect.dashPathEffect(floatArrayOf(5.dp.toPx(), 5.dp.toPx()))),
        cornerRadius = androidx.compose.ui.geometry.CornerRadius(16.dp.toPx())
    )
}

/** Photos sorted newest-first by DATE_TAKEN (iOS refreshPhotoAssetOrder); unknown dates keep order at the end. */
@Composable
private fun rememberPhotosByDate(uris: List<String>): List<Pair<String, Date?>> {
    val context = LocalContext.current
    var result by remember(uris) { mutableStateOf(uris.map { it to null as Date? }) }
    LaunchedEffect(uris) {
        result = withContext(Dispatchers.IO) {
            val dated = uris.mapIndexed { i, u -> Triple(u, photoTakenDate(context, u), i) }
            dated.sortedWith(Comparator { a, b ->
                val da = a.second; val db = b.second
                when {
                    da != null && db != null && da != db -> db.compareTo(da)
                    da != null && db == null -> -1
                    da == null && db != null -> 1
                    else -> a.third.compareTo(b.third)
                }
            }).map { it.first to it.second }
        }
    }
    return result
}

private fun photoTakenDate(context: android.content.Context, uri: String): Date? = runCatching {
    context.contentResolver.query(Uri.parse(uri), arrayOf(MediaStore.Images.Media.DATE_TAKEN), null, null, null)?.use { c ->
        if (c.moveToFirst()) c.getLong(0).takeIf { it > 0 }?.let { Date(it) } else null
    }
}.getOrNull() ?: runCatching {
    context.contentResolver.openInputStream(Uri.parse(uri))?.use { s ->
        val exif = androidx.exifinterface.media.ExifInterface(s)
        val raw = exif.getAttribute(androidx.exifinterface.media.ExifInterface.TAG_DATETIME_ORIGINAL)
            ?: exif.getAttribute(androidx.exifinterface.media.ExifInterface.TAG_DATETIME)
        raw?.let { SimpleDateFormat("yyyy:MM:dd HH:mm:ss", Locale.US).parse(it) }
    }
}.getOrNull()

/** Off-main-thread thumbnail (MediaStore thumbnail on API 29+, sampled decode otherwise). */
@Composable
fun AsyncPhotoThumb(uri: String, modifier: Modifier = Modifier, sizePx: Int = 360) {
    val context = LocalContext.current
    var bitmap by remember(uri) { mutableStateOf<Bitmap?>(null) }
    LaunchedEffect(uri) {
        bitmap = withContext(Dispatchers.IO) {
            val u = Uri.parse(uri)
            (if (Build.VERSION.SDK_INT >= 29) runCatching { context.contentResolver.loadThumbnail(u, Size(sizePx, sizePx), null) }.getOrNull() else null)
                ?: runCatching {
                    val opts = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                    context.contentResolver.openInputStream(u)?.use { BitmapFactory.decodeStream(it, null, opts) }
                    var sample = 1
                    while (opts.outWidth / (sample * 2) >= sizePx && opts.outHeight / (sample * 2) >= sizePx) sample *= 2
                    context.contentResolver.openInputStream(u)?.use { BitmapFactory.decodeStream(it, null, BitmapFactory.Options().apply { inSampleSize = sample }) }
                }.getOrNull()
        }
    }
    Box(modifier.background(MaterialTheme.colorScheme.onSurface.copy(alpha = 0.06f)), contentAlignment = Alignment.Center) {
        val b = bitmap
        if (b != null) Image(b.asImageBitmap(), contentDescription = "查看足迹照片", contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
        else Icon(Icons.Default.Photo, null, tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.4f))
    }
}

@Composable
fun DetailMapView(
    footprint: FootprintEntity,
    allPlaces: List<PlaceEntity> = emptyList(),
    activityTypes: List<ActivityTypeEntity> = emptyList()
) {
    val isDark = androidx.compose.foundation.isSystemInDarkTheme()
    val primaryColor = MaterialTheme.colorScheme.primary.toArgb()
    AndroidView(
        factory = { ctx -> com.tencent.tencentmap.mapsdk.maps.TextureMapView(ctx).apply { onResume() } },
        modifier = Modifier.fillMaxSize(),
        onRelease = { view -> view.onPause(); view.onDestroy() }
    ) { view ->
        val amap = view.map
        amap.mapType = if (isDark) com.tencent.tencentmap.mapsdk.maps.TencentMap.MAP_TYPE_DARK else com.tencent.tencentmap.mapsdk.maps.TencentMap.MAP_TYPE_NORMAL
        amap.uiSettings.apply {
            isZoomControlsEnabled = false
            isMyLocationButtonEnabled = false
            isRotateGesturesEnabled = false
            isTiltGesturesEnabled = false
        }
        val lats = TimelineEditActions.jsonDoubles(footprint.latitudeJson)
        val lons = TimelineEditActions.jsonDoubles(footprint.longitudeJson)
        val points = (0 until minOf(lats.size, lons.size)).map { com.tencent.tencentmap.mapsdk.maps.model.LatLng(lats[it], lons[it]) }
        amap.clear()
        amap.addImportantPlaceCircles(allPlaces)
        if (points.isNotEmpty()) {
            if (points.size > 1) {
                amap.addPolyline(com.tencent.tencentmap.mapsdk.maps.model.PolylineOptions().addAll(points).width(12f).color(primaryColor))
            }
            amap.addFootprintMarkers(buildFootprintMapMarkers(listOf(footprint), activityTypes), isDark = isDark)
            if (points.size == 1) {
                amap.moveCamera(com.tencent.tencentmap.mapsdk.maps.CameraUpdateFactory.newLatLngZoom(points[0], 17f))
            } else {
                val b = com.tencent.tencentmap.mapsdk.maps.model.LatLngBounds.Builder()
                points.forEach { b.include(it) }
                val bounds = b.build()
                view.post {
                    runCatching {
                        amap.moveCamera(com.tencent.tencentmap.mapsdk.maps.CameraUpdateFactory.newLatLngBounds(bounds, 150))
                        if (amap.cameraPosition.zoom > 17f) amap.moveCamera(com.tencent.tencentmap.mapsdk.maps.CameraUpdateFactory.zoomTo(17f))
                    }.onFailure { amap.moveCamera(com.tencent.tencentmap.mapsdk.maps.CameraUpdateFactory.newLatLngZoom(points[0], 16f)) }
                }
            }
        }
    }
}
