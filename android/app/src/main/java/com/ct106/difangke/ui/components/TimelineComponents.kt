package com.ct106.difangke.ui.components

import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Card
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

@Composable
fun FootprintCard(title: String, subtitle: String) {
    Card(modifier = Modifier.padding(8.dp)) {
        Text(text = title, modifier = Modifier.padding(16.dp))
        Text(text = subtitle, modifier = Modifier.padding(start = 16.dp, bottom = 16.dp))
    }
}
