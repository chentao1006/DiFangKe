package com.ct106.difangke.service

import android.net.Uri
import android.location.Location
import android.location.Geocoder
import android.util.Log
import com.ct106.difangke.BuildConfig
import com.ct106.difangke.DiFangKeApp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap

/**
 * 腾讯位置服务的地理编码与 POI 搜索。
 */
class GeocodeService private constructor() {

    companion object {
        val shared: GeocodeService by lazy { GeocodeService() }
        private const val TAG = "GeocodeService"
        private const val BASE_URL = "https://apis.map.qq.com/ws"
        private val routeOptionsCache = ConcurrentHashMap<String, List<RoutePlan>>()
        private val cityIdentityCache = ConcurrentHashMap<String, String>()

        /** iOS `applyingTransform("Traditional-Simplified")`; identity before API 29. */
        fun simplifiedChinese(value: String): String {
            if (value.isEmpty() || android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.Q) return value
            return runCatching {
                android.icu.text.Transliterator.getInstance("Traditional-Simplified").transliterate(value)
            }.getOrDefault(value)
        }

        /** zh_Hans_CN country name for an ISO region code. */
        fun countryDisplayName(countryCode: String?): String? {
            val code = countryCode?.trim()?.uppercase()?.takeIf { it.length == 2 } ?: return null
            return Locale.Builder().setRegion(code).build()
                .getDisplayCountry(Locale.SIMPLIFIED_CHINESE)
                .takeIf { it.isNotBlank() && it != code }
        }

        fun flagEmoji(countryCode: String): String {
            val code = countryCode.trim().uppercase()
            if (code.length != 2 || !code.all { it in 'A'..'Z' }) return ""
            return code.map { String(Character.toChars(127397 + it.code)) }.joinToString("")
        }
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

    data class ReverseGeocodeResult(
        val address: String?,
        val countryCode: String?,
        val countryName: String?,
        val cityName: String?,
        val cityIdentifier: String?
    )

    data class CitySearchResult(
        val cityName: String,
        val countryCode: String,
        val countryName: String,
        val latitude: Double,
        val longitude: Double,
        val cityIdentifier: String? = null
    )

    data class RouteInstruction(
        val title: String,
        val detail: String?,
        val transportTypeRaw: String,
        val latitude: Double? = null,
        val longitude: Double? = null,
        val points: List<Pair<Double, Double>> = emptyList()
    )

    data class RoutePlan(
        val points: List<Pair<Double, Double>>,
        val distanceMeters: Double,
        val durationMinutes: Double,
        val instructions: List<RouteInstruction>
    )

    /** Global city lookup normalized to city-level results only. */
    suspend fun searchCities(keyword: String): List<CitySearchResult> = withContext(Dispatchers.IO) {
        val query = keyword.trim()
        if (query.isEmpty()) return@withContext emptyList()
        val globalResults = runCatching {
            @Suppress("DEPRECATION")
            fun addresses(locale: Locale) = Geocoder(DiFangKeApp.instance, locale)
                .getFromLocationName(query, 20).orEmpty()

            val english = addresses(Locale.ENGLISH).filter { !it.countryCode.equals("CN", ignoreCase = true) }
            val simplifiedChinese = addresses(Locale.SIMPLIFIED_CHINESE).filter { it.countryCode.equals("CN", ignoreCase = true) }
            (english + simplifiedChinese).mapNotNull { address ->
                    val candidates = sequenceOf(address.locality, address.subAdminArea, address.subLocality, address.adminArea)
                        .mapNotNull { it?.trim()?.takeIf(String::isNotEmpty) }
                        .filterNot { it.endsWith("街道") }
                        .toList()
                    val city = candidates.firstOrNull { candidate ->
                        candidate.contains(query, ignoreCase = true) || query.contains(candidate, ignoreCase = true)
                    } ?: candidates.firstOrNull() ?: return@mapNotNull null
                    val code = address.countryCode?.trim()?.uppercase().orEmpty()
                    CitySearchResult(
                        cityName = city,
                        countryCode = code,
                        countryName = address.countryName?.trim().orEmpty().ifEmpty { countryDisplayName(code).orEmpty() },
                        latitude = address.latitude,
                        longitude = address.longitude
                    )
                }
        }.getOrDefault(emptyList())

        val json = getJson("/place/v1/suggestion?keyword=${Uri.encode(query)}&region=${Uri.encode("全国")}&region_fix=0&page_size=20")
        val domesticResults = buildList {
            val data = json?.optJSONArray("data") ?: return@buildList
            for (index in 0 until data.length()) {
                val item = data.optJSONObject(index) ?: continue
                val info = item.optJSONObject("ad_info") ?: continue
                val district = info.optString("district").trim()
                val resultName = item.optString("title").trim()
                val city = resultName
                    .takeIf { it.isSupportedAdministrativeName() && it.matchesAdministrativeQuery(query) }
                    ?: district.takeIf { it.isSupportedAdministrativeName() && it.matchesAdministrativeQuery(query) }
                    ?: info.optString("city").trim().ifEmpty { info.optString("province").trim() }
                val location = item.optJSONObject("location") ?: continue
                if (city.isEmpty()) continue
                val nationName = info.optString("nation").trim()
                val rawNationCode = info.optString("nation_code").trim().uppercase()
                val code = countryCodeForName(nationName)
                    ?: rawNationCode.takeIf { it.length == 2 }
                    ?: if (rawNationCode == "156") "CN" else rawNationCode
                val countryName = nationName.ifEmpty { countryDisplayName(code).orEmpty() }
                val adcode = normalizedTencentCityCode(
                    info.optString("adcode").trim(),
                    info.optString("city_code").trim(),
                    rawNationCode
                )
                val identifier = adcode.takeIf(String::isNotEmpty)?.let {
                    "tencent:${rawNationCode.lowercase()}:${it.lowercase()}"
                }
                add(CitySearchResult(city, code, countryName, location.optDouble("lat"), location.optDouble("lng"), identifier))
            }
        }
        val foldedQuery = query.lowercase(Locale.getDefault())
        val matchingDomesticResults = domesticResults.filter {
                "${it.cityName} ${it.countryName} ${it.countryCode}"
                    .lowercase(Locale.getDefault())
                    .contains(foldedQuery)
            }
        (globalResults + matchingDomesticResults)
            .distinctBy { it.cityIdentifier ?: "${it.countryCode.uppercase()}|${it.cityName.lowercase()}" }
    }

    private fun String.isSupportedAdministrativeName(): Boolean =
        listOf("自治县", "自治旗", "民族乡", "民族苏木", "林区", "特区", "市", "县", "旗", "镇", "乡", "苏木")
            .any { suffix -> endsWith(suffix) }

    private fun String.matchesAdministrativeQuery(query: String): Boolean {
        val suffixes = listOf("自治县", "自治旗", "民族乡", "民族苏木", "林区", "特区", "市", "县", "旗", "镇", "乡", "苏木")
        val suffix = suffixes.firstOrNull { endsWith(it) } ?: return false
        val normalizedName = simplifiedChinese(this).trim()
        val normalizedBaseName = simplifiedChinese(removeSuffix(suffix)).trim()
        val normalizedQuery = simplifiedChinese(query).trim()
        return normalizedName.equals(normalizedQuery, ignoreCase = true) ||
            normalizedBaseName.equals(normalizedQuery, ignoreCase = true)
    }

    /**
     * 逆地理编码：获取语义化地址
     */
    suspend fun reverseGeocode(lat: Double, lon: Double): String? =
        reverseGeocodeDetails(lat, lon)?.address

    /** Returns display address and geographic hierarchy from the same response. */
    suspend fun reverseGeocodeDetails(lat: Double, lon: Double): ReverseGeocodeResult? = withContext(Dispatchers.IO) {
        val result = getJson("/geocoder/v1/?location=$lat,$lon&get_poi=1") ?: return@withContext null
        val payload = result.optJSONObject("result") ?: return@withContext null
        val pois = payload.optJSONArray("pois")
        val firstPoi = pois?.optJSONObject(0)?.optString("title")
        val addressComponent = payload.optJSONObject("address_component")
        val address = coarseAutomaticPlaceName(
            listOf(
                firstPoi,
                payload.optString("address"),
                addressComponent?.optString("district"),
                addressComponent?.optString("street")
            )
        )
        val countryName = addressComponent?.optString("nation")?.trim()?.takeIf { it.isNotEmpty() }
        val countryCode = countryName?.let(::countryCodeForName)
        val cityName = sequenceOf("city", "district", "province")
            .mapNotNull { key -> addressComponent?.optString(key)?.trim()?.takeIf(String::isNotEmpty) }
            .firstOrNull()
        val adInfo = payload.optJSONObject("ad_info")
        val adcode = normalizedTencentCityCode(
            adInfo?.optString("adcode")?.trim().orEmpty(),
            adInfo?.optString("city_code")?.trim().orEmpty(),
            adInfo?.optString("nation_code")?.trim().orEmpty()
        )
        val nationCode = adInfo?.optString("nation_code")?.trim().orEmpty()
        val cityIdentifier = adcode.takeIf(String::isNotEmpty)?.let {
            "tencent:${nationCode.lowercase()}:${it.lowercase()}"
        } ?: globalCityIdentifier(lat, lon, cityName.orEmpty(), countryCode.orEmpty())
        ReverseGeocodeResult(address, countryCode, countryName, cityName, cityIdentifier)
    }

    /** Stable city identity for configured/search-selected cities and POI reverse geocoding alike. */
    suspend fun resolveCityIdentifier(
        lat: Double,
        lon: Double,
        cityName: String,
        countryCode: String
    ): String? = withContext(Dispatchers.IO) {
        val cacheKey = String.format(Locale.US, "%.4f,%.4f", lat, lon)
        cityIdentityCache[cacheKey]?.let { return@withContext it }
        val tencent = getJson("/geocoder/v1/?location=$lat,$lon&get_poi=0")
            ?.optJSONObject("result")
            ?.optJSONObject("ad_info")
        val adcode = normalizedTencentCityCode(
            tencent?.optString("adcode")?.trim().orEmpty(),
            tencent?.optString("city_code")?.trim().orEmpty(),
            tencent?.optString("nation_code")?.trim().orEmpty()
        )
        val nationCode = tencent?.optString("nation_code")?.trim().orEmpty()
        val identifier = if (adcode.isNotEmpty()) {
            "tencent:${nationCode.lowercase()}:${adcode.lowercase()}"
        } else {
            globalCityIdentifier(lat, lon, cityName, countryCode)
        }
        identifier?.let { cityIdentityCache[cacheKey] = it }
        identifier
    }

    private fun globalCityIdentifier(
        lat: Double,
        lon: Double,
        cityName: String,
        countryCode: String
    ): String? = try {
        val url = "https://api.bigdatacloud.net/data/reverse-geocode-client" +
            "?latitude=${Uri.encode(lat.toString())}&longitude=${Uri.encode(lon.toString())}&localityLanguage=en"
        httpClient.newCall(Request.Builder().url(url).build()).execute().use { response ->
            if (!response.isSuccessful) return null
            val payload = response.body?.string()?.let(::JSONObject) ?: return null
            val targets = listOf(cityName, payload.optString("city"), payload.optString("locality"))
                .map(::normalizedCityIdentityName)
                .filter(String::isNotEmpty)
            val localityInfo = payload.optJSONObject("localityInfo")
            val areas = buildList<JSONObject> {
                listOf("administrative", "informative").forEach { key ->
                    val array = localityInfo?.optJSONArray(key) ?: return@forEach
                    for (index in 0 until array.length()) array.optJSONObject(index)?.let(::add)
                }
            }
            val area = areas.firstOrNull {
                normalizedCityIdentityName(it.optString("name")) in targets
            } ?: return null
            val geonameID = area.optString("geonameId").trim()
            if (geonameID.isNotEmpty()) return "geonames:${geonameID.lowercase()}"
            val wikidataID = area.optString("wikidataId").trim()
            if (wikidataID.isNotEmpty()) return "wikidata:${wikidataID.lowercase()}"
            val isoCode = area.optString("isoCode").trim()
            if (isoCode.isNotEmpty()) return "iso:${countryCode.lowercase()}:${isoCode.lowercase()}"
            null
        }
    } catch (error: Exception) {
        Log.w(TAG, "Global city identity request failed", error)
        null
    }

    private fun normalizedCityIdentityName(value: String): String = simplifiedChinese(value)
        .lowercase(Locale.getDefault())
        .replace(" ", "")
        .replace("市", "")
        .replace("特别行政区", "")

    private fun normalizedTencentCityCode(adcode: String, cityCode: String, nationCode: String): String {
        if (cityCode.isNotEmpty()) return cityCode
        if (nationCode != "156" || adcode.length != 6) return adcode
        return if (adcode.take(2) in setOf("11", "12", "31", "50")) {
            adcode.take(2) + "0000"
        } else {
            adcode.take(4) + "00"
        }
    }

    private fun countryCodeForName(name: String): String? {
        if (name == "中国" || name.equals("China", ignoreCase = true)) return "CN"
        return Locale.getISOCountries().firstOrNull { code ->
            val locale = Locale.Builder().setRegion(code).build()
            locale.getDisplayCountry(Locale.SIMPLIFIED_CHINESE).equals(name, ignoreCase = true) ||
                locale.displayCountry.equals(name, ignoreCase = true)
        }
    }

    /**
     * 获取周边 POI：专门使用 PoiSearch 接口，确保能搜到大量地点
     */
    suspend fun getNearbyPOIs(
        centerLat: Double,
        centerLon: Double,
        radiusMeters: Int = 3000
    ): List<SearchResult> = withContext(Dispatchers.IO) {
        // Tencent's place-search endpoint rejects an empty keyword. Reverse
        // geocoding with get_poi=1 is its nearby-POI endpoint for this case.
        val payload = getJson("/geocoder/v1/?location=$centerLat,$centerLon&get_poi=1")
            ?.optJSONObject("result") ?: return@withContext emptyList()
        val pois = payload.optJSONArray("pois") ?: return@withContext emptyList()
        buildList {
            for (index in 0 until pois.length()) {
                val poi = pois.optJSONObject(index) ?: continue
                val location = poi.optJSONObject("location") ?: continue
                add(
                    SearchResult(
                        name = poi.optString("title"),
                        address = poi.optString("address"),
                        latitude = location.optDouble("lat"),
                        longitude = location.optDouble("lng")
                    )
                )
            }
        }.nearbyOnly(centerLat, centerLon, radiusMeters)
    }

    suspend fun searchNearby(
        keyword: String,
        centerLat: Double,
        centerLon: Double,
        radiusMeters: Int = 10000 // 搜索模式下范围扩大到 10km
    ): List<SearchResult> = searchTencentPois(keyword, centerLat, centerLon, radiusMeters)

    /** Global standard-place lookup used when a trip has no meaningful nearby center yet. */
    suspend fun searchPlaces(keyword: String): List<SearchResult> = withContext(Dispatchers.IO) {
        val query = keyword.trim()
        if (query.isEmpty()) return@withContext emptyList()
        val platformResults = runCatching {
            @Suppress("DEPRECATION")
            Geocoder(DiFangKeApp.instance, if (query.any { it.code > 127 }) Locale.SIMPLIFIED_CHINESE else Locale.ENGLISH)
                .getFromLocationName(query, 20).orEmpty()
                .mapNotNull { address ->
                    val name = sequenceOf(address.featureName, address.locality, address.subAdminArea, address.adminArea)
                        .mapNotNull { it?.trim()?.takeIf(String::isNotEmpty) }.firstOrNull() ?: return@mapNotNull null
                    SearchResult(name, address.getAddressLine(0).orEmpty(), address.latitude, address.longitude)
                }
        }.getOrDefault(emptyList())
        val json = getJson("/place/v1/suggestion?keyword=${Uri.encode(query)}&region=${Uri.encode("全国")}&region_fix=0&page_size=30")
        val domesticResults = buildList {
            val data = json?.optJSONArray("data") ?: return@buildList
            for (index in 0 until data.length()) {
                val poi = data.optJSONObject(index) ?: continue
                val location = poi.optJSONObject("location") ?: continue
                val name = poi.optString("title").trim()
                if (name.isNotEmpty()) add(SearchResult(name, poi.optString("address"), location.optDouble("lat"), location.optDouble("lng")))
            }
        }
        (platformResults + domesticResults).distinctBy { "${it.name}|${it.latitude}|${it.longitude}" }
    }

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
            }.nearbyOnly(lat, lon, radius)
        }

    /** The service may return relevance-ranked results outside `boundary`; the
     * timeline picker must always be geographically local and nearest first. */
    private fun List<SearchResult>.nearbyOnly(
        centerLat: Double,
        centerLon: Double,
        radiusMeters: Int
    ): List<SearchResult> = mapNotNull { result ->
        val distance = FloatArray(1)
        Location.distanceBetween(centerLat, centerLon, result.latitude, result.longitude, distance)
        result.takeIf { it.name.isNotBlank() && distance[0] <= radiusMeters }
            ?.let { it to distance[0] }
    }.sortedBy { it.second }
        .map { it.first }

    /**
     * Builds a signed Tencent WebService URL. Tencent validates the decoded
     * parameter values in its MD5 source string, while the actual HTTP URL must
     * remain percent-encoded. The signed path includes the /ws prefix.
     */
    private fun signedUrl(pathAndQuery: String): String {
        val path = pathAndQuery.substringBefore('?')
        val parameters = pathAndQuery.substringAfter('?', "")
            .split('&')
            .filter { it.isNotBlank() }
            .associate { parameter ->
                parameter.substringBefore('=') to parameter.substringAfter('=', "")
            }
            .toMutableMap()
        parameters["key"] = BuildConfig.TENCENT_MAP_KEY
        val query = parameters.toSortedMap().entries.joinToString("&") { (name, value) -> "$name=$value" }
        val signatureQuery = parameters.toSortedMap().entries.joinToString("&") { (name, value) ->
            "$name=${Uri.decode(value)}"
        }
        val signature = md5("/ws$path?$signatureQuery${BuildConfig.TENCENT_MAP_SECRET}")
        return "$BASE_URL$path?$query&sig=$signature"
    }

    private fun getJson(pathAndQuery: String): JSONObject? = try {
        val path = pathAndQuery.substringBefore('?')
        val url = signedUrl(pathAndQuery)
        Log.i(TAG, "POI request started: $path")
        httpClient.newCall(Request.Builder().url(url).build()).execute().use { response ->
            val body = response.body?.string()
            val payload = body?.let(::JSONObject)
            Log.i(TAG, "POI response: http=${response.code}, status=${payload?.optInt("status")}, message=${payload?.optString("message")}")
            if (!response.isSuccessful) return null
            payload?.takeIf { it.optInt("status") == 0 }
        }
    } catch (error: Exception) {
        Log.w(TAG, "Tencent location service request failed", error)
        null
    }

    /** Road-following route used by planned-trip maps. Coordinates are GCJ-02, matching Tencent Map. */
    suspend fun routePolyline(
        fromLat: Double,
        fromLon: Double,
        toLat: Double,
        toLon: Double,
        transportTypeRaw: String?
    ): List<Pair<Double, Double>> = routePlan(
        fromLat,
        fromLon,
        toLat,
        toLon,
        transportTypeRaw
    )?.points.orEmpty()

    suspend fun routePlan(
        fromLat: Double,
        fromLon: Double,
        toLat: Double,
        toLon: Double,
        transportTypeRaw: String?
    ): RoutePlan? = routePlans(fromLat, fromLon, toLat, toLon, transportTypeRaw).firstOrNull()

    suspend fun routePlans(
        fromLat: Double,
        fromLon: Double,
        toLat: Double,
        toLon: Double,
        transportTypeRaw: String?
    ): List<RoutePlan> = withContext(Dispatchers.IO) {
        val mode = when (transportTypeRaw) {
            "slow", "running" -> "walking"
            "bicycle" -> "bicycling"
            "ebike" -> "ebicycling"
            "bus", "subway", "train" -> "transit"
            "car", "motorcycle" -> "driving"
            else -> return@withContext emptyList()
        }
        val from = String.format(Locale.US, "%.6f,%.6f", fromLat, fromLon)
        val to = String.format(Locale.US, "%.6f,%.6f", toLat, toLon)
        val cacheKey = "v5|$mode|$from|$to"
        routeOptionsCache[cacheKey]?.let { return@withContext it }
        val storedRoutes = storedRoutes(cacheKey)
        if (BuildConfig.TENCENT_MAP_KEY.isBlank()) return@withContext storedRoutes
        val options = when (mode) {
            "transit" -> "&policy=LEAST_TIME"
            "driving" -> "&get_mp=1"
            else -> ""
        }
        val result = getJson("/direction/v1/$mode/?from=$from&to=$to&output=json$options")
            ?.optJSONObject("result") ?: return@withContext storedRoutes
        val responseRoutes = result.optJSONArray("routes") ?: return@withContext storedRoutes
        val plans = buildList {
            for (index in 0 until responseRoutes.length()) {
                val route = responseRoutes.optJSONObject(index) ?: continue
                val points = decodeRouteCoordinates(route)
                if (points.size < 2) continue
                add(
                    RoutePlan(
                        points = points,
                        distanceMeters = route.optDouble("distance", measuredRouteDistance(points)),
                        durationMinutes = route.optDouble("duration", 0.0),
                        instructions = decodeRouteInstructions(route)
                    )
                )
            }
        }
        if (plans.isEmpty()) return@withContext storedRoutes
        routeOptionsCache[cacheKey] = plans
        storeRoutes(cacheKey, plans)
        plans
    }

    private fun storedRoutes(cacheKey: String): List<RoutePlan> = runCatching {
        val raw = routeCacheFile(cacheKey).takeIf(File::isFile)?.readText() ?: return@runCatching null
        val json = JSONObject(raw)
        val routes = json.optJSONArray("routes")?.let { routesJSON ->
            buildList {
                for (index in 0 until routesJSON.length()) {
                    decodeStoredRoute(routesJSON.optJSONObject(index))?.let(::add)
                }
            }
        } ?: listOfNotNull(decodeStoredRoute(json))
        routes.takeIf(List<RoutePlan>::isNotEmpty)?.also {
            routeOptionsCache[cacheKey] = it
        }
    }.getOrNull().orEmpty()

    private fun decodeStoredRoute(json: JSONObject?): RoutePlan? {
        json ?: return null
        val pointsJSON = json.optJSONArray("points") ?: return null
        val points = buildList {
            for (index in 0 until pointsJSON.length()) {
                val point = pointsJSON.optJSONArray(index) ?: continue
                if (point.length() >= 2) add(point.optDouble(0) to point.optDouble(1))
            }
        }
        if (points.size < 2) return null
        val instructionsJSON = json.optJSONArray("instructions")
        val instructions = buildList {
            if (instructionsJSON != null) {
                for (index in 0 until instructionsJSON.length()) {
                    val instruction = instructionsJSON.optJSONObject(index) ?: continue
                    add(
                        RouteInstruction(
                            title = instruction.optString("title"),
                            detail = instruction.optString("detail").takeIf(String::isNotBlank),
                            transportTypeRaw = instruction.optString("transportTypeRaw", "car"),
                            latitude = instruction.optDouble("latitude").takeIf(Double::isFinite),
                            longitude = instruction.optDouble("longitude").takeIf(Double::isFinite),
                            points = instruction.optJSONArray("points")?.let { pointsJSON ->
                                buildList {
                                    for (pointIndex in 0 until pointsJSON.length()) {
                                        val point = pointsJSON.optJSONArray(pointIndex) ?: continue
                                        if (point.length() >= 2) add(point.optDouble(0) to point.optDouble(1))
                                    }
                                }
                            }.orEmpty()
                        )
                    )
                }
            }
        }
        return RoutePlan(
            points = points,
            distanceMeters = json.optDouble("distanceMeters", measuredRouteDistance(points)),
            durationMinutes = json.optDouble("durationMinutes", 0.0),
            instructions = instructions
        )
    }

    private fun storeRoutes(cacheKey: String, routes: List<RoutePlan>) {
        val json = JSONObject().apply {
            put("routes", JSONArray().apply {
                routes.forEach { route -> put(encodeStoredRoute(route)) }
            })
        }
        val file = routeCacheFile(cacheKey)
        file.parentFile?.mkdirs()
        file.writeText(json.toString())
    }

    private fun encodeStoredRoute(route: RoutePlan): JSONObject = JSONObject().apply {
        put("points", JSONArray().apply {
            route.points.forEach { (latitude, longitude) ->
                put(JSONArray().put(latitude).put(longitude))
            }
        })
        put("distanceMeters", route.distanceMeters)
        put("durationMinutes", route.durationMinutes)
        put("instructions", JSONArray().apply {
            route.instructions.forEach { instruction ->
                put(JSONObject().apply {
                    put("title", instruction.title)
                    put("detail", instruction.detail ?: "")
                    put("transportTypeRaw", instruction.transportTypeRaw)
                    instruction.latitude?.let { put("latitude", it) }
                    instruction.longitude?.let { put("longitude", it) }
                    if (instruction.points.isNotEmpty()) {
                        put("points", JSONArray().apply {
                            instruction.points.forEach { (latitude, longitude) ->
                                put(JSONArray().put(latitude).put(longitude))
                            }
                        })
                    }
                })
            }
        })
    }

    private fun routeCacheFile(cacheKey: String): File = File(
        File(DiFangKeApp.instance.filesDir, "trip_routes"),
        "${md5(cacheKey)}.json"
    )

    private fun decodeRouteCoordinates(route: JSONObject): List<Pair<Double, Double>> {
        decodeTencentPolyline(route.optJSONArray("polyline")).takeIf { it.isNotEmpty() }?.let { return it }
        val result = mutableListOf<Pair<Double, Double>>()
        listOf("steps", "walking", "routes").forEach { key ->
            when (val child = route.opt(key)) {
                is org.json.JSONArray -> {
                    for (index in 0 until child.length()) {
                        val objectChild = child.optJSONObject(index) ?: continue
                        decodeRouteCoordinates(objectChild).forEach { coordinate ->
                            if (result.lastOrNull() != coordinate) result += coordinate
                        }
                    }
                }
                is JSONObject -> {
                    decodeRouteCoordinates(child).forEach { coordinate ->
                        if (result.lastOrNull() != coordinate) result += coordinate
                    }
                }
            }
        }
        when (val lines = route.opt("lines")) {
            is org.json.JSONArray -> lines.optJSONObject(0)?.let { line ->
                decodeRouteCoordinates(line).forEach { coordinate ->
                    if (result.lastOrNull() != coordinate) result += coordinate
                }
            }
            is JSONObject -> decodeRouteCoordinates(lines).forEach { coordinate ->
                if (result.lastOrNull() != coordinate) result += coordinate
            }
        }
        return result
    }

    private fun decodeRouteInstructions(route: JSONObject): List<RouteInstruction> {
        val steps = route.optJSONArray("steps") ?: return emptyList()
        return buildList {
            for (index in 0 until steps.length()) {
                val step = steps.optJSONObject(index) ?: continue
                val stepCoordinate = decodeRouteCoordinates(step).firstOrNull()
                when (step.optString("mode").uppercase(Locale.ROOT)) {
                    "WALKING" -> add(
                        RouteInstruction(
                            title = "步行",
                            detail = routeMetricText(step.optDouble("distance", 0.0), step.optDouble("duration", 0.0)),
                            transportTypeRaw = "slow",
                            latitude = stepCoordinate?.first,
                            longitude = stepCoordinate?.second,
                            points = decodeRouteCoordinates(step)
                        )
                    )
                    "TRANSIT" -> {
                        val lines = step.optJSONArray("lines") ?: continue
                        lines.optJSONObject(0)?.let { line ->
                            val linePoints = decodeRouteCoordinates(line)
                            val lineCoordinate = linePoints.firstOrNull() ?: stepCoordinate
                            val details = buildList {
                                line.optJSONObject("geton")?.optString("title")?.takeIf(String::isNotBlank)?.let { add("${it}上车") }
                                line.optJSONObject("getoff")?.optString("title")?.takeIf(String::isNotBlank)?.let { add("${it}下车") }
                                line.optInt("station_count").takeIf { it > 0 }?.let { add("${it}站") }
                                routeMetricText(line.optDouble("distance", 0.0), line.optDouble("duration", 0.0))?.let { add(it) }
                            }
                            val vehicle = when (line.optString("vehicle").uppercase(Locale.ROOT)) {
                                "SUBWAY" -> "subway"
                                "TRAIN" -> "train"
                                else -> "bus"
                            }
                            add(
                                RouteInstruction(
                                    title = line.optString("title").ifBlank { "公共交通" },
                                    detail = details.takeIf { it.isNotEmpty() }?.joinToString(" · "),
                                    transportTypeRaw = vehicle,
                                    latitude = lineCoordinate?.first,
                                    longitude = lineCoordinate?.second,
                                    points = linePoints
                                )
                            )
                        }
                    }
                    else -> step.optString("instruction").takeIf(String::isNotBlank)?.let { instruction ->
                        add(
                            RouteInstruction(
                                title = instruction,
                                detail = routeMetricText(step.optDouble("distance", 0.0), step.optDouble("duration", 0.0)),
                                transportTypeRaw = "car",
                                latitude = stepCoordinate?.first,
                                longitude = stepCoordinate?.second,
                                points = decodeRouteCoordinates(step)
                            )
                        )
                    }
                }
            }
        }
    }

    private fun routeMetricText(distance: Double, durationMinutes: Double): String? = buildList {
        if (distance > 0) add(if (distance < 1_000) "${distance.toInt().coerceAtLeast(1)}米" else String.format(Locale.CHINA, "%.1f公里", distance / 1_000))
        if (durationMinutes > 0) add("约${durationMinutes.toInt().coerceAtLeast(1)}分钟")
    }.takeIf { it.isNotEmpty() }?.joinToString(" · ")

    private fun measuredRouteDistance(points: List<Pair<Double, Double>>): Double =
        points.zipWithNext().sumOf { (start, end) ->
            val result = FloatArray(1)
            Location.distanceBetween(start.first, start.second, end.first, end.second, result)
            result[0].toDouble()
        }

    private fun decodeTencentPolyline(values: org.json.JSONArray?): List<Pair<Double, Double>> {
        if (values == null || values.length() < 2) return emptyList()
        val coordinates = DoubleArray(values.length()) { values.optDouble(it) }
        for (index in 2 until coordinates.size) {
            coordinates[index] = coordinates[index - 2] + coordinates[index] / 1_000_000.0
        }
        return coordinates.toList().chunked(2).mapNotNull { pair ->
            if (pair.size == 2 && pair[0].isFinite() && pair[1].isFinite()) pair[0] to pair[1] else null
        }
    }

    /**
     * Tencent static map (GCJ-02). `width`/`height` are logical pixels; the
     * returned bitmap is `width*scale` x `height*scale`. Returns null when the
     * key has no static-map quota or the network fails, so callers can fall
     * back to a drawn map.
     */
    suspend fun staticMap(
        centerLat: Double,
        centerLon: Double,
        zoom: Int,
        width: Int,
        height: Int,
        scale: Int = 2
    ): android.graphics.Bitmap? = withContext(Dispatchers.IO) {
        if (BuildConfig.TENCENT_MAP_KEY.isBlank()) return@withContext null
        try {
            val center = String.format(Locale.US, "%.6f,%.6f", centerLat, centerLon)
            val url = signedUrl("/staticmap/v2/?center=$center&zoom=$zoom&size=${width}*${height}&scale=$scale&maptype=roadmap")
            httpClient.newCall(Request.Builder().url(url).build()).execute().use { response ->
                val contentType = response.header("Content-Type").orEmpty()
                if (!response.isSuccessful || !contentType.startsWith("image")) {
                    Log.w(TAG, "Static map unavailable: http=${response.code}, type=$contentType")
                    return@withContext null
                }
                val bytes = response.body?.bytes() ?: return@withContext null
                android.graphics.BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
            }
        } catch (error: Exception) {
            Log.w(TAG, "Static map request failed", error)
            null
        }
    }

    private fun md5(value: String): String = MessageDigest.getInstance("MD5")
        .digest(value.toByteArray(Charsets.UTF_8))
        .joinToString("") { byte -> "%02x".format(byte.toInt() and 0xff) }


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
