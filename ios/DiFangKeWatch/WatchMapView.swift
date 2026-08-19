import SwiftUI
import MapKit

struct WatchMapView: View {
    let day: WatchDaySnapshot?

    @State private var cameraPosition: MapCameraPosition

    init(day: WatchDaySnapshot?) {
        self.day = day
        _cameraPosition = State(initialValue: Self.initialCameraPosition(for: day))
    }

    private var footprintItems: [WatchTimelineItem] {
        (day?.timeline ?? []).filter { $0.latitude != nil && $0.longitude != nil }
    }

    private var routeItems: [WatchTimelineItem] {
        (day?.timeline ?? []).filter { ($0.routeCoordinates?.count ?? 0) >= 2 }
    }

    var body: some View {
        Group {
            if footprintItems.isEmpty && routeItems.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "map")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("没有位置记录")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Map(position: $cameraPosition) {
                    ForEach(routeItems) { item in
                        MapPolyline(coordinates: item.routeCoordinates!.map {
                            CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)
                        })
                        .stroke(.orange, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    }
                    ForEach(footprintItems) { item in
                        Marker(item.title, systemImage: item.icon, coordinate: CLLocationCoordinate2D(latitude: item.latitude!, longitude: item.longitude!))
                            .tint(activityColor(item.colorHex))
                    }
                }
                .mapStyle(.standard(elevation: .flat))
            }
        }
        .navigationTitle(title)
    }

    private var title: String {
        guard let date = day?.date else { return "地图" }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "今天" }
        if calendar.isDateInYesterday(date) { return "昨天" }
        return date.formatted(.dateTime.month().day())
    }

    private static func initialCameraPosition(for day: WatchDaySnapshot?) -> MapCameraPosition {
        guard let region = boundingRegion(for: day) else { return .automatic }
        return .region(region)
    }

    private static func boundingRegion(for day: WatchDaySnapshot?) -> MKCoordinateRegion? {
        let coordinates: [CLLocationCoordinate2D] = (day?.timeline ?? []).flatMap { item -> [CLLocationCoordinate2D] in
            var points: [CLLocationCoordinate2D] = []
            if let lat = item.latitude, let lon = item.longitude {
                points.append(CLLocationCoordinate2D(latitude: lat, longitude: lon))
            }
            if let route = item.routeCoordinates {
                points.append(contentsOf: route.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) })
            }
            return points
        }
        guard !coordinates.isEmpty else { return nil }
        let latitudes = coordinates.map(\.latitude)
        let longitudes = coordinates.map(\.longitude)
        let minLat = latitudes.min()!, maxLat = latitudes.max()!
        let minLon = longitudes.min()!, maxLon = longitudes.max()!
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
        let span = MKCoordinateSpan(
            latitudeDelta: max((maxLat - minLat) * 1.4, 0.01),
            longitudeDelta: max((maxLon - minLon) * 1.4, 0.01)
        )
        return MKCoordinateRegion(center: center, span: span)
    }
}
