import SwiftUI
import SwiftData
import CoreLocation

struct SavedPlacesView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(LocationManager.self) private var locationManager
    @State private var placeSnapshots: [SavedPlaceSnapshot] = []
    @State private var sortedPlaces: [SavedPlaceSnapshot] = []
    @State private var dataRevision = 0
    @State private var loadedRevision = 0

    struct SavedPlaceSnapshot: Identifiable, Sendable {
        let id: PersistentIdentifier
        let name: String
        let address: String?
        let latitude: Double
        let longitude: Double
    }

    private struct SortKey: Equatable {
        let loadedRevision: Int
        let latitude: Double?
        let longitude: Double?
    }

    private var sortKey: SortKey {
        let coordinate = locationManager.lastLocation?.coordinate
        return SortKey(loadedRevision: loadedRevision, latitude: coordinate?.latitude, longitude: coordinate?.longitude)
    }

    // Same filter and name order as the former @Query + filter, fetched off main.
    nonisolated private static func fetchSavedPlaces(in container: ModelContainer) -> [SavedPlaceSnapshot] {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<Place>(
            predicate: #Predicate { $0.isUserDefined == false && $0.isIgnored == false },
            sortBy: [SortDescriptor(\Place.name)]
        )
        return ((try? context.fetch(descriptor)) ?? []).map { place in
            SavedPlaceSnapshot(
                id: place.persistentModelID,
                name: place.name,
                address: place.address,
                latitude: place.latitude,
                longitude: place.longitude
            )
        }
    }

    // Distance order from the current location; distances are computed once per place.
    nonisolated private static func sortedByDistance(_ places: [SavedPlaceSnapshot], from location: CLLocation?) -> [SavedPlaceSnapshot] {
        guard let location else { return places }
        return places
            .map { ($0, location.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude))) }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    private func mutatePlace(_ snapshot: SavedPlaceSnapshot, _ change: (Place) -> Void) {
        if let place = modelContext.model(for: snapshot.id) as? Place {
            change(place)
            try? modelContext.save()
            CloudSettingsManager.shared.triggerDataSyncPulse()
        }
        placeSnapshots.removeAll { $0.id == snapshot.id }
        sortedPlaces.removeAll { $0.id == snapshot.id }
        dataRevision += 1
    }
    
    var body: some View {
        List {
            Section(header: Text("“已保存地点”是系统根据您的停留记录自动识别的位置。您可以将其忽略，或直接将其删除。")) {
                ForEach(sortedPlaces) { place in
                    HStack(spacing: 14) {
                        ZStack {
                            Circle()
                                .fill(Color.blue.opacity(0.1))
                                .frame(width: 44, height: 44)
                            Image(systemName: "clock.arrow.circlepath")
                                .foregroundColor(.blue)
                        }
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text(place.name)
                                .font(.headline)
                            
                            Text(place.address ?? "未知地址")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                    }
                    .padding(.vertical, 4)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            mutatePlace(place) { modelContext.delete($0) }
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                        
                        Button {
                            mutatePlace(place) { $0.isIgnored = true }
                        } label: {
                            Label("忽略", systemImage: "mappin.slash")
                        }
                        .tint(.secondary)
                    }
                }
            }
            
            if loadedRevision > 0 && placeSnapshots.isEmpty {
                VStack(spacing: 20) {
                    Spacer().frame(height: 40)
                    Image(systemName: "clock")
                        .font(.system(size: 50))
                        .foregroundColor(.gray.opacity(0.3))
                    Text("暂无自动识别的地点")
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }
        }
        .navigationTitle("已保存地点")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: dataRevision) {
            let container = modelContext.container
            let snapshots = await Task.detached(priority: .utility) {
                Self.fetchSavedPlaces(in: container)
            }.value
            guard !Task.isCancelled else { return }
            placeSnapshots = snapshots
            loadedRevision += 1
        }
        .task(id: sortKey) {
            let places = placeSnapshots
            let location = locationManager.lastLocation
            let sorted = await Task.detached(priority: .utility) {
                Self.sortedByDistance(places, from: location)
            }.value
            guard !Task.isCancelled else { return }
            sortedPlaces = sorted
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("FootprintDataChanged"))) { _ in
            dataRevision += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("RemoteDataChanged"))) { _ in
            dataRevision += 1
        }
    }
}
