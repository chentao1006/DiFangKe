package com.ct106.difangke.ui.screens.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.lifecycle.viewmodel.compose.viewModel
import com.ct106.difangke.data.db.entity.PlaceEntity

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PlacesManagerScreen(
    onBack: () -> Unit,
    viewModel: PlacesViewModel = viewModel()
) {
    val places by viewModel.importantPlaces.collectAsState()
    var placeToDelete by remember { mutableStateOf<PlaceEntity?>(null) }
    var editingPlace by remember { mutableStateOf<PlaceEntity?>(null) }
    var showingAddDialog by remember { mutableStateOf(false) }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("重要地点", fontWeight = FontWeight.Bold) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.Default.ArrowBack, contentDescription = "返回")
                    }
                },
                actions = {
                    IconButton(onClick = { showingAddDialog = true }) {
                        Icon(Icons.Default.Add, contentDescription = "添加")
                    }
                }
            )
        }
    ) { padding ->
        if (places.isEmpty()) {
            Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) {
                Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.padding(32.dp)) {
                    Icon(Icons.Default.Place, contentDescription = null, modifier = Modifier.size(64.dp), tint = MaterialTheme.colorScheme.outlineVariant)
                    Spacer(modifier = Modifier.height(16.dp))
                    Text("还没有重要地点", style = MaterialTheme.typography.titleMedium)
                    Text(
                        "添加家、公司、餐厅等常用地点，地方客将帮你更精准地记录您的足迹。",
                        style = MaterialTheme.typography.bodySmall,
                        color = Color.Gray,
                        textAlign = androidx.compose.ui.text.style.TextAlign.Center
                    )
                }
            }
        } else {
            LazyColumn(modifier = Modifier.fillMaxSize().padding(padding)) {
                item {
                    Text(
                        "个性化设置“重要地点”能让系统更好地理解您的生活重心。",
                        style = MaterialTheme.typography.bodySmall,
                        color = Color.Gray,
                        modifier = Modifier.padding(16.dp)
                    )
                }
                items(places) { place ->
                    PlaceRow(
                        place, 
                        onClick = { editingPlace = place },
                        onDelete = { placeToDelete = place }
                    )
                    Divider(modifier = Modifier.padding(horizontal = 16.dp), thickness = 0.5.dp, color = MaterialTheme.colorScheme.outlineVariant)
                }
            }
        }
    }

    if (showingAddDialog) {
        PlaceEditorDialog(
            place = null,
            onDismiss = { showingAddDialog = false },
            onSave = { name, address, lat, lon ->
                viewModel.savePlace(null, name, address, lat, lon)
                showingAddDialog = false
            }
        )
    }

    if (editingPlace != null) {
        PlaceEditorDialog(
            place = editingPlace,
            onDismiss = { editingPlace = null },
            onSave = { name, address, lat, lon ->
                viewModel.savePlace(editingPlace!!.placeID, name, address, lat, lon)
                editingPlace = null
            }
        )
    }

    if (placeToDelete != null) {
        AlertDialog(
            onDismissRequest = { placeToDelete = null },
            title = { Text("确认删除") },
            text = { Text("确定要删除“${placeToDelete!!.name}”吗？此操作不可撤销。") },
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

@Composable
fun PlaceRow(place: PlaceEntity, onClick: () -> Unit, onDelete: () -> Unit) {
    ListItem(
        modifier = Modifier.clickable(onClick = onClick),
        headlineContent = { Text(place.name, fontWeight = FontWeight.SemiBold) },
        supportingContent = { Text(place.address ?: "未知地址", maxLines = 1, fontSize = 12.sp) },
        leadingContent = {
            Box(
                modifier = Modifier
                    .size(44.dp)
                    .clip(CircleShape)
                    .background(MaterialTheme.colorScheme.primary.copy(alpha = 0.1f)),
                contentAlignment = Alignment.Center
            ) {
                Icon(
                    imageVector = when(place.name) {
                        "家" -> Icons.Default.Home
                        "公司" -> Icons.Default.Business
                        "学校" -> Icons.Default.School
                        else -> Icons.Default.Place
                    },
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.size(24.dp)
                )
            }
        },
        trailingContent = {
            IconButton(onClick = onDelete) {
                Icon(Icons.Default.Delete, contentDescription = "删除", tint = MaterialTheme.colorScheme.error.copy(alpha = 0.3f), modifier = Modifier.size(20.dp))
            }
        }
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PlaceEditorDialog(
    place: PlaceEntity?,
    onDismiss: () -> Unit,
    onSave: (String, String, Double, Double) -> Unit
) {
    var name by remember { mutableStateOf(place?.name ?: "") }
    var address by remember { mutableStateOf(place?.address ?: "") }
    var lat by remember { mutableStateOf(place?.latitude?.toString() ?: "") }
    var lon by remember { mutableStateOf(place?.longitude?.toString() ?: "") }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(if (place == null) "添加重要地点" else "编辑地点", fontWeight = FontWeight.Bold) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
                OutlinedTextField(
                    value = name,
                    onValueChange = { name = it },
                    label = { Text("名称 (如：家、公司)") },
                    modifier = Modifier.fillMaxWidth(),
                    shape = RoundedCornerShape(12.dp)
                )
                OutlinedTextField(
                    value = address,
                    onValueChange = { address = it },
                    label = { Text("详细地址") },
                    modifier = Modifier.fillMaxWidth(),
                    shape = RoundedCornerShape(12.dp)
                )
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedTextField(
                        value = lat,
                        onValueChange = { lat = it },
                        label = { Text("纬度") },
                        modifier = Modifier.weight(1f),
                        shape = RoundedCornerShape(12.dp)
                    )
                    OutlinedTextField(
                        value = lon,
                        onValueChange = { lon = it },
                        label = { Text("经度") },
                        modifier = Modifier.weight(1f),
                        shape = RoundedCornerShape(12.dp)
                    )
                }
            }
        },
        confirmButton = {
            Button(
                onClick = { 
                    val lVal = lat.toDoubleOrNull() ?: 0.0
                    val rVal = lon.toDoubleOrNull() ?: 0.0
                    onSave(name, address, lVal, rVal)
                },
                enabled = name.isNotBlank() && address.isNotBlank(),
                shape = RoundedCornerShape(12.dp)
            ) {
                Text("保存")
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text("取消")
            }
        }
    )
}


