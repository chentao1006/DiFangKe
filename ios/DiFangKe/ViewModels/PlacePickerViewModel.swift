import SwiftUI
import MapKit

@MainActor
class PlacePickerViewModel: NSObject, ObservableObject {
    @Published var searchResults: [MKMapItem] = []
    private var searchTask: Task<Void, Never>?
    private var completionResolutionTask: Task<Void, Never>?
    private let searchCompleter = MKLocalSearchCompleter()
    private var activeQuery = ""

    override init() {
        super.init()
        searchCompleter.delegate = self
    }

    func search(query: String, userCoord: CLLocationCoordinate2D?) {
        searchTask?.cancel()
        completionResolutionTask?.cancel()
        searchCompleter.cancel()

        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else {
            searchResults = []
            activeQuery = ""
            return
        }

        activeQuery = normalizedQuery
        searchResults = []
        searchCompleter.queryFragment = normalizedQuery

        searchTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 550_000_000)
            guard !Task.isCancelled, activeQuery == normalizedQuery, searchResults.isEmpty else { return }

            let nearbyResults = await searchMapItems(query: normalizedQuery, near: userCoord)
            guard !Task.isCancelled else { return }
            if !nearbyResults.isEmpty {
                searchResults = nearbyResults
                return
            }

            // City names and distant destinations must not be constrained to
            // the user's current map viewport.
            searchResults = await searchMapItems(query: normalizedQuery, near: nil)
        }
    }

    private func searchMapItems(query: String, near coordinate: CLLocationCoordinate2D?) async -> [MKMapItem] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if let coordinate {
            request.region = MKCoordinateRegion(
                center: coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5)
            )
        }
        let response = try? await MKLocalSearch(request: request).start()
        return response?.mapItems ?? []
    }

    private func resolveCompletions(_ completions: [MKLocalSearchCompletion], for query: String) async -> [MKMapItem] {
        var items: [MKMapItem] = []
        var seenCoordinates = Set<String>()

        for completion in completions.prefix(8) {
            guard !Task.isCancelled else { return [] }
            let response = try? await MKLocalSearch(request: MKLocalSearch.Request(completion: completion)).start()
            for item in response?.mapItems ?? [] {
                let coordinate = item.placemark.coordinate
                let key = "\(item.name ?? "")|\(coordinate.latitude)|\(coordinate.longitude)"
                if seenCoordinates.insert(key).inserted {
                    items.append(item)
                }
            }
        }
        return items
    }
}

extension PlacePickerViewModel: MKLocalSearchCompleterDelegate {
    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let completions = completer.results
        Task { @MainActor [weak self] in
            guard let self, !activeQuery.isEmpty else { return }
            let query = activeQuery
            completionResolutionTask?.cancel()
            completionResolutionTask = Task { @MainActor [weak self] in
                guard let self else { return }
                let items = await resolveCompletions(completions, for: query)
                guard !Task.isCancelled, activeQuery == query, !items.isEmpty else { return }
                searchResults = items
            }
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) { }
}
