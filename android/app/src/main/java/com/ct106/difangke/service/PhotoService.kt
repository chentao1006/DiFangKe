package com.ct106.difangke.service

import android.content.Context
import android.provider.MediaStore
import android.content.ContentUris
import android.util.Log
import com.ct106.difangke.data.db.entity.FootprintEntity
import org.json.JSONArray
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.util.Date

class PhotoService private constructor(private val context: Context) {

    companion object {
        private const val TAG = "PhotoService"
        
        @Volatile
        private var INSTANCE: PhotoService? = null

        fun getInstance(context: Context): PhotoService =
            INSTANCE ?: synchronized(this) {
                INSTANCE ?: PhotoService(context.applicationContext).also { INSTANCE = it }
            }
    }

    data class PhotoInfo(
        val id: String,
        val dateTaken: Date,
        val latitude: Double?,
        val longitude: Double?
    )

    /**
     * 将有地理位置的照片按连续停留聚成候选足迹。与 iOS 的照片寻回使用相同的
     * 500 米 / 4 小时边界；这里只产生草稿，必须由用户在结果页确认后才会写入数据库。
     */
    suspend fun scanFootprintCandidates(
        startDate: Date,
        endDate: Date,
        excludedPhotoUris: Set<String> = emptySet()
    ): List<FootprintEntity> {
        val photos = getPhotosBetween(startDate, endDate)
            .filter { photo ->
                photo.latitude != null && photo.longitude != null &&
                    ContentUris.withAppendedId(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, photo.id.toLong()).toString() !in excludedPhotoUris
            }
        if (photos.isEmpty()) return emptyList()

        val clusters = mutableListOf<MutableList<PhotoInfo>>()
        photos.forEach { photo ->
            val cluster = clusters.lastOrNull()
            val previous = cluster?.lastOrNull()
            if (previous != null && previous.latitude != null && previous.longitude != null &&
                distanceMeters(previous.latitude, previous.longitude, photo.latitude!!, photo.longitude!!) < 500 &&
                photo.dateTaken.time - previous.dateTaken.time < 4 * 60 * 60 * 1000L
            ) {
                cluster.add(photo)
            } else {
                clusters += mutableListOf(photo)
            }
        }

        return clusters.map { cluster ->
            val first = cluster.first()
            val last = cluster.last()
            val latitudes = cluster.mapNotNull { it.latitude }
            val longitudes = cluster.mapNotNull { it.longitude }
            val latitude = latitudes.average()
            val longitude = longitudes.average()
            val photoUris = cluster.map { photo ->
                ContentUris.withAppendedId(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, photo.id.toLong()).toString()
            }
            FootprintEntity(
                date = startOfDay(first.dateTaken),
                startTime = first.dateTaken,
                endTime = last.dateTaken,
                latitudeJson = JSONArray(latitudes).toString(),
                longitudeJson = JSONArray(longitudes).toString(),
                locationHash = FootprintEntity.generateLocationHash(latitude, longitude),
                statusValue = "candidate",
                photoAssetIDsJson = JSONArray(photoUris).toString()
            )
        }
    }

    private fun startOfDay(date: Date): Date = java.util.Calendar.getInstance().run {
        time = date
        set(java.util.Calendar.HOUR_OF_DAY, 0)
        set(java.util.Calendar.MINUTE, 0)
        set(java.util.Calendar.SECOND, 0)
        set(java.util.Calendar.MILLISECOND, 0)
        time
    }

    private fun distanceMeters(lat1: Double, lon1: Double, lat2: Double, lon2: Double): Double {
        val result = FloatArray(1)
        android.location.Location.distanceBetween(lat1, lon1, lat2, lon2, result)
        return result[0].toDouble()
    }

    /**
     * 查询指定时间范围内的照片集合
     * 对应 iOS HistoryListView 中的照片查询逻辑
     */
    @Suppress("DEPRECATION")
    suspend fun getPhotosBetween(startDate: Date, endDate: Date): List<PhotoInfo> = withContext(Dispatchers.IO) {
        val photos = mutableListOf<PhotoInfo>()
        
        val projection = arrayOf(
            MediaStore.Images.Media._ID,
            MediaStore.Images.Media.DATE_TAKEN,
            MediaStore.Images.Media.LATITUDE,
            MediaStore.Images.Media.LONGITUDE
        )

        // 筛选条件：在时间范围内
        val selection = "${MediaStore.Images.Media.DATE_TAKEN} >= ? AND ${MediaStore.Images.Media.DATE_TAKEN} <= ?"
        val selectionArgs = arrayOf(
            startDate.time.toString(),
            endDate.time.toString()
        )

        // 按拍摄时间正序
        val sortOrder = "${MediaStore.Images.Media.DATE_TAKEN} ASC"

        try {
            context.contentResolver.query(
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                projection,
                selection,
                selectionArgs,
                sortOrder
            )?.use { cursor ->
                val idColumn = cursor.getColumnIndexOrThrow(MediaStore.Images.Media._ID)
                val dateTakenColumn = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.DATE_TAKEN)
                val latColumn = cursor.getColumnIndex(MediaStore.Images.Media.LATITUDE)
                val lonColumn = cursor.getColumnIndex(MediaStore.Images.Media.LONGITUDE)

                while (cursor.moveToNext()) {
                    val id = cursor.getLong(idColumn).toString()
                    val dateTakenMs = cursor.getLong(dateTakenColumn)
                    
                    var lat: Double? = null
                    var lon: Double? = null
                    
                    if (latColumn != -1 && lonColumn != -1 && !cursor.isNull(latColumn) && !cursor.isNull(lonColumn)) {
                        lat = cursor.getDouble(latColumn)
                        lon = cursor.getDouble(lonColumn)
                    }

                    photos.add(
                        PhotoInfo(
                            id = id,
                            dateTaken = Date(dateTakenMs),
                            latitude = lat,
                            longitude = lon
                        )
                    )
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error querying MediaStore", e)
        }

        photos
    }
}
