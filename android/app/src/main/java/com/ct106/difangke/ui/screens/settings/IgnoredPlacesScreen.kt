package com.ct106.difangke.ui.screens.settings

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.ct106.difangke.data.db.entity.PlaceEntity

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun IgnoredPlacesScreen(
    onBack: () -> Unit,
    viewModel: PlacesViewModel = viewModel()
) {
    val places by viewModel.ignoredPlaces.collectAsState()
    var placeToDelete by remember { mutableStateOf<PlaceEntity?>(null) }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("已忽略地点", fontWeight = FontWeight.Bold) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.Default.ArrowBack, contentDescription = "返回")
                    }
                }
            )
        }
    ) { padding ->
        if (places.isEmpty()) {
            Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) {
                Text("暂无已忽略地点", color = Color.Gray)
            }
        } else {
            LazyColumn(modifier = Modifier.fillMaxSize().padding(padding)) {
                items(places) { place ->
                    ListItem(
                        headlineContent = { Text(place.name) },
                        supportingContent = { Text(place.address ?: "", maxLines = 1, fontSize = 12.sp) },
                        leadingContent = {
                            Icon(Icons.Default.LocationOff, contentDescription = null, tint = Color.Gray)
                        },
                        trailingContent = {
                            IconButton(onClick = { placeToDelete = place }) {
                                Icon(Icons.Default.Delete, contentDescription = "删除", tint = Color.LightGray, modifier = Modifier.size(20.dp))
                            }
                        }
                    )
                    Divider(modifier = Modifier.padding(horizontal = 16.dp), thickness = 0.5.dp, color = MaterialTheme.colorScheme.outlineVariant)
                }
            }
        }
    }

    if (placeToDelete != null) {
        AlertDialog(
            onDismissRequest = { placeToDelete = null },
            title = { Text("确认删除") },
            text = { Text("确定要取消忽略并删除此记录吗？") },
            confirmButton = {
                Button(onClick = {
                    viewModel.deletePlace(placeToDelete!!)
                    placeToDelete = null
                }, colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.error)) {
                    Text("删除")
                }
            },
            dismissButton = {
                TextButton(onClick = { placeToDelete = null }) {
                    Text("取消")
                }
            }
        )
    }
}
