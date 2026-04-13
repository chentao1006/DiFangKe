package com.ct106.difangke.ui.screens.settings

import android.os.Bundle
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
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
            onSave = { name, address, lat, lon, radius ->
                viewModel.savePlace(null, name, address, lat, lon, radius)
                showingAddDialog = false
            }
        )
    }

    if (editingPlace != null) {
        PlaceEditorDialog(
            place = editingPlace,
            onDismiss = { editingPlace = null },
            onSave = { name, address, lat, lon, radius ->
                viewModel.savePlace(editingPlace!!.placeID, name, address, lat, lon, radius)
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
        supportingContent = { Text("${place.address ?: "未知地址"} (${place.radius.toInt()}m)", maxLines = 1, fontSize = 12.sp) },
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
                        "工作", "公司" -> Icons.Default.Business
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

@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun PlaceEditorDialog(
    place: PlaceEntity?,
    onDismiss: () -> Unit,
    onSave: (String, String, Double, Double, Float) -> Unit
) {
    var name by remember { mutableStateOf(place?.name ?: "") }
    var address by remember { mutableStateOf(place?.address ?: "") }
    var lat by remember { mutableDoubleStateOf(place?.latitude ?: 39.90923) }
    var lon by remember { mutableDoubleStateOf(place?.longitude ?: 116.397428) }
    var radius by remember { mutableFloatStateOf(place?.radius ?: 200f) }

    val isDark = androidx.compose.foundation.isSystemInDarkTheme()
    val primaryColor = MaterialTheme.colorScheme.primary.toArgb()

    Dialog(
        onDismissRequest = onDismiss, 
        properties = DialogProperties(usePlatformDefaultWidth = false)
    ) {
        Surface(
            modifier = Modifier.fillMaxSize(),
            color = MaterialTheme.colorScheme.surface
        ) {
            Column(modifier = Modifier.fillMaxSize()) {
                TopAppBar(
                    title = { Text(if (place == null) "添加重要地点" else "编辑地点", fontWeight = FontWeight.Bold) },
                    navigationIcon = {
                        IconButton(onClick = onDismiss) { Icon(Icons.Default.Close, contentDescription = "取消") }
                    },
                    actions = {
                        TextButton(
                            onClick = { onSave(name, address, lat, lon, radius) },
                            enabled = name.isNotBlank()
                        ) {
                            Text("完成", fontWeight = FontWeight.Bold)
                        }
                    }
                )

                Column(
                    modifier = Modifier
                        .weight(1f)
                        .verticalScroll(rememberScrollState())
                ) {
                    // Map Picker
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(350.dp)
                    ) {
                        AndroidView(
                            factory = { ctx ->
                                com.amap.api.maps.TextureMapView(ctx).apply {
                                    onCreate(Bundle())
                                    onResume()
                                }
                            },
                            modifier = Modifier.fillMaxSize()
                        ) { view ->
                            val amap = view.map
                            amap.mapType = if (isDark) com.amap.api.maps.AMap.MAP_TYPE_NIGHT else com.amap.api.maps.AMap.MAP_TYPE_NORMAL
                            amap.uiSettings.isZoomControlsEnabled = false
                            
                            val center = com.amap.api.maps.model.LatLng(lat, lon)
                            amap.moveCamera(com.amap.api.maps.CameraUpdateFactory.newLatLngZoom(center, 15f))
                            
                            amap.clear()
                            amap.addMarker(com.amap.api.maps.model.MarkerOptions().position(center))
                            amap.addCircle(
                                com.amap.api.maps.model.CircleOptions()
                                    .center(center)
                                    .radius(radius.toDouble())
                                    .fillColor(primaryColor and 0x22FFFFFF)
                                    .strokeColor(primaryColor)
                                    .strokeWidth(2f)
                            )
                            
                            amap.setOnMapClickListener { pos ->
                                lat = pos.latitude
                                lon = pos.longitude
                            }
                        }
                        
                        // Center indicator
                        Icon(
                            Icons.Default.MyLocation,
                            contentDescription = null,
                            modifier = Modifier.align(Alignment.Center).size(24.dp).alpha(0.5f),
                            tint = MaterialTheme.colorScheme.primary
                        )
                        
                        Text(
                            "点击地图选择位置",
                            modifier = Modifier
                                .align(Alignment.BottomCenter)
                                .padding(bottom = 16.dp)
                                .background(Color.Black.copy(alpha = 0.5f), RoundedCornerShape(20.dp))
                                .padding(horizontal = 12.dp, vertical = 6.dp),
                            color = Color.White,
                            style = MaterialTheme.typography.labelSmall
                        )
                    }

                    Spacer(Modifier.height(24.dp))

                    Column(
                        modifier = Modifier.padding(horizontal = 24.dp),
                        verticalArrangement = Arrangement.spacedBy(20.dp)
                    ) {
                        OutlinedTextField(
                            value = name,
                            onValueChange = { name = it },
                            label = { Text("名称 (如：家、公司)") },
                            modifier = Modifier.fillMaxWidth(),
                            shape = RoundedCornerShape(12.dp),
                            singleLine = true
                        )

                        OutlinedTextField(
                            value = address,
                            onValueChange = { address = it },
                            label = { Text("详细地址 (可选)") },
                            modifier = Modifier.fillMaxWidth(),
                            shape = RoundedCornerShape(12.dp),
                            singleLine = true
                        )

                        Column {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Text("围栏半径", style = MaterialTheme.typography.titleSmall)
                                Spacer(Modifier.weight(1f))
                                Text("${radius.toInt()} 米", fontWeight = FontWeight.Bold, color = MaterialTheme.colorScheme.primary)
                            }
                            Slider(
                                value = radius,
                                onValueChange = { radius = it },
                                valueRange = 100f..1000f,
                                steps = 8
                            )
                            Text(
                                "当您进入此半径范围内，系统会自动识别为您到达了该地点。",
                                style = MaterialTheme.typography.labelSmall,
                                color = Color.Gray
                            )
                        }
                        
                        Text(
                            "坐标: ${String.format("%.6f", lat)}, ${String.format("%.6f", lon)}",
                            style = MaterialTheme.typography.labelSmall,
                            color = Color.Gray,
                            modifier = Modifier.alpha(0.5f)
                        )
                        
                        Spacer(Modifier.height(40.dp))
                    }
                }
            }
        }
    }
}
