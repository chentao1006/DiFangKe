package com.ct106.difangke.service

import android.util.Log
import com.amap.api.services.core.LatLonPoint
import com.amap.api.services.core.PoiItem
import com.amap.api.services.geocoder.*
import com.amap.api.services.poisearch.PoiResult
import com.amap.api.services.poisearch.PoiSearch
import com.ct106.difangke.DiFangKeApp
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume

/**
 * 高德地图地理编码与搜索服务
 * 使用 Android 原生 SDK 实现
 */
class GeocodeService private constructor() {

    companion object {
        val shared: GeocodeService by lazy { GeocodeService() }
        private const val TAG = "GeocodeService"
    }

    data class SearchResult(
        val name: String,
        val address: String,
        val latitude: Double,
        val longitude: Double,
        val isSavedPlace: Boolean = false,
        val placeID: String? = null
    )

    /**
     * 逆地理编码：获取语义化地址
     */
    suspend fun reverseGeocode(lat: Double, lon: Double): String? = suspendCancellableCoroutine { continuation ->
        val context = DiFangKeApp.instance
        try {
            val geocoderSearch = GeocodeSearch(context)
            geocoderSearch.setOnGeocodeSearchListener(object : GeocodeSearch.OnGeocodeSearchListener {
                override fun onRegeocodeSearched(result: RegeocodeResult?, rCode: Int) {
                    if (rCode == 1000 && result != null) {
                        val addr = result.regeocodeAddress
                        // 优先级：POI名称 > 建筑物 > 社区 > 街道门牌 > 格式化地址
                        val name = addr.pois?.firstOrNull()?.title
                            ?: addr.building.takeIf { it.isNotBlank() }
                            ?: addr.neighborhood.takeIf { it.isNotBlank() }
                            ?: (addr.township + addr.streetNumber?.street).takeIf { it.isNotBlank() }
                            ?: addr.formatAddress
                        
                        continuation.resume(name)
                    } else {
                        Log.w(TAG, "逆地理编码失败码：$rCode")
                        continuation.resume(null)
                    }
                }
                override fun onGeocodeSearched(result: GeocodeResult?, rCode: Int) {}
            })

            val query = RegeocodeQuery(LatLonPoint(lat, lon), 200f, GeocodeSearch.AMAP)
            geocoderSearch.getFromLocationAsyn(query)
        } catch (e: Exception) {
            continuation.resume(null)
        }
    }

    /**
     * 获取周边 POI：专门使用 PoiSearch 接口，确保能搜到大量地点
     */
    suspend fun getNearbyPOIs(
        centerLat: Double,
        centerLon: Double,
        radiusMeters: Int = 3000
    ): List<SearchResult> = suspendCancellableCoroutine { continuation ->
        val context = DiFangKeApp.instance
        try {
            // 第一个参数为空表示搜索所有类型，第二个参数为空表示所有分类
            val query = PoiSearch.Query("", "", "")
            query.pageSize = 30
            
            val poiSearch = PoiSearch(context, query)
            poiSearch.bound = PoiSearch.SearchBound(LatLonPoint(centerLat, centerLon), radiusMeters)
            
            poiSearch.setOnPoiSearchListener(object : PoiSearch.OnPoiSearchListener {
                override fun onPoiSearched(result: PoiResult?, rCode: Int) {
                    if (rCode == 1000 && result != null) {
                        val searchResults = result.pois.map { poi ->
                            SearchResult(
                                name = poi.title ?: "",
                                address = poi.snippet ?: "",
                                latitude = poi.latLonPoint.latitude,
                                longitude = poi.latLonPoint.longitude
                            )
                        }
                        continuation.resume(searchResults)
                    } else {
                        Log.w(TAG, "PoiSearch 失败码：$rCode")
                        continuation.resume(emptyList())
                    }
                }
                override fun onPoiItemSearched(poi: PoiItem?, rCode: Int) {}
            })
            
            poiSearch.searchPOIAsyn()
        } catch (e: Exception) {
            Log.e(TAG, "PoiSearch 异常", e)
            continuation.resume(emptyList())
        }
    }

    suspend fun searchNearby(
        keyword: String,
        centerLat: Double,
        centerLon: Double,
        radiusMeters: Int = 10000 // 搜索模式下范围扩大到 10km
    ): List<SearchResult> = suspendCancellableCoroutine { continuation ->
        val context = DiFangKeApp.instance
        try {
            val query = PoiSearch.Query(keyword, "", "")
            query.pageSize = 30
            
            val poiSearch = PoiSearch(context, query)
            // 搜索模式下可以根据需要决定是否限制范围
            poiSearch.bound = PoiSearch.SearchBound(LatLonPoint(centerLat, centerLon), radiusMeters)
            
            poiSearch.setOnPoiSearchListener(object : PoiSearch.OnPoiSearchListener {
                override fun onPoiSearched(result: PoiResult?, rCode: Int) {
                    if (rCode == 1000 && result != null) {
                        val searchResults = result.pois.map { poi ->
                            SearchResult(
                                name = poi.title ?: "",
                                address = poi.snippet ?: "",
                                latitude = poi.latLonPoint.latitude,
                                longitude = poi.latLonPoint.longitude
                            )
                        }
                        continuation.resume(searchResults)
                    } else {
                        continuation.resume(emptyList())
                    }
                }
                override fun onPoiItemSearched(poi: PoiItem?, rCode: Int) {}
            })
            poiSearch.searchPOIAsyn()
        } catch (e: Exception) {
            continuation.resume(emptyList())
        }
    }
}
