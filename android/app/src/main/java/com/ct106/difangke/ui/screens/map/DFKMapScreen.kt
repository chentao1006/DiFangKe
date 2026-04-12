package com.ct106.difangke.ui.screens.map

import android.os.Bundle
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
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

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DFKMapScreen(
    onBack: () -> Unit,
    viewModel: MapViewModel = viewModel()
) {
    val polylineColor = MaterialTheme.colorScheme.primary.toArgb()
    val pathPoints by viewModel.pathPoints.collectAsState()
    val isDark = androidx.compose.foundation.isSystemInDarkTheme()
    var hasCentredToNow by remember { mutableStateOf(false) }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("今日足迹") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.Default.ArrowBack, contentDescription = "返回")
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
                
                // 核心修复：如果是第一次进入页面，优先移动到当前轨迹最新的定位点
                if (!hasCentredToNow) {
                    val latest = latLngs.last()
                    // 只有当坐标有效时才移动（排除 0,0 异常）
                    if (latest.latitude != 0.0 && latest.longitude != 0.0) {
                        amap.moveCamera(CameraUpdateFactory.newLatLngZoom(latest, 16f))
                        hasCentredToNow = true
                    }
                }
            }
        }
    }
}
