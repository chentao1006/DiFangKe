package com.ct106.difangke.ui.components

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.*
import androidx.compose.material.icons.filled.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.Color

@Composable
fun getIconForName(name: String?): ImageVector {
    return when(name?.lowercase()) {
        "home" -> Icons.Default.Home
        "work" -> Icons.Default.Work
        "restaurant", "eat" -> Icons.Default.Restaurant
        "shopping_bag", "shopping", "shopping_cart" -> Icons.Default.ShoppingCart
        "directions_run", "run" -> Icons.AutoMirrored.Filled.DirectionsRun
        "directions_walk", "walk" -> Icons.AutoMirrored.Filled.DirectionsWalk
        "directions_bike", "cycle" -> Icons.AutoMirrored.Filled.DirectionsBike
        "directions_car", "car" -> Icons.Default.DirectionsCar
        "directions_bus" -> Icons.Default.DirectionsBus
        "place" -> Icons.Default.Place
        "flight", "airplane_ticket", "plane" -> Icons.Default.Flight
        "train" -> Icons.Default.Train
        "tram" -> Icons.Default.Tram
        "directions_boat" -> Icons.Default.DirectionsBoat
        "sports_esports" -> Icons.Default.SportsEsports
        "menu_book" -> Icons.AutoMirrored.Filled.MenuBook
        "local_hospital", "medical_services" -> Icons.Default.MedicalServices
        "bedtime", "nights_stay" -> Icons.Default.Bedtime
        "theater_comedy" -> Icons.Default.TheaterComedy
        "fitness_center" -> Icons.Default.FitnessCenter
        "self_improvement" -> Icons.Default.SelfImprovement
        "local_cafe", "coffee" -> Icons.Default.LocalCafe
        "movie" -> Icons.Default.Movie
        "brush" -> Icons.Default.Brush
        "palette" -> Icons.Default.Palette
        "camera_alt" -> Icons.Default.CameraAlt
        "music_note" -> Icons.Default.MusicNote
        "school" -> Icons.Default.School
        "laptop", "laptop_mac" -> Icons.Default.LaptopMac
        "calculate" -> Icons.Default.Calculate
        "bank", "home_work" -> Icons.Default.HomeWork
        "park" -> Icons.Default.Park
        "stadium" -> Icons.Default.Stadium
        "hiking" -> Icons.Default.Hiking
        "pool" -> Icons.Default.Pool
        "pets" -> Icons.Default.Pets
        "volunteer_activism" -> Icons.Default.VolunteerActivism
        "local_bar" -> Icons.Default.LocalBar
        "local_gas_station" -> Icons.Default.LocalGasStation
        "local_parking" -> Icons.Default.LocalParking
        "local_shipping" -> Icons.Default.LocalShipping
        "landscape" -> Icons.Default.Landscape
        "beach_access" -> Icons.Default.BeachAccess
        "celebration" -> Icons.Default.Celebration
        "cake" -> Icons.Default.Cake
        "fastfood" -> Icons.Default.Fastfood
        "church" -> Icons.Default.Church
        "temple_buddhist" -> Icons.Default.TempleBuddhist
        "museum" -> Icons.Default.Museum
        "attractions" -> Icons.Default.Attractions
        "castle" -> Icons.Default.Castle
        "stroller" -> Icons.Default.Stroller
        "child_care" -> Icons.Default.ChildCare
        "family_restroom" -> Icons.Default.FamilyRestroom
        "wc" -> Icons.Default.Wc
        "smoke_free" -> Icons.Default.SmokeFree
        "smoking_rooms" -> Icons.Default.SmokingRooms
        "apartment" -> Icons.Default.Apartment
        "cottage" -> Icons.Default.Cottage
        "factory" -> Icons.Default.Factory
        "sailing" -> Icons.Default.Sailing
        "kayaking" -> Icons.Default.Kayaking
        "downhill_skiing" -> Icons.Default.DownhillSkiing
        "snowboarding" -> Icons.Default.Snowboarding
        "surfing" -> Icons.Default.Surfing
        "piano" -> Icons.Default.Piano
        "emoji_events" -> Icons.Default.EmojiEvents
        "sightseeing" -> Icons.Default.PhotoCamera
        else -> Icons.Default.Place
    }
}

fun getIconColorForName(name: String?): Color {
    return when(name?.lowercase()) {
        "home" -> Color(0xFF4CAF50)
        "work" -> Color(0xFF2196F3)
        "restaurant", "eat" -> Color(0xFFFF9800)
        "shopping_bag", "shopping", "shopping_cart" -> Color(0xFFE91E63)
        "directions_run", "run", "fitness_center" -> Color(0xFF4CAF50)
        "local_cafe", "coffee" -> Color(0xFF795548)
        "park", "hiking", "landscape" -> Color(0xFF4CAF50)
        "plane", "flight" -> Color(0xFF2196F3)
        "train", "subway" -> Color(0xFF3F51B5)
        else -> Color(0xFF9E9E9E)
    }
}
