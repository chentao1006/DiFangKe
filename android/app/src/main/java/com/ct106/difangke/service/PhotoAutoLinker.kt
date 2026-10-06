package com.ct106.difangke.service

import android.Manifest
import android.content.ContentUris
import android.content.Context
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import androidx.core.content.ContextCompat
import androidx.exifinterface.media.ExifInterface
import com.ct106.difangke.data.db.AppDatabase
import com.ct106.difangke.data.db.entity.FootprintEntity
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * iOS LocationManager.linkPhotos / PhotoService.fetchAssets port:
 * on footprint detail open, link gallery images taken within
 * [start − 60 s, end + 60 s] and (when GPS is present) within 1000 m.
 */
object PhotoAutoLinker {

    const val MAX_DISTANCE_METERS = 1000.0
    private const val BUFFER_MS = 60_000L

    /** Permissions needed to query the gallery (full or partial access). */
    fun requiredPermissions(): Array<String> = when {
        Build.VERSION.SDK_INT >= 34 -> arrayOf(
            Manifest.permission.READ_MEDIA_IMAGES,
            Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED,
            Manifest.permission.ACCESS_MEDIA_LOCATION
        )
        Build.VERSION.SDK_INT >= 33 -> arrayOf(Manifest.permission.READ_MEDIA_IMAGES, Manifest.permission.ACCESS_MEDIA_LOCATION)
        Build.VERSION.SDK_INT >= 29 -> arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE, Manifest.permission.ACCESS_MEDIA_LOCATION)
        else -> arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE)
    }

    fun hasGalleryAccess(context: Context): Boolean {
        fun granted(p: String) = ContextCompat.checkSelfPermission(context, p) == PackageManager.PERMISSION_GRANTED
        return when {
            Build.VERSION.SDK_INT >= 34 -> granted(Manifest.permission.READ_MEDIA_IMAGES) || granted(Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED)
            Build.VERSION.SDK_INT >= 33 -> granted(Manifest.permission.READ_MEDIA_IMAGES)
            else -> granted(Manifest.permission.READ_EXTERNAL_STORAGE)
        }
    }

    /** Gallery image URIs (as strings) matching the footprint's time window and location. */
    suspend fun findPhotos(
        context: Context,
        startMs: Long,
        endMs: Long,
        latitude: Double?,
        longitude: Double?,
        maxDistance: Double = MAX_DISTANCE_METERS
    ): List<String> = withContext(Dispatchers.IO) {
        if (!hasGalleryAccess(context)) return@withContext emptyList()
        val result = mutableListOf<String>()
        val collection = MediaStore.Images.Media.EXTERNAL_CONTENT_URI
        val projection = arrayOf(MediaStore.Images.Media._ID, MediaStore.Images.Media.DATE_TAKEN)
        val selection = "${MediaStore.Images.Media.DATE_TAKEN} > ? AND ${MediaStore.Images.Media.DATE_TAKEN} < ?"
        val args = arrayOf((startMs - BUFFER_MS).toString(), (endMs + BUFFER_MS).toString())
        runCatching {
            context.contentResolver.query(collection, projection, selection, args, "${MediaStore.Images.Media.DATE_TAKEN} ASC")?.use { c ->
                val idCol = c.getColumnIndexOrThrow(MediaStore.Images.Media._ID)
                while (c.moveToNext()) {
                    val uri = ContentUris.withAppendedId(collection, c.getLong(idCol))
                    if (latitude != null && longitude != null) {
                        val gps = readGps(context, uri)
                        if (gps != null) {
                            val (gLat, gLon) = wgs84ToGcj02(gps.first, gps.second)
                            if (distance(latitude, longitude, gLat, gLon) > maxDistance) continue
                        }
                    }
                    result += uri.toString()
                }
            }
        }
        result
    }

    /**
     * Link photos to [footprint] if it has none yet (iOS skips footprints whose photos are
     * already valid). Returns the updated entity when something was linked, else null.
     */
    suspend fun linkPhotos(context: Context, db: AppDatabase, footprint: FootprintEntity): FootprintEntity? {
        val current = db.footprintDao().getById(footprint.footprintID) ?: return null
        val existing = runCatching {
            val a = JSONArray(current.photoAssetIDsJson)
            (0 until a.length()).map { a.getString(it) }
        }.getOrDefault(emptyList())
        if (existing.isNotEmpty()) return null
        val lats = runCatching { JSONArray(current.latitudeJson) }.getOrNull()
        val lons = runCatching { JSONArray(current.longitudeJson) }.getOrNull()
        val lat = lats?.let { a -> (0 until a.length()).map { a.getDouble(it) }.takeIf { it.isNotEmpty() }?.average() }
        val lon = lons?.let { a -> (0 until a.length()).map { a.getDouble(it) }.takeIf { it.isNotEmpty() }?.average() }
        val found = findPhotos(context, current.startTime.time, current.endTime.time, lat, lon)
        if (found.isEmpty()) return null
        val updated = current.copy(photoAssetIDsJson = JSONArray((existing + found).distinct()).toString())
        db.footprintDao().update(updated)
        return updated
    }

    private fun readGps(context: Context, uri: Uri): Pair<Double, Double>? = runCatching {
        val target = if (Build.VERSION.SDK_INT >= 29) runCatching { MediaStore.setRequireOriginal(uri) }.getOrDefault(uri) else uri
        context.contentResolver.openInputStream(target)?.use { stream ->
            val exif = ExifInterface(stream)
            exif.latLong?.let { it[0] to it[1] }
        }
    }.getOrNull()?.takeIf { abs(it.first) > 0.0001 || abs(it.second) > 0.0001 }

    private fun distance(lat1: Double, lon1: Double, lat2: Double, lon2: Double): Double {
        val r = 6371000.0
        val dLat = Math.toRadians(lat2 - lat1)
        val dLon = Math.toRadians(lon2 - lon1)
        val a = sin(dLat / 2) * sin(dLat / 2) + cos(Math.toRadians(lat1)) * cos(Math.toRadians(lat2)) * sin(dLon / 2) * sin(dLon / 2)
        return r * 2 * atan2(sqrt(a), sqrt(1 - a))
    }

    private fun outOfChina(lat: Double, lon: Double) = lon < 72.004 || lon > 137.8347 || lat < 0.8293 || lat > 55.8271

    /** WGS-84 → GCJ-02 (identity outside mainland China). */
    fun wgs84ToGcj02(lat: Double, lon: Double): Pair<Double, Double> {
        if (outOfChina(lat, lon)) return lat to lon
        val a = 6378245.0
        val ee = 0.00669342162296594323
        var dLat = transformLat(lon - 105.0, lat - 35.0)
        var dLon = transformLon(lon - 105.0, lat - 35.0)
        val radLat = lat / 180.0 * Math.PI
        var magic = sin(radLat)
        magic = 1 - ee * magic * magic
        val sqrtMagic = sqrt(magic)
        dLat = (dLat * 180.0) / ((a * (1 - ee)) / (magic * sqrtMagic) * Math.PI)
        dLon = (dLon * 180.0) / (a / sqrtMagic * cos(radLat) * Math.PI)
        return (lat + dLat) to (lon + dLon)
    }

    private fun transformLat(x: Double, y: Double): Double {
        var ret = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * sqrt(abs(x))
        ret += (20.0 * sin(6.0 * x * Math.PI) + 20.0 * sin(2.0 * x * Math.PI)) * 2.0 / 3.0
        ret += (20.0 * sin(y * Math.PI) + 40.0 * sin(y / 3.0 * Math.PI)) * 2.0 / 3.0
        ret += (160.0 * sin(y / 12.0 * Math.PI) + 320 * sin(y * Math.PI / 30.0)) * 2.0 / 3.0
        return ret
    }

    private fun transformLon(x: Double, y: Double): Double {
        var ret = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * sqrt(abs(x))
        ret += (20.0 * sin(6.0 * x * Math.PI) + 20.0 * sin(2.0 * x * Math.PI)) * 2.0 / 3.0
        ret += (20.0 * sin(x * Math.PI) + 40.0 * sin(x / 3.0 * Math.PI)) * 2.0 / 3.0
        ret += (150.0 * sin(x / 12.0 * Math.PI) + 300.0 * sin(x / 30.0 * Math.PI)) * 2.0 / 3.0
        return ret
    }
}
