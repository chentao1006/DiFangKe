package com.ct106.difangke.ui.screens.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.ct106.difangke.ui.components.*

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DataManagerScreen(
    onBack: () -> Unit,
    onNavigateToRecycleBin: () -> Unit,
    onNavigateToRawPoints: () -> Unit,
    viewModel: DataManagerViewModel = viewModel()
) {
    val todayPoints by viewModel.todayPointsCount.collectAsState()
    val importResult by viewModel.importResult.collectAsState()
    val isProcessing by viewModel.isProcessing.collectAsState()
    val rebuildProgress by viewModel.rebuildProgress.collectAsState()
    
    var showDeleteAlert by remember { mutableStateOf(false) }
    var showRebuildAlert by remember { mutableStateOf(false) }

    // 文件选择器
    val importLauncher = androidx.activity.compose.rememberLauncherForActivityResult(
        contract = androidx.activity.result.contract.ActivityResultContracts.GetContent()
    ) { uri ->
        uri?.let { viewModel.importData(it) }
    }
    val exportLauncher = androidx.activity.compose.rememberLauncherForActivityResult(
        contract = androidx.activity.result.contract.ActivityResultContracts.CreateDocument("application/json")
    ) { uri ->
        uri?.let { viewModel.exportData(it) }
    }
    val rawLogsExportLauncher = androidx.activity.compose.rememberLauncherForActivityResult(
        contract = androidx.activity.result.contract.ActivityResultContracts.CreateDocument("text/csv")
    ) { uri ->
        uri?.let { viewModel.exportRawLogs(it) }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("数据操作", fontWeight = FontWeight.Bold) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "返回")
                    }
                }
            )
        }
    ) { padding ->
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.3f))
        ) {
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding)
                    .verticalScroll(rememberScrollState())
            ) {
                SettingsHeader("备份与恢复")
                SettingsNavigationItem(
                    title = "导出备份",
                    icon = Icons.Default.FileUpload,
                    onClick = { exportLauncher.launch("difangke-backup-${java.text.SimpleDateFormat("yyyyMMdd-HHmm", java.util.Locale.US).format(java.util.Date())}.json") }
                )
                SettingsNavigationItem(
                    title = "导入数据",
                    icon = Icons.Default.FileDownload,
                    onClick = { importLauncher.launch("application/json") }
                )

                SettingsHeader("数据轨迹 (Raw)")
                ListItem(
                    headlineContent = { Text("今日记录点数") },
                    trailingContent = { Text("$todayPoints 个", color = Color.Gray) },
                    leadingContent = { Icon(Icons.Default.MyLocation, contentDescription = null, tint = Color(0xFF34C759)) },
                    colors = ListItemDefaults.colors(containerColor = Color.Transparent)
                )
                SettingsNavigationItem(
                    title = "查看今日原始轨迹",
                    icon = Icons.Default.Description,
                    onClick = onNavigateToRawPoints
                )
                SettingsNavigationItem(
                    title = "导出全部原始轨迹",
                    icon = Icons.Default.FileUpload,
                    onClick = { rawLogsExportLauncher.launch("difangke-raw-locations-${java.text.SimpleDateFormat("yyyyMMdd-HHmm", java.util.Locale.US).format(java.util.Date())}.csv") }
                )

                SettingsHeader("回收站")
                SettingsNavigationItem(
                    title = "足迹回收站",
                    icon = Icons.Default.DeleteSweep,
                    onClick = onNavigateToRecycleBin
                )

                SettingsHeader("数据维护")
                SettingsNavigationItem(
                    title = "重建所有时间线",
                    icon = Icons.Default.Restore,
                    onClick = { showRebuildAlert = true }
                )

                SettingsHeader("危险操作")
                ListItem(
                    modifier = androidx.compose.ui.Modifier.clickable { showDeleteAlert = true },
                    headlineContent = { Text("清空所有数据", color = Color.Red, fontWeight = FontWeight.Bold) },
                    supportingContent = { Text("彻底清空所有产生的足迹和自定义地点。") },
                    colors = ListItemDefaults.colors(containerColor = Color.Transparent)
                )
                
                Spacer(modifier = Modifier.height(32.dp))
            }

            if (isProcessing) {
                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .background(Color.Black.copy(alpha = 0.3f)),
                    contentAlignment = androidx.compose.ui.Alignment.Center
                ) {
                    Column(horizontalAlignment = androidx.compose.ui.Alignment.CenterHorizontally) {
                        CircularProgressIndicator()
                        rebuildProgress?.let { (current, total) ->
                            Spacer(Modifier.height(16.dp))
                            Text("正在重建时间线：$current / $total", color = Color.White)
                            TextButton(onClick = viewModel::cancelRebuildAllTimelines) {
                                Text("取消重建", color = Color.White)
                            }
                        }
                    }
                }
            }
        }
    }

    if (importResult != null) {
        AlertDialog(
            onDismissRequest = { viewModel.clearImportResult() },
            title = { Text("导入结果") },
            text = { Text(importResult!!) },
            confirmButton = {
                TextButton(onClick = { viewModel.clearImportResult() }) {
                    Text("确定")
                }
            }
        )
    }

    if (showDeleteAlert) {
        AlertDialog(
            onDismissRequest = { showDeleteAlert = false },
            title = { Text("确认删除") },
            text = { Text("这将删除所有本地的足迹数据，操作不可逆！") },
            confirmButton = {
                Button(onClick = {
                    viewModel.clearAllData()
                    showDeleteAlert = false
                }, colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.error)) {
                    Text("删除")
                }
            },
            dismissButton = {
                TextButton(onClick = { showDeleteAlert = false }) {
                    Text("取消")
                }
            }
        )
    }

    if (showRebuildAlert) {
        AlertDialog(
            onDismissRequest = { showRebuildAlert = false },
            title = { Text("重建所有时间线") },
            text = { Text("将根据全部原始轨迹重新生成足迹和自动交通记录。手动修改与已确认记录会保留，此过程可能需要较长时间。") },
            confirmButton = {
                Button(onClick = {
                    showRebuildAlert = false
                    viewModel.rebuildAllTimelines()
                }) { Text("开始重建") }
            },
            dismissButton = { TextButton(onClick = { showRebuildAlert = false }) { Text("取消") } }
        )
    }
}
