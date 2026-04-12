package com.ct106.difangke.viewmodel

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import com.ct106.difangke.DiFangKeApp
import com.ct106.difangke.service.OpenAIService

class HistoryViewModel(application: Application) : AndroidViewModel(application) {

    private val db = DiFangKeApp.instance.database
    val openAI = OpenAIService.shared

    // TODO: 实现历史记录的数据加载和处理
}
