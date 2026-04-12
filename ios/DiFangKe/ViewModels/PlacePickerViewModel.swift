import SwiftUI
import MapKit

@MainActor
class PlacePickerViewModel: NSObject, ObservableObject {
    @Published var searchResults: [MKMapItem] = []

    func search(query: String, userCoord: CLLocationCoordinate2D?) {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if let coord = userCoord {
            request.region = MKCoordinateRegion(center: coord,
                                                 span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5))
        }
        Task {
            if let items = try? await MKLocalSearch(request: request).start() {
                searchResults = items.mapItems
            }
        }
    }
}
