import SwiftUI
import MapKit
import CoreLocation

// MARK: - Location Selection Components (Shared)

struct SuggestionsMenuContent: View {
    let locationManager: LocationManager
    let coordinate: CLLocationCoordinate2D?
    let forOngoing: Bool
    var footprint: Footprint? = nil
    var onSearchRequested: () -> Void
    var onCustomSelection: ((String) -> Void)? = nil
    
    @State private var suggestions: [LocationSuggestion] = []
    @State private var isLoading = false
    
    var body: some View {
        Group {
            Button {
                onSearchRequested()
            } label: {
                Text("搜索其他地点...")
            }
            
            Divider()
            
            if isLoading {
                Text("正在寻找附近地点...")
            } else if suggestions.isEmpty {
                Text("未发现附近建议")
            } else {
                ForEach(suggestions) { suggestion in
                    Button {
                        if let customSelected = onCustomSelection {
                            customSelected(suggestion.name)
                        } else {
                            locationManager.selectSuggestion(suggestion, forOngoing: forOngoing, footprint: footprint)
                        }
                    } label: {
                        HStack {
                            Text(suggestion.name)
                        }
                    }
                }
            }
        }
        .onAppear {
            if let coord = coordinate {
                isLoading = true
                Task {
                    let results = await locationManager.fetchNearbySuggestions(at: coord)
                    await MainActor.run {
                        self.suggestions = results
                        self.isLoading = false
                    }
                }
            }
        }
    }
}

struct LocationSearchSheet: View {
    @Environment(\.dismiss) private var dismiss
    let locationManager: LocationManager
    let coordinate: CLLocationCoordinate2D?
    let forOngoing: Bool
    var footprint: Footprint? = nil
    var onCustomSelection: ((String) -> Void)? = nil

    @State private var searchText = ""
    @State private var searchResults: [LocationSuggestion] = []
    @State private var isSearching = false
    @FocusState private var isFocused: Bool
    @State private var searchTask: Task<Void, Never>? = nil

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                    TextField("搜索地点/地址", text: $searchText)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                        .focused($isFocused)
                        .onChange(of: searchText) { oldValue, newValue in
                            searchTask?.cancel()
                            searchTask = Task {
                                try? await Task.sleep(nanoseconds: 500_000_000)
                                if !Task.isCancelled {
                                    performFullSearch(query: newValue)
                                }
                            }
                        }
                        .onSubmit {
                            searchTask?.cancel()
                            performFullSearch(query: searchText)
                        }
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundColor(.secondary) }
                    }
                }
                .padding(10)
                .background(Color(uiColor: .secondarySystemBackground))
                .cornerRadius(10)
                .padding()

                List {
                    if !searchResults.isEmpty {
                        ForEach(searchResults) { suggestion in
                            Button {
                                if let customSelected = onCustomSelection {
                                    customSelected(suggestion.name)
                                    dismiss()
                                } else {
                                    locationManager.selectSuggestion(suggestion, forOngoing: forOngoing, footprint: footprint)
                                    dismiss()
                                }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(suggestion.name).font(.body).foregroundColor(.primary)
                                        Text(suggestion.address).font(.caption).foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    Text(distanceLabel(for: suggestion)).font(.caption2).foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
            .navigationTitle("手动修正地址")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("取消") { dismiss() } }
            }
            .overlay {
                if isSearching {
                    ProgressView().padding().background(.ultraThinMaterial).cornerRadius(10)
                }
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { isFocused = true }
            }
        }
    }

    private func performFullSearch(query: String) {
        guard !query.isEmpty else { return }
        isSearching = true
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if let center = coordinate {
            request.region = MKCoordinateRegion(center: center, latitudinalMeters: 5000, longitudinalMeters: 5000)
        }
        let search = MKLocalSearch(request: request)
        search.start { response, error in
            isSearching = false
            guard let response = response, error == nil else { return }
            self.searchResults = response.mapItems.map { item in
                let addr = [item.placemark.thoroughfare, item.placemark.subThoroughfare, item.placemark.locality, item.placemark.administrativeArea].compactMap { $0 }.joined(separator: " ")
                return LocationSuggestion(name: item.name ?? "位置", address: addr, coordinate: item.placemark.coordinate)
            }
        }
    }

    private func distanceLabel(for suggestion: LocationSuggestion) -> String {
        guard let center = coordinate else { return "" }
        let l1 = CLLocation(latitude: center.latitude, longitude: center.longitude)
        let l2 = CLLocation(latitude: suggestion.coordinate.latitude, longitude: suggestion.coordinate.longitude)
        let dist = l1.distance(from: l2)
        if dist < 1000 { return String(format: "%.0f米", dist) }
        else { return String(format: "%.1f公里", dist / 1000.0) }
    }
}
