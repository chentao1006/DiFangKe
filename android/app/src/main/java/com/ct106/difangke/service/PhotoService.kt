package com.ct106.difangke.service

import android.content.Context
import android.net.Uri
import android.provider.MediaStore
import android.util.Log
import androidx.exifinterface.media.ExifInterface
import com.ct106.difangke.data.db.entity.FootprintEntity
import org.json.JSONArray
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

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
        val uri: String,
        val dateTaken: Date,
        val latitude: Double?,
        val longitude: Double?
    )

    /**
     * 将有地理位置的照片按连续停留聚成候选足迹。与 iOS 的照片寻回使用相同的
     * 500 米 / 4 小时边界；这里只产生草稿，必须由用户在结果页确认后才会写入数据库。
     *
     * 照片来自用户在系统照片选择器中手动选中的一批 URI（不再后台批量扫描相册）。
     */
    suspend fun scanFootprintCandidates(
        photoUris: List<Uri>,
        excludedPhotoUris: Set<String> = emptySet()
    ): List<FootprintEntity> {
        val photos = photosFromUris(photoUris)
            .filter { photo ->
                photo.latitude != null && photo.longitude != null && photo.uri !in excludedPhotoUris
            }
            .sortedBy { it.dateTaken }
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
            val photoUrisJson = cluster.map { it.uri }
            FootprintEntity(
                date = startOfDay(first.dateTaken),
                startTime = first.dateTaken,
                endTime = last.dateTaken,
                latitudeJson = JSONArray(latitudes).toString(),
                longitudeJson = JSONArray(longitudes).toString(),
                locationHash = FootprintEntity.generateLocationHash(latitude, longitude),
                statusValue = "candidate",
                photoAssetIDsJson = JSONArray(photoUrisJson).toString()
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
     * 读取用户手动选中的照片的拍摄时间与 GPS 坐标（EXIF 元数据）。
     * 通过 MediaStore.setRequireOriginal 请求未脱敏的原始字节，配合
     * ACCESS_MEDIA_LOCATION 权限获取 GPS；若未授权或读取失败，位置信息会缺失，
     * 该照片在聚类时会被跳过（而不是让整个导入流程失败）。
     */
    private suspend fun photosFromUris(uris: List<Uri>): List<PhotoInfo> = withContext(Dispatchers.IO) {
        uris.mapNotNull { uri -> readPhotoInfo(uri) }
    }

    private fun readPhotoInfo(uri: Uri): PhotoInfo? {
        val originalUri = runCatching { MediaStore.setRequireOriginal(uri) }.getOrDefault(uri)
        return try {
            context.contentResolver.openInputStream(originalUri)?.use { stream ->
                val exif = ExifInterface(stream)
                val dateTaken = parseExifDate(exif) ?: return null
                val latLong = exif.latLong
                PhotoInfo(
                    uri = uri.toString(),
                    dateTaken = dateTaken,
                    latitude = latLong?.get(0),
                    longitude = latLong?.get(1)
                )
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error reading EXIF for $uri", e)
            null
        }
    }

    private fun parseExifDate(exif: ExifInterface): Date? {
        val raw = exif.getAttribute(ExifInterface.TAG_DATETIME_ORIGINAL)
            ?: exif.getAttribute(ExifInterface.TAG_DATETIME)
            ?: return null
        val format = SimpleDateFormat("yyyy:MM:dd HH:mm:ss", Locale.US)
        return runCatching { format.parse(raw) }.getOrNull()
    }
}
