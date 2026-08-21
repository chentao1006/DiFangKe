import SwiftUI
import MapKit
import Foundation

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
        
        // Pre-fetch address if we don't have one
        if address.isEmpty || address == "正在解析位置..." {
            context.coordinator.updateAddress(for: center)
        }
        
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
        private var geocodeRequestID = UUID()

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
            
            var didMoveSignificantly = false
            if let oldCoord = self.selectedCoord {
                let oldLoc = CLLocation(latitude: oldCoord.latitude, longitude: oldCoord.longitude)
                let newLoc = CLLocation(latitude: center.latitude, longitude: center.longitude)
                
                if oldLoc.distance(from: newLoc) > 10.0 {
                    didMoveSignificantly = true
                }
            } else {
                didMoveSignificantly = true
            }
            
            // Sync values to bindings
            DispatchQueue.main.async {
                // If not updating from slider, sync map radius back to binding
                if !self.isUpdatingFromSlider {
                    // Update radius if it changed significantly (> 0.5m) to avoid jitter
                    if abs(Double(self.radius) - actualRadiusInMeters) > 0.5 {
                        self.radius = Float(actualRadiusInMeters)
                    }
                }
                
                if didMoveSignificantly {
                    self.selectedCoord = center
                }
            }
            
            if didMoveSignificantly {
                updateAddress(for: center)
            }
            lastSpan = currentSpan
        }
        
        func updateAddress(for coord: CLLocationCoordinate2D) {
            // Do not replace the label while a request is still in flight. That
            // causes the UI to flash an "unknown" coordinate on every small pan.
            // We only fall back after this specific request has actually failed.
            let requestID = UUID()
            geocodeRequestID = requestID
            let coordinateText = String(format: "%.6f, %.6f", coord.latitude, coord.longitude)

            geocoder.cancelGeocode()
            geocoder.reverseGeocodeLocation(
                CLLocation(latitude: coord.latitude, longitude: coord.longitude),
                preferredLocale: Locale(identifier: "zh_CN")
            ) { [weak self] placemarks, _ in
                guard let self, self.geocodeRequestID == requestID else { return }
                guard let pm = placemarks?.first else {
                    self.resolveWithOpenStreetMapFallback(
                        for: coord,
                        requestID: requestID,
                        coordinateText: coordinateText
                    )
                    return
                }

                let poiName = pm.areasOfInterest?.first
                let cleaned: (String?) -> String? = { value in
                    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
                    // Nominatim-style localized data sometimes contains both
                    // simplified and traditional variants separated by `;`.
                    return value.split(separator: ";", maxSplits: 1).first.map(String.init)
                }
                // Some overseas placemarks contain only ISO country code and no
                // localized `country` string. Convert the code ourselves so the
                // country is never lost merely because that optional is empty.
                let countryName = cleaned(pm.country)
                    ?? pm.isoCountryCode.flatMap { Locale(identifier: "zh_CN").localizedString(forRegionCode: $0) }
                let placeName = [poiName, pm.name, pm.thoroughfare, pm.locality, pm.administrativeArea, countryName]
                    .compactMap(cleaned)
                    .first
                // A reverse-geocoding response without a POI can still reliably
                // identify a country, state/province, or city. Keep overseas
                // hierarchy, while preserving the original concise China format.
                let addressParts = (pm.isoCountryCode == "CN"
                    ? [pm.locality, pm.subLocality, pm.thoroughfare, pm.subThoroughfare]
                    : [countryName, pm.administrativeArea, pm.subAdministrativeArea, pm.locality, pm.subLocality, pm.thoroughfare, pm.subThoroughfare])
                    .compactMap(cleaned)
                    .reduce(into: [String]()) { parts, part in
                        if !parts.contains(part) { parts.append(part) }
                    }
                guard let placeName, !addressParts.isEmpty else {
                    self.resolveWithOpenStreetMapFallback(
                        for: coord,
                        requestID: requestID,
                        coordinateText: coordinateText
                    )
                    return
                }

                DispatchQueue.main.async {
                    guard self.geocodeRequestID == requestID else { return }
                    self.address = pm.isoCountryCode == "CN"
                        ? addressParts.joined()
                        : addressParts.joined(separator: " ")
                    self.inferredPlaceName?.wrappedValue = placeName
                }
            }
        }

        private func resolveWithOpenStreetMapFallback(
            for coordinate: CLLocationCoordinate2D,
            requestID: UUID,
            coordinateText: String
        ) {
            Task { [weak self] in
                let result = await OpenStreetMapGeocoder.shared.lookup(coordinate: coordinate)
                DispatchQueue.main.async {
                    guard let self, self.geocodeRequestID == requestID else { return }
                    if let result {
                        self.address = result.address
                        self.inferredPlaceName?.wrappedValue = result.placeName
                    } else {
                        self.address = coordinateText
                        self.inferredPlaceName?.wrappedValue = "未知地点"
                    }
                }
            }
        }
    }
}

