package com.ct106.difangke.ui.screens.map

import android.os.Bundle
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.ArrowBack
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.viewmodel.compose.viewModel
import com.amap.api.maps.AMap
import com.amap.api.maps.MapView
import com.amap.api.maps.CameraUpdateFactory
import com.amap.api.maps.model.LatLng
import com.amap.api.maps.model.LatLngBounds
import com.amap.api.maps.model.MyLocationStyle
import com.amap.api.maps.model.PolylineOptions
import java.util.Calendar

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DFKMapScreen(
    onBack: () -> Unit,
    dateTimestamp: Long? = null,
    viewModel: MapViewModel = viewModel()
) {
    LaunchedEffect(dateTimestamp) {
        viewModel.loadPathForDate(dateTimestamp)
    }
    val polylineColor = MaterialTheme.colorScheme.primary.toArgb()
    val pathPoints by viewModel.pathPoints.collectAsState()
    val isDark = androidx.compose.foundation.isSystemInDarkTheme()
    var hasCentredToNow by remember { mutableStateOf(false) }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { 
                    val isToday = remember(dateTimestamp) {
                        if (dateTimestamp == null) true
                        else {
                            val cal1 = Calendar.getInstance()
                            val cal2 = Calendar.getInstance().apply { timeInMillis = dateTimestamp }
                            cal1.get(Calendar.YEAR) == cal2.get(Calendar.YEAR) && 
                            cal1.get(Calendar.DAY_OF_YEAR) == cal2.get(Calendar.DAY_OF_YEAR)
                        }
                    }
                    Text(if (isToday) "今日足迹" else "历史足迹") 
                },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "返回")
                    }
                }
            )
        }
    ) { padding ->
        AndroidView(
            factory = { ctx ->
                com.amap.api.maps.TextureMapView(ctx).apply {
                    onCreate(Bundle())
                    onResume()
                }
            },
            modifier = Modifier
                .fillMaxSize()
                .padding(padding),
            onRelease = { view ->
                view.onPause()
                view.onDestroy()
            }
        ) { view ->
            val amap = view.map
            
            // 设置地图模式：根据系统深色模式自动切换
            amap.mapType = if (isDark) {
                com.amap.api.maps.AMap.MAP_TYPE_NIGHT 
            } else {
                com.amap.api.maps.AMap.MAP_TYPE_NORMAL
            }

            // 配置高德地图 UI
            amap.uiSettings.isZoomControlsEnabled = false
            amap.uiSettings.isMyLocationButtonEnabled = true
            amap.uiSettings.isRotateGesturesEnabled = false
            amap.uiSettings.isTiltGesturesEnabled = false
            
            // 策略选择：如果没有轨迹点，就开启高德自动定位找人；如果有轨迹，就手动聚焦到轨迹末端
            val myLocationStyle = MyLocationStyle()
            if (pathPoints.isEmpty()) {
                // 情况 A：今天还没出门，开启自动定位并将地图移动到当前位置
                myLocationStyle.myLocationType(MyLocationStyle.LOCATION_TYPE_LOCATE)
            } else {
                // 情况 B：已有轨迹，显示蓝点但不自动改变相机（由我们代码控制相机）
                myLocationStyle.myLocationType(MyLocationStyle.LOCATION_TYPE_LOCATION_ROTATE_NO_CENTER)
            }
            amap.myLocationStyle = myLocationStyle
            amap.isMyLocationEnabled = true
            
            // 绘制轨迹
            if (pathPoints.isNotEmpty()) {
                amap.clear()
                val latLngs = pathPoints.map { LatLng(it.first, it.second) }
                amap.addPolyline(
                    PolylineOptions()
                        .addAll(latLngs)
                        .width(15f)
                        .color(polylineColor)
                        .useGradient(true)
                )
                
                // 核心优化：自动调整缩放和范围，使轨迹完整显示
                if (!hasCentredToNow) {
                    if (latLngs.size > 1) {
                        val boundsBuilder = LatLngBounds.Builder()
                        latLngs.forEach { boundsBuilder.include(it) }
                        val bounds = boundsBuilder.build()
                        // 延迟一两帧执行，确保地图 View 尺寸已测量
                        amap.animateCamera(CameraUpdateFactory.newLatLngBounds(bounds, 150))
                        hasCentredToNow = true
                    } else if (latLngs.isNotEmpty()) {
                        val latest = latLngs.last()
                        if (latest.latitude != 0.0 && latest.longitude != 0.0) {
                            amap.moveCamera(CameraUpdateFactory.newLatLngZoom(latest, 16f))
                            hasCentredToNow = true
                        }
                    }
                }
            }
        }
    }
}
