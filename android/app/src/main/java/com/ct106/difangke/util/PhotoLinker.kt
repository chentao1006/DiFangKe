package com.ct106.difangke.util

import android.content.ContentUris
import android.content.Context
import android.provider.MediaStore
import com.ct106.difangke.data.db.entity.FootprintEntity
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import java.util.*

object PhotoLinker {
    /**
     * 自动关联特定足迹发生期间拍摄的照片
     */
    suspend fun linkPhotosToFootprint(context: Context, footprint: FootprintEntity): List<String> = withContext(Dispatchers.IO) {
        val photos = mutableListOf<String>()
        val startTime = footprint.startTime.time
        val endTime = footprint.endTime.time
        
        val projection = arrayOf(
            MediaStore.Images.Media._ID,
            MediaStore.Images.Media.DATE_TAKEN
        )
        
        // 筛选时间范围内的照片
        val selection = "${MediaStore.Images.Media.DATE_TAKEN} >= ? AND ${MediaStore.Images.Media.DATE_TAKEN} <= ?"
        val selectionArgs = arrayOf(startTime.toString(), endTime.toString())
        val sortOrder = "${MediaStore.Images.Media.DATE_TAKEN} ASC"
        
        context.contentResolver.query(
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
            projection,
            selection,
            selectionArgs,
            sortOrder
        )?.use { cursor ->
            val idColumn = cursor.getColumnIndexOrThrow(MediaStore.Images.Media._ID)
            while (cursor.moveToNext()) {
                val id = cursor.getLong(idColumn)
                val contentUri = ContentUris.withAppendedId(
                    MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                    id
                )
                photos.add(contentUri.toString())
            }
        }
        
        return@withContext photos
    }

    /**
     * 更新足迹的照片列表
     */
    fun mergePhotoIds(existingJson: String, newUris: List<String>): String {
        val currentSet = mutableSetOf<String>()
        try {
            val arr = JSONArray(existingJson)
            for (i in 0 until arr.length()) {
                currentSet.add(arr.getString(i))
            }
        } catch (e: Exception) {}
        
        currentSet.addAll(newUris)
        
        val result = JSONArray()
        currentSet.forEach { result.put(it) }
        return result.toString()
    }
}
