import SwiftUI
import MapKit
import SwiftData

/// DiFangKe 统一地图组件，用于确保全应用地图表现一致
struct DFKMapView: View {
    @Binding var cameraPosition: MapCameraPosition
    var isInteractive: Bool = false
    var showsUserLocation: Bool = true
    var points: [CLLocationCoordinate2D] = []
    var mainAnnotationCoordinate: CLLocationCoordinate2D? = nil
    var mainAnnotationTitle: String? = nil
    
    @Query(sort: \Place.name) private var allPlaces: [Place]
    
    var body: some View {
        Map(position: $cameraPosition, interactionModes: isInteractive ? .all : []) {
            if showsUserLocation {
                UserAnnotation()
            }
            
            if !points.isEmpty {
                MapPolyline(coordinates: points)
                    .stroke(Color.dfkAccent, lineWidth: isInteractive ? 5 : 3)
            }
            
            if let mainCoord = mainAnnotationCoordinate {
                Marker(mainAnnotationTitle ?? "", coordinate: mainCoord)
                    .tint(Color.dfkAccent)
            }
            
            // 重要地点呈现
            ForEach(allPlaces.filter { $0.isUserDefined }) { place in
                MapCircle(center: place.coordinate, radius: Double(place.radius))
                    .foregroundStyle(Color.orange.opacity(0.1))
                    .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                
                Annotation("", coordinate: place.coordinate) {
                    Text(place.name)
                        .font(.system(size: isInteractive ? 10 : 8, weight: .bold))
                        .foregroundColor(.orange)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color(uiColor: .systemBackground).opacity(0.8)))
                }
            }
        }
        .mapControls {
            if isInteractive {
                MapUserLocationButton()
                MapCompass()
                MapPitchToggle()
            }
        }
        .mapStyle(.standard)
    }
}

extension Array where Element == CLLocationCoordinate2D {
    /// 计算包含所有坐标点的最佳矩形区域
    func boundingRegion(paddingFactor: Double = 1.3) -> MKCoordinateRegion? {
        guard !isEmpty else { return nil }
        
        var minLat = self[0].latitude
        var maxLat = self[0].latitude
        var minLon = self[0].longitude
        var maxLon = self[0].longitude
        
        for p in self {
            minLat = Swift.min(minLat, p.latitude)
            maxLat = Swift.max(maxLat, p.latitude)
            minLon = Swift.min(minLon, p.longitude)
            maxLon = Swift.max(maxLon, p.longitude)
        }
        
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
        
        // 计算跨度并增加外边距
        let latDelta = (maxLat - minLat) * paddingFactor
        let lonDelta = (maxLon - minLon) * paddingFactor
        
        // 确保跨度不为0 (比如只有一个点的情况)
        let finalLatDelta = Swift.max(latDelta, 0.005) // 约 500m
        let finalLonDelta = Swift.max(lonDelta, 0.005)
        
        return MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: finalLatDelta, longitudeDelta: finalLonDelta)
        )
    }
}
