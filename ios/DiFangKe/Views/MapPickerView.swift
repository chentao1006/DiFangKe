import SwiftUI
import MapKit

struct MapPickerView: UIViewRepresentable {
    @Binding var selectedCoord: CLLocationCoordinate2D?
    @Binding var radius: Float
    @Binding var address: String
    let centerTrigger: UUID
    @Binding var shouldSnapToUser: Bool
    let userCoord: CLLocationCoordinate2D?
    var radiusTrigger: UUID = UUID()

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.isZoomEnabled = true
        map.isScrollEnabled = true
        map.isRotateEnabled = false // Keep it simple for better center-pin UX
        map.isPitchEnabled = false

        // 1. Initial Position Setup
        let center = selectedCoord ?? userCoord ?? CLLocationCoordinate2D(latitude: 31.2304, longitude: 121.4737)
        
        // If we have a radius already (Edit Mode), calculate the initial zoom to fit the circle
        if let currentRadius = radius > 0 ? radius : nil {
            let screenWidth = UIScreen.main.bounds.width
            let ratio = screenWidth / 120.0 
            let region = MKCoordinateRegion(center: center, 
                                          latitudinalMeters: Double(currentRadius) * 2 * ratio,
                                          longitudinalMeters: Double(currentRadius) * 2 * ratio)
            map.setRegion(region, animated: false)
        } else {
            map.setRegion(MKCoordinateRegion(center: center,
                                              span: MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005)),
                          animated: false)
        }
        
        // Pre-fetch address
        context.coordinator.updateAddress(for: center)
        
        return map
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        if shouldSnapToUser {
            if let userLoc = mapView.userLocation.location {
                mapView.setCenter(userLoc.coordinate, animated: true)
                let region = MKCoordinateRegion(center: userLoc.coordinate, latitudinalMeters: 600, longitudinalMeters: 600)
                mapView.setRegion(region, animated: true)
            }
            DispatchQueue.main.async { shouldSnapToUser = false }
        } else if let coord = selectedCoord, context.coordinator.lastTrigger != centerTrigger {
            mapView.setCenter(coord, animated: true)
            context.coordinator.lastTrigger = centerTrigger
        }
        
        if context.coordinator.lastRadiusTrigger != radiusTrigger {
            context.coordinator.lastRadiusTrigger = radiusTrigger
            context.coordinator.isUpdatingFromSlider = true
            let center = selectedCoord ?? mapView.centerCoordinate
            let screenCircleDiameter = 120.0
            let mapWidth = Double(mapView.bounds.width)
            guard mapWidth > 0 else { return }
            let spanMeters = Double(radius) * 2.0 * (mapWidth / screenCircleDiameter)
            let region = MKCoordinateRegion(center: center, latitudinalMeters: spanMeters, longitudinalMeters: spanMeters)
            mapView.setRegion(region, animated: false) // Change to false to stop drift
            
            // Immediately sync back to avoid next frame update calculation drift
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                context.coordinator.isUpdatingFromSlider = false
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(selectedCoord: $selectedCoord, radius: $radius, address: $address, radiusTrigger: radiusTrigger)
    }

    class Coordinator: NSObject, MKMapViewDelegate {
        @Binding var selectedCoord: CLLocationCoordinate2D?
        @Binding var radius: Float
        @Binding var address: String
        var lastTrigger: UUID?
        var lastRadiusTrigger: UUID
        var isUpdatingFromSlider = false
        
        private let screenCircleRadius: CGFloat = 60 // 120pt / 2
        private let geocoder = CLGeocoder()
        private var lastSpan: MKCoordinateSpan?

        init(selectedCoord: Binding<CLLocationCoordinate2D?>, radius: Binding<Float>, address: Binding<String>, radiusTrigger: UUID) {
            _selectedCoord = selectedCoord
            _radius = radius
            _address = address
            self.lastRadiusTrigger = radiusTrigger
        }

        func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            lastSpan = mapView.region.span
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            let center = mapView.centerCoordinate
            let currentSpan = mapView.region.span
            
            // 1. Calculate geographical radius based on circle overlay size
            let mapPointsPerMeter = MKMapPointsPerMeterAtLatitude(center.latitude)
            let mapPointsPerScreenPoint = mapView.visibleMapRect.size.width / Double(mapView.bounds.width)
            let actualRadiusInMeters = (Double(screenCircleRadius) * mapPointsPerScreenPoint) / mapPointsPerMeter
            
            // Sync values to bindings
            DispatchQueue.main.async {
                // If not updating from slider, sync map radius back to binding
                if !self.isUpdatingFromSlider {
                    // Update radius if it changed significantly (> 0.5m) to avoid jitter
                    if abs(Double(self.radius) - actualRadiusInMeters) > 0.5 {
                        self.radius = Float(actualRadiusInMeters)
                    }
                }
                
                // Only update coordinate if it actually moved significant distance
                if let oldCoord = self.selectedCoord {
                    let oldLoc = CLLocation(latitude: oldCoord.latitude, longitude: oldCoord.longitude)
                    let newLoc = CLLocation(latitude: center.latitude, longitude: center.longitude)
                    
                    if oldLoc.distance(from: newLoc) > 0.5 {
                        self.selectedCoord = center
                    }
                } else {
                    self.selectedCoord = center
                }
            }
            
            updateAddress(for: center)
            lastSpan = currentSpan
        }
        
        func updateAddress(for coord: CLLocationCoordinate2D) {
            geocoder.reverseGeocodeLocation(CLLocation(latitude: coord.latitude, longitude: coord.longitude)) { [weak self] placemarks, _ in
                if let pm = placemarks?.first {
                    let poiName = pm.areasOfInterest?.first
                    let name = [poiName, pm.name, pm.thoroughfare].compactMap { $0 }.first ?? ""
                    self?.address = (pm.locality ?? "") + name
                }
            }
        }
    }
}
