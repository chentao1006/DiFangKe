package com.ct106.difangke.ui.screens.detail

import android.os.Bundle
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.viewmodel.compose.viewModel
import com.ct106.difangke.data.db.entity.ActivityTypeEntity
import com.ct106.difangke.data.db.entity.FootprintEntity
import com.ct106.difangke.ui.components.getIconForName
import java.text.SimpleDateFormat
import java.util.*
import org.json.JSONArray

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FootprintDetailScreen(
    footprintId: String,
    onBack: () -> Unit,
    viewModel: FootprintDetailViewModel = viewModel()
) {
    val footprint by viewModel.footprint.collectAsState()
    val activityTypes by viewModel.activityTypes.collectAsState()
    
    var title by remember { mutableStateOf("") }
    var reason by remember { mutableStateOf("") }
    var selectedActivityType by remember { mutableStateOf<String?>(null) }
    var showingDeleteAlert by remember { mutableStateOf(false) }

    if (showingDeleteAlert) {
        AlertDialog(
            onDismissRequest = { showingDeleteAlert = false },
            title = { Text("删除足迹", fontWeight = FontWeight.Bold) },
            text = { Text("确定要删除这段段时光吗？此操作不可撤销。") },
            confirmButton = {
                TextButton(
                    onClick = {
                        viewModel.deleteFootprint()
                        onBack()
                        showingDeleteAlert = false
                    },
                    colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.error)
                ) {
                    Text("删除")
                }
            },
            dismissButton = {
                TextButton(onClick = { showingDeleteAlert = false }) {
                    Text("取消")
                }
            }
        )
    }

    LaunchedEffect(footprintId) {
        viewModel.loadFootprint(footprintId)
    }

    LaunchedEffect(footprint) {
        footprint?.let {
            title = it.title
            reason = it.reason ?: ""
            selectedActivityType = it.activityTypeValue
        }
    }

    val timeFormat = SimpleDateFormat("HH:mm", Locale.CHINA)
    val dateFormat = SimpleDateFormat("yyyy年M月d日 EEEE", Locale.CHINA)

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("足迹详情", fontWeight = FontWeight.Bold) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.Default.ArrowBack, contentDescription = "返回")
                    }
                },
                actions = {
                    TextButton(onClick = {
                        viewModel.updateFootprint(title, reason, selectedActivityType)
                        onBack()
                    }) {
                        Text("完成", fontWeight = FontWeight.Bold)
                    }
                }
            )
        }
    ) { padding ->
        if (footprint == null) {
            Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                CircularProgressIndicator()
            }
        } else {
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding)
                    .verticalScroll(rememberScrollState())
                    .padding(bottom = 32.dp)
            ) {
                // 1. 标题和活动类型
                Column(modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        OutlinedTextField(
                            value = title,
                            onValueChange = { title = it },
                            placeholder = { Text("有什么值得记住的") },
                            modifier = Modifier.weight(1f),
                            shape = RoundedCornerShape(16.dp),
                            colors = TextFieldDefaults.outlinedTextFieldColors(
                                focusedBorderColor = MaterialTheme.colorScheme.primary.copy(alpha = 0.5f),
                                unfocusedBorderColor = Color.Transparent,
                                containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.3f)
                            ),
                            singleLine = true,
                            textStyle = MaterialTheme.typography.titleLarge.copy(fontWeight = FontWeight.Bold)
                        )
                        
                        Spacer(modifier = Modifier.width(12.dp))
                        
                        ActivityTypeIcon(
                            selectedId = selectedActivityType,
                            allTypes = activityTypes,
                            onTypeSelected = { selectedActivityType = it }
                        )
                    }
                    
                    Spacer(modifier = Modifier.height(12.dp))
                    
                    ActivitySuggestions(
                        allTypes = activityTypes,
                        selectedId = selectedActivityType,
                        onTypeSelected = { selectedActivityType = it }
                    )
                }

                // 2. 时间和地址卡片
                ElevatedCard(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp, vertical = 8.dp),
                    shape = RoundedCornerShape(16.dp),
                    colors = CardDefaults.elevatedCardColors(containerColor = MaterialTheme.colorScheme.surface)
                ) {
                    Column(modifier = Modifier.padding(16.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Default.Place, contentDescription = null, modifier = Modifier.size(16.dp), tint = MaterialTheme.colorScheme.primary)
                            Spacer(modifier = Modifier.width(8.dp))
                            Text(
                                text = footprint!!.address ?: "未知位置",
                                style = MaterialTheme.typography.bodyMedium,
                                fontWeight = FontWeight.Medium
                            )
                        }
                        
                        Spacer(modifier = Modifier.height(12.dp))
                        
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Default.CalendarToday, contentDescription = null, modifier = Modifier.size(14.dp), tint = Color.Gray)
                            Spacer(modifier = Modifier.width(8.dp))
                            Text(dateFormat.format(footprint!!.date), style = MaterialTheme.typography.bodySmall, color = Color.Gray)
                        }
                        
                        Spacer(modifier = Modifier.height(4.dp))
                        
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Default.AccessTime, contentDescription = null, modifier = Modifier.size(14.dp), tint = Color.Gray)
                            Spacer(modifier = Modifier.width(8.dp))
                            Text(
                                "${timeFormat.format(footprint!!.startTime)} - ${timeFormat.format(footprint!!.endTime)}",
                                style = MaterialTheme.typography.bodySmall,
                                color = Color.Gray
                            )
                            Spacer(modifier = Modifier.weight(1f))
                            val durationMins = (footprint!!.endTime.time - footprint!!.startTime.time) / 60000
                            Text("停留 ${if (durationMins >= 60) "${durationMins/60}小时${durationMins%60}分" else "${durationMins}分钟"}", 
                                style = MaterialTheme.typography.bodySmall, 
                                fontWeight = FontWeight.Bold,
                                color = MaterialTheme.colorScheme.primary.copy(alpha=0.7f)
                            )
                        }
                    }
                }

                // 3. 地图展示
                Text(
                    "位置轨迹",
                    style = MaterialTheme.typography.labelLarge,
                    color = Color.Gray,
                    modifier = Modifier.padding(horizontal = 24.dp, vertical = 8.dp)
                )
                
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(240.dp)
                        .padding(horizontal = 16.dp)
                        .clip(RoundedCornerShape(20.dp))
                        .background(MaterialTheme.colorScheme.surfaceVariant)
                ) {
                    DetailMapView(footprint = footprint!!)
                }

                // 4. 感想备注
                Text(
                    "感想与备注",
                    style = MaterialTheme.typography.labelLarge,
                    color = Color.Gray,
                    modifier = Modifier.padding(horizontal = 24.dp, vertical = 12.dp)
                )
                
                OutlinedTextField(
                    value = reason,
                    onValueChange = { reason = it },
                    placeholder = { Text("记录此刻的心情...") },
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp),
                    shape = RoundedCornerShape(16.dp),
                    colors = TextFieldDefaults.outlinedTextFieldColors(
                        focusedBorderColor = MaterialTheme.colorScheme.primary.copy(alpha = 0.5f),
                        unfocusedBorderColor = Color.Transparent,
                        containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.3f)
                    ),
                    minLines = 4
                )
                
                Spacer(modifier = Modifier.height(24.dp))
                
                // 删除按钮
                TextButton(
                    onClick = { showingDeleteAlert = true },
                    modifier = Modifier.align(Alignment.CenterHorizontally),
                    colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.error)
                ) {
                    Icon(Icons.Default.Delete, contentDescription = null)
                    Spacer(modifier = Modifier.width(8.dp))
                    Text("删除此足迹")
                }
            }
        }
    }
}

