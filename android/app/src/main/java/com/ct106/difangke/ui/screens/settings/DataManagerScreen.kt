package com.ct106.difangke.ui.screens.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
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
    viewModel: DataManagerViewModel = viewModel()
) {
    val todayPoints by viewModel.todayPointsCount.collectAsState()
    val importResult by viewModel.importResult.collectAsState()
    val isProcessing by viewModel.isProcessing.collectAsState()
    
    var showDeleteAlert by remember { mutableStateOf(false) }

    // 文件选择器
    val importLauncher = androidx.activity.compose.rememberLauncherForActivityResult(
        contract = androidx.activity.result.contract.ActivityResultContracts.GetContent()
    ) { uri ->
        uri?.let { viewModel.importData(it) }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("数据操作", fontWeight = FontWeight.Bold) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.Default.ArrowBack, contentDescription = "返回")
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
                    onClick = { /* TODO: 未来支持导出 */ }
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
                    title = "查看/导出日志",
                    icon = Icons.Default.Description,
                    onClick = { /* TODO */ }
                )

                SettingsHeader("回收站")
                SettingsNavigationItem(
                    title = "足迹回收站",
                    icon = Icons.Default.DeleteSweep,
                    onClick = { /* TODO */ }
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
                    CircularProgressIndicator()
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
}
