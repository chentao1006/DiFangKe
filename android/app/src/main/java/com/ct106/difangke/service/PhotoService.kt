package com.ct106.difangke.service

import android.content.Context
import android.net.Uri
import android.provider.MediaStore
import android.util.Log
import com.ct106.difangke.AppConfig
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
        excludedPhotoUris: Set<String> = emptySet(),
        history: List<FootprintEntity> = emptyList()
    ): List<FootprintEntity> {
        val photos = photosFromUris(photoUris)
            .filter { photo ->
                photo.latitude != null && photo.longitude != null && photo.uri !in excludedPhotoUris &&
                    // A photo taken during an existing stay already has a
                    // footprint, even if it hasn't been attached to it yet.
                    history.none { footprint -> photoBelongsToStay(photo, footprint) }
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

    /**
     * iOS PhotoService.asset(_:belongsToStayFrom:to:near:maxDistance:): the
     * single rule for whether a photo belongs to a stay. Photos without a
     * location were not taken there, so they never match automatically.
     */
    fun photoBelongsToStay(photo: PhotoInfo, footprint: FootprintEntity): Boolean {
        val latitude = photo.latitude ?: return false
        val longitude = photo.longitude ?: return false
        val bufferMillis = (AppConfig.PHOTO_LINKING_TIME_BUFFER * 1000).toLong()
        if (photo.dateTaken.time <= footprint.startTime.time - bufferMillis ||
            photo.dateTaken.time >= footprint.endTime.time + bufferMillis
        ) return false
        val latitudes = jsonDoubles(footprint.latitudeJson)
        val longitudes = jsonDoubles(footprint.longitudeJson)
        if (latitudes.isEmpty() || longitudes.isEmpty()) return true
        return distanceMeters(latitudes.average(), longitudes.average(), latitude, longitude) <=
            AppConfig.PHOTO_LINKING_MAX_DISTANCE
    }

    /**
     * iOS PhotoService.latestAsset(among:): a footprint's representative photo
     * is the most recently taken one. The stored list is in insertion order
     * (import appends oldest first, manual additions go last), so it can't be
     * read off either end.
     */
    suspend fun latestPhotoUri(uris: List<String>): String? = withContext(Dispatchers.IO) {
        if (uris.size <= 1) return@withContext uris.firstOrNull()
        uris.maxByOrNull { uri -> readDateTaken(uri)?.time ?: Long.MIN_VALUE }
    }

    private fun readDateTaken(uri: String): Date? = runCatching {
        context.contentResolver.openInputStream(Uri.parse(uri))?.use { parseExifDate(ExifInterface(it)) }
    }.getOrNull()

    private fun jsonDoubles(json: String): List<Double> = runCatching {
        val array = JSONArray(json)
        List(array.length()) { array.getDouble(it) }
    }.getOrDefault(emptyList())

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
