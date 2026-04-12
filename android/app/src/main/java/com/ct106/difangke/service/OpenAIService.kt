package com.ct106.difangke.service

import android.content.Context
import android.util.Log
import com.ct106.difangke.AppConfig
import com.ct106.difangke.DiFangKeApp
import com.ct106.difangke.data.db.entity.DailyInsightEntity
import com.ct106.difangke.data.db.entity.FootprintEntity
import com.ct106.difangke.data.db.entity.TransportRecordEntity
import com.ct106.difangke.data.model.CandidateFootprint
import com.google.gson.Gson
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import org.json.JSONObject
import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.HttpURLConnection
import java.net.URL
import java.text.SimpleDateFormat
import java.util.*

/**
 * 对应 iOS OpenAIService.swift
 */
class OpenAIService private constructor() {

    companion object {
        private const val TAG = "OpenAIService"
        val shared: OpenAIService by lazy { OpenAIService() }
        private val DATE_FMT = SimpleDateFormat("yyyy年M月d日", Locale.CHINA)
        private val TIME_FMT = SimpleDateFormat("HH:mm", Locale.CHINA)
    }

    private val gson = Gson()
    private val prefs by lazy { DiFangKeApp.instance.preferences }
    private val db by lazy { DiFangKeApp.instance.database }
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())

    // 内存缓存
    var cacheDate: Date? = null
    var cachedTomorrowQuote: Pair<String, String>? = null

    /**
     * 发送网络请求的通用方法
     */
    private suspend fun postRequest(body: Map<String, Any>): JSONObject? = withContext(Dispatchers.IO) {
        val serviceType = prefs.aiServiceType.first()
        val isCustom = serviceType == "custom"

        val baseUrl = if (isCustom) prefs.getCustomAiUrl().trim() else AppConfig.PUBLIC_SERVICE_URL
        val apiKey = if (isCustom) prefs.getCustomAiKey().trim() else AppConfig.SERVICE_SECRET
        val model = if (isCustom) prefs.getCustomAiModel().trim() else "gpt-3.5-turbo"

        if (baseUrl.isEmpty() || apiKey.isEmpty()) {
            Log.e(TAG, "AI 接口配置不完整")
            return@withContext null
        }

        val urlStr = if (baseUrl.endsWith("/")) "${baseUrl}chat/completions" else "$baseUrl/chat/completions"
        
        val requestBody = body.toMutableMap()
        if (!requestBody.containsKey("model")) {
            requestBody["model"] = model
        }

        runCatching {
            val url = URL(urlStr)
            val conn = url.openConnection() as HttpURLConnection
            conn.apply {
                requestMethod = "POST"
                connectTimeout = 15000
                readTimeout = 15000
                setRequestProperty("Content-Type", "application/json")
                setRequestProperty("Authorization", "Bearer $apiKey")
                doOutput = true
            }

            val jsonOutput = gson.toJson(requestBody)
            conn.outputStream.use { os ->
                os.write(jsonOutput.toByteArray(Charsets.UTF_8))
            }

            if (conn.responseCode !in 200..299) {
                Log.e(TAG, "HTTP Error: ${conn.responseCode}")
                return@runCatching null
            }

            val responseText = BufferedReader(InputStreamReader(conn.inputStream)).readText()
            conn.disconnect()

            JSONObject(responseText)
        }.onFailure {
            Log.e(TAG, "Request failed", it)
        }.getOrNull()
    }

    /**
     * 分析单一足迹（对应 iOS analyzeFootprint）
     */
    suspend fun analyzeFootprint(
        fp: FootprintEntity,
        placeName: String? = null,
        activityName: String? = null
    ): Boolean = withContext(Dispatchers.IO) {
        if (fp.aiAnalyzed || FootprintTitles.isGeneric(fp.title)) return@withContext false

        val startStr = TIME_FMT.format(fp.startTime)
        val endStr = TIME_FMT.format(fp.endTime)
        val cal = Calendar.getInstance()
        cal.time = fp.startTime
        val weekdays = arrayOf("日", "一", "二", "三", "四", "五", "六")
        val weekdayStr = "周${weekdays[cal.get(Calendar.DAY_OF_WEEK) - 1]}"
        val dateContext = "公历${DATE_FMT.format(fp.startTime)}，$weekdayStr"

        var promptSnippet = ""
        if (!placeName.isNullOrEmpty()) {
            promptSnippet = "用户正在“$placeName”"
            if (!activityName.isNullOrEmpty()) promptSnippet += "进行“$activityName”活动。"
        } else {
            promptSnippet = if (!fp.address.isNullOrEmpty()) "这里的具体参考地址是：${fp.address}。" else "该位置是一个未曾记录的新去处。"
            if (!activityName.isNullOrEmpty()) promptSnippet += "用户正在这里进行“$activityName”。"
        }

        val prompt = """
        用户在某地点停留：
        日期环境：$dateContext
        时间：$startStr - $endStr
        时长：${fp.duration / 60}分钟
        地点与活动信息：$promptSnippet

        请根据以上信息进行分析并输出：
        1. 简短标题：10字以内，反映地点内涵或活动属性，严禁使用“地点记录”、“停留”、“发现足迹”等通用废话。
        2. 精彩程度：0.0 ~ 1.0。
        3. 足迹备注：20字以内，要求富有生活气息、温情且具有洞察力。
           【注意】：即便信息极少，也要尝试从时间段提取美感，绝对禁止出现“没有详情”、“具体活动不明”等死板表述。

        返回格式（严格JSON）：
        { "title": "...", "score": 0.85, "reason": "..." }
        """.trimIndent()

        val body = mapOf(
            "temperature" to 0.85,
            "response_format" to mapOf("type" to "json_object"),
            "messages" to listOf(
                mapOf("role" to "system", "content" to "你是一位拥有敏锐洞察力的生活美学专家，擅长从平凡的日常足迹中捕捉闪光点。你的回应必须是直接的 JSON 格式，文字风格温暖、精炼且富有感染力。"),
                mapOf("role" to "user", "content" to prompt)
            )
        )

        val response = postRequest(body) ?: return@withContext false

        try {
            val content = response.getJSONArray("choices").getJSONObject(0).getJSONObject("message").getString("content")
            val cleanStr = content.replace("```json", "").replace("```", "").trim()
            val resultJson = JSONObject(cleanStr)

            val newTitle = resultJson.optString("title", "新足迹")
            val reason = resultJson.optString("reason", "")
            val score = resultJson.optDouble("score", 0.0).toFloat()

            val updatedFp = fp.copy(
                title = newTitle,
                reason = reason,
                aiScore = score,
                aiAnalyzed = true
            )
            db.footprintDao().update(updatedFp)

            if (score >= 0.3 && prefs.isHighlightNotificationEnabled.first()) {
                NotificationHelper.sendHighlightNotification(
                    DiFangKeApp.instance, newTitle, reason, fp.footprintID.hashCode()
                )
            }
            true
        } catch (e: Exception) {
            Log.e(TAG, "解析足迹 AI 返回失败", e)
            false
        }
    }

    /**
     * 生成每日总结（对应 iOS processDailySummaryTask）
     */
    suspend fun generateDailySummary(
        date: Date,
        footprints: List<FootprintEntity>,
        transports: List<TransportRecordEntity>,
        force: Boolean = false
    ): Boolean = withContext(Dispatchers.IO) {
        val cal = Calendar.getInstance().apply {
            time = date
            set(Calendar.HOUR_OF_DAY, 0)
            set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
        }
        val startOfDay = cal.time

        // 获取当天已有的总结
        val calEnd = Calendar.getInstance().apply {
            time = startOfDay
            add(Calendar.DAY_OF_YEAR, 1)
        }
        val existing = db.dailyInsightDao().getForDay(startOfDay, calEnd.time)

        if (!force && existing?.aiGenerated == true) return@withContext true

        data class SimpleItem(val time: Date, val desc: String)
        val items = mutableListOf<SimpleItem>()

        for (fp in footprints) {
            if (FootprintTitles.isGeneric(fp.title)) continue
            var desc = fp.title
            if (fp.isHighlight == true) desc = "【重点收藏】$desc"
            items.add(SimpleItem(fp.startTime, desc))
        }

        for (tp in transports) {
            if (tp.statusRaw == "ignored") continue
            val typeName = com.ct106.difangke.data.model.TransportType.from(tp.typeRaw).localizedName
            val desc = "通过${typeName}从${tp.startLocation}前往${tp.endLocation}"
            items.add(SimpleItem(tp.startTime, desc))
        }

        if (items.isEmpty()) return@withContext false

        items.sortBy { it.time }
        val deduplicated = mutableListOf<String>()
        var lastDesc: String? = null

        for (item in items) {
            if (item.desc == lastDesc) continue
            deduplicated.add("[${TIME_FMT.format(item.time)}] ${item.desc}")
            lastDesc = item.desc
        }

        val fingerprint = deduplicated.joinToString("\n")
        if (force && existing?.dataFingerprint == fingerprint) return@withContext true

        val dateStr = DATE_FMT.format(startOfDay)
        val prompt = "今天是 $dateStr。请根据以下足迹编写一段极简晚间回顾（15字以内）。要求：作为一位善于发现生活之美的观察者，语气温润且富有洞察力，将碎片化的记录串联成有温度的文字，绝对不要使用生硬的模板：\n$fingerprint"

        val body = mapOf(
            "temperature" to 0.85,
            "messages" to listOf(
                mapOf("role" to "system", "content" to "你是一位文字优美、情感细腻的散文作家。请用中文回答，保持简洁、深远且充满创意的风格，避免重复和套路。"),
                mapOf("role" to "user", "content" to prompt)
            )
        )

        val response = postRequest(body) ?: return@withContext false

        try {
            val content = response.getJSONArray("choices").getJSONObject(0).getJSONObject("message").getString("content").trim()
            
            if (existing != null) {
                db.dailyInsightDao().update(existing.copy(
                    content = content,
                    aiGenerated = true,
                    dataFingerprint = fingerprint
                ))
            } else {
                db.dailyInsightDao().insert(DailyInsightEntity(
                    date = startOfDay,
                    content = content,
                    aiGenerated = true,
                    dataFingerprint = fingerprint
                ))
            }
            true
        } catch (e: Exception) {
            Log.e(TAG, "解析总结失败", e)
            false
        }
    }

    /**
     * 生成明日寄语（对应 iOS generateTomorrowQuote）
     */
    suspend fun getTomorrowQuote(): Pair<String, String> = withContext(Dispatchers.IO) {
        val now = Date()
        if (cachedTomorrowQuote != null && cacheDate != null) {
            val cal1 = Calendar.getInstance().apply { time = now }
            val cal2 = Calendar.getInstance().apply { time = cacheDate!! }
            if (cal1.get(Calendar.DAY_OF_YEAR) == cal2.get(Calendar.DAY_OF_YEAR)) {
                return@withContext cachedTomorrowQuote!!
            }
        }

        val fallback = Pair("明天见", "期待新的一天")
        
        val body = mapOf(
            "temperature" to 0.9,
            "messages" to listOf(
                mapOf("role" to "system", "content" to "Generate a warm quote for tomorrow in JSON: {\"title\":\"...\",\"subtitle\":\"...\"}"),
                mapOf("role" to "user", "content" to "帮我写一段对明天的寄语")
            )
        )

        val response = postRequest(body) ?: return@withContext fallback

        try {
            val content = response.getJSONArray("choices").getJSONObject(0).getJSONObject("message").getString("content")
            val cleanStr = content.replace("```json", "").replace("```", "").trim()
            val resultJson = JSONObject(cleanStr)
            
            val res = Pair(
                resultJson.optString("title", "明天见"),
                resultJson.optString("subtitle", "期待新的一天")
            )
            cachedTomorrowQuote = res
            cacheDate = now
            res
        } catch (e: Exception) {
            fallback
        }
    }
}
