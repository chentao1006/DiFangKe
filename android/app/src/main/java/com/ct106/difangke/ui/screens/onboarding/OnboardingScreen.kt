package com.ct106.difangke.ui.screens.onboarding

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.DirectionsWalk
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.LocationOn
import androidx.compose.material.icons.filled.MyLocation
import androidx.compose.material.icons.filled.NotificationsActive
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import com.ct106.difangke.data.prefs.AppPreferences
import com.ct106.difangke.service.LocationTrackingService
import kotlinx.coroutines.launch

/** Onboarding steps (mirrors iOS OnboardingView; background location is Android-specific). */
private enum class OnboardingStep { LOCATION, BACKGROUND_LOCATION, ACTIVITY, NOTIFICATIONS, AI }

private val Accent = Color(0xFF00A0AC)
private val Orange = Color(0xFFFF9500)
private val Red = Color(0xFFFF3B30)
private val Purple = Color(0xFFAF52DE)

@Composable
fun OnboardingScreen(onFinish: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val prefs = remember { AppPreferences(context) }
    val activity = remember(context) { context.findActivity() }

    val usesActivityRecognition = remember { declaresActivityRecognition(context) }

    var step by remember {
        mutableStateOf(
            if (hasForegroundLocation(context)) nextAfterLocation(context, usesActivityRecognition)
            else OnboardingStep.LOCATION
        )
    }
    var showLocationSettingsAlert by remember { mutableStateOf(false) }
    var locationDenied by remember { mutableStateOf(false) }
    var backgroundDenied by remember { mutableStateOf(false) }

    fun openAppSettings() {
        try {
            context.startActivity(
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", context.packageName, null))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
        } catch (_: Exception) {
            context.startActivity(Intent(Settings.ACTION_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }
    }

    fun onForegroundGranted() {
        scope.launch {
            prefs.setTrackingEnabled(true)
            runCatching { LocationTrackingService.start(context) }
        }
        step = nextAfterLocation(context, usesActivityRecognition)
    }

    fun finish(aiEnabled: Boolean) {
        scope.launch {
            prefs.setAiEnabled(aiEnabled)
            prefs.setHasLaunchedBefore(true)
            onFinish()
        }
    }

    val locationLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { result ->
        val granted = result[Manifest.permission.ACCESS_FINE_LOCATION] == true ||
            result[Manifest.permission.ACCESS_COARSE_LOCATION] == true
        if (granted) {
            locationDenied = false
            onForegroundGranted()
        } else {
            locationDenied = true
            showLocationSettingsAlert = true
        }
    }

    val backgroundLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { granted ->
        if (granted) {
            runCatching { LocationTrackingService.start(context) }
            step = afterBackground(usesActivityRecognition)
        } else {
            backgroundDenied = true
        }
    }

    val activityLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { _ -> step = OnboardingStep.NOTIFICATIONS }

    val notificationLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { _ -> step = OnboardingStep.AI }

    // Returning from system settings: re-check and advance like iOS onChange(authStatus).
    DisposableEffect(activity) {
        val observer = LifecycleEventObserver { _, event ->
            if (event != Lifecycle.Event.ON_RESUME) return@LifecycleEventObserver
            when (step) {
                OnboardingStep.LOCATION -> if (hasForegroundLocation(context)) {
                    showLocationSettingsAlert = false
                    locationDenied = false
                    onForegroundGranted()
                }
                OnboardingStep.BACKGROUND_LOCATION -> if (hasBackgroundLocation(context)) {
                    runCatching { LocationTrackingService.start(context) }
                    step = afterBackground(usesActivityRecognition)
                }
                else -> Unit
            }
        }
        activity?.lifecycle?.addObserver(observer)
        onDispose { activity?.lifecycle?.removeObserver(observer) }
    }

    val isDark = isSystemInDarkTheme()
    val background = if (isDark) Color.Black else Color(0xFFF2F2F7)

    Scaffold(containerColor = background) { padding ->
        AnimatedContent(
            targetState = step,
            transitionSpec = {
                slideInHorizontally { it } togetherWith slideOutHorizontally { -it }
            },
            modifier = Modifier
                .fillMaxSize()
                .padding(padding),
            label = "onboarding"
        ) { current ->
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(30.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center
            ) {
                when (current) {
                    OnboardingStep.LOCATION -> {
                        OnboardingStepContent(
                            title = "记录走过的足迹",
                            description = "为了能在后台自动为您记录走过的足迹，地方客需要位置权限。请先在系统弹窗中选择「使用 App 时允许」；完成初始设置后，地方客会再询问您是否允许「始终」定位，以便离开 App 后仍能持续记录。",
                            icon = Icons.Filled.LocationOn,
                            color = Accent,
                            buttonText = "继续"
                        ) {
                            val permanentlyDenied = locationDenied && activity != null &&
                                !activity.shouldShowRequestPermissionRationaleCompat(Manifest.permission.ACCESS_FINE_LOCATION)
                            if (permanentlyDenied) {
                                openAppSettings()
                            } else {
                                locationLauncher.launch(
                                    arrayOf(
                                        Manifest.permission.ACCESS_FINE_LOCATION,
                                        Manifest.permission.ACCESS_COARSE_LOCATION
                                    )
                                )
                            }
                        }
                        if (locationDenied) {
                            SecondaryButton("暂不开启") {
                                step = OnboardingStep.NOTIFICATIONS
                            }
                        }
                    }

                    OnboardingStep.BACKGROUND_LOCATION -> {
                        val viaSettings = Build.VERSION.SDK_INT >= Build.VERSION_CODES.R
                        OnboardingStepContent(
                            title = "离开 App 也能记录",
                            description = if (viaSettings) {
                                "为了在离开 App 后仍能持续记录足迹、停留与行程，请在接下来的系统设置页面中，将位置权限设为「始终允许」。"
                            } else {
                                "为了在离开 App 后仍能持续记录足迹、停留与行程，请在系统弹窗中选择「始终允许」。"
                            },
                            icon = Icons.Filled.MyLocation,
                            color = Accent,
                            buttonText = if (viaSettings) "前往设置" else "继续"
                        ) {
                            if (backgroundDenied) {
                                openAppSettings()
                            } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                                // On Android 11+ this opens the app's location settings page.
                                backgroundLauncher.launch(Manifest.permission.ACCESS_BACKGROUND_LOCATION)
                            } else {
                                step = afterBackground(usesActivityRecognition)
                            }
                        }
                        SecondaryButton("暂不开启") {
                            step = afterBackground(usesActivityRecognition)
                        }
                    }

                    OnboardingStep.ACTIVITY -> {
                        OnboardingStepContent(
                            title = "更精准的足迹判定",
                            description = "结合您的运动状态（步行、骑行等），地方客可以更准确地判断您何时停留或离开，极大节省电量并提高记录准确度。",
                            icon = Icons.AutoMirrored.Filled.DirectionsWalk,
                            color = Orange,
                            buttonText = "继续"
                        ) {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q &&
                                ContextCompat.checkSelfPermission(context, Manifest.permission.ACTIVITY_RECOGNITION) !=
                                PackageManager.PERMISSION_GRANTED
                            ) {
                                activityLauncher.launch(Manifest.permission.ACTIVITY_RECOGNITION)
                            } else {
                                step = OnboardingStep.NOTIFICATIONS
                            }
                        }
                    }

                    OnboardingStep.NOTIFICATIONS -> {
                        OnboardingStepContent(
                            title = "及时回顾每一天",
                            description = "开启通知，我们会在每天结束时为您推送今天的足迹汇总，绝不发送无用垃圾信息。",
                            icon = Icons.Filled.NotificationsActive,
                            color = Red,
                            buttonText = "开启通知"
                        ) {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                                ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) !=
                                PackageManager.PERMISSION_GRANTED
                            ) {
                                notificationLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
                            } else {
                                step = OnboardingStep.AI
                            }
                        }
                        SecondaryButton("暂不开启") { step = OnboardingStep.AI }
                    }

                    OnboardingStep.AI -> {
                        OnboardingStepContent(
                            title = "AI 智能分析",
                            description = "开启 AI 助手为您自动总结地点特色，让足迹更有个性和温度。此功能可随时在设置中关闭。",
                            icon = Icons.Filled.AutoAwesome,
                            color = Purple,
                            buttonText = "开启 AI 智能分析"
                        ) { finish(aiEnabled = true) }
                        SecondaryButton("暂不开启") { finish(aiEnabled = false) }
                        Text(
                            text = "隐私受保护：AI 分析仅针对坐标和时长进行。我们将通过匿名处理进行概括，不涉及个人身份。",
                            fontSize = 11.sp,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            textAlign = TextAlign.Center,
                            modifier = Modifier
                                .padding(top = 20.dp)
                                .padding(horizontal = 20.dp)
                        )
                    }
                }
            }
        }
    }

    if (showLocationSettingsAlert) {
        AlertDialog(
            onDismissRequest = { showLocationSettingsAlert = false },
            title = { Text("定位权限已关闭") },
            text = { Text("地方客无法记录足迹、停留与行程。请在系统设置中允许定位。") },
            confirmButton = {
                TextButton(onClick = {
                    showLocationSettingsAlert = false
                    openAppSettings()
                }) { Text("前往系统设置") }
            },
            dismissButton = {
                TextButton(onClick = { showLocationSettingsAlert = false }) { Text("稍后") }
            }
        )
    }
}

