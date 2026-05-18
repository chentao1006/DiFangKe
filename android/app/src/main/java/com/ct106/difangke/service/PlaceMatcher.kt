package com.ct106.difangke.service

import com.ct106.difangke.AppConfig
import com.ct106.difangke.data.db.entity.PlaceEntity

object PlaceMatcher {
    private data class Match(
        val place: PlaceEntity,
        val distance: Double
    )

    fun bestPlaceForCoordinate(
        latitude: Double,
        longitude: Double,
        places: List<PlaceEntity>,
        processor: FootprintProcessor = FootprintProcessor.shared
    ): PlaceEntity? {
        val candidates = places
            .asSequence()
            .filter { !it.isIgnored }
            .filter { it.latitude.isFinite() && it.longitude.isFinite() && it.radius.isFinite() && it.radius > 0f }
            .map { place ->
                Match(
                    place = place,
                    distance = processor.haversineMeters(place.latitude, place.longitude, latitude, longitude)
                )
            }
            .toList()

        candidates
            .filter { it.place.isUserDefined && it.distance <= it.place.radius.toDouble() }
            .minByOrNull { it.distance }
            ?.let { return it.place }

        candidates
            .filter { it.place.isUserDefined && it.distance <= it.place.radius + AppConfig.TAG_INHERITANCE_DISTANCE }
            .minByOrNull { it.distance }
            ?.let { return it.place }

        return candidates
            .filter { !it.place.isUserDefined && it.distance <= it.place.radius + 50.0 }
            .minByOrNull { it.distance }
            ?.place
    }
}
