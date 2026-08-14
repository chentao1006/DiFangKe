package com.ct106.difangke.ui.components

import android.location.Location
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Clear
import androidx.compose.material.icons.filled.LocationOn
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.ct106.difangke.data.db.entity.PlaceEntity
import com.ct106.difangke.service.GeocodeService

/** Shared nearby-place picker for both saved footprints and the live stay. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun NearbyPlacePickerSheet(
    latitude: Double,
    longitude: Double,
    savedPlaces: List<PlaceEntity>,
    onDismiss: () -> Unit,
    onSelect: (GeocodeService.SearchResult) -> Unit
) {
    var query by remember { mutableStateOf("") }
    var results by remember { mutableStateOf<List<GeocodeService.SearchResult>>(emptyList()) }
    var loading by remember { mutableStateOf(true) }
    var refresh by remember { mutableIntStateOf(0) }
    LaunchedEffect(latitude, longitude, savedPlaces, query, refresh) {
        loading = true
        val remote = runCatching {
            if (query.isBlank()) GeocodeService.shared.getNearbyPOIs(latitude, longitude)
            else GeocodeService.shared.searchNearby(query, latitude, longitude)
        }.getOrDefault(emptyList())
        val saved = if (query.isBlank()) savedPlaces.filter { place ->
            !place.isIgnored && FloatArray(1).also { Location.distanceBetween(latitude, longitude, place.latitude, place.longitude, it) }[0] <= 500f
        }.map { place ->
            GeocodeService.SearchResult(place.name, place.address ?: "已保存地点", place.latitude, place.longitude, true, place.placeID)
        } else emptyList()
        results = (saved + remote).distinctBy { it.name }
        loading = false
    }
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(Modifier.fillMaxWidth().padding(bottom = 28.dp)) {
            Text("选择附近地点", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold, modifier = Modifier.padding(horizontal = 24.dp, vertical = 12.dp))
            OutlinedTextField(query, { query = it }, placeholder = { Text("搜索地点关键词...") }, singleLine = true,
                leadingIcon = { Icon(Icons.Default.Search, null) }, trailingIcon = { if (query.isNotEmpty()) IconButton(onClick = { query = "" }) { Icon(Icons.Default.Clear, null) } },
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp))
            when {
                loading -> Box(Modifier.fillMaxWidth().padding(36.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
                results.isEmpty() -> Column(Modifier.fillMaxWidth().padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally) { Text("未发现周边地点"); TextButton(onClick = { refresh++ }) { Text("重新加载") } }
                else -> LazyColumn(Modifier.heightIn(max = 420.dp)) { items(results, key = { "${it.name}_${it.latitude}_${it.longitude}" }) { poi ->
                    ListItem(headlineContent = { Text(poi.name, fontWeight = FontWeight.SemiBold) }, supportingContent = { Text(poi.address, maxLines = 1, overflow = TextOverflow.Ellipsis) }, leadingContent = { Icon(Icons.Default.LocationOn, null) }, modifier = Modifier.clickable { onSelect(poi) })
                } }
            }
        }
    }
}
