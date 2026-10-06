package com.ct106.difangke.service

import com.ct106.difangke.data.db.entity.PlaceEntity
import com.ct106.difangke.service.timeline.GeoMath

/**
 * Place matching rules ported from iOS:
 * - [getPlaceForCoordinate]: TimelineBuilder.getPlaceForCoordinate (rebuild/timeline):
 *   user-defined places within radius+150 m (nearest), else other places within radius+50 m (nearest).
 * - [matchedPlaceFor]: LocationManager.matchedPlaceFor (consolidation): as above, but the
 *   second wave prefers `isPriority` before distance.
 * - [liveMatchedPlace]: LocationManager.matchedPlace (live UI): any place within radius+100 m,
 *   `isPriority` first, otherwise nearest.
 */
object PlaceMatcher {
    private data class Match(val place: PlaceEntity, val distance: Double)

    private fun usable(place: PlaceEntity) =
        place.latitude.isFinite() && place.longitude.isFinite() && place.radius.isFinite() && place.radius >= 0f

    private fun matches(latitude: Double, longitude: Double, places: List<PlaceEntity>): List<Match> =
        places.filter(::usable).map { Match(it, GeoMath.distance(latitude, longitude, it.latitude, it.longitude)) }

    fun getPlaceForCoordinate(latitude: Double, longitude: Double, places: List<PlaceEntity>): PlaceEntity? {
        val all = matches(latitude, longitude, places)
        all.filter { it.place.isUserDefined && !it.place.isIgnored && it.distance <= it.place.radius + 150.0 }
            .minByOrNull { it.distance }?.let { return it.place }
        return all.filter { !it.place.isUserDefined && !it.place.isIgnored && it.distance <= it.place.radius + 50.0 }
            .minByOrNull { it.distance }?.place
    }

    fun matchedPlaceFor(latitude: Double, longitude: Double, places: List<PlaceEntity>): PlaceEntity? {
        val all = matches(latitude, longitude, places)
        all.filter { it.place.isUserDefined && !it.place.isIgnored && it.distance <= it.place.radius + 150.0 }
            .minByOrNull { it.distance }?.let { return it.place }
        return all.filter { !it.place.isUserDefined && !it.place.isIgnored && it.distance <= it.place.radius + 50.0 }
            .sortedWith(compareByDescending<Match> { it.place.isPriority }.thenBy { it.distance })
            .firstOrNull()?.place
    }

    fun liveMatchedPlace(latitude: Double, longitude: Double, places: List<PlaceEntity>): PlaceEntity? {
        val valid = matches(latitude, longitude, places).filter { it.distance <= it.place.radius + 100.0 }
        valid.firstOrNull { it.place.isPriority }?.let { return it.place }
        return valid.minByOrNull { it.distance }?.place
    }

    /** Kept for existing callers; now identical to iOS getPlaceForCoordinate. */
    @Suppress("UNUSED_PARAMETER")
    fun bestPlaceForCoordinate(
        latitude: Double,
        longitude: Double,
        places: List<PlaceEntity>,
        processor: FootprintProcessor? = null
    ): PlaceEntity? = getPlaceForCoordinate(latitude, longitude, places)

    /** An ignored place is a recording exclusion (iOS ignoreLocation uses radius + 100 m). */
    @Suppress("UNUSED_PARAMETER")
    fun ignoredPlaceForCoordinate(
        latitude: Double,
        longitude: Double,
        places: List<PlaceEntity>,
        processor: FootprintProcessor? = null
    ): PlaceEntity? = matches(latitude, longitude, places.filter { it.isIgnored })
        .filter { it.distance <= it.place.radius + 100.0 }
        .minByOrNull { it.distance }
        ?.place
}
