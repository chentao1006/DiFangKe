package com.ct106.difangke.service.timeline

import com.google.gson.JsonArray
import com.google.gson.JsonElement
import com.google.gson.JsonNull
import com.google.gson.JsonParser
import com.google.gson.JsonPrimitive

/**
 * Port of iOS `CodableCoordinate`. [timestamp] is epoch millis.
 *
 * Stored in `TransportRecordEntity.pointsJson` backward-compatibly as
 * `[lat, lon, tsMillis]` arrays (the historical Android format). Flags are an
 * optional 4th element bitmask: 1 = synthetic padding, 2 = stable stay boundary.
 * Points without a timestamp but with flags are written as `[lat, lon, 0, flags]`.
 * The decoder also accepts iOS-style objects `{lat, lon, timestamp, isSyntheticPadding, isStableStayBoundary}`.
 */
data class RouteCoordinate(
    val lat: Double,
    val lon: Double,
    val timestamp: Long? = null,
    val isSyntheticPadding: Boolean = false,
    val isStableStayBoundary: Boolean = false
) {
    val isValid: Boolean get() = GeoMath.isValidCoordinate(lat, lon)
    val latLon: Pair<Double, Double> get() = lat to lon
}

object RouteCodec {
    const val FLAG_SYNTHETIC = 1
    const val FLAG_STABLE_BOUNDARY = 2
    /** Seconds between 1970-01-01 and 2001-01-01 (Swift reference date). */
    private const val APPLE_REFERENCE_OFFSET = 978_307_200.0

    fun encode(points: List<RouteCoordinate>): String {
        val array = JsonArray()
        for (p in points) {
            val item = JsonArray()
            item.add(JsonPrimitive(p.lat))
            item.add(JsonPrimitive(p.lon))
            val flags = (if (p.isSyntheticPadding) FLAG_SYNTHETIC else 0) or
                (if (p.isStableStayBoundary) FLAG_STABLE_BOUNDARY else 0)
            if (p.timestamp != null || flags != 0) item.add(JsonPrimitive(p.timestamp ?: 0L))
            if (flags != 0) item.add(JsonPrimitive(flags))
            array.add(item)
        }
        return array.toString()
    }

    /** Returns null when the JSON cannot be parsed at all (iOS `try? decode` failure). */
    fun decodeOrNull(json: String?): List<RouteCoordinate>? {
        if (json.isNullOrBlank()) return null
        return try {
            val root = JsonParser.parseString(json)
            if (!root.isJsonArray) return null
            root.asJsonArray.mapNotNull { decodeElement(it) }
        } catch (_: Exception) {
            null
        }
    }

    fun decode(json: String?): List<RouteCoordinate> = decodeOrNull(json) ?: emptyList()

    private fun decodeElement(element: JsonElement): RouteCoordinate? {
        if (element.isJsonArray) {
            val a = element.asJsonArray
            if (a.size() < 2) return null
            val lat = a[0].asDoubleOrNull() ?: return null
            val lon = a[1].asDoubleOrNull() ?: return null
            val ts = if (a.size() >= 3) normalizeTimestamp(a[2].asDoubleOrNull()) else null
            val flags = if (a.size() >= 4) (a[3].asDoubleOrNull()?.toInt() ?: 0) else 0
            return RouteCoordinate(
                lat, lon, ts,
                isSyntheticPadding = flags and FLAG_SYNTHETIC != 0,
                isStableStayBoundary = flags and FLAG_STABLE_BOUNDARY != 0
            )
        }
        if (element.isJsonObject) {
            val o = element.asJsonObject
            val lat = (o.get("lat") ?: o.get("latitude"))?.asDoubleOrNull() ?: return null
            val lon = (o.get("lon") ?: o.get("longitude"))?.asDoubleOrNull() ?: return null
            val ts = normalizeTimestamp(o.get("timestamp")?.asDoubleOrNull())
            return RouteCoordinate(
                lat, lon, ts,
                isSyntheticPadding = o.get("isSyntheticPadding")?.asBooleanOrNull() == true,
                isStableStayBoundary = o.get("isStableStayBoundary")?.asBooleanOrNull() == true
            )
        }
        return null
    }

    /** Millis (>1e11), unix seconds (>=1e9) or Swift reference-date seconds. */
    fun normalizeTimestamp(raw: Double?): Long? {
        if (raw == null || !raw.isFinite() || raw <= 0.0) return null
        return when {
            raw > 1e11 -> raw.toLong()
            raw >= 1e9 -> (raw * 1000).toLong()
            else -> ((raw + APPLE_REFERENCE_OFFSET) * 1000).toLong()
        }
    }

    private fun JsonElement.asDoubleOrNull(): Double? =
        if (this is JsonNull || !isJsonPrimitive) null else runCatching { asDouble }.getOrNull()

    private fun JsonElement.asBooleanOrNull(): Boolean? =
        if (this is JsonNull || !isJsonPrimitive) null else runCatching { asBoolean }.getOrNull()
}