@Composable
fun ActivityTypeIcon(
    selectedId: String?,
    allTypes: List<ActivityTypeEntity>,
    onTypeSelected: (String?) -> Unit
) {
    var showMenu by remember { mutableStateOf(false) }
    val selected = allTypes.find { it.id == selectedId }
    
    Box {
        Box(
            modifier = Modifier
                .size(56.dp)
                .clip(CircleShape)
                .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f))
                .clickable { showMenu = true },
            contentAlignment = Alignment.Center
        ) {
            if (selected != null) {
                // 这里可以根据 icon 字符串映射到图标
                Icon(
                    imageVector = com.ct106.difangke.ui.components.getIconForName(selected.icon),
                    contentDescription = selected.name,
                    tint = try { Color(android.graphics.Color.parseColor(selected.colorHex)) } catch (e: Exception) { MaterialTheme.colorScheme.primary },
                    modifier = Modifier.size(28.dp)
                )
            } else {
                Icon(
                    Icons.Default.Category,
                    contentDescription = "选择类型",
                    tint = Color.Gray,
                    modifier = Modifier.size(24.dp)
                )
            }
        }
        
        DropdownMenu(expanded = showMenu, onDismissRequest = { showMenu = false }) {
            DropdownMenuItem(
                text = { Text("无类型") },
                onClick = { onTypeSelected(null); showMenu = false },
                leadingIcon = { Icon(Icons.Default.Close, contentDescription = null) }
            )
            allTypes.forEach { type ->
                DropdownMenuItem(
                    text = { Text(type.name) },
                    onClick = { onTypeSelected(type.id); showMenu = false },
                    leadingIcon = { 
                        Icon(
                            imageVector = com.ct106.difangke.ui.components.getIconForName(type.icon),
                            contentDescription = null,
                            tint = try { Color(android.graphics.Color.parseColor(type.colorHex)) } catch (e: Exception) { Color.Gray }
                        )
                    }
                )
            }
        }
    }
}

