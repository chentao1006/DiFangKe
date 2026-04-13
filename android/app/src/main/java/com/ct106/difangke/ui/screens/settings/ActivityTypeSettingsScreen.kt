package com.ct106.difangke.ui.screens.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.lifecycle.viewmodel.compose.viewModel
import com.ct106.difangke.data.db.entity.ActivityTypeEntity

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ActivityTypeSettingsScreen(
    onBack: () -> Unit,
    viewModel: ActivityTypeViewModel = viewModel()
) {
    val activities by viewModel.activities.collectAsState()
    var editingActivity by remember { mutableStateOf<ActivityTypeEntity?>(null) }
    var showingAddDialog by remember { mutableStateOf(false) }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("管理活动类型", fontWeight = FontWeight.Bold) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.Default.ArrowBack, contentDescription = "返回")
                    }
                },
                actions = {
                    IconButton(onClick = { showingAddDialog = true }) {
                        Icon(Icons.Default.Add, contentDescription = "添加")
                    }
                }
            )
        }
    ) { padding ->
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding),
            contentPadding = PaddingValues(bottom = 32.dp)
        ) {
            item {
                Text(
                    "这些类型将出现在足迹详情的选择菜单中。",
                    style = MaterialTheme.typography.bodySmall,
                    color = Color.Gray,
                    modifier = Modifier.padding(16.dp)
                )
            }
            
            items(activities.sortedBy { it.sortOrder }) { activity ->
                ActivityTypeRow(
                    activity = activity,
                    onClick = { editingActivity = activity },
                    onDelete = { viewModel.deleteActivity(activity) }
                )
                Divider(
                    modifier = Modifier.padding(horizontal = 16.dp),
                    thickness = 0.5.dp,
                    color = MaterialTheme.colorScheme.outlineVariant
                )
            }
        }
    }

    if (showingAddDialog) {
        ActivityTypeEditorDialog(
            activity = null,
            onDismiss = { showingAddDialog = false },
            onSave = { name, icon, color ->
                viewModel.saveActivity(null, name, icon, color)
                showingAddDialog = false
            }
        )
    }

    if (editingActivity != null) {
        ActivityTypeEditorDialog(
            activity = editingActivity,
            onDismiss = { editingActivity = null },
            onSave = { name, icon, color ->
                viewModel.saveActivity(editingActivity!!.id, name, icon, color)
                editingActivity = null
            }
        )
    }
}

@Composable
fun ActivityTypeRow(
    activity: ActivityTypeEntity,
    onClick: () -> Unit,
    onDelete: () -> Unit
) {
    ListItem(
        modifier = Modifier.clickable(onClick = onClick),
        headlineContent = { Text(activity.name) },
        leadingContent = {
            val color = try { Color(android.graphics.Color.parseColor(activity.colorHex)) } catch (e: Exception) { MaterialTheme.colorScheme.primary }
            Box(
                modifier = Modifier
                    .size(40.dp)
                    .clip(CircleShape)
                    .background(color.copy(alpha = 0.15f)),
                contentAlignment = Alignment.Center
            ) {
                Icon(
                    imageVector = getIconForName(activity.icon),
                    contentDescription = null,
                    tint = color,
                    modifier = Modifier.size(20.dp)
                )
            }
        },
        trailingContent = {
            IconButton(onClick = onDelete) {
                Icon(Icons.Default.Delete, contentDescription = "删除", tint = MaterialTheme.colorScheme.error.copy(alpha = 0.3f), modifier = Modifier.size(20.dp))
            }
        }
    )
}

