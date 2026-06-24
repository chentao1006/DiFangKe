import SwiftUI
import MapKit

struct MapPickerView: View {
    @Binding var selectedCoord: CLLocationCoordinate2D?
    @Binding var radius: Float
    @Binding var address: String
    var inferredPlaceName: Binding<String?>? = nil
    let centerTrigger: UUID
    @Binding var shouldSnapToUser: Bool
    let userCoord: CLLocationCoordinate2D?
    var radiusTrigger: UUID = UUID()
    var snapRegionMeters: CLLocationDistance = 600
    var initialRegionMeters: CLLocationDistance? = nil

    var body: some View {
        GeometryReader { proxy in
            _MapPickerView(
                selectedCoord: $selectedCoord,
                radius: $radius,
                address: $address,
                inferredPlaceName: inferredPlaceName,
                centerTrigger: centerTrigger,
                shouldSnapToUser: $shouldSnapToUser,
                userCoord: userCoord,
                radiusTrigger: radiusTrigger,
                snapRegionMeters: snapRegionMeters,
                initialRegionMeters: initialRegionMeters
            )
            .frame(minWidth: 1, minHeight: 1)
        }
    }
}

struct _MapPickerView: UIViewRepresentable {
    @Binding var selectedCoord: CLLocationCoordinate2D?
    @Binding var radius: Float
    @Binding var address: String
    var inferredPlaceName: Binding<String?>?
    let centerTrigger: UUID
    @Binding var shouldSnapToUser: Bool
    let userCoord: CLLocationCoordinate2D?
    var radiusTrigger: UUID = UUID()
    var snapRegionMeters: CLLocationDistance = 600
    var initialRegionMeters: CLLocationDistance? = nil

    func makeUIView(context: Context) -> MKMapView {
        let map = SafeMKMapView(frame: .zero)
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.isZoomEnabled = true
        map.isScrollEnabled = true
        map.isRotateEnabled = false // Keep it simple for better center-pin UX
        map.isPitchEnabled = false

        // 1. Initial Position Setup
        let center = selectedCoord ?? userCoord ?? CLLocationCoordinate2D(latitude: 31.2304, longitude: 121.4737)
        
        if let initialRegionMeters {
            map.setRegion(
                MKCoordinateRegion(
                    center: center,
                    latitudinalMeters: initialRegionMeters,
                    longitudinalMeters: initialRegionMeters
                ),
                animated: false
            )
        // If we have a radius already (Edit Mode), calculate the initial zoom to fit the circle
        } else if let currentRadius = radius > 0 ? radius : nil {
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
        guard let safeMap = mapView as? SafeMKMapView else { return }
        
        // Capture properties needed for update
        let currentSnap = shouldSnapToUser
        let currentSelectedCoord = selectedCoord
        let currentCenterTrigger = centerTrigger
        let currentRadiusTrigger = radiusTrigger
        let currentRadius = radius
        
        let updateBlock = { [weak coordinator = context.coordinator, weak safeMap] in
            guard let safeMap, let coordinator else { return }
            
            if currentSnap {
                if let userLoc = safeMap.userLocation.location {
                    safeMap.setCenter(userLoc.coordinate, animated: true)
                    let region = MKCoordinateRegion(center: userLoc.coordinate, latitudinalMeters: snapRegionMeters, longitudinalMeters: snapRegionMeters)
                    safeMap.setRegion(region, animated: true)
                }
                DispatchQueue.main.async { self.shouldSnapToUser = false }
            } else if let coord = currentSelectedCoord, coordinator.lastTrigger != currentCenterTrigger {
                safeMap.setCenter(coord, animated: true)
                coordinator.lastTrigger = currentCenterTrigger
            }
            
            if coordinator.lastRadiusTrigger != currentRadiusTrigger {
                coordinator.lastRadiusTrigger = currentRadiusTrigger
                coordinator.isUpdatingFromSlider = true
                let center = currentSelectedCoord ?? safeMap.centerCoordinate
                let screenCircleDiameter = 120.0
                let mapWidth = Double(safeMap.bounds.width)
                guard mapWidth > 0 else { return }
                let spanMeters = Double(currentRadius) * 2.0 * (mapWidth / screenCircleDiameter)
                let region = MKCoordinateRegion(center: center, latitudinalMeters: spanMeters, longitudinalMeters: spanMeters)
                safeMap.setRegion(region, animated: false) // Change to false to stop drift
                
                // Immediately sync back to avoid next frame update calculation drift
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    coordinator.isUpdatingFromSlider = false
                }
            }
        }
        
        safeMap.onLayoutSubviews = { [weak safeMap] in
            guard let safeMap else { return }
            if safeMap.bounds.width > 10 && safeMap.bounds.height > 10 {
                updateBlock()
            }
        }
        
        if safeMap.bounds.width > 10 && safeMap.bounds.height > 10 {
            updateBlock()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(selectedCoord: $selectedCoord, radius: $radius, address: $address, inferredPlaceName: inferredPlaceName, radiusTrigger: radiusTrigger)
    }

    class Coordinator: NSObject, MKMapViewDelegate {
        @Binding var selectedCoord: CLLocationCoordinate2D?
        @Binding var radius: Float
        @Binding var address: String
        var inferredPlaceName: Binding<String?>?
        var lastTrigger: UUID?
        var lastRadiusTrigger: UUID
        var isUpdatingFromSlider = false
        
        private let screenCircleRadius: CGFloat = 60 // 120pt / 2
        private let geocoder = CLGeocoder()
        private var lastSpan: MKCoordinateSpan?

        init(selectedCoord: Binding<CLLocationCoordinate2D?>, radius: Binding<Float>, address: Binding<String>, inferredPlaceName: Binding<String?>?, radiusTrigger: UUID) {
            _selectedCoord = selectedCoord
            _radius = radius
            _address = address
            self.inferredPlaceName = inferredPlaceName
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
                    self?.inferredPlaceName?.wrappedValue = poiName ?? pm.name ?? name
                }
            }
        }
    }
}
