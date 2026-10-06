package com.ct106.difangke.ui.components

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.*
import androidx.compose.material.icons.filled.*
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.Color

/**
 * Maps iOS SF Symbol names (synced/backed-up activity types) to Material icons.
 * Returns null for unknown names.
 */
fun sfSymbolToMaterialIcon(name: String?): ImageVector? = when (name) {
    "house.fill" -> Icons.Default.Home
    "briefcase.fill" -> Icons.Default.Work
    "fork.knife" -> Icons.Default.Restaurant
    "cart.fill" -> Icons.Default.ShoppingCart
    "bag.fill" -> Icons.Default.ShoppingBag
    "figure.run" -> Icons.AutoMirrored.Filled.DirectionsRun
    "figure.walk" -> Icons.AutoMirrored.Filled.DirectionsWalk
    "figure.outdoor.cycle" -> Icons.AutoMirrored.Filled.DirectionsBike
    "figure.hiking", "figure.climbing" -> Icons.Default.Hiking
    "figure.pool.swim" -> Icons.Default.Pool
    "figure.yoga" -> Icons.Default.SelfImprovement
    "figure.dance" -> Icons.Default.Nightlife
    "figure.skiing.downhill" -> Icons.Default.DownhillSkiing
    "figure.surfing" -> Icons.Default.Surfing
    "figure.skateboarding" -> Icons.Default.Skateboarding
    "figure.soccer" -> Icons.Default.SportsSoccer
    "figure.basketball" -> Icons.Default.SportsBasketball
    "figure.tennis", "figure.badminton" -> Icons.Default.SportsTennis
    "figure.table.tennis" -> Icons.Default.SportsTennis
    "figure.golf" -> Icons.Default.SportsGolf
    "figure.bowling" -> Icons.Default.SportsScore
    "figure.fishing" -> Icons.Default.Phishing
    "figure.strengthtraining.traditional" -> Icons.Default.FitnessCenter
    "figure.and.child.holdinghands" -> Icons.Default.FamilyRestroom
    "airplane" -> Icons.Default.Flight
    "cross.fill" -> Icons.Default.MedicalServices
    "pills.fill" -> Icons.Default.Medication
    "facemask.fill" -> Icons.Default.Masks
    "bed.double.fill" -> Icons.Default.Bedtime
    "moon.stars.fill" -> Icons.Default.NightsStay
    "tram.fill" -> Icons.Default.Tram
    "bus.fill" -> Icons.Default.DirectionsBus
    "car.fill" -> Icons.Default.DirectionsCar
    "ferry.fill" -> Icons.Default.DirectionsBoat
    "fuelpump.fill" -> Icons.Default.LocalGasStation
    "cup.and.saucer.fill" -> Icons.Default.LocalCafe
    "wineglass.fill" -> Icons.Default.WineBar
    "birthday.cake.fill" -> Icons.Default.Cake
    "party.popper.fill" -> Icons.Default.Celebration
    "gift.fill" -> Icons.Default.CardGiftcard
    "book.fill" -> Icons.AutoMirrored.Filled.MenuBook
    "graduationcap.fill" -> Icons.Default.School
    "brain.head.profile", "lightbulb.fill" -> Icons.Default.Lightbulb
    "gamecontroller.fill", "puzzlepiece.fill" -> Icons.Default.SportsEsports
    "theatermasks.fill" -> Icons.Default.TheaterComedy
    "play.rectangle.fill" -> Icons.Default.Movie
    "tv.fill" -> Icons.Default.Tv
    "music.note" -> Icons.Default.MusicNote
    "mic.fill" -> Icons.Default.Mic
    "paintpalette.fill" -> Icons.Default.Palette
    "camera.fill", "camera.aperture" -> Icons.Default.CameraAlt
    "heart.fill" -> Icons.Default.Favorite
    "star.fill" -> Icons.Default.Star
    "person.fill" -> Icons.Default.Person
    "person.2.fill", "person.3.fill" -> Icons.Default.Group
    "face.smiling" -> Icons.Default.SentimentSatisfied
    "pawprint.fill" -> Icons.Default.Pets
    "leaf.fill" -> Icons.Default.Park
    "mountain.2.fill" -> Icons.Default.Landscape
    "sun.max.fill" -> Icons.Default.WbSunny
    "cloud.fill" -> Icons.Default.Cloud
    "umbrella.fill" -> Icons.Default.BeachAccess
    "drop.fill" -> Icons.Default.WaterDrop
    "flame.fill" -> Icons.Default.LocalFireDepartment
    "bolt.fill" -> Icons.Default.Bolt
    "map.fill" -> Icons.Default.Map
    "mappin.and.ellipse" -> Icons.Default.Place
    "tag.fill" -> Icons.Default.LocalOffer
    "bell.fill" -> Icons.Default.Notifications
    "envelope.fill" -> Icons.Default.Email
    "phone.fill" -> Icons.Default.Phone
    "printer.fill" -> Icons.Default.Print
    "hammer.fill" -> Icons.Default.Construction
    "wrench.adjustable.fill" -> Icons.Default.Build
    "tshirt.fill" -> Icons.Default.Checkroom
    "comb.fill" -> Icons.Default.ContentCut
    "shower.fill" -> Icons.Default.Shower
    "toilet.fill" -> Icons.Default.Wc
    "sofa.fill" -> Icons.Default.Weekend
    "lamp.floor.fill" -> Icons.Default.Light
    "circle.fill" -> Icons.Default.Circle
    "questionmark.circle.dashed" -> Icons.AutoMirrored.Filled.HelpOutline
    else -> null
}

fun getIconForName(name: String?): ImageVector {
    sfSymbolToMaterialIcon(name)?.let { return it }
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
