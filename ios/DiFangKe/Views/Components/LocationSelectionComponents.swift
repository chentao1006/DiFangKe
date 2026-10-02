import SwiftUI
import MapKit
import CoreLocation

// MARK: - IME-safe text editing

/// Keeps in-progress input-method composition out of a parent form's state updates.
///
/// SwiftUI may recreate a text field when a large form observes its own `@State` text
/// on every keystroke. That interrupts marked text (for example, Chinese Pinyin) and
/// commits the first character prematurely. Keep the editing state in this small
/// observable object and copy it back only when the enclosing form saves or loses focus.
final class IMETextState: ObservableObject {
    @Published var text: String

    init(_ text: String = "") {
        self.text = text
    }
}

struct IMESafeMultilineTextField: View {
    let prompt: LocalizedStringKey
    @ObservedObject var textState: IMETextState
    @FocusState.Binding var isFocused: Bool
    var alignment: TextAlignment = .leading

    var body: some View {
        TextField(prompt, text: $textState.text, axis: .vertical)
            .multilineTextAlignment(alignment)
            .focused($isFocused)
    }
}

extension View {
    func dfkMultilineInputStyle() -> some View {
        textFieldStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Stable activity selection

/// A value snapshot keeps an open picker independent from SwiftData, location,
/// map, and photo updates occurring behind it. Rebuilding a native `Menu`
/// during those updates resets its scroll position to the top.
struct StableActivityPickerItem: Identifiable, Equatable {
    let id: UUID
    let name: String
    let icon: String
}

/// Present the snapshot itself so a popover cannot capture pre-tap empty arrays.
struct ActivityPickerPresentation: Identifiable {
    let id = UUID()
    let suggestedItems: [StableActivityPickerItem]
    let allItems: [StableActivityPickerItem]
}

struct StableActivityPickerPopover: View {
    @Environment(\.dismiss) private var dismiss

    let suggestedItems: [StableActivityPickerItem]
    let allItems: [StableActivityPickerItem]
    let onSelect: (UUID?) -> Void
    var onAdd: (() -> Void)? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                pickerButton(title: "无", icon: "circle.slash") {
                    onSelect(nil)
                    dismiss()
                }

                if !suggestedItems.isEmpty {
                    sectionDivider
                    sectionTitle("推荐活动")
                    // Keep repeated activity IDs in separate section view trees.
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(suggestedItems) { item in
                            pickerButton(title: item.name, icon: item.icon) {
                                onSelect(item.id)
                                dismiss()
                            }
                        }
                    }
                }

                if allItems.isEmpty {
                    sectionDivider
                    emptyState
                } else {
                    sectionDivider
                    sectionTitle("所有活动")
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(allItems) { item in
                            pickerButton(title: item.name, icon: item.icon) {
                                onSelect(item.id)
                                dismiss()
                            }
                        }
                    }
                }

