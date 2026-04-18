package com.ct106.difangke.service

import android.content.Context
import com.ct106.difangke.data.db.AppDatabase
import com.ct106.difangke.data.db.entity.FootprintEntity
import com.ct106.difangke.data.db.entity.PlaceEntity
import com.google.gson.Gson
import com.google.gson.GsonBuilder
import com.google.gson.annotations.SerializedName
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import java.text.SimpleDateFormat
import java.util.*
import java.util.TimeZone

/**
 * 对应 iOS BackupService
 */
class BackupService(private val context: Context, private val db: AppDatabase) {

    private val gson = GsonBuilder()
        .registerTypeAdapter(Date::class.java, com.google.gson.JsonDeserializer { json, _, _ ->
            val df = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US)
            df.timeZone = TimeZone.getTimeZone("UTC")
            try {
                df.parse(json.asString)
            } catch (e: Exception) {
                null
            }
        })
        .registerTypeAdapter(Date::class.java, com.google.gson.JsonSerializer { src: Date, _, _ ->
            val df = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US)
            df.timeZone = TimeZone.getTimeZone("UTC")
            com.google.gson.JsonPrimitive(df.format(src))
        })
        .setPrettyPrinting()
        .create()

    data class BackupDTO(
        val version: Int,
        val places: List<PlaceDTO>,
        val footprints: List<FootprintDTO>,
        @SerializedName("activityTypes") val activityTypes: List<ActivityTypeDTO>? = null,
        @SerializedName("transports") val transports: List<TransportDTO>? = null
    )

    data class PlaceDTO(
        val id: String,
        val name: String,
        val lat: Double,
        val lon: Double,
        val rad: Float,
        val addr: String?,
        @SerializedName("isIgnored") val isIgnored: Boolean? = false,
        @SerializedName("isUserDefined") val isUserDefined: Boolean? = true
    )

    data class FootprintDTO(
        val id: String,
        val date: Date,
        val start: Date,
        val end: Date,
        val lats: List<Double>,
        val lngs: List<Double>,
        val title: String,
        val reason: String?,
        val status: String,
        val score: Float,
        @SerializedName("placeID") val placeID: String?,
        val photos: List<String>,
        val addr: String?,
        @SerializedName("isHighlight") val isHighlight: Boolean?,
        @SerializedName("activityType") val activityType: String? = null
    )

    data class ActivityTypeDTO(
        val id: String,
        val name: String,
        val icon: String,
        val colorHex: String
    )

    data class TransportDTO(
        val id: String,
        val day: Date,
        val start: Date,
        val end: Date,
        val from: String,
        val to: String,
        val type: String,
        val dist: Double,
        val speed: Double,
        val pts: String,
        val manualType: String?,
        val status: String? = null,
        val steps: Int? = null
    )

    data class RestoreReport(
        val newFootprints: Int,
        val skippedFootprints: Int,
        val newPlacesUser: Int,
        val skippedPlacesUser: Int,
        val newPlacesSystem: Int,
        val skippedPlacesSystem: Int,
        val newTransports: Int,
        val skippedTransports: Int,
        val newActivityTypes: Int,
        val skippedActivityTypes: Int
    )

    suspend fun generateBackup(): String = withContext(Dispatchers.IO) {
        val footprints = db.footprintDao().getAll()
        val places = db.placeDao().getAll()
        val activities = db.activityTypeDao().getAll()
        val transports = db.transportRecordDao().getAllSync()

        val dto = BackupDTO(
            version = 1,
            places = places.map { p ->
                PlaceDTO(p.placeID, p.name, p.latitude, p.longitude, p.radius, p.address, p.isIgnored, p.isUserDefined)
            },
            footprints = footprints.map { f ->
                val lats = try { 
                    val arr = JSONArray(f.latitudeJson)
                    (0 until arr.length()).map { arr.getDouble(it) }
                } catch (e: Exception) { emptyList() }
                
                val lngs = try {
                    val arr = JSONArray(f.longitudeJson)
                    (0 until arr.length()).map { arr.getDouble(it) }
                } catch (e: Exception) { emptyList() }

                FootprintDTO(
                    id = f.footprintID,
                    date = f.date,
                    start = f.startTime,
                    end = f.endTime,
                    lats = lats,
                    lngs = lngs,
                    title = f.title,
                    reason = f.reason,
                    status = f.statusValue,
                    score = f.aiScore,
                    placeID = f.placeID,
                    photos = try { 
                        val arr = JSONArray(f.photoAssetIDsJson)
                        (0 until arr.length()).map { arr.getString(it) } 
                    } catch(e: Exception) { emptyList() },
                    addr = f.address,
                    isHighlight = f.isHighlight,
                    activityType = f.activityTypeValue
                )
            },
            activityTypes = activities.map { a ->
                ActivityTypeDTO(a.id, a.name, a.icon, a.colorHex)
            },
            transports = transports.map { tr ->
                TransportDTO(
                    id = tr.recordID,
                    day = tr.day,
                    start = tr.startTime,
                    end = tr.endTime,
                    from = tr.startLocation,
                    to = tr.endLocation,
                    type = tr.typeRaw,
                    dist = tr.distance,
                    speed = tr.averageSpeed,
                    pts = tr.pointsJson,
                    manualType = tr.manualTypeRaw,
                    status = tr.statusRaw,
                    steps = tr.stepCount
                )
            }
        )
        gson.toJson(dto)
    }

    suspend fun restoreBackup(json: String): RestoreReport = withContext(Dispatchers.IO) {
        val backup = gson.fromJson(json, BackupDTO::class.java)
        
        var newPlacesUser = 0
        var skippedPlacesUser = 0
        var newPlacesSystem = 0
        var skippedPlacesSystem = 0
        for (p in backup.places) {
            val isUserDefined = p.isUserDefined ?: true
            val existing = db.placeDao().getById(p.id)
            if (existing == null) {
                db.placeDao().insert(PlaceEntity(
                    placeID = p.id,
                    name = p.name,
                    latitude = p.lat,
                    longitude = p.lon,
                    radius = p.rad,
                    address = p.addr,
                    isIgnored = p.isIgnored ?: false,
                    isUserDefined = isUserDefined
                ))
                if (isUserDefined) newPlacesUser++ else newPlacesSystem++
            } else {
                if (isUserDefined) skippedPlacesUser++ else skippedPlacesSystem++
            }
        }

        var newFootprints = 0
        var skippedFootprints = 0
        for (f in backup.footprints) {
            val existing = db.footprintDao().getById(f.id)
            if (existing == null) {
                db.footprintDao().insert(FootprintEntity(
                    footprintID = f.id,
                    date = f.date,
                    startTime = f.start,
                    endTime = f.end,
                    latitudeJson = JSONArray(f.lats).toString(),
                    longitudeJson = JSONArray(f.lngs).toString(),
                    title = f.title,
                    reason = f.reason,
                    statusValue = f.status,
                    aiScore = f.score,
                    placeID = f.placeID,
                    photoAssetIDsJson = JSONArray(f.photos).toString(),
                    address = f.addr,
                    isHighlight = f.isHighlight ?: false,
                    aiAnalyzed = true,
                    activityTypeValue = f.activityType
                ))
                newFootprints++
            } else {
                skippedFootprints++
            }
        }

        var newTransports = 0
        var skippedTransports = 0
        backup.transports?.forEach { t ->
            val existing = db.transportRecordDao().getById(t.id)
            if (existing == null) {
                db.transportRecordDao().insert(com.ct106.difangke.data.db.entity.TransportRecordEntity(
                    recordID = t.id,
                    day = t.day,
                    startTime = t.start,
                    endTime = t.end,
                    startLocation = t.from,
                    endLocation = t.to,
                    typeRaw = t.type,
                    distance = t.dist,
                    averageSpeed = t.speed,
                    pointsJson = t.pts,
                    manualTypeRaw = t.manualType,
                    statusRaw = t.status ?: "active",
                    stepCount = t.steps
                ))
                newTransports++
            } else {
                skippedTransports++
            }
        }

        var newActivities = 0
        var skippedActivities = 0
        backup.activityTypes?.forEachIndexed { index, a ->
            val existing = db.activityTypeDao().getById(a.id)
            if (existing == null) {
                db.activityTypeDao().insert(com.ct106.difangke.data.db.entity.ActivityTypeEntity(
                    id = a.id,
                    name = a.name,
                    icon = a.icon,
                    colorHex = a.colorHex,
                    sortOrder = index,
                    isSystem = false
                ))
                newActivities++
            } else {
                skippedActivities++
            }
        }

        RestoreReport(
            newFootprints = newFootprints,
            skippedFootprints = skippedFootprints,
            newPlacesUser = newPlacesUser,
            skippedPlacesUser = skippedPlacesUser,
            newPlacesSystem = newPlacesSystem,
            skippedPlacesSystem = skippedPlacesSystem,
            newTransports = newTransports,
            skippedTransports = skippedTransports,
            newActivityTypes = newActivities,
            skippedActivityTypes = skippedActivities
        )
    }
}
