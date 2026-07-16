package com.ct106.difangke.service

import android.net.Uri
import android.util.Log
import com.ct106.difangke.BuildConfig
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONObject

/**
 * 腾讯位置服务的地理编码与 POI 搜索。
 */
class GeocodeService private constructor() {

    companion object {
        val shared: GeocodeService by lazy { GeocodeService() }
        private const val TAG = "GeocodeService"
        private const val BASE_URL = "https://apis.map.qq.com/ws"
    }

    private val httpClient = OkHttpClient()

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
    suspend fun reverseGeocode(lat: Double, lon: Double): String? = withContext(Dispatchers.IO) {
        val result = getJson("/geocoder/v1/?location=$lat,$lon&get_poi=1") ?: return@withContext null
        val payload = result.optJSONObject("result") ?: return@withContext null
        val pois = payload.optJSONArray("pois")
        val firstPoi = pois?.optJSONObject(0)?.optString("title")
        val addressComponent = payload.optJSONObject("address_component")
        coarseAutomaticPlaceName(
            listOf(
                firstPoi,
                payload.optString("address"),
                addressComponent?.optString("district"),
                addressComponent?.optString("street")
            )
        )
    }

    /**
     * 获取周边 POI：专门使用 PoiSearch 接口，确保能搜到大量地点
     */
    suspend fun getNearbyPOIs(
        centerLat: Double,
        centerLon: Double,
        radiusMeters: Int = 3000
    ): List<SearchResult> = searchTencentPois("", centerLat, centerLon, radiusMeters)

    suspend fun searchNearby(
        keyword: String,
        centerLat: Double,
        centerLon: Double,
        radiusMeters: Int = 10000 // 搜索模式下范围扩大到 10km
    ): List<SearchResult> = searchTencentPois(keyword, centerLat, centerLon, radiusMeters)

    private suspend fun searchTencentPois(keyword: String, lat: Double, lon: Double, radius: Int): List<SearchResult> =
        withContext(Dispatchers.IO) {
            val encodedKeyword = Uri.encode(keyword)
            val json = getJson("/place/v1/search?keyword=$encodedKeyword&boundary=nearby($lat,$lon,$radius)&page_size=30")
                ?: return@withContext emptyList()
            val data = json.optJSONArray("data") ?: return@withContext emptyList()
            buildList {
                for (index in 0 until data.length()) {
                    val poi = data.optJSONObject(index) ?: continue
                    val location = poi.optJSONObject("location") ?: continue
                    add(SearchResult(poi.optString("title"), poi.optString("address"), location.optDouble("lat"), location.optDouble("lng")))
                }
            }
        }

    private fun getJson(pathAndQuery: String): JSONObject? = try {
        val separator = if (pathAndQuery.contains('?')) '&' else '?'
        val url = "$BASE_URL$pathAndQuery${separator}key=${BuildConfig.TENCENT_MAP_KEY}"
        httpClient.newCall(Request.Builder().url(url).build()).execute().use { response ->
            if (!response.isSuccessful) return null
            response.body?.string()?.let(::JSONObject)?.takeIf { it.optInt("status") == 0 }
        }
    } catch (error: Exception) {
        Log.w(TAG, "Tencent location service request failed", error)
        null
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