@Composable
private fun OnboardingStepContent(
    title: String,
    description: String,
    icon: ImageVector,
    color: Color,
    buttonText: String,
    onClick: () -> Unit
) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(30.dp)
    ) {
        Icon(icon, contentDescription = null, tint = color, modifier = Modifier.size(100.dp))
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            Text(title, fontSize = 28.sp, fontWeight = FontWeight.Bold, textAlign = TextAlign.Center)
            Text(
                description,
                textAlign = TextAlign.Center,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 16.dp)
            )
        }
        Button(
            onClick = onClick,
            shape = RoundedCornerShape(14.dp),
            colors = ButtonDefaults.buttonColors(containerColor = color.copy(alpha = 0.85f), contentColor = Color.White),
            contentPadding = PaddingValues(vertical = 16.dp),
            modifier = Modifier.widthIn(max = 350.dp).fillMaxWidth()
        ) {
            Text(buttonText, fontWeight = FontWeight.SemiBold, fontSize = 17.sp)
        }
    }
}

@Composable
private fun SecondaryButton(text: String, onClick: () -> Unit) {
    TextButton(onClick = onClick, modifier = Modifier.padding(top = 10.dp)) {
        Text(text, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

// ── Permission helpers ──────────────────────────────────────────────

private fun hasForegroundLocation(context: Context): Boolean =
    ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED ||
        ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED

private fun hasBackgroundLocation(context: Context): Boolean =
    Build.VERSION.SDK_INT < Build.VERSION_CODES.Q ||
        ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_BACKGROUND_LOCATION) == PackageManager.PERMISSION_GRANTED

private fun nextAfterLocation(context: Context, usesActivityRecognition: Boolean): OnboardingStep =
    if (!hasBackgroundLocation(context)) OnboardingStep.BACKGROUND_LOCATION
    else afterBackground(usesActivityRecognition)

private fun afterBackground(usesActivityRecognition: Boolean): OnboardingStep =
    if (usesActivityRecognition) OnboardingStep.ACTIVITY else OnboardingStep.NOTIFICATIONS

/** The motion step is shown only when the app actually declares ACTIVITY_RECOGNITION. */
private fun declaresActivityRecognition(context: Context): Boolean {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return false
    return try {
        val info = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.packageManager.getPackageInfo(
                context.packageName,
                PackageManager.PackageInfoFlags.of(PackageManager.GET_PERMISSIONS.toLong())
            )
        } else {
            @Suppress("DEPRECATION")
            context.packageManager.getPackageInfo(context.packageName, PackageManager.GET_PERMISSIONS)
        }
        info.requestedPermissions?.contains(Manifest.permission.ACTIVITY_RECOGNITION) == true
    } catch (_: Exception) {
        false
    }
}

private fun Activity.shouldShowRequestPermissionRationaleCompat(permission: String): Boolean =
    androidx.core.app.ActivityCompat.shouldShowRequestPermissionRationale(this, permission)

private tailrec fun Context.findActivity(): ComponentActivity? = when (this) {
    is ComponentActivity -> this
    is ContextWrapper -> baseContext.findActivity()
    else -> null
}
