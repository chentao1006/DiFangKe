package com.ct106.difangke.ui.components

import com.amap.api.maps.AMap
import com.amap.api.maps.model.CircleOptions
import com.amap.api.maps.model.LatLng
import com.ct106.difangke.data.db.entity.PlaceEntity
import kotlin.math.max
import kotlin.math.min

private const val IMPORTANT_PLACE_STROKE_COLOR = 0xFFFF9800.toInt()
private const val IMPORTANT_PLACE_FILL_COLOR = 0x22FF9800

fun AMap.addImportantPlaceCircles(places: List<PlaceEntity>) {
    places.asSequence()
        .filter { it.isUserDefined && !it.isIgnored }
        .filter { it.latitude.isFinite() && it.longitude.isFinite() }
        .filter { it.radius.isFinite() && it.radius > 1f }
        .forEach { place ->
            addCircle(
                CircleOptions()
                    .center(LatLng(place.latitude, place.longitude))
                    .radius(max(5.0, min(place.radius.toDouble(), 10_000.0)))
                    .strokeColor(IMPORTANT_PLACE_STROKE_COLOR)
                    .fillColor(IMPORTANT_PLACE_FILL_COLOR)
                    .strokeWidth(3f)
            )
        }
}