// 辅助函数把图标名称转为 ImageVector
@Composable
fun getIconForName(name: String): androidx.compose.ui.graphics.vector.ImageVector {
    return when(name) {
        "home" -> Icons.Default.Home
        "work" -> Icons.Default.Work
        "restaurant" -> Icons.Default.Restaurant
        "shopping_bag" -> Icons.Default.ShoppingBag
        "directions_run" -> Icons.Default.DirectionsRun
        "directions_walk" -> Icons.Default.DirectionsWalk
        "directions_bike" -> Icons.Default.DirectionsBike
        "directions_car" -> Icons.Default.DirectionsCar
        "flight" -> Icons.Default.Flight
        "train" -> Icons.Default.Train
        "tram" -> Icons.Default.Tram
        "directions_boat" -> Icons.Default.DirectionsBoat
        "sports_esports" -> Icons.Default.SportsEsports
        "menu_book" -> Icons.Default.MenuBook
        "local_hospital" -> Icons.Default.LocalHospital
        "bedtime" -> Icons.Default.Bedtime
        "theater_comedy" -> Icons.Default.TheaterComedy
        "fitness_center" -> Icons.Default.FitnessCenter
        "self_improvement" -> Icons.Default.SelfImprovement
        "coffee" -> Icons.Default.LocalCafe
        "restaurant" -> Icons.Default.Restaurant
        "shopping_cart" -> Icons.Default.ShoppingCart
        "shopping_bag" -> Icons.Default.ShoppingBag
        "movie" -> Icons.Default.Movie
        "brush" -> Icons.Default.Brush
        "palette" -> Icons.Default.Palette
        "camera_alt" -> Icons.Default.CameraAlt
        "music_note" -> Icons.Default.MusicNote
        "school" -> Icons.Default.School
        "work" -> Icons.Default.Work
        "laptop" -> Icons.Default.LaptopMac
        "calculate" -> Icons.Default.Calculate
        "bank" -> Icons.Default.HomeWork
        "park" -> Icons.Default.Park
        "stadium" -> Icons.Default.Stadium
        "hiking" -> Icons.Default.Hiking
        "pool" -> Icons.Default.Pool
        "pets" -> Icons.Default.Pets
        "volunteer_activism" -> Icons.Default.VolunteerActivism
        else -> Icons.Default.Label
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ActivityTypeEditorDialog(
    activity: ActivityTypeEntity?,
    onDismiss: () -> Unit,
    onSave: (String, String, String) -> Unit
) {
    var name by remember { mutableStateOf(activity?.name ?: "") }
    var colorHex by remember { mutableStateOf(activity?.colorHex ?: "#007AFF") }
    var iconName by remember { mutableStateOf(activity?.icon ?: "label") }
    
    val colors = listOf(
        "#007AFF", "#FF9500", "#34C759", "#FF2D55", "#5856D6", "#AF52DE", 
        "#FF3B30", "#A2845E", "#00A0AC", "#32ADE6", "#64D2FF", "#BBD6D9",
        "#FFCC00", "#FF453A", "#30D158", "#BF5AF2", "#FF9F0A", "#64D2FF",
        "#5E5CE6", "#0A84FF", "#FF375F", "#DBA06D", "#98989D", "#636366"
    )

    val icons = listOf(
        "home", "work", "laptop", "restaurant", "coffee", "shopping_cart", "shopping_bag",
        "directions_run", "directions_walk", "directions_bike", "directions_car", "flight", "train",
        "sports_esports", "menu_book", "movie", "camera_alt", "music_note", "brush", "palette",
        "local_hospital", "bedtime", "theater_comedy", "fitness_center", "self_improvement",
        "school", "calculate", "bank", "park", "stadium", "hiking", "pool", "pets", "label"
    )

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(if (activity == null) "新建活动类型" else "编辑活动类型", fontWeight = FontWeight.Bold) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(20.dp), modifier = Modifier.fillMaxWidth()) {
                OutlinedTextField(
                    value = name,
                    onValueChange = { name = it },
                    label = { Text("名称") },
                    modifier = Modifier.fillMaxWidth(),
                    shape = RoundedCornerShape(12.dp)
                )
                
                Column {
                    Text("选择图标", style = MaterialTheme.typography.labelMedium, color = Color.Gray)
                    Spacer(Modifier.height(8.dp))
                    LazyVerticalGrid(
                        columns = GridCells.Fixed(5),
                        modifier = Modifier.height(150.dp)
                    ) {
                        items(icons) { ic ->
                            val isSelected = iconName == ic
                            Box(
                                modifier = Modifier
                                    .padding(4.dp)
                                    .size(36.dp)
                                    .clip(CircleShape)
                                    .background(if (isSelected) MaterialTheme.colorScheme.primary.copy(alpha=0.1f) else Color.Transparent)
                                    .clickable { iconName = ic },
                                contentAlignment = Alignment.Center
                            ) {
                                Icon(
                                    getIconForName(ic), 
                                    null, 
                                    modifier = Modifier.size(20.dp),
                                    tint = if (isSelected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                        }
                    }
                }

                Column {
                    Text("选择颜色", style = MaterialTheme.typography.labelMedium, color = Color.Gray)
                    Spacer(Modifier.height(8.dp))
                    LazyVerticalGrid(
                        columns = GridCells.Fixed(6),
                        modifier = Modifier.height(140.dp),
                        contentPadding = PaddingValues(4.dp),
                        verticalArrangement = Arrangement.spacedBy(12.dp),
                        horizontalArrangement = Arrangement.spacedBy(12.dp)
                    ) {
                        items(colors) { hex ->
                            ColorCircle(hex = hex, isSelected = colorHex == hex) { colorHex = hex }
                        }
                    }
                }
            }
        },
        confirmButton = {
            Button(
                onClick = { if (name.isNotBlank()) onSave(name, iconName, colorHex) },
                enabled = name.isNotBlank(),
                shape = RoundedCornerShape(12.dp)
            ) {
                Text("保存")
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text("取消")
            }
        }
    )
}

@Composable
fun ColorCircle(hex: String, isSelected: Boolean, onClick: () -> Unit) {
    val color = try { Color(android.graphics.Color.parseColor(hex)) } catch (e: Exception) { Color.Gray }
    Box(
        modifier = Modifier
            .size(36.dp)
            .aspectRatio(1f)
            .clip(CircleShape)
            .background(color)
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center
    ) {
        if (isSelected) {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(Color.Black.copy(alpha = 0.2f))
            )
            Icon(Icons.Default.Check, contentDescription = null, tint = Color.White, modifier = Modifier.size(20.dp))
        }
    }
}
