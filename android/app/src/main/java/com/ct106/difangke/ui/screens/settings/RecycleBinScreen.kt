package com.ct106.difangke.ui.screens.settings

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.DeleteForever
import androidx.compose.material.icons.filled.Restore
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.ct106.difangke.DiFangKeApp
import com.ct106.difangke.data.db.entity.FootprintEntity
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Locale

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RecycleBinScreen(onBack: () -> Unit) {
    val dao = remember { DiFangKeApp.instance.database.footprintDao() }
    val footprints by dao.observeIgnored().collectAsState(initial = emptyList())
    val scope = rememberCoroutineScope()
    var clearAll by remember { mutableStateOf(false) }
    val dateFormat = remember { SimpleDateFormat("M月d日 HH:mm", Locale.CHINA) }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("足迹回收站", fontWeight = FontWeight.Bold) },
                navigationIcon = { IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "返回") } },
                actions = {
                    if (footprints.isNotEmpty()) {
                        TextButton(onClick = { clearAll = true }) { Text("全部清空", color = MaterialTheme.colorScheme.error) }
                    }
                }
            )
        }
    ) { padding ->
        if (footprints.isEmpty()) {
            Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) {
                Text("回收站空空如也", color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        } else {
            LazyColumn(
                modifier = Modifier.fillMaxSize().padding(padding),
                contentPadding = PaddingValues(vertical = 8.dp)
            ) {
                item { Text("已删除的足迹 (${footprints.size})", modifier = Modifier.padding(16.dp), style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary) }
                items(footprints, key = { it.footprintID }) { footprint ->
                    RecycleFootprintRow(
                        footprint = footprint,
                        dateFormat = dateFormat,
                        onRestore = { scope.launch { dao.update(footprint.copy(statusValue = "confirmed")) } },
                        onDelete = { scope.launch { dao.delete(footprint) } }
                    )
                }
            }
        }
    }
    if (clearAll) {
        AlertDialog(
            onDismissRequest = { clearAll = false },
            title = { Text("清空回收站？") },
            text = { Text("永久删除所有已删除足迹，此操作不可恢复。") },
            confirmButton = { TextButton(onClick = { scope.launch { dao.deleteAllIgnored() }; clearAll = false }) { Text("永久删除", color = MaterialTheme.colorScheme.error) } },
            dismissButton = { TextButton(onClick = { clearAll = false }) { Text("取消") } }
        )
    }
}

@Composable
private fun RecycleFootprintRow(
    footprint: FootprintEntity,
    dateFormat: SimpleDateFormat,
    onRestore: () -> Unit,
    onDelete: () -> Unit
) {
    ListItem(
        headlineContent = { Text(footprint.address?.takeIf { it.isNotBlank() } ?: footprint.title?.takeIf { it.isNotBlank() } ?: "未知地点") },
        supportingContent = { Text("${dateFormat.format(footprint.startTime)} - ${SimpleDateFormat("HH:mm", Locale.CHINA).format(footprint.endTime)}") },
        trailingContent = {
            Row {
                IconButton(onClick = onRestore) { Icon(Icons.Default.Restore, "恢复") }
                IconButton(onClick = onDelete) { Icon(Icons.Default.DeleteForever, "永久删除", tint = MaterialTheme.colorScheme.error) }
            }
        }
    )
}
