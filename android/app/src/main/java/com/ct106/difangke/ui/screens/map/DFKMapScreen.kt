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
import com.tencent.tencentmap.mapsdk.maps.TencentMap
import com.tencent.tencentmap.mapsdk.maps.MapView
import com.tencent.tencentmap.mapsdk.maps.CameraUpdateFactory
import com.tencent.tencentmap.mapsdk.maps.model.LatLng
import com.tencent.tencentmap.mapsdk.maps.model.LatLngBounds
import com.tencent.tencentmap.mapsdk.maps.model.MyLocationStyle
import com.tencent.tencentmap.mapsdk.maps.model.PolylineOptions
import com.ct106.difangke.ui.components.addFootprintMarkers
import com.ct106.difangke.ui.components.addImportantPlaceCircles
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
    val footprintMarkers by viewModel.footprintMarkers.collectAsState()
    val allPlaces by viewModel.allPlaces.collectAsState()
    val isDark = androidx.compose.foundation.isSystemInDarkTheme()
    var hasCentredToNow by remember { mutableStateOf(false) }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { 
                    val titleText = remember(dateTimestamp) {
                        if (dateTimestamp == null) "今日足迹"
                        else {
                            val cal1 = Calendar.getInstance()
                            val cal2 = Calendar.getInstance().apply { timeInMillis = dateTimestamp }
                            val isToday = cal1.get(Calendar.YEAR) == cal2.get(Calendar.YEAR) && 
                                          cal1.get(Calendar.DAY_OF_YEAR) == cal2.get(Calendar.DAY_OF_YEAR)
                            if (isToday) "今日足迹"
                            else {
                                val sdf = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.getDefault())
                                "${sdf.format(cal2.time)} 足迹"
                            }
                        }
                    }
                    Text(titleText) 
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
                com.tencent.tencentmap.mapsdk.maps.TextureMapView(ctx).apply {
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
                com.tencent.tencentmap.mapsdk.maps.TencentMap.MAP_TYPE_DARK
            } else {
                com.tencent.tencentmap.mapsdk.maps.TencentMap.MAP_TYPE_NORMAL
            }

            // 配置高德地图 UI
            amap.uiSettings.isZoomControlsEnabled = false
            amap.uiSettings.isMyLocationButtonEnabled = true
            amap.uiSettings.isRotateGesturesEnabled = false
            amap.uiSettings.isTiltGesturesEnabled = false
            
            // 策略选择：如果没有数据，就开启高德自动定位找人；如果有轨迹或足迹，就手动聚焦
            val myLocationStyle = MyLocationStyle()
            if (pathPoints.isEmpty() && footprintMarkers.isEmpty()) {
                // 情况 A：今天还没出门，开启自动定位并将地图移动到当前位置
                myLocationStyle.myLocationType(MyLocationStyle.LOCATION_TYPE_LOCATION_ROTATE)
            } else {
                // 情况 B：已有轨迹或足迹，显示蓝点但不自动改变相机（由我们代码控制相机）
                myLocationStyle.myLocationType(MyLocationStyle.LOCATION_TYPE_LOCATION_ROTATE_NO_CENTER)
            }
            amap.setMyLocationStyle(myLocationStyle)
            
            // 设置 LocationSource，修复点击定位按钮定位到大西洋(0,0)的问题
            amap.setLocationSource(object : com.tencent.tencentmap.mapsdk.maps.LocationSource {
                private var locationClient: com.tencent.map.geolocation.TencentLocationManager? = null
                private var locationListener: com.tencent.map.geolocation.TencentLocationListener? = null

                override fun activate(listener: com.tencent.tencentmap.mapsdk.maps.LocationSource.OnLocationChangedListener?) {
                    if (locationClient == null) {
                        try {
                            locationClient = com.tencent.map.geolocation.TencentLocationManager.getInstance(view.context.applicationContext)
                            locationListener = object : com.tencent.map.geolocation.TencentLocationListener {
                                override fun onStatusUpdate(name: String?, status: Int, desc: String?) = Unit
                                override fun onLocationChanged(location: com.tencent.map.geolocation.TencentLocation?, errorCode: Int, errorInfo: String?) {
                                    if (location != null && errorCode == com.tencent.map.geolocation.TencentLocation.ERROR_OK) {
                                        listener?.onLocationChanged(android.location.Location(location.provider).apply {
                                            latitude = location.latitude
                                            longitude = location.longitude
                                            accuracy = location.accuracy
                                            speed = location.speed
                                            time = location.time
                                        })
                                    } else {
                                        android.util.Log.e("MapLocation", "定位失败: $errorCode $errorInfo")
}

                                }
                            }
                        } catch (e: Exception) {
                            e.printStackTrace()
                        }
                    }
                    locationClient?.requestLocationUpdates(
                        com.tencent.map.geolocation.TencentLocationRequest.create()
                            .setLocMode(com.tencent.map.geolocation.TencentLocationRequest.HIGH_ACCURACY_MODE)
                            .setInterval(2000L)
                            .setRequestLevel(com.tencent.map.geolocation.TencentLocationRequest.REQUEST_LEVEL_GEO),
                        locationListener ?: return
                    )
                }

                override fun deactivate() {
                    locationListener?.let { locationClient?.removeUpdates(it) }
                    locationClient = null
                }
            })
            
            amap.isMyLocationEnabled = true

            amap.clear()
            amap.addImportantPlaceCircles(allPlaces)
            amap.addFootprintMarkers(footprintMarkers, isDark = isDark)

            val validLatLngs = mutableListOf<LatLng>()
            footprintMarkers.forEach {
                validLatLngs.add(LatLng(it.latitude, it.longitude))
            }
            
            // 绘制轨迹
            if (pathPoints.isNotEmpty()) {
                class SegmentInfo(val points: MutableList<MapPathPoint> = mutableListOf(), var connectToNextWithDash: Boolean = false)
                val segments = mutableListOf<SegmentInfo>()
                var currentSegment = SegmentInfo()
                var previousPoint: MapPathPoint? = null

                pathPoints.forEach { point ->
                    if (point.isSeparator) {
                        if (currentSegment.points.isNotEmpty()) {
                            currentSegment.connectToNextWithDash = point.connectsPreviousToNext
                            segments.add(currentSegment)
                            currentSegment = SegmentInfo()
                        }
                        previousPoint = null
                    } else {
                        validLatLngs.add(LatLng(point.latitude, point.longitude))
                        
                        var isDashed = false
                        val previous = previousPoint
                        if (previous != null && !previous.isSeparator) {
                            val timeGap = if (point.timestamp != null && previous.timestamp != null) {
                                kotlin.math.abs(point.timestamp - previous.timestamp)
                            } else 0L
                            if (timeGap > 5 * 60 * 1000L) {
                                isDashed = true
                            }
                        }

                        if (isDashed && previous != null) {
                            if (currentSegment.points.isNotEmpty()) {
                                currentSegment.connectToNextWithDash = true
                                segments.add(currentSegment)
                                currentSegment = SegmentInfo()
                            }
                        }
                        
                        currentSegment.points.add(point)
                        previousPoint = point
                    }
                }
                if (currentSegment.points.isNotEmpty()) {
                    segments.add(currentSegment)
                }

                // 处理并平滑所有连续线段
                val processedSegments = segments.map { segmentInfo ->
                    val segment = segmentInfo.points
                    val splineLatLngs = mutableListOf<LatLng>()
                    
                    if (segment.size > 1) {
                        val filtered = mutableListOf<MapPathPoint>()
                        filtered.add(segment.first())
                        for (i in 1 until segment.size - 1) {
                            val prev = filtered.last()
                            val curr = segment[i]
                            val dist = distanceMeters(
                                LatLng(prev.latitude, prev.longitude),
                                LatLng(curr.latitude, curr.longitude)
                            )
                            if (dist > 4f) {
                                filtered.add(curr)
                            }
                        }
                        if (segment.size > 2) {
                            filtered.add(segment.last())
                        } else if (segment.size == 2) {
                            filtered.add(segment[1])
                        }

                        val averagedLatLngs = mutableListOf<LatLng>()
                        val windowSize = 5
                        val halfWindow = windowSize / 2
                        for (i in filtered.indices) {
                            if (i == 0 || i == filtered.size - 1) {
                                averagedLatLngs.add(LatLng(filtered[i].latitude, filtered[i].longitude))
                                continue
                            }
                            var sumLat = 0.0; var sumLng = 0.0; var count = 0
                            val start = maxOf(0, i - halfWindow)
                            val end = minOf(filtered.size - 1, i + halfWindow)
                            for (j in start..end) {
                                sumLat += filtered[j].latitude
                                sumLng += filtered[j].longitude
                                count++
                            }
                            averagedLatLngs.add(LatLng(sumLat / count, sumLng / count))
                        }

                        if (averagedLatLngs.size >= 3) {
                            val granularity = 10
                            for (i in 0 until averagedLatLngs.size - 1) {
                                val p0 = averagedLatLngs[maxOf(i - 1, 0)]
                                val p1 = averagedLatLngs[i]
                                val p2 = averagedLatLngs[i + 1]
                                val p3 = averagedLatLngs[minOf(i + 2, averagedLatLngs.size - 1)]
                                for (tStep in 0 until granularity) {
                                    val t = tStep.toDouble() / granularity.toDouble()
                                    val t2 = t * t; val t3 = t2 * t
                                    val lat = 0.5 * ((2.0 * p1.latitude) + (-p0.latitude + p2.latitude) * t + (2.0 * p0.latitude - 5.0 * p1.latitude + 4.0 * p2.latitude - p3.latitude) * t2 + (-p0.latitude + 3.0 * p1.latitude - 3.0 * p2.latitude + p3.latitude) * t3)
                                    val lon = 0.5 * ((2.0 * p1.longitude) + (-p0.longitude + p2.longitude) * t + (2.0 * p0.longitude - 5.0 * p1.longitude + 4.0 * p2.longitude - p3.longitude) * t2 + (-p0.longitude + 3.0 * p1.longitude - 3.0 * p2.longitude + p3.longitude) * t3)
                                    splineLatLngs.add(LatLng(lat, lon))
                                }
                            }
                            splineLatLngs.add(averagedLatLngs.last())
                        } else {
                            splineLatLngs.addAll(averagedLatLngs)
                        }
                    }
                    Pair(segmentInfo, splineLatLngs)
                }

                // 绘制实线
                processedSegments.forEach { (_, splined) ->
                    if (splined.isNotEmpty()) {
                        val options = PolylineOptions().addAll(splined).width(15f).color(polylineColor).gradient(true)
                        amap.addPolyline(options)
                    }
                }

                // 绘制虚线：使用三次贝塞尔曲线，使其顺着前后实线的切线方向延伸
                for (i in 0 until processedSegments.size - 1) {
                    val (segA, splinedA) = processedSegments[i]
                    val (_, splinedB) = processedSegments[i + 1]
                    
                    if (segA.connectToNextWithDash && splinedA.isNotEmpty() && splinedB.isNotEmpty()) {
                        val p0 = splinedA.last()
                        val p3 = splinedB.first()
                        
                        val p0TangentPrev = if (splinedA.size >= 10) splinedA[splinedA.size - 1 - minOf(splinedA.size - 1, 10)] else if (splinedA.size >= 2) splinedA.first() else null
                        val p3TangentNext = if (splinedB.size >= 10) splinedB[minOf(splinedB.size - 1, 10)] else if (splinedB.size >= 2) splinedB.last() else null
                        
                        val dLat0 = if (p0TangentPrev != null) p0.latitude - p0TangentPrev.latitude else 0.0
                        val dLon0 = if (p0TangentPrev != null) p0.longitude - p0TangentPrev.longitude else 0.0
                        val dLat3 = if (p3TangentNext != null) p3TangentNext.latitude - p3.latitude else 0.0
                        val dLon3 = if (p3TangentNext != null) p3TangentNext.longitude - p3.longitude else 0.0
                        
                        val distLat = p3.latitude - p0.latitude
                        val distLon = p3.longitude - p0.longitude
                        val dist = Math.sqrt(distLat*distLat + distLon*distLon)
                        
                        val len0 = Math.sqrt(dLat0*dLat0 + dLon0*dLon0)
                        val len3 = Math.sqrt(dLat3*dLat3 + dLon3*dLon3)
                        
                        val maxTangent = 0.005
                        val tLen0 = minOf(dist * 0.35, maxTangent)
                        val tLen3 = minOf(dist * 0.35, maxTangent)
                        val tLenFallback = minOf(dist * 0.3, maxTangent)
                        val scale0 = if (len0 > 0) tLen0 / len0 else 0.0
                        val scale3 = if (len3 > 0) tLen3 / len3 else 0.0
                        val fallbackScale = if (dist > 0) tLenFallback / dist else 0.0
                        
                        val c1 = LatLng(
                            p0.latitude + (if(len0 > 0) dLat0 * scale0 else distLat * fallbackScale),
                            p0.longitude + (if(len0 > 0) dLon0 * scale0 else distLon * fallbackScale)
                        )
                        val c2 = LatLng(
                            p3.latitude - (if(len3 > 0) dLat3 * scale3 else distLat * fallbackScale),
                            p3.longitude - (if(len3 > 0) dLon3 * scale3 else distLon * fallbackScale)
                        )
                        
                        val bezierPoints = mutableListOf<LatLng>()
                        val steps = 20
                        for (j in 0..steps) {
                            val t = j.toDouble() / steps.toDouble()
                            val u = 1.0 - t
                            val u2 = u * u
                            val u3 = u2 * u
                            val t2 = t * t
                            val t3 = t2 * t
                            val lat = u3 * p0.latitude + 3.0 * u2 * t * c1.latitude + 3.0 * u * t2 * c2.latitude + t3 * p3.latitude
                            val lon = u3 * p0.longitude + 3.0 * u2 * t * c1.longitude + 3.0 * u * t2 * c2.longitude + t3 * p3.longitude
                            bezierPoints.add(LatLng(lat, lon))
                        }
                        
                        val dashedOptions = PolylineOptions().addAll(bezierPoints).width(15f).color(polylineColor)
                        amap.addPolyline(dashedOptions)
                    }
                }
            }

            // 核心优化：自动调整缩放和范围，使轨迹和足迹完整显示
            if (!hasCentredToNow) {
                if (validLatLngs.size > 1) {
                        val boundsBuilder = LatLngBounds.Builder()
                        validLatLngs.forEach { boundsBuilder.include(it) }
                        val bounds = boundsBuilder.build()
                        val centerLat = (bounds.northeast.latitude + bounds.southwest.latitude) / 2
                        val centerLon = (bounds.northeast.longitude + bounds.southwest.longitude) / 2
                        val center = LatLng(centerLat, centerLon)

                        val distance = distanceMeters(bounds.southwest, bounds.northeast)

                        val doBounds = {
                            val paddingPx = (30 * view.context.resources.displayMetrics.density).toInt()
                            try {
                                if (distance < 500f) {
                                    // 只有一个足迹或小范围活动，避免放太大，给一个13.5的区级视野
                                    amap.moveCamera(CameraUpdateFactory.newLatLngZoom(center, 13.5f))
                                } else {
                                    amap.moveCamera(CameraUpdateFactory.newLatLngBounds(bounds, paddingPx))
                                    if (amap.cameraPosition.zoom > 16f) {
                                        amap.moveCamera(CameraUpdateFactory.zoomTo(16f))
                                    }
                                }
                            } catch (e: Exception) {
                                amap.moveCamera(CameraUpdateFactory.newLatLngZoom(center, 13.5f))
                            }
                        }

                        if (view.width > 0 && view.height > 0) {
                            doBounds()
                        } else {
                            amap.moveCamera(CameraUpdateFactory.newLatLngZoom(center, 12f))
                            amap.addOnMapLoadedCallback { doBounds() }
                        }
                        hasCentredToNow = true
                    } else if (validLatLngs.isNotEmpty()) {
                        val latest = validLatLngs.last()
                        if (latest.latitude != 0.0 && latest.longitude != 0.0) {
                            amap.moveCamera(CameraUpdateFactory.newLatLngZoom(latest, 14.5f))
                            hasCentredToNow = true
                    }
                }
            }
        }
    }
}

private fun distanceMeters(first: LatLng, second: LatLng): Float {
    val earthRadius = 6_371_000.0
    val dLat = Math.toRadians(second.latitude - first.latitude)
    val dLon = Math.toRadians(second.longitude - first.longitude)
    val a = kotlin.math.sin(dLat / 2) * kotlin.math.sin(dLat / 2) +
        kotlin.math.cos(Math.toRadians(first.latitude)) * kotlin.math.cos(Math.toRadians(second.latitude)) *
        kotlin.math.sin(dLon / 2) * kotlin.math.sin(dLon / 2)
    return (earthRadius * 2 * kotlin.math.atan2(kotlin.math.sqrt(a), kotlin.math.sqrt(1 - a))).toFloat()
}
