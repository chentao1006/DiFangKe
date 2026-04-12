package com.ct106.difangke.ui.screens.main

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.ct106.difangke.data.model.TimelineItem
import com.ct106.difangke.viewmodel.MainViewModel

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MainScreen(
    viewModel: MainViewModel = viewModel(),
    onNavigateToHistory: () -> Unit,
    onNavigateToSettings: () -> Unit,
    onNavigateToMap: () -> Unit
) {
    val items by viewModel.timelineItems.collectAsState()
    val trackingState by viewModel.trackingState.collectAsState()

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("今日足迹") },
                actions = {
                    IconButton(onClick = onNavigateToMap) {
                        Text("地图")
                    }
                    IconButton(onClick = onNavigateToHistory) {
                        Text("历史")
                    }
                    IconButton(onClick = onNavigateToSettings) {
                        Text("设置")
                    }
                }
            )
        },
        floatingActionButton = {
            FloatingActionButton(onClick = { viewModel.toggleTracking() }) {
                Text(if (trackingState == com.ct106.difangke.service.LocationTrackingService.TrackingState.Idle) "启动" else "停止")
            }
        }
    ) { padding ->
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .background(MaterialTheme.colorScheme.background),
            contentPadding = PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            items(items) { item ->
                when (item) {
                    is TimelineItem.FootprintItem -> {
                        Card(
                            modifier = Modifier.fillMaxWidth(),
                            colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface)
                        ) {
                            Column(modifier = Modifier.padding(16.dp)) {
                                Text(item.footprint.title, style = MaterialTheme.typography.titleMedium)
                                item.footprint.address?.let {
                                    Text(it, style = MaterialTheme.typography.bodySmall)
                                }
                            }
                        }
                    }
                    is TimelineItem.TransportItem -> {
                        // Transport Card
                    }
                }
            }
        }
    }
}
