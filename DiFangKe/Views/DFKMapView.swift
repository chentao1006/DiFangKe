import SwiftUI
import MapKit
import SwiftData

/// DiFangKe 统一地图组件，用于确保全应用地图表现一致
struct DFKMapView: View {
    @Binding var cameraPosition: MapCameraPosition
    var isInteractive: Bool = false
    var showsUserLocation: Bool = true
    var points: [CLLocationCoordinate2D] = []
    
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
