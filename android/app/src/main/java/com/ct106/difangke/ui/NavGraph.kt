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
    const val MAIN = "main"
    const val HISTORY = "history"
    const val SETTINGS = "settings"
    const val MAP = "map"
    const val STATISTICS = "statistics"
    const val FOOTPRINT_DETAIL = "footprint_detail/{id}"
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
        composable(NavRoutes.MAIN) {
            MainScreen(
                onNavigateToHistory = { navController.navigate(NavRoutes.HISTORY) },
                onNavigateToSettings = { navController.navigate(NavRoutes.SETTINGS) },
                onNavigateToMap = { navController.navigate(NavRoutes.MAP) },
                onNavigateToDetail = { id -> navController.navigate("footprint_detail/$id") }
            )
        }
        composable(NavRoutes.HISTORY) {
            HistoryScreen(
                onBack = { navController.popBackStack() },
                onNavigateToStatistics = { navController.navigate(NavRoutes.STATISTICS) },
                onNavigateToDetail = { id -> navController.navigate("footprint_detail/$id") }
            )
        }
        composable(NavRoutes.SETTINGS) {
            SettingsScreen(
                onBack = { navController.popBackStack() }
            )
        }
        composable(NavRoutes.MAP) {
            DFKMapScreen(onBack = { navController.popBackStack() })
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
    }
}
