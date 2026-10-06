package com.ct106.difangke.ui.components

import android.location.Location
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Cancel
import androidx.compose.material.icons.filled.LocationOn
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Star
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.ct106.difangke.data.db.entity.PlaceEntity
import com.ct106.difangke.service.GeocodeService
import kotlinx.coroutines.delay
import java.util.Locale

private fun distanceMeters(lat1: Double, lon1: Double, lat2: Double, lon2: Double): Float =
    FloatArray(1).also { Location.distanceBetween(lat1, lon1, lat2, lon2, it) }[0]

/** iOS LocationSearchSheet.distanceLabel: "%.0f米" / "%.1f公里". */
fun placeDistanceLabel(meters: Float): String =
    if (meters < 1000) String.format(Locale.CHINA, "%.0f米", meters) else String.format(Locale.CHINA, "%.1f公里", meters / 1000f)

/**
 * Shared place picker for saved footprints and the live stay (iOS SuggestionsMenu +
 * LocationSearchSheet): first row "搜索其他地点..." opens a 500 ms-debounced search whose
 * results are sorted by distance with distance labels; below it, nearby suggestions.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun NearbyPlacePickerSheet(
    latitude: Double,
    longitude: Double,
    savedPlaces: List<PlaceEntity>,
    onDismiss: () -> Unit,
    onSelect: (GeocodeService.SearchResult) -> Unit
) {
    var searchMode by remember { mutableStateOf(false) }
    var query by remember { mutableStateOf("") }
    var nearby by remember { mutableStateOf<List<GeocodeService.SearchResult>>(emptyList()) }
    var nearbyLoading by remember { mutableStateOf(true) }
    var searchResults by remember { mutableStateOf<List<GeocodeService.SearchResult>>(emptyList()) }
    var searching by remember { mutableStateOf(false) }
    var refresh by remember { mutableIntStateOf(0) }

    LaunchedEffect(latitude, longitude, refresh) {
        nearbyLoading = true
        val remote = runCatching { GeocodeService.shared.getNearbyPOIs(latitude, longitude) }.getOrDefault(emptyList())
        val saved = savedPlaces.filter { !it.isIgnored && distanceMeters(latitude, longitude, it.latitude, it.longitude) <= 500f }
            .sortedBy { distanceMeters(latitude, longitude, it.latitude, it.longitude) }
            .map { GeocodeService.SearchResult(it.name, it.address ?: "已保存地点", it.latitude, it.longitude, true, it.placeID) }
        nearby = (saved + remote).distinctBy { it.name }
        nearbyLoading = false
    }

    LaunchedEffect(query, searchMode) {
        val q = query.trim()
        if (!searchMode || q.isEmpty()) {
            searchResults = emptyList(); searching = false; return@LaunchedEffect
        }
        delay(500)
        searching = true
        val results = runCatching { GeocodeService.shared.searchNearby(q, latitude, longitude) }.getOrDefault(emptyList())
        searchResults = results.sortedWith(compareBy<GeocodeService.SearchResult> {
            (distanceMeters(latitude, longitude, it.latitude, it.longitude) / 1f).toInt()
        }.thenBy { it.name })
        searching = false
    }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = searchMode)) {
        Column(Modifier.fillMaxWidth().padding(bottom = 28.dp)) {
            if (searchMode) {
                val focus = remember { FocusRequester() }
                LaunchedEffect(Unit) { delay(300); runCatching { focus.requestFocus() } }
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(horizontal = 8.dp)) {
                    IconButton(onClick = { searchMode = false; query = "" }) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "返回") }
                    Text("搜索其他地点", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
                }
                OutlinedTextField(
                    query, { query = it },
                    placeholder = { Text("搜索地点/地址") },
                    singleLine = true,
                    leadingIcon = { Icon(Icons.Default.Search, null) },
                    trailingIcon = { if (query.isNotEmpty()) IconButton(onClick = { query = "" }) { Icon(Icons.Default.Cancel, null) } },
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp).focusRequester(focus)
                )
                when {
                    searching -> Box(Modifier.fillMaxWidth().padding(36.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
                    else -> LazyColumn(Modifier.heightIn(max = 480.dp)) {
                        items(searchResults, key = { "${it.name}_${it.latitude}_${it.longitude}" }) { poi ->
                            ListItem(
                                headlineContent = { Text(poi.name) },
                                supportingContent = { Text(poi.address, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                                trailingContent = {
                                    Text(placeDistanceLabel(distanceMeters(latitude, longitude, poi.latitude, poi.longitude)), fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                },
                                modifier = Modifier.clickable { onSelect(poi) }
                            )
                        }
                    }
                }
            } else {
                Text("选择地点", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold, modifier = Modifier.padding(horizontal = 24.dp, vertical = 12.dp))
                ListItem(
                    headlineContent = { Text("搜索其他地点...", color = MaterialTheme.colorScheme.primary) },
                    leadingContent = { Icon(Icons.Default.Search, null, tint = MaterialTheme.colorScheme.primary) },
                    modifier = Modifier.clickable { searchMode = true }
                )
                HorizontalDivider()
                when {
                    nearbyLoading -> ListItem(headlineContent = { Text("正在寻找附近地点...", color = MaterialTheme.colorScheme.onSurfaceVariant) })
                    nearby.isEmpty() -> Column(Modifier.fillMaxWidth().padding(16.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                        Text("未发现附近建议", color = MaterialTheme.colorScheme.onSurfaceVariant)
                        TextButton(onClick = { refresh++ }) { Text("重新加载") }
                    }
                    else -> LazyColumn(Modifier.heightIn(max = 420.dp)) {
                        items(nearby, key = { "${it.name}_${it.latitude}_${it.longitude}" }) { poi ->
                            ListItem(
                                headlineContent = { Text(poi.name, fontWeight = FontWeight.SemiBold) },
                                supportingContent = { Text(poi.address, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                                leadingContent = {
                                    if (poi.isSavedPlace) Icon(Icons.Default.Star, null, tint = Color(0xFFFF9500))
                                    else Icon(Icons.Default.LocationOn, null)
                                },
                                trailingContent = {
                                    Text(placeDistanceLabel(distanceMeters(latitude, longitude, poi.latitude, poi.longitude)), fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                },
                                modifier = Modifier.clickable { onSelect(poi) }
                            )
                        }
                    }
                }
            }
        }
    }
}
