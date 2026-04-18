package com.ct106.difangke.ui

import androidx.compose.animation.*
import androidx.compose.animation.core.tween
import androidx.compose.runtime.*
import androidx.compose.ui.platform.LocalContext
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import com.ct106.difangke.ui.screens.history.HistoryScreen
import com.ct106.difangke.ui.screens.main.MainScreen
import com.ct106.difangke.ui.screens.onboarding.OnboardingScreen
import com.ct106.difangke.ui.screens.settings.SettingsScreen
import com.ct106.difangke.ui.screens.map.DFKMapScreen
import com.ct106.difangke.ui.screens.statistics.StatisticsScreen
import com.ct106.difangke.ui.screens.detail.FootprintDetailScreen
import com.ct106.difangke.data.prefs.AppPreferences
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking

object NavRoutes {
    const val ONBOARDING = "onboarding"
    const val MAIN = "main?date={date}"
    const val HISTORY = "history"
    const val SETTINGS = "settings"
    const val MAP = "map?date={date}"
    const val STATISTICS = "statistics"
    const val FOOTPRINT_DETAIL = "footprint_detail/{id}"
    const val TRANSPORT_DETAIL = "transport_detail/{id}"
    const val PLACES_MANAGER = "settings/places"
    const val SAVED_PLACES = "settings/saved_places"
    const val IGNORED_PLACES = "settings/ignored_places"
    const val ACTIVITY_TYPE_SETTINGS = "settings/activities"
    const val AI_SETTINGS = "settings/ai"
    const val DATA_MANAGER = "settings/data"
    const val DAILY_TIMELINE = "daily_timeline/{date}"
}


@Composable
fun NavGraph() {
    val navController = rememberNavController()
    val context = LocalContext.current
    val prefs = remember { AppPreferences(context) }
    
    var startDestination by remember { mutableStateOf<String?>(null) }
    
    LaunchedEffect(Unit) {
        val hasLaunched = prefs.getHasLaunchedBefore()
        startDestination = if (hasLaunched) NavRoutes.MAIN else NavRoutes.ONBOARDING
    }

    if (startDestination == null) {
        // 等待配置加载时显示空白屏（通常只有几十毫秒）
        return
    }

    NavHost(
        navController = navController,
        startDestination = startDestination!!,
        enterTransition = { fadeIn(animationSpec = tween(300)) },
        exitTransition = { fadeOut(animationSpec = tween(300)) }
    ) {
        composable(NavRoutes.ONBOARDING) {
            OnboardingScreen(
                onFinish = {
                    navController.navigate(NavRoutes.MAIN) {
                        popUpTo(NavRoutes.ONBOARDING) { inclusive = true }
                    }
                }
            )
        }
        composable(NavRoutes.MAIN) { backStackEntry ->
            val initialDateStr = backStackEntry.arguments?.getString("date")
            val initialDate = initialDateStr?.toLongOrNull()?.let { java.util.Date(it) }
            
            MainScreen(
                initialDate = initialDate,
                onNavigateToHistory = { navController.navigate(NavRoutes.HISTORY) },
                onNavigateToStatistics = { navController.navigate(NavRoutes.STATISTICS) },
                onNavigateToSettings = { navController.navigate(NavRoutes.SETTINGS) },
                onNavigateToMap = { date -> 
                    val route = if (date != null) "map?date=${date.time}" else "map"
                    navController.navigate(route)
                },
                onNavigateToDetail = { id -> 
                    if (id.startsWith("t_")) {
                        navController.navigate("transport_detail/${id.substring(2)}") 
                    } else if (id.startsWith("f_")) {
                        navController.navigate("footprint_detail/${id.substring(2)}")
                    } else {
                        // For backwards compatibility or direct UUIDs
                        navController.navigate("footprint_detail/$id")
                    }
                }
            )
        }
        composable(NavRoutes.HISTORY) {
            HistoryScreen(
                onBack = { navController.popBackStack() },
                onNavigateToDetail = { id -> 
                    if (id.startsWith("t_")) {
                        navController.navigate("transport_detail/${id.substring(2)}") 
                    } else if (id.startsWith("f_")) {
                        navController.navigate("footprint_detail/${id.substring(2)}")
                    } else {
                        navController.navigate("footprint_detail/$id")
                    }
                },
                onDateSelected = { date -> 
                    navController.navigate("daily_timeline/${date.time}")
                }
            )
        }
        composable(NavRoutes.SETTINGS) {
            SettingsScreen(
                onBack = { navController.popBackStack() },
                onNavigate = { route -> navController.navigate(route) }
            )
        }
        composable(NavRoutes.PLACES_MANAGER) {
            com.ct106.difangke.ui.screens.settings.PlacesManagerScreen(onBack = { navController.popBackStack() })
        }
        composable(NavRoutes.SAVED_PLACES) {
            com.ct106.difangke.ui.screens.settings.SavedPlacesScreen(onBack = { navController.popBackStack() })
        }
        composable(NavRoutes.IGNORED_PLACES) {
            com.ct106.difangke.ui.screens.settings.IgnoredPlacesScreen(onBack = { navController.popBackStack() })
        }
        composable(NavRoutes.ACTIVITY_TYPE_SETTINGS) {
            com.ct106.difangke.ui.screens.settings.ActivityTypeSettingsScreen(onBack = { navController.popBackStack() })
        }
        composable(NavRoutes.AI_SETTINGS) {
            com.ct106.difangke.ui.screens.settings.AiSettingsScreen(onBack = { navController.popBackStack() })
        }
        composable(NavRoutes.DATA_MANAGER) {
            com.ct106.difangke.ui.screens.settings.DataManagerScreen(onBack = { navController.popBackStack() })
        }
        composable(NavRoutes.MAP) { backStackEntry ->
            val dateTimestamp = backStackEntry.arguments?.getString("date")?.toLongOrNull()
            DFKMapScreen(
                onBack = { navController.popBackStack() },
                dateTimestamp = dateTimestamp
            )
        }
        composable(NavRoutes.STATISTICS) {
            StatisticsScreen(onBack = { navController.popBackStack() })
        }
        composable(NavRoutes.FOOTPRINT_DETAIL) { backStackEntry ->
            val id = backStackEntry.arguments?.getString("id") ?: ""
            FootprintDetailScreen(
                footprintId = id,
                onBack = { navController.popBackStack() }
            )
        }
        composable(NavRoutes.TRANSPORT_DETAIL) { backStackEntry ->
            val id = backStackEntry.arguments?.getString("id") ?: ""
            com.ct106.difangke.ui.screens.detail.TransportDetailScreen(
                transportId = id,
                onBack = { navController.popBackStack() }
            )
        }
        composable(NavRoutes.DAILY_TIMELINE) { backStackEntry ->
            val dateTimestamp = backStackEntry.arguments?.getString("date")?.toLongOrNull() ?: System.currentTimeMillis()
            com.ct106.difangke.ui.screens.history.DailyTimelineScreen(
                date = java.util.Date(dateTimestamp),
                onBack = { navController.popBackStack() },
                onNavigateToDetail = { id -> 
                    if (id.startsWith("t_")) {
                        navController.navigate("transport_detail/${id.substring(2)}") 
                    } else if (id.startsWith("f_")) {
                        navController.navigate("footprint_detail/${id.substring(2)}")
                    } else {
                        navController.navigate("footprint_detail/$id")
                    }
                },
                onNavigateToMap = { date -> 
                    navController.navigate("map?date=${date.time}")
                }
            )
        }
    }
}
