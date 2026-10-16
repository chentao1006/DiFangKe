package com.ct106.difangke.ui.screens.history

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.lifecycle.viewmodel.compose.viewModel
import com.ct106.difangke.data.db.entity.FootprintEntity
import com.ct106.difangke.viewmodel.HistoryViewModel
import java.text.SimpleDateFormat
import java.util.Locale

/**
 * iOS PhotoImportFlowModifier: the whole photo import flow (permission,
 * picker, scan, review, save). Shared by Review, the calendar and the
 * timeline so each starts it in place. Returns the action that starts it.
 * Imported footprints reach the timeline through the observed database.
 */
@Composable
fun rememberPhotoImportFlow(viewModel: HistoryViewModel = viewModel()): () -> Unit {
    val photoCandidates by viewModel.photoCandidates.collectAsState()
    val isScanningPhotos by viewModel.isScanningPhotos.collectAsState()
    val context = LocalContext.current
    var showPhotoResults by remember { mutableStateOf(false) }
    var showNoPhotoResults by remember { mutableStateOf(false) }
    var wasScanningPhotos by remember { mutableStateOf(false) }

    val photoPickerLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.PickMultipleVisualMedia()
    ) { uris ->
        if (uris.isNotEmpty()) {
            uris.forEach { uri ->
                runCatching {
                    context.contentResolver.takePersistableUriPermission(
                        uri,
                        android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION
                    )
                }
            }
            viewModel.scanPhotos(uris)
        }
    }
    // 读取所选照片的拍摄地点需要此权限（读取 EXIF 中的 GPS 信息）；
    // 用户在选完照片后立刻看到用途，拒绝也不影响照片选择本身。
    val mediaLocationPermissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) {
        photoPickerLauncher.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
    }

    LaunchedEffect(isScanningPhotos) {
        if (wasScanningPhotos && !isScanningPhotos) {
            if (photoCandidates.isNotEmpty()) showPhotoResults = true
            else showNoPhotoResults = true
        }
        wasScanningPhotos = isScanningPhotos
    }

    if (isScanningPhotos) {
        AlertDialog(
            onDismissRequest = {},
            title = { Text("正在扫描照片") },
            text = { Text("正在按拍摄地点和时间整理可导入的足迹…") },
            confirmButton = {}
        )
    }
    if (showNoPhotoResults) {
        AlertDialog(
            onDismissRequest = { showNoPhotoResults = false },
            title = { Text("未发现足迹") },
            text = { Text("所选范围内没有包含位置信息的照片。") },
            confirmButton = { TextButton(onClick = { showNoPhotoResults = false }) { Text("好") } }
        )
    }
    if (showPhotoResults) {
        PhotoImportCandidatesDialog(
            candidates = photoCandidates,
            onDismiss = { showPhotoResults = false },
            onImport = {
                viewModel.importPhotoCandidates(it)
                showPhotoResults = false
            }
        )
    }

    return {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_MEDIA_LOCATION) != PackageManager.PERMISSION_GRANTED
        ) {
            mediaLocationPermissionLauncher.launch(Manifest.permission.ACCESS_MEDIA_LOCATION)
        } else {
            photoPickerLauncher.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
        }
    }
}

@Composable
private fun PhotoImportCandidatesDialog(
    candidates: List<FootprintEntity>,
    onDismiss: () -> Unit,
    onImport: (List<FootprintEntity>) -> Unit
) {
    var selectedIDs by remember(candidates) { mutableStateOf(candidates.map { it.footprintID }.toSet()) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("从照片找回足迹") },
        text = {
            LazyColumn(Modifier.heightIn(max = 360.dp)) {
                item {
                    Text("已按地点和时间整理出 ${candidates.size} 个候选足迹；确认后才会写入时间线。", style = MaterialTheme.typography.bodySmall)
                    Spacer(Modifier.height(12.dp))
                }
                items(candidates, key = { it.footprintID }) { candidate ->
                    val count = try { org.json.JSONArray(candidate.photoAssetIDsJson).length() } catch (_: Exception) { 0 }
                    Row(
                        modifier = Modifier.fillMaxWidth().clickable {
                            selectedIDs = if (candidate.footprintID in selectedIDs) selectedIDs - candidate.footprintID else selectedIDs + candidate.footprintID
                        }.padding(vertical = 8.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Checkbox(candidate.footprintID in selectedIDs, onCheckedChange = null)
                        Column(Modifier.padding(start = 8.dp)) {
                            Text(SimpleDateFormat("yyyy年M月d日 HH:mm", Locale.CHINA).format(candidate.startTime), fontWeight = FontWeight.Medium)
                            Text("$count 张带地点的照片", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                }
            }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("取消") } },
        confirmButton = {
            TextButton(onClick = { onImport(candidates.filter { it.footprintID in selectedIDs }) }, enabled = selectedIDs.isNotEmpty()) { Text("导入") }
        }
    )
}
