package com.ct106.difangke.ui.screens.main

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Timeline
import androidx.compose.material.icons.outlined.BarChart
import androidx.compose.material.icons.outlined.Map
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import com.ct106.difangke.ui.screens.history.ReviewScreen
import com.ct106.difangke.ui.screens.settings.SettingsScreen
import java.util.Date

/** iOS TimelineDestination: an explicit navigation request, including repeated requests for the same day. */
data class TimelineDestination(
    val date: Date,
    val footprintID: String? = null,
    val id: Long = System.nanoTime()
)

private enum class MainTab(val label: String, val icon: ImageVector) {
    RECORDS("足迹", Icons.Default.Timeline),
    TRIP("出行", Icons.Outlined.Map),
    REVIEW("回顾", Icons.Outlined.BarChart),
    SETTINGS("设置", Icons.Outlined.Settings)
}
/**
 * iOS MainTabView: owns app navigation. Only Records hosts the map and the
 * resizable timeline sheet; Review opens a day or footprint there.
 */
@Composable
fun MainTabScreen(
    initialDate: Date?,
    onNavigate: (String) -> Unit,
    onNavigateToRawPoints: (Date) -> Unit,
    onNavigateToPlaces: () -> Unit
) {
    var selectedTab by rememberSaveable { mutableStateOf(MainTab.RECORDS) }
    var destination by remember { mutableStateOf<TimelineDestination?>(null) }

    BackHandler(enabled = selectedTab != MainTab.RECORDS) { selectedTab = MainTab.RECORDS }

    Scaffold(
        bottomBar = {
            NavigationBar {
                MainTab.entries.forEach { tab ->
                    NavigationBarItem(
                        selected = selectedTab == tab,
                        onClick = { selectedTab = tab },
                        icon = { Icon(tab.icon, contentDescription = null) },
                        label = { Text(tab.label) }
                    )
                }
            }
        },
        contentWindowInsets = WindowInsets(0)
    ) { padding ->
        Box(
            Modifier
                .fillMaxSize()
                .padding(padding)
                .consumeWindowInsets(padding)
        ) {
            // Records stays composed beneath the other tabs so its map and
            // timeline position survive tab switches (iOS keeps its scene).
            MainScreen(
                initialDate = initialDate,
                isActive = selectedTab == MainTab.RECORDS,
                destination = destination,
                onDestinationConsumed = { destination = null },
                onNavigateToRawPoints = onNavigateToRawPoints,
                onNavigateToPlaces = onNavigateToPlaces
            )
            when (selectedTab) {
                MainTab.RECORDS -> Unit
                MainTab.TRIP -> TripScreen()
                MainTab.REVIEW -> ReviewScreen(
                    onFootprintSelected = { footprint ->
                        destination = TimelineDestination(footprint.startTime, footprint.footprintID)
                        selectedTab = MainTab.RECORDS
                    }
                )
                MainTab.SETTINGS -> SettingsScreen(onNavigate = onNavigate)
            }
        }
    }
}