@Composable
fun ActivitySuggestions(
    allTypes: List<ActivityTypeEntity>,
    selectedId: String?,
    onTypeSelected: (String) -> Unit
) {
    if (selectedId != null) return
    
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text("建议: ", style = MaterialTheme.typography.bodySmall, color = Color.Gray)
        Spacer(modifier = Modifier.width(8.dp))
        allTypes.take(3).forEach { type ->
            SuggestionChip(
                onClick = { onTypeSelected(type.id) },
                label = { Text(type.name, fontSize = 12.sp) },
                modifier = Modifier.padding(end = 8.dp)
            )
        }
    }
}

@Composable
fun DetailMapView(footprint: FootprintEntity) {
    val isDark = androidx.compose.foundation.isSystemInDarkTheme()
    val primaryColor = MaterialTheme.colorScheme.primary.toArgb()
    
    AndroidView(
        factory = { ctx ->
            com.amap.api.maps.TextureMapView(ctx).apply {
                onCreate(Bundle())
                onResume()
            }
        },
        modifier = Modifier.fillMaxSize(),
        onRelease = { view ->
            view.onPause()
            view.onDestroy()
        }
    ) { view ->
        val amap = view.map
        amap.mapType = if (isDark) com.amap.api.maps.AMap.MAP_TYPE_NIGHT else com.amap.api.maps.AMap.MAP_TYPE_NORMAL
        
        amap.uiSettings.apply {
            isZoomControlsEnabled = false
            isMyLocationButtonEnabled = false
            isRotateGesturesEnabled = false
            isTiltGesturesEnabled = false
        }
        
        // 解析轨迹点
        val lats = try { JSONArray(footprint.latitudeJson) } catch (e: Exception) { JSONArray() }
        val lons = try { JSONArray(footprint.longitudeJson) } catch (e: Exception) { JSONArray() }
        
        if (lats.length() > 0) {
            val points = mutableListOf<com.amap.api.maps.model.LatLng>()
            val builder = com.amap.api.maps.model.LatLngBounds.Builder()
            
            for (i in 0 until lats.length()) {
                val p = com.amap.api.maps.model.LatLng(lats.getDouble(i), lons.getDouble(i))
                points.add(p)
                builder.include(p)
            }
            
            amap.clear()
            amap.addPolyline(
                com.amap.api.maps.model.PolylineOptions()
                    .addAll(points)
                    .width(12f)
                    .color(primaryColor)
                    .useGradient(true)
            )
            
            // 移动相机到轨迹范围
            if (points.size == 1) {
                amap.moveCamera(com.amap.api.maps.CameraUpdateFactory.newLatLngZoom(points[0], 17f))
            } else {
                try {
                    amap.moveCamera(com.amap.api.maps.CameraUpdateFactory.newLatLngBounds(builder.build(), 100))
                } catch (e: Exception) {
                    amap.moveCamera(com.amap.api.maps.CameraUpdateFactory.newLatLngZoom(points[0], 16f))
                }
            }
        }
    }
}