/// Secondary reverse-geocoder used only after Apple's service returns no usable
/// placemark. Nominatim is backed by OpenStreetMap and its public endpoint
/// requires low request volume, so results are cached and calls are serialized
/// to at most one per second.
actor OpenStreetMapGeocoder {
    struct Result: Sendable {
        let placeName: String
        let address: String
        let countryCode: String?
        let countryName: String?
        let cityName: String?
    }

    struct SearchResult: Sendable {
        let name: String
        let address: String
        let coordinate: CLLocationCoordinate2D
    }

    static let shared = OpenStreetMapGeocoder()

    private var cache: [String: Result] = [:]
    private var searchCache: [String: [SearchResult]] = [:]
    private var nextRequestDate = Date.distantPast

    func lookup(coordinate: CLLocationCoordinate2D) async -> Result? {
        guard coordinate.latitude.isFinite, coordinate.longitude.isFinite,
              CLLocationCoordinate2DIsValid(coordinate) else { return nil }

        let key = String(format: "%.4f,%.4f", coordinate.latitude, coordinate.longitude)
        if let cached = cache[key] { return cached }

        // A precise road/POI lookup can legitimately return no feature for a
        // valid overseas coordinate. Retry at an administrative zoom so the
        // country/city statistics still get a usable result.
        for zoom in [18, 10] {
            await waitForRequestSlot()

            var components = URLComponents(string: "https://nominatim.openstreetmap.org/reverse")!
            components.queryItems = [
                URLQueryItem(name: "format", value: "jsonv2"),
                URLQueryItem(name: "lat", value: String(coordinate.latitude)),
                URLQueryItem(name: "lon", value: String(coordinate.longitude)),
                URLQueryItem(name: "zoom", value: String(zoom)),
                URLQueryItem(name: "addressdetails", value: "1"),
                URLQueryItem(name: "accept-language", value: "zh-CN,th;q=0.8,en;q=0.6")
            ]
            guard let url = components.url else { continue }

            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 8
            request.setValue("DiFangKe iOS reverse-geocoding fallback", forHTTPHeaderField: "User-Agent")
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { continue }
                let payload = try JSONDecoder().decode(NominatimReverseResponse.self, from: data)
                if let result = makeResult(from: payload.address ?? [:], displayName: payload.displayName) {
                    cache[key] = result
                    return result
                }
            } catch {
                continue
            }
        }
        return nil
    }

    func search(query: String) async -> [SearchResult] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { return [] }
        if let cached = searchCache[normalizedQuery] { return cached }

        await waitForRequestSlot()
        var components = URLComponents(string: "https://nominatim.openstreetmap.org/search")!
        components.queryItems = [
            URLQueryItem(name: "format", value: "jsonv2"),
            URLQueryItem(name: "q", value: normalizedQuery),
            URLQueryItem(name: "limit", value: "5"),
            URLQueryItem(name: "addressdetails", value: "1"),
            URLQueryItem(name: "accept-language", value: "zh-CN")
        ]
        guard let url = components.url else { return [] }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("DiFangKe iOS place-search fallback", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
            let payload = try JSONDecoder().decode([NominatimSearchResponse].self, from: data)
            let results = payload.compactMap { entry -> SearchResult? in
                guard let latitude = Double(entry.lat), let longitude = Double(entry.lon) else { return nil }
                let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
                guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
                let address = makeResult(from: entry.address)?.address ?? entry.displayName
                let name = entry.name?.split(separator: "/", maxSplits: 1).first.map(String.init)
                    ?? makeResult(from: entry.address)?.placeName
                    ?? entry.displayName
                return SearchResult(name: name, address: address, coordinate: coordinate)
            }
            searchCache[normalizedQuery] = results
            return results
        } catch {
            return []
        }
    }

    private func waitForRequestSlot() async {
        let wait = nextRequestDate.timeIntervalSinceNow
        if wait > 0 {
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        }
        nextRequestDate = Date().addingTimeInterval(1)
    }

    private func makeResult(from address: [String: String], displayName: String? = nil) -> Result? {
        func value(_ keys: String...) -> String? {
            keys.lazy.compactMap { key in
                guard let text = address[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
                return text.split(separator: ";", maxSplits: 1).first.map(String.init)
            }.first
        }
        func unique(_ parts: [String?]) -> [String] {
            parts.compactMap { $0 }.reduce(into: [String]()) { result, part in
                if !result.contains(part) { result.append(part) }
            }
        }

        let countryCode = value("country_code")?.uppercased()
        let country = value("country")
            ?? countryCode.flatMap { Locale(identifier: "zh_CN").localizedString(forRegionCode: $0) }
        let city = value("city", "town", "village", "municipality", "county", "district")
        let region = value("state", "state_district", "province", "region")
        let locality = value("suburb", "city_district", "neighbourhood")
        let road = value("road", "pedestrian", "residential")
        let houseNumber = value("house_number")
        let placeName = value("amenity", "building", "shop", "tourism") ?? city ?? region ?? country
            ?? displayName?.split(separator: ",", maxSplits: 1).first.map(String.init)
        guard let placeName else { return nil }

        let address = countryCode == "CN"
            ? unique([city, locality, road, houseNumber]).joined()
            : unique([country, region, city, locality, road, houseNumber]).joined(separator: " ")
        let resolvedAddress = address.isEmpty ? (displayName ?? "") : address
        guard !resolvedAddress.isEmpty else { return nil }
        return Result(
            placeName: placeName,
            address: resolvedAddress,
            countryCode: countryCode,
            countryName: country,
            cityName: city ?? region
        )
    }
}

private struct NominatimReverseResponse: Decodable {
    let address: [String: String]?
    let displayName: String?

    enum CodingKeys: String, CodingKey {
        case address
        case displayName = "display_name"
    }
}

private struct NominatimSearchResponse: Decodable {
    let lat: String
    let lon: String
    let name: String?
    let displayName: String
    let address: [String: String]

    enum CodingKeys: String, CodingKey {
        case lat, lon, name, address
        case displayName = "display_name"
    }
}
