package com.ct106.difangke.service

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.util.Log
import android.widget.Toast
import com.ct106.difangke.AppConfig
import com.ct106.difangke.BuildConfig
import com.google.gson.Gson
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
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
 * Android 更新管理器
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
     * 在浏览器中打开更新下载地址
     */
    fun openDownloadInBrowser(url: String, versionCode: Int) {
        val finalUrl = if (url.contains("?")) "$url&v=$versionCode" else "$url?v=$versionCode"
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse(finalUrl)).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }

        try {
            context.startActivity(intent)
            Toast.makeText(context, "已打开浏览器开始下载更新", Toast.LENGTH_SHORT).show()
        } catch (e: ActivityNotFoundException) {
            Log.e(TAG, "打开浏览器失败", e)
            Toast.makeText(context, "未找到可用浏览器，请复制链接手动下载", Toast.LENGTH_LONG).show()
        } catch (e: Exception) {
            Log.e(TAG, "启动浏览器失败", e)
            Toast.makeText(context, "启动浏览器失败: ${e.message}", Toast.LENGTH_LONG).show()
        }
    }

    /** Google Play 发行包始终到 Google Play 检查更新。 */
    fun isPlayStoreDistribution(): Boolean = BuildConfig.IS_PLAY_DISTRIBUTION

    /**
     * 打开 Google Play Store 对应的应用页面
     */
    fun openPlayStore() {
        val appPackageName = context.packageName
        try {
            val intent = Intent(Intent.ACTION_VIEW, Uri.parse("market://details?id=$appPackageName")).apply {
                // market:// 是通用协议；不指定包名会被部分国产 ROM 的应用商店接管。
                setPackage("com.android.vending")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            context.startActivity(intent)
        } catch (e: ActivityNotFoundException) {
            val intent = Intent(Intent.ACTION_VIEW, Uri.parse("https://play.google.com/store/apps/details?id=$appPackageName")).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            context.startActivity(intent)
        }
    }
}
