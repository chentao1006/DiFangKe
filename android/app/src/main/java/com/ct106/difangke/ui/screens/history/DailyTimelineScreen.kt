package com.ct106.difangke.ui.screens.history

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.lifecycle.viewmodel.compose.viewModel
import com.ct106.difangke.viewmodel.MainViewModel
import com.ct106.difangke.ui.screens.main.TimelinePage
import java.text.SimpleDateFormat
import java.util.*

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DailyTimelineScreen(
    date: Date,
    onBack: () -> Unit,
    onNavigateToDetail: (String) -> Unit,
    onNavigateToMap: (Date) -> Unit,
    viewModel: MainViewModel = viewModel()
) {
    val trackingState by viewModel.trackingState.collectAsState()
    val activityTypes by viewModel.activityTypes.collectAsState()
    val allPlaces by viewModel.allPlaces.collectAsState()
    
    val isDark = isSystemInDarkTheme()
    val bgColor = if (isDark) Color.Black else Color(0xFFF2F2F7)
    
    val dateTitle = SimpleDateFormat("yyyy年M月d日", Locale.CHINA).format(date)

    Scaffold(
        containerColor = bgColor,
        topBar = {
            CenterAlignedTopAppBar(
                title = { Text(dateTitle, fontWeight = FontWeight.Bold) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "返回")
                    }
                },
                colors = TopAppBarDefaults.centerAlignedTopAppBarColors(
                    containerColor = bgColor
                )
            )
        }
    ) { padding ->
        Box(modifier = Modifier.padding(padding).fillMaxSize()) {
            TimelinePage(
                date = date,
                viewModel = viewModel,
                trackingState = trackingState,
                activityTypes = activityTypes,
                allPlaces = allPlaces,
                isFirstPage = false,
                isLastPage = false,
                hasLocationPermission = true,
                onRequestPermission = { },
                onItemClick = onNavigateToDetail,
                onMapClick = { onNavigateToMap(date) }
            )
        }
    }
}
