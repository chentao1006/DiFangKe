package com.ct106.difangke.service

import android.content.Context
import android.provider.MediaStore
import android.util.Log
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
     * 查询指定时间范围内的照片集合
     * 对应 iOS HistoryListView 中的照片查询逻辑
     */
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
