package com.ct106.difangke.service

import android.util.Log
import com.ct106.difangke.AppConfig
import com.ct106.difangke.DiFangKeApp
import com.google.gson.Gson
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder

/**
 * 高德地图 REST 逆地理编码服务
 * 无需 AMap SDK，使用 HTTP 接口
 * API 文档：https://lbs.amap.com/api/webservice/guide/api/georegeo
 */
class GeocodeService private constructor() {

    companion object {
        val shared: GeocodeService by lazy { GeocodeService() }
        private const val TAG = "GeocodeService"
    }

    private val gson = Gson()

    /**
     * 逆地理编码（对应 iOS TimelineBuilder.resolveAddress）
     * @return 地址字符串（如"北京市朝阳区望京街道"），失败时返回 null
     */
    suspend fun reverseGeocode(lat: Double, lon: Double): String? = withContext(Dispatchers.IO) {
        val key = AppConfig.AMAP_REST_KEY
        if (key == "YOUR_AMAP_REST_KEY_HERE" || key.isBlank()) {
            Log.w(TAG, "高德 REST API Key 未配置，跳过逆地理编码")
            return@withContext null
        }

        runCatching {
            // 高德使用 GCJ-02 坐标，location 格式为 "经度,纬度"
            val urlStr = "${AppConfig.AMAP_GEOCODE_URL}?" +
                    "key=${URLEncoder.encode(key, "UTF-8")}" +
                    "&location=$lon,$lat" +
                    "&radius=500" +
                    "&extensions=base" +
                    "&output=json"

            val url = URL(urlStr)
            val conn = url.openConnection() as HttpURLConnection
            conn.apply {
                requestMethod = "GET"
                connectTimeout = 8000
                readTimeout = 8000
                setRequestProperty("User-Agent", "DiFangKe-Android/1.0")
            }

            val responseCode = conn.responseCode
            if (responseCode != 200) {
                Log.w(TAG, "Geocode HTTP $responseCode")
                return@runCatching null
            }

            val body = conn.inputStream.bufferedReader().readText()
            conn.disconnect()

            // 解析响应 JSON
            val root = gson.fromJson(body, Map::class.java)
            val status = root["status"] as? String
            if (status != "1") {
                val info = root["info"]
                Log.w(TAG, "Geocode API error: $info")
                return@runCatching null
            }

            // regeocode.formatted_address
            val regeocode = root["regeocode"] as? Map<*, *>
            val formattedAddress = regeocode?.get("formatted_address") as? String

            // 如果 formatted_address 太长，尝试取更简短的 addressComponent
            if (formattedAddress != null && formattedAddress.length <= 25) {
                formattedAddress
            } else {
                // 返回 district + township 作为更简短地址
                val addrComponent = regeocode?.get("addressComponent") as? Map<*, *>
                val district = addrComponent?.get("district") as? String ?: ""
                val township = addrComponent?.get("township") as? String ?: ""
                val streetNumber = addrComponent?.get("streetNumber") as? Map<*, *>
                val street = streetNumber?.get("street") as? String ?: ""
                val number = streetNumber?.get("number") as? String ?: ""
                val result = buildString {
                    if (district.isNotBlank()) append(district)
                    if (township.isNotBlank() && !district.endsWith(township)) append(township)
                    if (street.isNotBlank()) append(street)
                    if (number.isNotBlank()) append(number)
                }
                result.ifBlank { formattedAddress }
            }
        }.onFailure {
            Log.e(TAG, "Geocode failed", it)
        }.getOrNull()
    }

    /**
     * 关键词搜索（用于地点选择器）
     * 高德周边搜索 API
     */
    suspend fun searchNearby(
        keyword: String,
        centerLat: Double,
        centerLon: Double,
        radiusMeters: Int = 3000
    ): List<SearchResult> = withContext(Dispatchers.IO) {
        val key = AppConfig.AMAP_REST_KEY
        if (key == "YOUR_AMAP_REST_KEY_HERE" || key.isBlank()) {
            return@withContext emptyList()
        }

        runCatching {
            val urlStr = "https://restapi.amap.com/v3/place/around?" +
                    "key=$key" +
                    "&location=$centerLon,$centerLat" +
                    "&keywords=${URLEncoder.encode(keyword, "UTF-8")}" +
                    "&radius=$radiusMeters" +
                    "&output=json" +
                    "&page=1&offset=20"

            val url = URL(urlStr)
            val conn = url.openConnection() as HttpURLConnection
            conn.connectTimeout = 8000
            conn.readTimeout = 8000

            if (conn.responseCode != 200) return@runCatching emptyList()

            val body = conn.inputStream.bufferedReader().readText()
            conn.disconnect()

            val root = gson.fromJson(body, Map::class.java)
            if (root["status"] as? String != "1") return@runCatching emptyList()

            @Suppress("UNCHECKED_CAST")
            val pois = root["pois"] as? List<Map<*, *>> ?: emptyList()

            pois.mapNotNull { poi ->
                val name = poi["name"] as? String ?: return@mapNotNull null
                val address = poi["address"] as? String ?: ""
                val locationStr = poi["location"] as? String ?: return@mapNotNull null
                val parts = locationStr.split(",")
                if (parts.size < 2) return@mapNotNull null
                val lon = parts[0].toDoubleOrNull() ?: return@mapNotNull null
                val lat = parts[1].toDoubleOrNull() ?: return@mapNotNull null
                SearchResult(name = name, address = address, latitude = lat, longitude = lon)
            }
        }.onFailure {
            Log.e(TAG, "Search failed", it)
        }.getOrElse { emptyList() }
    }

    data class SearchResult(
        val name: String,
        val address: String,
        val latitude: Double,
        val longitude: Double
    )
}
