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
                        val name = coarseAutomaticPlaceName(
                            listOfNotNull(
                                addr.aois?.firstOrNull()?.aoiName,
                                addr.building,
                                addr.neighborhood,
                                addr.pois?.firstOrNull()?.title,
                                listOfNotNull(addr.district, addr.township).joinToString("")
                            )
                        )
                        
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

    fun coarseAutomaticPlaceName(candidates: List<String?>): String? {
        val cleaned = candidates
            .mapNotNull { it?.trim() }
            .filter { it.isNotEmpty() }

        cleaned.firstOrNull { isCoarseAutomaticPlaceName(it) }?.let { return it }

        return cleaned.lastOrNull { name ->
            !hasFinePlaceSignal(name) && name.length <= 12
        }
    }

    private fun isCoarseAutomaticPlaceName(name: String): Boolean {
        if (hasFinePlaceSignal(name)) return false

        val coarseKeywords = listOf(
            "景区", "景点", "公园", "广场", "博物馆", "美术馆", "图书馆", "体育馆", "展览馆",
            "商场", "购物中心", "中心", "大厦", "大楼", "写字楼", "园区", "科技园", "产业园",
            "大学", "学院", "学校", "医院", "酒店", "机场", "火车站", "高铁站", "地铁站",
            "车站", "码头", "社区", "小区", "花园", "公寓", "住宅", "村", "镇", "街道"
        )

        return coarseKeywords.any { name.contains(it) }
    }

    private fun hasFinePlaceSignal(name: String): Boolean {
        val finePatterns = listOf(
            Regex("""\d+\s*号"""),
            Regex("""\d+\s*弄"""),
            Regex("""\d+\s*室"""),
            Regex("""\d+\s*层"""),
            Regex("""\d+\s*楼"""),
            Regex("""[\dA-Za-z一二三四五六七八九十]+号楼"""),
            Regex("""[\dA-Za-z一二三四五六七八九十]+栋"""),
            Regex("""单元|门牌|入口|出口|柜台|摊|铺|档口"""),
            Regex("""店$|分店|便利店|超市|餐厅|饭店|咖啡|奶茶|茶饮|甜品|小吃|烧烤|火锅|面馆|粉店|酒吧"""),
            Regex("""药房|药店|诊所|理发|美甲|洗衣|快递|驿站""")
        )

        return finePatterns.any { it.containsMatchIn(name) }
    }
}
