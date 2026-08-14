package com.ct106.difangke.ui

import androidx.compose.animation.*
import androidx.compose.animation.core.tween
import androidx.activity.compose.BackHandler
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
    const val MAIN = "main?date={date}&tripID={tripID}"
    const val HISTORY = "history?date={date}"
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
    const val RECYCLE_BIN = "settings/recycle_bin"
    const val DAILY_TIMELINE = "daily_timeline/{date}"
    const val RAW_POINTS = "raw_points?date={date}"
}


@Composable
fun NavGraph(
    initialDate: Long? = null,
    initialFutureTripID: String? = null,
    initialFootprintID: String? = null
) {
    val navController = rememberNavController()
    val context = LocalContext.current
    val prefs = remember { AppPreferences(context) }
    
    var startDestination by remember { mutableStateOf<String?>(null) }
    
    LaunchedEffect(Unit) {
        val hasLaunched = prefs.getHasLaunchedBefore()
        startDestination = if (hasLaunched) {
            // Keep a real root destination at all times. Starting directly at
            // a detail route lets a fast Back press pop the NavHost completely
            // while MainActivity remains visible, which is the white screen.
            NavRoutes.MAIN
        } else {
            NavRoutes.ONBOARDING
        }
    }

    if (startDestination == null) {
        // 等待配置加载时显示空白屏（通常只有几十毫秒）
        return
    }

    val activity = LocalContext.current as? androidx.activity.ComponentActivity
    DisposableEffect(activity, navController) {
        val listener = androidx.core.util.Consumer<android.content.Intent> { intent ->
            val date = intent.getLongExtra("date", -1L)
            val tripID = intent.getStringExtra("futureTripID")
            val footprintID = intent.getStringExtra("footprintID")
            if (footprintID != null) {
                intent.removeExtra("footprintID")
                navController.navigate("footprint_detail/$footprintID")
            } else if (date != -1L || tripID != null) {
                intent.removeExtra("date")
                intent.removeExtra("futureTripID")
                navController.navigate("main?date=${if (date == -1L) "" else date}&tripID=${tripID ?: ""}") {
                    popUpTo(NavRoutes.MAIN) { inclusive = true }
                }
            }
        }
        activity?.addOnNewIntentListener(listener)
        onDispose {
            activity?.removeOnNewIntentListener(listener)
        }
    }

    // Do not delegate the root case to NavController's default callback.
    // During a rapid sequence of Back presses its callback can receive a
    // second event before composition has disabled it, popping MAIN and
    // leaving NavHost with no destination (a white MainActivity). The stack
    // itself updates synchronously, so checking the previous entry makes each
    // press deterministic: pop a child, otherwise close the activity.
    BackHandler(enabled = startDestination != null) {
        if (navController.previousBackStackEntry != null) {
            navController.popBackStack()
        } else {
            activity?.finish()
        }
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
            val initialFutureTripID = backStackEntry.arguments?.getString("tripID")?.takeIf { it.isNotBlank() }
            
            MainScreen(
                initialDate = initialDate,
                initialFutureTripID = initialFutureTripID,
                onNavigateToHistory = { date -> navController.navigate("history?date=${date.time}") },
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
                },
                onNavigateToRawPoints = { date ->
                    navController.navigate("raw_points?date=${date.time}")
                },
                onNavigateToPlaces = { navController.navigate(NavRoutes.PLACES_MANAGER) }
            )
        }
        composable(NavRoutes.HISTORY) { backStackEntry ->
            val initialDate = backStackEntry.arguments?.getString("date")
                ?.toLongOrNull()
                ?.let { timestamp -> java.util.Date(timestamp) }
                ?: java.util.Date()
            HistoryScreen(
                initialDate = initialDate,
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
                },
                onNavigateToRawPoints = { date ->
                    navController.navigate("raw_points?date=${date.time}")
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
            com.ct106.difangke.ui.screens.settings.DataManagerScreen(
                onBack = { navController.popBackStack() },
                onNavigateToRecycleBin = { navController.navigate(NavRoutes.RECYCLE_BIN) },
                onNavigateToRawPoints = { navController.navigate("raw_points?date=${System.currentTimeMillis()}") }
            )
        }
        composable(NavRoutes.RECYCLE_BIN) {
            com.ct106.difangke.ui.screens.settings.RecycleBinScreen(onBack = { navController.popBackStack() })
        }
        composable(NavRoutes.MAP) { backStackEntry ->
            val dateTimestamp = backStackEntry.arguments?.getString("date")?.toLongOrNull()
            DFKMapScreen(
                onBack = { navController.popBackStack() },
                onNavigateToDetail = { id ->
                    if (id.startsWith("t_")) navController.navigate("transport_detail/${id.substring(2)}")
                    else navController.navigate("footprint_detail/${id.removePrefix("f_")}")
                },
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
                },
                onNavigateToRawPoints = { date ->
                    navController.navigate("raw_points?date=${date.time}")
                }
            )
        }
        composable(NavRoutes.RAW_POINTS) { backStackEntry ->
            val dateTimestamp = backStackEntry.arguments?.getString("date")?.toLongOrNull() ?: System.currentTimeMillis()
            com.ct106.difangke.ui.screens.map.RawPointsScreen(
                date = java.util.Date(dateTimestamp),
                onBack = { navController.popBackStack() }
            )
        }
    }

    // Resolve launch deep links only after NavHost has installed MAIN as its
    // root. Back from a notification/detail now always returns to the home
    // timeline instead of leaving an empty navigation graph.
    LaunchedEffect(startDestination) {
        if (startDestination != NavRoutes.MAIN) return@LaunchedEffect
        when {
            initialFootprintID != null -> {
                navController.navigate("footprint_detail/$initialFootprintID")
            }
            initialFutureTripID != null || initialDate != null -> {
                navController.navigate(
                    "main?date=${initialDate ?: ""}&tripID=${initialFutureTripID ?: ""}"
                )
            }
        }
    }
}
