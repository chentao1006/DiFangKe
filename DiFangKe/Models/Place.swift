import Foundation
import SwiftData
import CoreLocation

@Model
final class Place {
    var placeID: UUID = UUID()
    var name: String = ""
    var latitude: Double = 0.0
    var longitude: Double = 0.0
    var radius: Float = 50.0
    var address: String?
    var isIgnored: Bool = false
    var isUserDefined: Bool = true
    
    var coordinate: CLLocationCoordinate2D {
        get { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
        set {
            self.latitude = newValue.latitude
            self.longitude = newValue.longitude
        }
    }
    
    init(placeID: UUID = UUID(), 
         name: String, 
         coordinate: CLLocationCoordinate2D, 
         radius: Float = 50.0,
         address: String? = nil,
         isUserDefined: Bool = true) {
        self.placeID = placeID
        self.name = name
        self.latitude = coordinate.latitude
        self.longitude = coordinate.longitude
        self.radius = radius
        self.address = address
        self.isUserDefined = isUserDefined
    }
}

@Model
final class PlaceTag {
    var name: String = ""
    
    init(name: String = "") {
        self.name = name
    }
}
