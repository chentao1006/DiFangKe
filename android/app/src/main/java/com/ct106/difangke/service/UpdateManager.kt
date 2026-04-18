package com.ct106.difangke.service

import android.app.DownloadManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.util.Log
import android.widget.Toast
import androidx.core.content.FileProvider
import com.ct106.difangke.AppConfig
import com.google.gson.Gson
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.net.HttpURLConnection
import java.net.URL

import com.google.gson.annotations.SerializedName

/**
 * APK 更新包信息
 */
data class UpdateInfo(
    @SerializedName("versionCode")
    val versionCode: Int,
    @SerializedName("versionName")
    val versionName: String,
    @SerializedName("downloadUrl")
    val downloadUrl: String,
    @SerializedName("releaseNotes")
    val releaseNotes: String
)

/**
 * Android 自动更新管理器
 */
class UpdateManager private constructor(private val context: Context) {

    companion object {
        private const val TAG = "UpdateManager"
        @Volatile
        private var instance: UpdateManager? = null

        fun getInstance(context: Context): UpdateManager {
            return instance ?: synchronized(this) {
                instance ?: UpdateManager(context.applicationContext).also { instance = it }
            }
        }
    }

    private val gson = Gson()
    private val downloadManager = context.getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager

    /**
     * 从服务器获取更新信息
     */
    suspend fun checkUpdate(): UpdateInfo? = withContext(Dispatchers.IO) {
        runCatching {
            val url = URL(AppConfig.UPDATE_CHECK_URL)
            val conn = url.openConnection() as HttpURLConnection
            conn.connectTimeout = 10000
            conn.readTimeout = 10000
            conn.setRequestProperty("Accept", "application/json")
            
            val responseCode = conn.responseCode
            if (responseCode != 200) {
                Log.w(TAG, "检查更新失败: HTTP $responseCode")
                return@runCatching null
            }
            
            val body = conn.inputStream.bufferedReader().readText()
            conn.disconnect()
            
            gson.fromJson(body, UpdateInfo::class.java)
        }.onFailure {
            Log.e(TAG, "检查更新时发生异常", it)
        }.getOrNull()
    }

    /**
     * 判断是否有新版本
     */
    fun isNewVersionAvailable(remoteVersionCode: Int): Boolean {
        return try {
            val packageInfo = context.packageManager.getPackageInfo(context.packageName, 0)
            val currentVersionCode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                packageInfo.longVersionCode
            } else {
                @Suppress("DEPRECATION")
                packageInfo.versionCode.toLong()
            }
            remoteVersionCode > currentVersionCode
        } catch (e: Exception) {
            false
        }
    }

    /**
     * 开始下载并安装 APK
     */
    fun downloadAndInstall(url: String, versionCode: Int, fileName: String = "difangke_latest.apk") {
        try {
            // 为 URL 加上版本号 query，防止下载到旧缓存
            val finalUrl = if (url.contains("?")) "$url&v=$versionCode" else "$url?v=$versionCode"
            
            // 清理旧文件
            val destinationFile = File(context.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS), fileName)
            if (destinationFile.exists()) {
                destinationFile.delete()
            }

            val request = DownloadManager.Request(Uri.parse(finalUrl))
                .setTitle("正在下载地方客更新")
                .setDescription("正在获取最新版本...")
                .setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)
                .setDestinationInExternalFilesDir(context, Environment.DIRECTORY_DOWNLOADS, fileName)
                .setAllowedOverMetered(true)
                .setAllowedOverRoaming(true)
                .setMimeType("application/vnd.android.package-archive")

            val downloadId = downloadManager.enqueue(request)
            Toast.makeText(context, "开始下载更新...", Toast.LENGTH_SHORT).show()

            // 注册广播监听下载完成
            val onComplete = object : BroadcastReceiver() {
                override fun onReceive(ctx: Context, intent: Intent) {
                    val id = intent.getLongExtra(DownloadManager.EXTRA_DOWNLOAD_ID, -1L)
                    if (id == downloadId) {
                        Log.d(TAG, "下载完成，准备安装: $destinationFile")
                        installApk(destinationFile)
                        context.unregisterReceiver(this)
                    }
                }
            }
            
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                context.registerReceiver(onComplete, IntentFilter(DownloadManager.ACTION_DOWNLOAD_COMPLETE), Context.RECEIVER_NOT_EXPORTED)
            } else {
                context.registerReceiver(onComplete, IntentFilter(DownloadManager.ACTION_DOWNLOAD_COMPLETE))
            }
        } catch (e: Exception) {
            Log.e(TAG, "启动下载失败", e)
            Toast.makeText(context, "启动下载失败: ${e.message}", Toast.LENGTH_LONG).show()
        }
    }

    /**
     * 弹出系统安装界面
     */
    fun installApk(file: File) {
        if (!file.exists()) {
            Log.e(TAG, "安装失败：文件不存在 $file")
            return
        }
        
        val intent = Intent(Intent.ACTION_VIEW).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            val uri = FileProvider.getUriForFile(
                context,
                "${context.packageName}.fileprovider",
                file
            )
            setDataAndType(uri, "application/vnd.android.package-archive")
        }
        
        try {
            context.startActivity(intent)
        } catch (e: Exception) {
            Log.e(TAG, "启动安装程序失败", e)
            Toast.makeText(context, "无法启动安装程序，请手动在文件管理器中安装", Toast.LENGTH_LONG).show()
        }
    }
}