                if let onAdd {
                    sectionDivider
                    pickerButton(title: "添加活动类型", icon: "plus") {
                        dismiss()
                        onAdd()
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .frame(width: 300, height: min(480, pickerHeight))
        .presentationCompactAdaptation(.popover)
    }

    private var pickerHeight: CGFloat {
        let rowCount = 1 + suggestedItems.count + allItems.count + (onAdd == nil ? 0 : 1)
        let sectionCount = (suggestedItems.isEmpty ? 1 : 2) + (onAdd == nil ? 0 : 1)
        return CGFloat(rowCount * 48 + sectionCount * 34 + 16)
    }

    private var sectionDivider: some View {
        Divider().padding(.vertical, 4)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
    }

    private var emptyState: some View {
        Label("暂无活动类型", systemImage: "exclamationmark.circle")
            .font(.body)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .padding(.horizontal, 16)
    }

    private func pickerButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.body)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                .padding(.horizontal, 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Location Selection Components (Shared)

struct SuggestionsMenu<Label: View>: View {
    let locationManager: LocationManager
    let coordinate: CLLocationCoordinate2D?
    let forOngoing: Bool
    var footprint: Footprint? = nil
    var isDraft: Bool = false
    var onSearchRequested: () -> Void
    var onCustomSelection: ((String) -> Void)? = nil
    var onSelectionApplied: (() -> Void)? = nil
    @ViewBuilder var label: () -> Label
    
    @State private var suggestions: [LocationSuggestion] = []
    // Starts true: loading begins only once the menu opens.
    @State private var isLoading = true

    private var coordinateKey: String {
        guard let coordinate else { return "none" }
        return "\(coordinate.latitude),\(coordinate.longitude)"
    }
    
    var body: some View {
        Menu {
            Button {
                onSearchRequested()
            } label: {
                Text("搜索其他地点...")
            }
            
            Divider()

            suggestionItems
                // Menu content only exists while the menu is open. Loading
                // here (not on the Menu itself) keeps every timeline row that
                // merely shows this button from firing a batch of MapKit
                // searches, which exceeded Apple's 50-per-minute limit.
                .task(id: coordinateKey) {
                    suggestions = []
                    guard let coordinate else { isLoading = false; return }
                    isLoading = true
                    let results = await locationManager.fetchNearbySuggestions(at: coordinate)
                    guard !Task.isCancelled else { return }
                    suggestions = results
                    isLoading = false
                }
        } label: {
            label()
        }
    }

    @ViewBuilder
    private var suggestionItems: some View {
        Group {
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
                            locationManager.selectSuggestion(suggestion, forOngoing: forOngoing, footprint: footprint, isDraft: isDraft)
                        }
                        onSelectionApplied?()
                    } label: {
                        HStack {
                            Text(suggestion.name)
                        }
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
    var isDraft: Bool = false
    var onCustomSelection: ((String) -> Void)? = nil
    var onSelectionApplied: (() -> Void)? = nil

    @State private var searchText = ""
    @State private var searchResults: [LocationSuggestion] = []
    @State private var isSearching = false
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                    TextField("搜索地点/地址", text: $searchText)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                        .focused($isFocused)
                        .task(id: searchText) {
                            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !query.isEmpty else {
                                searchResults = []
                                isSearching = false
                                return
                            }

                            try? await Task.sleep(nanoseconds: 500_000_000)
                            if Task.isCancelled { return }
                            performFullSearch(query: query)
                        }
                        .onSubmit {
                            performFullSearch(query: searchText)
                        }
                    Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundColor(.secondary) }
                        .opacity(searchText.isEmpty ? 0 : 1)
                        .allowsHitTesting(!searchText.isEmpty)
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
                                    onSelectionApplied?()
                                    dismiss()
                                } else {
                                    locationManager.selectSuggestion(suggestion, forOngoing: forOngoing, footprint: footprint, isDraft: isDraft)
                                    onSelectionApplied?()
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
            .navigationTitle("搜索其他地点")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button { dismiss() } label: { Image(systemName: "xmark").dfkToolbarDismissIcon() } }
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
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else {
            searchResults = []
            return
        }
        isSearching = true
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = normalizedQuery
        if let center = coordinate {
            request.region = MKCoordinateRegion(center: center, latitudinalMeters: 5000, longitudinalMeters: 5000)
        }
        let search = MKLocalSearch(request: request)
        search.start { response, error in
            isSearching = false
            guard let response = response, error == nil else { return }
            let mappedResults = response.mapItems.map { item in
                let addr = [item.placemark.thoroughfare, item.placemark.subThoroughfare, item.placemark.locality, item.placemark.administrativeArea].compactMap { $0 }.joined(separator: " ")
                return LocationSuggestion(
                    name: item.name ?? "位置", 
                    address: addr, 
                    coordinate: item.placemark.coordinate,
                    category: item.pointOfInterestCategory?.rawValue
                )
            }
            // Apple Maps does not guarantee text-search ordering by distance.
            // A footprint's coordinate is the editing anchor, so nearby
            // matches must be shown first.
            if let center = coordinate {
                let origin = CLLocation(latitude: center.latitude, longitude: center.longitude)
                self.searchResults = mappedResults.sorted {
                    let firstDistance = origin.distance(from: CLLocation(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude))
                    let secondDistance = origin.distance(from: CLLocation(latitude: $1.coordinate.latitude, longitude: $1.coordinate.longitude))
                    if abs(firstDistance - secondDistance) > 1 { return firstDistance < secondDistance }
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
            } else {
                self.searchResults = mappedResults
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
