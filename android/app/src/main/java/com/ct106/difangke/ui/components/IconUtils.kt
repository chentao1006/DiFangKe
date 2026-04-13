package com.ct106.difangke.ui.components

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.*
import androidx.compose.material.icons.filled.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.vector.ImageVector

@Composable
fun getIconForName(name: String?): ImageVector {
    return when(name) {
        "home" -> Icons.Default.Home
        "work" -> Icons.Default.Work
        "restaurant" -> Icons.Default.Restaurant
        "shopping_bag" -> Icons.Default.ShoppingBag
        "directions_run" -> Icons.Default.DirectionsRun
        "directions_walk" -> Icons.Default.DirectionsWalk
        "directions_bike" -> Icons.Default.DirectionsBike
        "directions_car" -> Icons.Default.DirectionsCar
        "flight", "airplane_ticket" -> Icons.Default.Flight
        "train" -> Icons.Default.Train
        "tram" -> Icons.Default.Tram
        "directions_boat" -> Icons.Default.DirectionsBoat
        "sports_esports" -> Icons.Default.SportsEsports
        "menu_book" -> Icons.Default.MenuBook
        "local_hospital", "medical_services" -> Icons.Default.MedicalServices
        "bedtime", "nights_stay" -> Icons.Default.Bedtime
        "theater_comedy" -> Icons.Default.TheaterComedy
        "fitness_center" -> Icons.Default.FitnessCenter
        "self_improvement" -> Icons.Default.SelfImprovement
        "local_cafe", "coffee" -> Icons.Default.LocalCafe
        "shopping_cart" -> Icons.Default.ShoppingCart
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
        "car" -> Icons.Default.DirectionsCar
        "walk" -> Icons.Default.DirectionsWalk
        "run" -> Icons.Default.DirectionsRun
        "cycle" -> Icons.Default.DirectionsBike
        "eat" -> Icons.Default.Restaurant
        "shopping" -> Icons.Default.ShoppingCart
        "sightseeing" -> Icons.Default.PhotoCamera
        "plane" -> Icons.Default.Flight
        else -> Icons.AutoMirrored.Filled.Help
    }
}
