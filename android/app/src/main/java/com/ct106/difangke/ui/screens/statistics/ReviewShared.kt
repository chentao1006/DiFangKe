package com.ct106.difangke.ui.screens.statistics

import com.ct106.difangke.data.db.entity.FootprintEntity
import com.ct106.difangke.data.db.entity.PlaceEntity
import com.ct106.difangke.data.model.TransportType
import com.ct106.difangke.ui.share.shareCenter
import com.tencent.tencentmap.mapsdk.maps.model.LatLng
import java.text.Normalizer
import kotlin.math.roundToLong

private val combiningMarks = Regex("\\p{Mn}+")

/** ICU transliterators are expensive to create and not documented as thread-safe. */
private val latinTransliterator = ThreadLocal<android.icu.text.Transliterator?>()

/**
 * iOS normalizedPlaceSearchKey: case/diacritic folded, transliterated, alphanumerics only.
 * Transliteration needs API 29; older systems keep the folded text, as
 * [com.ct106.difangke.service.GeocodeService.simplifiedChinese] does.
 */
fun normalizedPlaceSearchKey(value: String): String {
    val folded = combiningMarks.replace(Normalizer.normalize(value, Normalizer.Form.NFD), "")
    val latin = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.Q) {
        runCatching {
            val transliterator = latinTransliterator.get()
                ?: android.icu.text.Transliterator.getInstance("Any-Latin").also(latinTransliterator::set)
            combiningMarks.replace(Normalizer.normalize(transliterator.transliterate(folded), Normalizer.Form.NFD), "")
        }.getOrDefault(folded)
    } else {
        folded
    }
    return latin.filter { it.isLetterOrDigit() }.lowercase()
}

/**
 * iOS reviewIntegratedPlaceKey: Review treats every visit with the same
 * place/address name in the same country and city as one place; unnamed
 * visits fall back to a ~110 m coordinate cell.
 */
fun reviewIntegratedPlaceKey(footprint: FootprintEntity, placesById: Map<String, PlaceEntity>): String {
    val placeName = footprint.placeID?.let(placesById::get)?.name?.trim()
    val address = footprint.address?.trim()
    val displayName = listOfNotNull(placeName, address).firstOrNull { it.isNotEmpty() }
        ?.let(::normalizedPlaceSearchKey).orEmpty()
    if (displayName.isNotEmpty()) {
        val country = normalizedPlaceSearchKey(footprint.countryCode ?: footprint.countryName ?: "")
        val city = normalizedPlaceSearchKey(footprint.cityName ?: "")
        return "named:$country:$city:$displayName"
    }
    val center = footprint.shareCenter()
    val factor = 1_000.0
    val latitude = ((center?.lat ?: 0.0) * factor).roundToLong() / factor
    val longitude = ((center?.lon ?: 0.0) * factor).roundToLong() / factor
    return "coordinate:$latitude,$longitude"
}

/** iOS DFKTransportOverviewPoint: a fused trajectory sample used by the review map. */
data class ReviewTransportOverviewPoint(
    val id: String,
    val latitude: Double,
    val longitude: Double,
    val intensity: Int
)

/** A decoded transport route for the review map. Segments are split at [0,0] separators. */
data class ReviewMapRoute(
    val id: String,
    val type: TransportType,
    val distance: Double,
    val segments: List<List<LatLng>>
)

/** iOS ReviewMapBounds: the extent of every footprint and route point in the range. */
data class ReviewMapBounds(
    val minimumLatitude: Double,
    val maximumLatitude: Double,
    val minimumLongitude: Double,
    val maximumLongitude: Double
)
