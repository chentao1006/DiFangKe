import SwiftUI
import MapKit

struct PlaceSearchResult: Identifiable, Hashable {
    let id: String
    let name: String
    let address: String
    let coordinate: CLLocationCoordinate2D

    init(name: String, address: String, coordinate: CLLocationCoordinate2D) {
        self.id = "\(name)|\(coordinate.latitude)|\(coordinate.longitude)"
        self.name = name
        self.address = address
        self.coordinate = coordinate
    }

    static func == (lhs: PlaceSearchResult, rhs: PlaceSearchResult) -> Bool { lhs.id == rhs.id }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

@MainActor
class PlacePickerViewModel: NSObject, ObservableObject {
    @Published var searchResults: [PlaceSearchResult] = []
    private var searchTask: Task<Void, Never>?
    private var completionResolutionTask: Task<Void, Never>?
    private let searchCompleter = MKLocalSearchCompleter()
    private var activeQuery = ""
    private var finalizedQuery = ""

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
            finalizedQuery = ""
            return
        }

        activeQuery = normalizedQuery
        finalizedQuery = ""
        searchResults = []
        searchCompleter.queryFragment = normalizedQuery

        searchTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 550_000_000)
            guard !Task.isCancelled, activeQuery == normalizedQuery else { return }

            let nearbyResults = await searchMapItems(query: normalizedQuery, near: userCoord)
            guard !Task.isCancelled else { return }
            // City names and distant destinations must not be constrained to
            // the user's current map viewport.
            let globalResults = nearbyResults.isEmpty
                ? await searchMapItems(query: normalizedQuery, near: nil)
                : nearbyResults
            guard !Task.isCancelled, activeQuery == normalizedQuery else { return }

            // Apple Maps can return unrelated local fuzzy matches for overseas
            // names (for example, “东.Dong” for “东京”). Prefer an exact result
            // from the OpenStreetMap fallback when one is available.
            let fallbackResults = await OpenStreetMapGeocoder.shared.search(query: normalizedQuery)
            guard !Task.isCancelled, activeQuery == normalizedQuery else { return }
            let convertedFallback = fallbackResults.map {
                PlaceSearchResult(name: $0.name, address: $0.address, coordinate: $0.coordinate)
            }
            searchResults = prioritizeExactMatches(convertedFallback, over: globalResults, query: normalizedQuery)
            finalizedQuery = normalizedQuery
        }
    }

    private func searchMapItems(query: String, near coordinate: CLLocationCoordinate2D?) async -> [PlaceSearchResult] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if let coordinate {
            request.region = MKCoordinateRegion(
                center: coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5)
            )
        }
        let response = try? await MKLocalSearch(request: request).start()
        return (response?.mapItems ?? []).map {
            PlaceSearchResult(name: $0.name ?? "位置", address: $0.placemark.title ?? "", coordinate: $0.placemark.coordinate)
        }
    }

    private func resolveCompletions(_ completions: [MKLocalSearchCompletion], for query: String) async -> [PlaceSearchResult] {
        var items: [PlaceSearchResult] = []
        var seenCoordinates = Set<String>()

        for completion in completions.prefix(8) {
            guard !Task.isCancelled else { return [] }
            let response = try? await MKLocalSearch(request: MKLocalSearch.Request(completion: completion)).start()
            for item in response?.mapItems ?? [] {
                let coordinate = item.placemark.coordinate
                let key = "\(item.name ?? "")|\(coordinate.latitude)|\(coordinate.longitude)"
                if seenCoordinates.insert(key).inserted {
                    items.append(PlaceSearchResult(name: item.name ?? "位置", address: item.placemark.title ?? "", coordinate: coordinate))
                }
            }
        }
        return items
    }

    private func prioritizeExactMatches(_ fallback: [PlaceSearchResult], over apple: [PlaceSearchResult], query: String) -> [PlaceSearchResult] {
        let normalizedQuery = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let exactFallback = fallback.filter {
            $0.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).contains(normalizedQuery)
        }
        let combined = exactFallback.isEmpty ? apple + fallback : exactFallback + apple + fallback
        var seen = Set<String>()
        return combined.filter { seen.insert($0.id).inserted }
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
                guard !Task.isCancelled, activeQuery == query, finalizedQuery != query, !items.isEmpty else { return }
                searchResults = items
            }
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) { }
}
