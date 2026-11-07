import SwiftUI
import MapKit
import SwiftData
import Photos

private struct DFKTransportIconPoint: Identifiable {
    let id: String
    let coordinate: CLLocationCoordinate2D
    let type: TransportType
    let travelsWest: Bool
}

private struct DFKReviewTransportLine: Identifiable {
    let id: String
    let polyline: MKPolyline
    let isDashed: Bool
}

/// Review-map transport data, exactly as the review map has always drawn it,
/// but computed in background tasks and only read by the view.
private struct DFKReviewTransportGeometry {
    struct Route {
        let segment: TransportLineSegment
        let minLatitude: Double
        let maxLatitude: Double
        let minLongitude: Double
        let maxLongitude: Double
    }

    struct Midpoint {
        let coordinate: CLLocationCoordinate2D
        let type: TransportType
        let travelsWest: Bool
        /// Route length; longer routes claim their icon spot first.
        let distance: Double
        /// The route, so the icon can sit mid-way along its on-screen part.
        let coordinates: [CLLocationCoordinate2D]
        let bounds: DFKCoordinateBounds
    }

    struct PreparedRoute {
        let source: Route
        let line: DFKReviewTransportLine
    }

    /// Retain only the current scale. Panning reuses the same MapKit objects
    /// without keeping a copy of the year's routes at every visited scale.
    final class ScaleCache: @unchecked Sendable {
        private let lock = NSLock()
        private var cell: Double?
        private var routes: [PreparedRoute] = []

        func value(for cell: Double) -> [PreparedRoute]? {
            lock.lock()
            defer { lock.unlock() }
            return self.cell == cell ? routes : nil
        }

        func store(_ routes: [PreparedRoute], cell: Double) {
            lock.lock()
            defer { lock.unlock() }
            self.cell = cell
            self.routes = routes
        }
    }

    var key: String?
    /// Routes with the same shape drawn once, with their bounds for culling.
    var routes: [Route] = []
    var segments: [TransportLineSegment] = []
    var midpoints: [Midpoint] = []
    private let scaleCache = ScaleCache()

    static func build(key: String, transports: [DFKMapTransportDisplay]) -> DFKReviewTransportGeometry {
        var geometry = DFKReviewTransportGeometry(key: key)
        var seen: Set<String> = []
        for display in transports {
            guard !Task.isCancelled else { return geometry }
            let transport = display.transport
            let segments = display.segments
            let transportCoordinates = display.coordinates
            if let midpoint = display.midpoint {
                var bounds = DFKCoordinateBounds()
                bounds.add(contentsOf: transportCoordinates)
                geometry.midpoints.append(.init(
                    coordinate: midpoint,
                    type: transport.currentType,
                    travelsWest: display.travelsWest,
                    distance: transport.distance,
                    coordinates: transportCoordinates,
                    bounds: bounds
                ))
            }
            for segment in segments {
                let coordinates = segment.coordinates.filter(\.isRenderableMapCoordinate)
                guard coordinates.count >= 2 else { continue }
                let step = max(1, coordinates.count / 24)
                var sampled = stride(from: 0, to: coordinates.count, by: step).map { coordinates[$0] }
                if let last = coordinates.last,
                   sampled.last?.latitude != last.latitude || sampled.last?.longitude != last.longitude {
                    sampled.append(last)
                }
                let forward = sampled.map { String(format: "%.3f,%.3f", $0.latitude, $0.longitude) }.joined(separator: ";")
                let reverse = sampled.reversed().map { String(format: "%.3f,%.3f", $0.latitude, $0.longitude) }.joined(separator: ";")
                guard seen.insert("\(segment.isDashed ? "d" : "s"):\(min(forward, reverse))").inserted else { continue }
                let latitudes = coordinates.map(\.latitude)
                let longitudes = coordinates.map(\.longitude)
                geometry.routes.append(.init(
                    segment: TransportLineSegment(id: segment.id, coordinates: coordinates, isDashed: segment.isDashed),
                    minLatitude: latitudes.min() ?? 0,
                    maxLatitude: latitudes.max() ?? 0,
                    minLongitude: longitudes.min() ?? 0,
                    maxLongitude: longitudes.max() ?? 0
                ))
            }
        }
        geometry.midpoints.sort { $0.distance > $1.distance }
        // Detailed observed routes claim shared shapes before short repeats.
        geometry.routes.sort {
            if $0.segment.isDashed != $1.segment.isDashed { return !$0.segment.isDashed }
            return $0.segment.coordinates.count > $1.segment.coordinates.count
        }
        geometry.segments = geometry.routes.map(\.segment)
        return geometry
    }

    /// The visible area grown by 8% on each side.
    static func paddedBounds(_ region: MKCoordinateRegion) -> (minLatitude: Double, maxLatitude: Double, minLongitude: Double, maxLongitude: Double) {
        let latitudePadding = region.span.latitudeDelta * 0.08
        let longitudePadding = region.span.longitudeDelta * 0.08
        return (
            region.center.latitude - region.span.latitudeDelta / 2 - latitudePadding,
            region.center.latitude + region.span.latitudeDelta / 2 + latitudePadding,
            region.center.longitude - region.span.longitudeDelta / 2 - longitudePadding,
            region.center.longitude + region.span.longitudeDelta / 2 + longitudePadding
        )
    }

    /// Prepare continuous routes once per scale, then only cull on a pan.
    func visibleSegments(in region: MKCoordinateRegion, baseCell: Double) -> [DFKReviewTransportLine] {
        let bounds = Self.paddedBounds(region)
        let adaptiveCell = max(baseCell, max(region.span.latitudeDelta, region.span.longitudeDelta) / 110)
        let level = adaptiveCell > baseCell ? Int(ceil(log(adaptiveCell / baseCell) / log(1.6))) : 0
        let cell = baseCell * pow(1.6, Double(level))
        let prepared: [PreparedRoute]
        if let cached = scaleCache.value(for: cell) {
            prepared = cached
        } else {
            prepared = prepareRoutes(cell: cell)
            guard !Task.isCancelled else { return [] }
            scaleCache.store(prepared, cell: cell)
        }
        return prepared.compactMap { route in
            let source = route.source
            guard source.maxLatitude >= bounds.minLatitude && source.minLatitude <= bounds.maxLatitude &&
                    source.maxLongitude >= bounds.minLongitude && source.minLongitude <= bounds.maxLongitude else { return nil }
            return route.line
        }
    }

    private func prepareRoutes(cell: Double) -> [PreparedRoute] {
        struct CellEdge: Hashable {
            let fromX: Int, fromY: Int, toX: Int, toY: Int
            let isDashed: Bool
        }
        func gridCell(_ coordinate: CLLocationCoordinate2D) -> (x: Int, y: Int) {
            (Int((coordinate.longitude / cell).rounded()), Int((coordinate.latitude / cell).rounded()))
        }

        var result: [PreparedRoute] = []
        var drawnEdges: Set<CellEdge> = []
        for route in routes {
            guard !Task.isCancelled else { return [] }
            let coordinates = route.segment.coordinates
            var thinned: [CLLocationCoordinate2D] = [coordinates[0]]
            var lastCell = gridCell(coordinates[0])
            var edges: Set<CellEdge> = []
            for (index, coordinate) in coordinates.enumerated().dropFirst() {
                let pointCell = gridCell(coordinate)
                let isLast = index == coordinates.count - 1
                guard pointCell != lastCell || isLast else { continue }
                thinned.append(coordinate)
                if pointCell != lastCell {
                    let a = lastCell, b = pointCell
                    edges.insert((a.x, a.y) <= (b.x, b.y)
                        ? CellEdge(fromX: a.x, fromY: a.y, toX: b.x, toY: b.y, isDashed: route.segment.isDashed)
                        : CellEdge(fromX: b.x, fromY: b.y, toX: a.x, toY: a.y, isDashed: route.segment.isDashed))
                }
                lastCell = pointCell
            }
            // Omit only a route whose entire shape is already represented.
            // Any new edge keeps the WHOLE route, including shared edges, so
            // intersections and overlaps never cut it into disconnected runs.
            guard edges.isEmpty || !edges.isSubset(of: drawnEdges) else { continue }
            drawnEdges.formUnion(edges)
            result.append(PreparedRoute(
                source: route,
                line: DFKReviewTransportLine(
                    id: route.segment.id,
                    polyline: MKPolyline(coordinates: thinned, count: thinned.count),
                    isDashed: route.segment.isDashed
                )
            ))
        }
        return result
    }

    /// Longest routes claim nearby same-type icon positions first, using
    /// the same screen-space rule as the footprint map. Snapshot drawing
    /// performs its own merge after projecting into the snapshot's size.
    func iconPoints(in region: MKCoordinateRegion, culls: Bool, viewWidth: CGFloat, diameter: CGFloat) -> [DFKTransportIconPoint] {
        let bounds = Self.paddedBounds(region)
        var kept: [DFKTransportIconPoint] = []
        for index in midpoints.indices {
            guard !Task.isCancelled else { return [] }
            let midpoint = midpoints[index]
            let coordinate: CLLocationCoordinate2D
            if culls {
                guard midpoint.bounds.maxLatitude >= bounds.minLatitude && midpoint.bounds.minLatitude <= bounds.maxLatitude &&
                        midpoint.bounds.maxLongitude >= bounds.minLongitude && midpoint.bounds.minLongitude <= bounds.maxLongitude else { continue }
                guard let visible = midpoint.coordinates.visibleDistanceMidpoint(in: region),
                      visible.latitude >= bounds.minLatitude, visible.latitude <= bounds.maxLatitude,
                      visible.longitude >= bounds.minLongitude, visible.longitude <= bounds.maxLongitude else { continue }
                coordinate = visible
            } else {
                coordinate = midpoint.coordinate
            }
            kept.append(DFKTransportIconPoint(
                id: "\(midpoint.type.rawValue):\(index)",
                coordinate: coordinate,
                type: midpoint.type,
                travelsWest: midpoint.travelsWest
            ))
        }
        let indices = MapTransportIconMerge.keptIndices(
            coordinates: kept.map(\.coordinate),
            types: kept.map(\.type.rawValue),
            region: region,
            viewWidth: viewWidth,
            diameter: diameter
        )
        return indices.map { kept[$0] }
    }
}

/// Launch-stable FNV-1a hash. Map input keys stay cheap (no string joins)
/// and still match the persisted snapshot cache across launches.
private struct DFKMapKeyHasher {
    private(set) var value: UInt64 = 0xcbf2_9ce4_8422_2325

    private mutating func mix(_ byte: UInt8) {
        value ^= UInt64(byte)
        value = value &* 0x0000_0100_0000_01b3
    }

    mutating func combine(_ bits: UInt64) {
        var remaining = bits
        for _ in 0..<8 {
            mix(UInt8(truncatingIfNeeded: remaining))
            remaining >>= 8
        }
    }

    mutating func combine(_ int: Int) { combine(UInt64(bitPattern: Int64(int))) }
    mutating func combine(_ double: Double) { combine(double.bitPattern) }
    mutating func combine(_ bool: Bool) { combine(bool ? UInt64(1) : UInt64(0)) }
    mutating func combine(_ date: Date) { combine(date.timeIntervalSince1970) }

    /// Values at the 4-decimal precision snapshot keys have always used.
    mutating func combineRounded(_ double: Double) {
        guard double.isFinite, abs(double) < 1e12 else {
            combine(UInt64.max)
            return
        }
        combine(Int((double * 10_000).rounded()))
    }

    mutating func combine(_ coordinate: CLLocationCoordinate2D?) {
        guard let coordinate else {
            combine(UInt64.max)
            return
        }
        combine(coordinate.latitude)
        combine(coordinate.longitude)
    }

    mutating func combineRounded(_ coordinate: CLLocationCoordinate2D?) {
        guard let coordinate else {
            combine(UInt64.max)
            return
        }
        combineRounded(coordinate.latitude)
        combineRounded(coordinate.longitude)
    }

    mutating func combine(_ uuid: UUID?) {
        guard let uuid else {
            combine(UInt64.max)
            return
        }
        let bytes = uuid.uuid
        for byte in [bytes.0, bytes.1, bytes.2, bytes.3, bytes.4, bytes.5, bytes.6, bytes.7,
                     bytes.8, bytes.9, bytes.10, bytes.11, bytes.12, bytes.13, bytes.14, bytes.15] {
            mix(byte)
        }
    }

    mutating func combine(_ string: String?) {
        guard let string else {
            combine(UInt64.max - 1)
            return
        }
        for byte in string.utf8 {
            mix(byte)
        }
        combine(string.utf8.count)
    }

    var intValue: Int { Int(truncatingIfNeeded: value) }
}

/// Bounds of a coordinate set; yields the same region as
/// `Array<CLLocationCoordinate2D>.boundingRegion` without keeping the points.
private struct DFKCoordinateBounds {
    var minLatitude = 0.0
    var maxLatitude = 0.0
    var minLongitude = 0.0
    var maxLongitude = 0.0
    var isEmpty = true

    mutating func add(_ coordinate: CLLocationCoordinate2D) {
        if isEmpty {
            minLatitude = coordinate.latitude
            maxLatitude = coordinate.latitude
            minLongitude = coordinate.longitude
            maxLongitude = coordinate.longitude
            isEmpty = false
            return
        }
        minLatitude = min(minLatitude, coordinate.latitude)
        maxLatitude = max(maxLatitude, coordinate.latitude)
        minLongitude = min(minLongitude, coordinate.longitude)
        maxLongitude = max(maxLongitude, coordinate.longitude)
    }

    mutating func add<S: Sequence>(contentsOf coordinates: S) where S.Element == CLLocationCoordinate2D {
        for coordinate in coordinates {
            add(coordinate)
        }
    }

    func region(paddingFactor: Double) -> MKCoordinateRegion? {
        guard !isEmpty else { return nil }
        let center = CLLocationCoordinate2D(latitude: (minLatitude + maxLatitude) / 2, longitude: (minLongitude + maxLongitude) / 2)
        let latDelta = (maxLatitude - minLatitude) * paddingFactor
        let lonDelta = (maxLongitude - minLongitude) * paddingFactor
        return MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: max(latDelta, 0.005), longitudeDelta: max(lonDelta, 0.005))
        )
    }
}

/// Plain values read from one footprint on the main actor, so grouping and
/// geometry for the map can run off the main thread.
private struct DFKMapFootprintInput {
    let footprintID: UUID
    let latitude: Double
    let longitude: Double
    let duration: TimeInterval
    let startTime: Date
    let placeID: UUID?
    let locationHash: String
    let address: String?
    let countryCode: String?
    let countryName: String?
    let cityName: String?
    let firstPhotoAssetID: String?

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

private struct DFKMapPlaceInput {
    let placeID: UUID
    let name: String
    let latitude: Double
    let longitude: Double
    let radius: Double
    let isUserDefined: Bool

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

private struct DFKMapPlaceCircle: Identifiable {
    let id: Int
    let coordinate: CLLocationCoordinate2D
    let radius: Double
}

/// A transport with its route geometry computed once.
private struct DFKMapTransportDisplay: Identifiable {
    let transport: Transport
    let segments: [TransportLineSegment]
    /// Renderable route points, for placing the icon on the visible part.
    let coordinates: [CLLocationCoordinate2D]
    let midpoint: CLLocationCoordinate2D?
    let travelsWest: Bool

    var id: UUID { transport.id }
}

/// One footprint marker: footprints referenced by index into the content's
/// footprint list, grouped and ordered off the main thread.
private struct DFKMapFootprintGroup {
    let id: String
    let memberIndices: [Int]
    let representativeIndex: Int
    let coordinate: CLLocationCoordinate2D
    let totalDuration: TimeInterval
    let placeCount: Int
    let latestPhotoAssetID: String?
}

/// Everything the map draws that is derived from its inputs, built in a
/// background task and only read by the view.
private struct DFKMapContent {
    var key: Int?
    var footprints: [DFKMapFootprintInput] = []
    var placeGroups: [DFKMapFootprintGroup] = []
    var transports: [DFKMapTransportDisplay] = []
    var transportSegments: [TransportLineSegment] = []
    var annotationTransports: [DFKMapTransportDisplay] = []
    var userDefinedPlaces: [DFKMapPlaceCircle] = []
    var snapshotPlaceCircles: [DFKMapPlaceCircle] = []
    var photoAnnotations: [(asset: PHAsset, coordinate: CLLocationCoordinate2D)] = []
    var heatmapPoints: [DFKMapView.HeatmapPoint] = []
    var interactiveBounds = DFKCoordinateBounds()
    var snapshotBounds = DFKCoordinateBounds()
    var drawsStandalonePhotosInSnapshot = false
}

private enum DFKMapContentBuilder {
    struct Request {
        let key: Int
        let footprints: [DFKMapFootprintInput]
        let places: [DFKMapPlaceInput]
        let transports: [Transport]
        let points: [CLLocationCoordinate2D]
        let mainAnnotationCoordinate: CLLocationCoordinate2D?
        let photoAssets: [PHAsset]
        let heatmapPoints: [DFKMapView.HeatmapPoint]
        let showsStandalonePhotos: Bool
        let showsUserDefinedPlaceRadii: Bool
        let clustersPlacesByMapScale: Bool
        let usesReviewTransportOverview: Bool
        let selectedFootprintID: UUID?
        let selectedFootprintCoordinate: CLLocationCoordinate2D?
    }

    static func display(for transport: Transport) -> DFKMapTransportDisplay {
        let segments = TransportRouteCompletion.cachedSegments(for: transport)
        let smoothedPoints = segments.flatMap(\.coordinates).filter(\.isRenderableMapCoordinate)
        return DFKMapTransportDisplay(
            transport: transport,
            segments: segments,
            coordinates: smoothedPoints,
            midpoint: smoothedPoints.distanceMidpoint,
            travelsWest: smoothedPoints.travelsWest
        )
    }

    static func build(_ request: Request) -> DFKMapContent {
        var content = DFKMapContent(key: request.key)
        content.footprints = request.footprints

        content.transports = request.transports.compactMap { transport in
            guard transport.points.filter(\.isRenderableMapCoordinate).count >= 2 else { return nil }
            return display(for: transport)
        }
        content.transportSegments = content.transports.flatMap(\.segments)
        content.annotationTransports = content.transports

        for (index, place) in request.places.enumerated() where place.isUserDefined {
            if request.showsUserDefinedPlaceRadii {
                content.snapshotPlaceCircles.append(DFKMapPlaceCircle(id: index, coordinate: place.coordinate, radius: place.radius))
            }
            if place.coordinate.isRenderableMapCoordinate, place.radius.isFinite, place.radius > 1 {
                content.userDefinedPlaces.append(DFKMapPlaceCircle(id: index, coordinate: place.coordinate, radius: place.radius))
            }
        }

        if request.showsStandalonePhotos {
            content.photoAnnotations = request.photoAssets.compactMap { asset -> (asset: PHAsset, coordinate: CLLocationCoordinate2D)? in
                guard let coord = asset.location?.gcj02.coordinate else { return nil }
                return (asset, coord)
            }
        }
        content.heatmapPoints = request.heatmapPoints.filter { $0.coordinate.isRenderableMapCoordinate }
        content.drawsStandalonePhotosInSnapshot = request.footprints.contains { $0.firstPhotoAssetID != nil }

        // Interactive framing uses renderable coordinates only; the snapshot
        // framing keeps every input coordinate, as it always has.
        var interactive = DFKCoordinateBounds()
        var snapshot = DFKCoordinateBounds()
        interactive.add(contentsOf: request.points.filter(\.isRenderableMapCoordinate))
        snapshot.add(contentsOf: request.points)
        if let main = request.mainAnnotationCoordinate {
            if main.isRenderableMapCoordinate {
                interactive.add(main)
            }
            snapshot.add(main)
        }
        for footprint in request.footprints {
            let coordinate = footprint.coordinate
            if coordinate.isRenderableMapCoordinate {
                interactive.add(coordinate)
            }
            snapshot.add(coordinate)
        }
        for transport in content.transports {
            interactive.add(contentsOf: transport.coordinates)
            snapshot.add(contentsOf: transport.coordinates)
        }
        interactive.add(contentsOf: content.photoAnnotations.map(\.coordinate))
        interactive.add(contentsOf: content.heatmapPoints.map(\.coordinate))
        if content.drawsStandalonePhotosInSnapshot {
            snapshot.add(contentsOf: request.photoAssets.compactMap { $0.location?.gcj02.coordinate })
        }
        snapshot.add(contentsOf: request.heatmapPoints.map(\.coordinate))
        content.interactiveBounds = interactive
        content.snapshotBounds = snapshot

        content.placeGroups = placeGroups(for: request)
        return content
    }

    private static func placeGroups(for request: Request) -> [DFKMapFootprintGroup] {
        struct Bucket {
            var weightedLatitude: Double
            var weightedLongitude: Double
            var totalWeight: TimeInterval
            var totalDuration: TimeInterval
            var representativeIndex: Int
            var memberIndices: [Int]
        }

        // Same lookup as `allPlaces.first(where:)`: the first place wins.
        var placesByID: [UUID: DFKMapPlaceInput] = [:]
        if request.clustersPlacesByMapScale {
            for place in request.places where placesByID[place.placeID] == nil {
                placesByID[place.placeID] = place
            }
        }

        let footprints = request.footprints
        var buckets: [String: Bucket] = [:]
        var orderedKeys: [String] = []

        for (index, footprint) in footprints.enumerated() where footprint.coordinate.isRenderableMapCoordinate {
            let durationWeight = max(footprint.duration, 1)
            let key: String
            if request.clustersPlacesByMapScale {
                let place = footprint.placeID.flatMap { placesByID[$0] }
                key = reviewIntegratedPlaceKey(
                    placeName: place?.name,
                    placeLatitude: place?.latitude ?? 0,
                    placeLongitude: place?.longitude ?? 0,
                    address: footprint.address,
                    countryCode: footprint.countryCode,
                    countryName: footprint.countryName,
                    cityName: footprint.cityName,
                    latitude: footprint.latitude,
                    longitude: footprint.longitude
                )
            } else if let placeID = footprint.placeID {
                key = "place:\(placeID.uuidString)"
            } else if !footprint.locationHash.isEmpty {
                key = "hash:\(footprint.locationHash)"
            } else {
                key = String(format: "coord:%.5f,%.5f", footprint.latitude, footprint.longitude)
            }

            if var bucket = buckets[key] {
                bucket.weightedLatitude += footprint.latitude * durationWeight
                bucket.weightedLongitude += footprint.longitude * durationWeight
                bucket.totalWeight += durationWeight
                bucket.totalDuration += footprint.duration
                bucket.memberIndices.append(index)
                if footprint.duration > footprints[bucket.representativeIndex].duration {
                    bucket.representativeIndex = index
                }
                buckets[key] = bucket
            } else {
                orderedKeys.append(key)
                buckets[key] = Bucket(
                    weightedLatitude: footprint.latitude * durationWeight,
                    weightedLongitude: footprint.longitude * durationWeight,
                    totalWeight: durationWeight,
                    totalDuration: footprint.duration,
                    representativeIndex: index,
                    memberIndices: [index]
                )
            }
        }

        return orderedKeys.compactMap { key in
            guard let bucket = buckets[key] else { return nil }
            let divisor = max(bucket.totalWeight, 1)
            let representativeIndex = request.selectedFootprintID.flatMap { selectedID in
                bucket.memberIndices.first { footprints[$0].footprintID == selectedID }
            } ?? bucket.representativeIndex
            let representative = footprints[representativeIndex]
            let members = sortedByStartTime(bucket.memberIndices, in: footprints)
            return DFKMapFootprintGroup(
                id: key,
                memberIndices: members,
                representativeIndex: representativeIndex,
                // Detail selection represents this footprint, not the
                // duration-weighted position of every visit at the same place.
                coordinate: request.selectedFootprintID == representative.footprintID
                    ? (request.selectedFootprintCoordinate ?? representative.coordinate)
                    : CLLocationCoordinate2D(
                        latitude: bucket.weightedLatitude / divisor,
                        longitude: bucket.weightedLongitude / divisor
                    ),
                totalDuration: bucket.totalDuration,
                placeCount: 1,
                latestPhotoAssetID: latestPhotoAssetID(of: members, in: footprints)
            )
        }
    }

    /// Groups places on a 7×7 grid of the region, as the review map always has.
    static func aggregatedGroups(
        places: [DFKMapFootprintGroup],
        footprints: [DFKMapFootprintInput],
        region: MKCoordinateRegion?
    ) -> [DFKMapFootprintGroup] {
        guard let region, places.count > 1 else { return places }

        let latitudeCell = max(region.span.latitudeDelta / 7, 0.000_001)
        let longitudeCell = max(region.span.longitudeDelta / 7, 0.000_001)
        let latitudeOrigin = region.center.latitude - region.span.latitudeDelta / 2
        let longitudeOrigin = region.center.longitude - region.span.longitudeDelta / 2
        // Only cells on screen plus a one-cell margin get markers. Off-screen
        // places are invisible anyway; grouping them too made a zoomed-in map
        // build one marker (and one photo) per place for the whole period,
        // which starved the map renderer and the app of memory.
        let visibleCells = -1...7
        var grouped: [String: [DFKMapFootprintGroup]] = [:]
        for place in places {
            let latitudeIndex = Int(floor((place.coordinate.latitude - latitudeOrigin) / latitudeCell))
            let longitudeIndex = Int(floor((place.coordinate.longitude - longitudeOrigin) / longitudeCell))
            guard visibleCells.contains(latitudeIndex), visibleCells.contains(longitudeIndex) else { continue }
            grouped["\(latitudeIndex):\(longitudeIndex)", default: []].append(place)
        }

        return grouped.keys.sorted().compactMap { key in
            guard let members = grouped[key], let first = members.first else { return nil }
            guard members.count > 1 else { return first }
            let totalWeight = members.reduce(0.0) { $0 + max($1.totalDuration, 1) }
            let latitude = members.reduce(0.0) {
                $0 + $1.coordinate.latitude * max($1.totalDuration, 1)
            } / totalWeight
            let longitude = members.reduce(0.0) {
                $0 + $1.coordinate.longitude * max($1.totalDuration, 1)
            } / totalWeight
            let representativeIndex = members.max { $0.totalDuration < $1.totalDuration }?.representativeIndex ?? first.representativeIndex
            let memberIndices = sortedByStartTime(members.flatMap(\.memberIndices), in: footprints)
            return DFKMapFootprintGroup(
                id: "cluster:\(key):\(members.map(\.id).sorted().joined(separator: "|"))",
                memberIndices: memberIndices,
                representativeIndex: representativeIndex,
                coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                totalDuration: members.reduce(0) { $0 + $1.totalDuration },
                placeCount: members.reduce(0) { $0 + $1.placeCount },
                latestPhotoAssetID: latestPhotoAssetID(of: memberIndices, in: footprints)
            )
        }
    }

    private static func sortedByStartTime(_ indices: [Int], in footprints: [DFKMapFootprintInput]) -> [Int] {
        indices.sorted { footprints[$0].startTime < footprints[$1].startTime }
    }

    /// Latest footprint's first photo, matching the footprint card (`.first`).
    private static func latestPhotoAssetID(of sortedIndices: [Int], in footprints: [DFKMapFootprintInput]) -> String? {
        sortedIndices
            .sorted { footprints[$0].startTime > footprints[$1].startTime }
            .lazy
            .compactMap { footprints[$0].firstPhotoAssetID }
            .first
    }
}

/// Map marker photos, looked up in one Photos query and requested off main.
private enum DFKMapPhotoImageLoader {
    static func images(for assetIDs: [String], targetSize: CGSize, highQuality: Bool) async -> [String: UIImage] {
        guard !assetIDs.isEmpty else { return [:] }
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return [:] }

        var resolvedByStoredID: [String: String] = [:]
        for assetID in assetIDs where resolvedByStoredID[assetID] == nil {
            resolvedByStoredID[assetID] = PhotoService.shared.resolvedAssetIdentifier(for: assetID)
        }
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: Array(Set(resolvedByStoredID.values)), options: nil)
        var assetsByResolvedID: [String: PHAsset] = [:]
        fetched.enumerateObjects { asset, _, _ in
            assetsByResolvedID[asset.localIdentifier] = asset
        }

        var images: [String: UIImage] = [:]
        for assetID in assetIDs {
            if Task.isCancelled { break }
            guard let resolvedID = resolvedByStoredID[assetID],
                  let asset = assetsByResolvedID[resolvedID],
                  let image = await requestImage(for: asset, targetSize: targetSize, highQuality: highQuality) else { continue }
            images[assetID] = image
        }
        return images
    }

    private static func requestImage(for asset: PHAsset, targetSize: CGSize, highQuality: Bool) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let lock = NSLock()
            var didResume = false
            func resumeOnce(with image: UIImage?) {
                lock.lock()
                defer { lock.unlock() }
                guard !didResume else { return }
                didResume = true
                continuation.resume(returning: image)
            }

            let options = PHImageRequestOptions()
            if highQuality {
                options.isNetworkAccessAllowed = true
                options.deliveryMode = .highQualityFormat
                options.resizeMode = .exact
            } else {
                options.isNetworkAccessAllowed = false
                options.deliveryMode = .fastFormat
                options.resizeMode = .fast
            }

            PHImageManager.default().requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFill,
                options: options
            ) { image, _ in
                resumeOnce(with: image)
            }
        }
    }
}

/// Everything the generated snapshot draws over the map image, as values, so
/// projection and drawing run off the main thread.
private struct DFKMapSnapshotDrawing {
    let snapshot: MKMapSnapshotter.Snapshot
    let region: MKCoordinateRegion
    let size: CGSize
    let scale: CGFloat
    let isDark: Bool
    let themeColor: UIColor
    let deepRedColor: UIColor
    let placeCircles: [DFKMapPlaceCircle]
    let usesReviewTransportOverview: Bool
    let segments: [TransportLineSegment]
    let iconPoints: [DFKTransportIconPoint]
    let annotationTransports: [DFKMapTransportDisplay]
    let footprintMarkers: [(coordinate: CLLocationCoordinate2D, image: UIImage)]
    let heatmapPoints: [DFKMapView.HeatmapPoint]
    let standalonePhotos: [(coordinate: CLLocationCoordinate2D, image: UIImage)]
    let mainAnnotationCoordinate: CLLocationCoordinate2D?

    func render() -> UIImage {
        var image = UIImage()
        // Dynamic system colors resolve for the map's own appearance.
        UITraitCollection(userInterfaceStyle: isDark ? .dark : .light).performAsCurrent {
            image = draw()
        }
        return image
    }

    private func draw() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        let renderer = UIGraphicsImageRenderer(size: snapshot.image.size, format: format)
        let strokeColor = isDark ? UIColor.black : UIColor.white

        return renderer.image { ctx in
            snapshot.image.draw(at: .zero)

            for place in placeCircles {
                let center = snapshot.point(for: place.coordinate)
                let metersPerDegreeLongitude = 111_320.0 * max(0.2, cos(place.coordinate.latitude * .pi / 180.0))
                let visibleWidthMeters = max(1, region.span.longitudeDelta * metersPerDegreeLongitude)
                let metersPerPoint = visibleWidthMeters / max(size.width, 1)
                let radius = max(10, CGFloat(place.radius / max(Double(metersPerPoint), 1)))
                let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
                ctx.cgContext.setFillColor(UIColor.orange.withAlphaComponent(0.12).cgColor)
                ctx.cgContext.fillEllipse(in: rect)
                ctx.cgContext.setStrokeColor(UIColor.orange.withAlphaComponent(0.35).cgColor)
                ctx.cgContext.setLineWidth(1)
                ctx.cgContext.strokeEllipse(in: rect)
            }

            ctx.cgContext.setLineCap(.round)
            ctx.cgContext.setLineJoin(.round)

            if usesReviewTransportOverview {
                for segment in segments {
                    let points = segment.coordinates.map { snapshot.point(for: $0) }
                    guard let first = points.first, points.count >= 2 else { continue }
                    ctx.cgContext.beginPath()
                    ctx.cgContext.move(to: first)
                    for point in points.dropFirst() {
                        ctx.cgContext.addLine(to: point)
                    }
                    ctx.cgContext.setStrokeColor(themeColor.withAlphaComponent(segment.isDashed ? 0.4 : 0.65).cgColor)
                    ctx.cgContext.setLineWidth(segment.isDashed ? 1 : 2.5)
                    ctx.cgContext.setLineDash(phase: 0, lengths: segment.isDashed ? [4, 4] : [])
                    ctx.cgContext.strokePath()
                }
                ctx.cgContext.setLineDash(phase: 0, lengths: [])

                let keptIcons = MapTransportIconMerge.keptIndices(
                    points: iconPoints.map { snapshot.point(for: $0.coordinate) },
                    types: iconPoints.map(\.type.rawValue),
                    diameter: 24
                )
                for iconPoint in keptIcons.map({ iconPoints[$0] }) {
                    let point = snapshot.point(for: iconPoint.coordinate)
                    let circleRect = CGRect(x: point.x - 12, y: point.y - 12, width: 24, height: 24)
                    UIColor.systemBackground.setFill()
                    UIBezierPath(ovalIn: circleRect).fill()
                    themeColor.setStroke()
                    let outline = UIBezierPath(ovalIn: circleRect)
                    outline.lineWidth = 1.5
                    outline.stroke()
                    if let sourceImage = UIImage(systemName: iconPoint.type.sfSymbol) {
                        let iconImage = iconPoint.travelsWest ? sourceImage.withHorizontallyFlippedOrientation() : sourceImage
                        Self.drawImageAspectFit(
                            iconImage.withTintColor(themeColor),
                            in: CGRect(x: point.x - 6, y: point.y - 6, width: 12, height: 12)
                        )
                    }
                }
            } else {
                for segment in segments {
                    let projected = segment.coordinates.map { snapshot.point(for: $0) }
                    guard projected.count >= 2 else { continue }

                    ctx.cgContext.beginPath()
                    ctx.cgContext.move(to: projected[0])
                    for i in 1..<projected.count {
                        ctx.cgContext.addLine(to: projected[i])
                    }
                    ctx.cgContext.setStrokeColor(
                        themeColor.withAlphaComponent(segment.isDashed ? 0.4 : 0.65).cgColor
                    )
                    ctx.cgContext.setLineWidth(segment.isDashed ? 1 : 2.5)
                    ctx.cgContext.setLineDash(phase: 0, lengths: segment.isDashed ? [4, 4] : [])
                    ctx.cgContext.strokePath()
                }
                ctx.cgContext.setLineDash(phase: 0, lengths: [])

                let placedTransports = annotationTransports.compactMap { display -> (display: DFKMapTransportDisplay, point: CGPoint)? in
                    guard display.transport.points.count >= 2, let midCoord = display.midpoint else { return nil }
                    return (display, snapshot.point(for: midCoord))
                }
                let keptTransports = MapTransportIconMerge.keptIndices(
                    points: placedTransports.map(\.point),
                    types: placedTransports.map(\.display.transport.currentType.rawValue),
                    diameter: 14
                )
                for (display, midPoint) in keptTransports.map({ placedTransports[$0] }) {
                    let rect = CGRect(x: midPoint.x - 7, y: midPoint.y - 7, width: 14, height: 14)
                    let path = UIBezierPath(ovalIn: rect)
                    UIColor.systemBackground.setFill()
                    path.fill()
                    themeColor.setStroke()
                    path.lineWidth = 1.2
                    path.stroke()

                    if let sourceImage = UIImage(systemName: display.transport.currentType.sfSymbol) {
                        let iconImage = display.travelsWest ? sourceImage.withHorizontallyFlippedOrientation() : sourceImage
                        Self.drawImageAspectFit(iconImage.withTintColor(themeColor), in: CGRect(x: midPoint.x - 4, y: midPoint.y - 4, width: 8, height: 8))
                    }
                }
            }

            for marker in footprintMarkers {
                let point = snapshot.point(for: marker.coordinate)
                marker.image.draw(at: CGPoint(
                    x: point.x - marker.image.size.width / 2,
                    y: point.y - marker.image.size.height
                ))
            }

            for point in heatmapPoints {
                let mapped = snapshot.point(for: point.coordinate)
                let rawRatio = Double(point.intensity) / Double(max(1, point.maxIntensity))
                let ratio = pow(rawRatio, 0.4)
                let color: UIColor = {
                    if point.maxIntensity <= 1 {
                        return .orange
                    } else if ratio < 0.25 {
                        return .orange
                    } else if ratio < 0.85 {
                        return .red
                    } else {
                        return deepRedColor
                    }
                }()
                let sizeValue = max(14.0, min(30.0, CGFloat(point.intensity) * 3))
                let rect = CGRect(x: mapped.x - sizeValue / 2, y: mapped.y - sizeValue / 2, width: sizeValue, height: sizeValue)
                ctx.cgContext.setFillColor(color.withAlphaComponent(0.28).cgColor)
                ctx.cgContext.fillEllipse(in: rect)
            }

            // Photos without a loaded image are skipped to keep it clean.
            for entry in standalonePhotos {
                let point = snapshot.point(for: entry.coordinate)
                let markerSize: CGFloat = 40 // Standalone photos should be larger to be visible
                let tipHeight: CGFloat = 8
                let rect = CGRect(x: point.x - markerSize / 2, y: point.y - markerSize - tipHeight, width: markerSize, height: markerSize)
                let markerPath = UIBezierPath.photoMapMarkerPath(in: CGRect(x: rect.minX, y: rect.minY, width: markerSize, height: markerSize + tipHeight), cornerRadius: 6, tipHeight: tipHeight)
                let contentRect = rect.insetBy(dx: 4, dy: 4)
                let contentPath = UIBezierPath(roundedRect: contentRect, cornerRadius: 4)

                ctx.cgContext.saveGState()
                ctx.cgContext.setShadow(offset: CGSize(width: 0, height: 2), blur: 4, color: UIColor.black.withAlphaComponent(0.20).cgColor)
                UIColor.systemBackground.setFill()
                markerPath.fill()
                ctx.cgContext.restoreGState()

                ctx.cgContext.saveGState()
                contentPath.addClip()
                Self.drawImageAspectFill(entry.image, in: contentRect)
                ctx.cgContext.restoreGState()

                UIColor.separator.withAlphaComponent(0.30).setStroke()
                contentPath.lineWidth = 0.8
                contentPath.stroke()

                UIColor.systemBackground.setStroke()
                markerPath.lineWidth = 1.5
                markerPath.stroke()
            }

            if let mainAnnotationCoordinate {
                let point = snapshot.point(for: mainAnnotationCoordinate)
                let rect = CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10)
                ctx.cgContext.setFillColor(themeColor.cgColor)
                ctx.cgContext.fillEllipse(in: rect)
                ctx.cgContext.setStrokeColor(strokeColor.cgColor)
                ctx.cgContext.setLineWidth(1.5)
                ctx.cgContext.strokeEllipse(in: rect)
            }
        }
    }

    private static func drawImageAspectFill(_ image: UIImage, in rect: CGRect) {
        let imageAspect = image.size.width / image.size.height
        let rectAspect = rect.width / rect.height
        var drawRect = rect

        if imageAspect > rectAspect {
            drawRect.size.width = rect.height * imageAspect
            drawRect.origin.x = rect.midX - drawRect.width / 2
        } else {
            drawRect.size.height = rect.width / imageAspect
            drawRect.origin.y = rect.midY - drawRect.height / 2
        }
        image.draw(in: drawRect)
    }

    private static func drawImageAspectFit(_ image: UIImage, in rect: CGRect) {
        let imageSize = image.size
        let aspectWidth = rect.width / imageSize.width
        let aspectHeight = rect.height / imageSize.height
        let aspectRatio = min(aspectWidth, aspectHeight)

        let newSize = CGSize(width: imageSize.width * aspectRatio, height: imageSize.height * aspectRatio)
        let newOrigin = CGPoint(x: rect.origin.x + (rect.width - newSize.width) / 2, y: rect.origin.y + (rect.height - newSize.height) / 2)

        image.draw(in: CGRect(origin: newOrigin, size: newSize))
    }
}

import UIKit
import CryptoKit

@MainActor
final class DFKMapSnapshotCache {
    static let shared = DFKMapSnapshotCache()
    // NSCache is thread-safe; the size/clear helpers below may run off main.
    nonisolated(unsafe) private let memoryCache = NSCache<NSString, UIImage>()
    private let fileManager = FileManager.default
    nonisolated private let cacheDirectory: URL
    private let maxDiskCacheSizeBytes: Int64 = 200 * 1024 * 1024
    private let maxFileAge: TimeInterval = 30 * 24 * 60 * 60
    private let maxUnusedAge: TimeInterval = 14 * 24 * 60 * 60
    private let cleanupInterval: TimeInterval = 12 * 60 * 60
    private let ioQueue = DispatchQueue(label: "com.difangke.mapSnapshotCache", qos: .utility)

    private init() {
        memoryCache.countLimit = 24
        memoryCache.totalCostLimit = 32 * 1024 * 1024
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cacheDirectory = caches.appendingPathComponent("DFKMapSnapshots", isDirectory: true)
        if !fileManager.fileExists(atPath: cacheDirectory.path) {
            try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        }
        scheduleCleanupIfNeeded(force: false)
    }

    private func cacheURL(for key: String) -> URL {
        let data = Data(key.utf8)
        let hash = SHA256.hash(data: data)
        let filename = hash.compactMap { String(format: "%02x", $0) }.joined()
        return cacheDirectory.appendingPathComponent(filename + ".png")
    }

    func image(for key: String) -> UIImage? {
        if let memoryImage = memoryCache.object(forKey: key as NSString) {
            return memoryImage
        }

        let url = cacheURL(for: key)
        if let data = try? Data(contentsOf: url), let diskImage = UIImage(data: data) {
            memoryCache.setObject(diskImage, forKey: key as NSString, cost: Self.memoryCost(of: diskImage))
            updateAccessDate(for: url)
            scheduleCleanupIfNeeded(force: false)
            return diskImage
        }

        return nil
    }

    func memoryImage(for key: String) -> UIImage? {
        memoryCache.object(forKey: key as NSString)
    }

    /// `image(for:)` with the disk read and decode off the main thread.
    func imageAsync(for key: String) async -> UIImage? {
        if let memoryImage = memoryCache.object(forKey: key as NSString) {
            return memoryImage
        }

        let url = cacheURL(for: key)
        let diskImage = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else { return nil }
            return image.preparingForDisplay() ?? image
        }.value
        guard let diskImage else { return nil }
        memoryCache.setObject(diskImage, forKey: key as NSString, cost: Self.memoryCost(of: diskImage))
        updateAccessDate(for: url)
        scheduleCleanupIfNeeded(force: false)
        return diskImage
    }

    func setImage(_ image: UIImage, for key: String) {
        memoryCache.setObject(image, forKey: key as NSString, cost: Self.memoryCost(of: image))

        let url = cacheURL(for: key)
        ioQueue.async {
            if let data = image.pngData() {
                try? data.write(to: url)
                Self.setDates(for: url, accessDate: Date(), modificationDate: Date())
            }
        }
        scheduleCleanupIfNeeded(force: false)
    }

    func removeImage(for key: String) {
        memoryCache.removeObject(forKey: key as NSString)
        let url = cacheURL(for: key)
        ioQueue.async {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func removeAllMemoryImages() {
        memoryCache.removeAllObjects()
    }

    nonisolated private static func memoryCost(of image: UIImage) -> Int {
        (image.cgImage?.bytesPerRow ?? 0) * (image.cgImage?.height ?? 0)
    }

    /// Directory enumeration; safe to call from a background task.
    nonisolated func calculateCacheSize() -> Int64 {
        let fileManager = FileManager.default
        let files = (try? fileManager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        var totalSize: Int64 = 0
        for file in files {
            if let attrs = try? file.resourceValues(forKeys: [.fileSizeKey]), let size = attrs.fileSize {
                totalSize += Int64(size)
            }
        }
        return totalSize
    }

    /// File deletion; safe to call from a background task.
    nonisolated func clearCache() {
        let fileManager = FileManager.default
        memoryCache.removeAllObjects()
        let files = (try? fileManager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil)) ?? []
        for file in files {
            try? fileManager.removeItem(at: file)
        }
        UserDefaults.standard.removeObject(forKey: Self.lastCleanupKey)
    }

    private func updateAccessDate(for url: URL) {
        ioQueue.async {
            Self.setDates(for: url, accessDate: Date(), modificationDate: nil)
        }
    }

    private func scheduleCleanupIfNeeded(force: Bool) {
        let now = Date()
        let defaults = UserDefaults.standard
        if !force,
           let lastCleanup = defaults.object(forKey: Self.lastCleanupKey) as? Date,
           now.timeIntervalSince(lastCleanup) < cleanupInterval {
            return
        }

        defaults.set(now, forKey: Self.lastCleanupKey)
        ioQueue.async { [cacheDirectory, maxFileAge, maxUnusedAge, maxDiskCacheSizeBytes] in
            let fileManager = FileManager.default
            let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .contentAccessDateKey]
            let files = (try? fileManager.contentsOfDirectory(
                at: cacheDirectory,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsHiddenFiles]
            )) ?? []

            struct CacheEntry {
                let url: URL
                let size: Int64
                let modificationDate: Date
                let accessDate: Date
            }

            let entries: [CacheEntry] = files.compactMap { url in
                guard let values = try? url.resourceValues(forKeys: resourceKeys),
                      values.isRegularFile == true else {
                    return nil
                }

                let modificationDate = values.contentModificationDate ?? .distantPast
                let accessDate = values.contentAccessDate ?? modificationDate
                let size = Int64(values.fileSize ?? 0)
                return CacheEntry(url: url, size: size, modificationDate: modificationDate, accessDate: accessDate)
            }

            let expirationDate = now.addingTimeInterval(-maxFileAge)
            let unusedDeadline = now.addingTimeInterval(-maxUnusedAge)

            var retainedEntries: [CacheEntry] = []
            for entry in entries {
                if entry.modificationDate < expirationDate || entry.accessDate < unusedDeadline {
                    try? fileManager.removeItem(at: entry.url)
                } else {
                    retainedEntries.append(entry)
                }
            }

            var totalSize = retainedEntries.reduce(Int64(0)) { $0 + $1.size }
            if totalSize <= maxDiskCacheSizeBytes {
                return
            }

            for entry in retainedEntries.sorted(by: { $0.accessDate < $1.accessDate }) {
                try? fileManager.removeItem(at: entry.url)
                totalSize -= entry.size
                if totalSize <= maxDiskCacheSizeBytes {
                    break
                }
            }
        }
    }

    nonisolated private static let lastCleanupKey = "dfk.mapSnapshotCache.lastCleanup"

    nonisolated private static func setDates(
        for url: URL,
        accessDate: Date?,
        modificationDate: Date?
    ) {
        var mutableURL = url
        var values = URLResourceValues()
        if let accessDate = accessDate {
            values.contentAccessDate = accessDate
        }
        if let modificationDate = modificationDate {
            values.contentModificationDate = modificationDate
        }
        try? mutableURL.setResourceValues(values)
    }
}

func reviewIntegratedPlaceKey(for footprint: Footprint, allPlaces: [Place]) -> String {
    let place = footprint.placeID.flatMap { placeID in
        allPlaces.first(where: { $0.placeID == placeID })
    }
    return reviewIntegratedPlaceKey(
        placeName: place?.name,
        placeLatitude: place?.latitude ?? 0,
        placeLongitude: place?.longitude ?? 0,
        address: footprint.address,
        countryCode: footprint.countryCode,
        countryName: footprint.countryName,
        cityName: footprint.cityName,
        latitude: footprint.latitude,
        longitude: footprint.longitude
    )
}

/// Value form of `reviewIntegratedPlaceKey(for:allPlaces:)`, usable off main.
/// `placeName` is nil when the footprint has no matching place.
func reviewIntegratedPlaceKey(
    placeName rawPlaceName: String?,
    placeLatitude: Double,
    placeLongitude: Double,
    address rawAddress: String?,
    countryCode: String?,
    countryName: String?,
    cityName: String?,
    latitude footprintLatitude: Double,
    longitude footprintLongitude: Double
) -> String {
    let placeName = rawPlaceName?.trimmingCharacters(in: .whitespacesAndNewlines)

    // A saved place is one spot however each visit was geocoded: visits whose
    // city or country came back differently (or not at all) must not split
    // it. Keyed by the place itself, so synced duplicates of the same place
    // (same name, same spot) also count as one.
    if let placeName, !placeName.isEmpty {
        let factor = 100.0
        let latitude = (placeLatitude * factor).rounded() / factor
        let longitude = (placeLongitude * factor).rounded() / factor
        return "place:\(normalizedPlaceSearchKey(placeName)):\(latitude),\(longitude)"
    }
    let address = rawAddress?.trimmingCharacters(in: .whitespacesAndNewlines)
    let displayName = [placeName, address]
        .compactMap { $0 }
        .first { !$0.isEmpty }
        .map(normalizedPlaceSearchKey) ?? ""

    if !displayName.isEmpty {
        let country = normalizedPlaceSearchKey(countryCode ?? countryName ?? "")
        let city = normalizedPlaceSearchKey(cityName ?? "")
        return "named:\(country):\(city):\(displayName)"
    }

    let factor = 1_000.0
    let latitude = (footprintLatitude * factor).rounded() / factor
    let longitude = (footprintLongitude * factor).rounded() / factor
    return "coordinate:\(latitude),\(longitude)"
}

/// DiFangKe 统一地图组件，用于确保全应用地图表现一致
struct DFKMapView: View {
    @Binding var cameraPosition: MapCameraPosition
    var isInteractive: Bool = false
    var rendersLiveMap: Bool = true
    var showsUserLocation: Bool = true
    var points: [CLLocationCoordinate2D] = []
    var mainAnnotationCoordinate: CLLocationCoordinate2D? = nil
    var mainAnnotationTitle: String? = nil
    var timelineItems: [TimelineItem] = []
    var photoAssets: [PHAsset] = []
    var widgetSnapshotOffset: Int? = nil
    var allowsGeneratedSnapshot: Bool = true
    var showsStandalonePhotos: Bool = false
    var prefersActivityIcons: Bool = false
    var condensesTransportOverview: Bool = false
    var clustersPlacesByMapScale: Bool = false
    var placeClusterRegion: MKCoordinateRegion? = nil
    var showsUserDefinedPlaceRadii: Bool = true
    var topContentInset: CGFloat = 0
    var bottomContentInset: CGFloat = 0
    var isMiniTimelineMode: Bool = false
    var selectedFootprintID: UUID? = nil
    var selectedFootprintCoordinate: CLLocationCoordinate2D? = nil
    var selectedTimeCoordinate: CLLocationCoordinate2D? = nil
    var timelineUpdateIdentifier: Int? = nil
    var onMapInteraction: ((MapInteractionType) -> Void)? = nil
    var showsMapControls: Bool = true

    enum MapInteractionType {
        case tap
        case pan
        case zoom
    }

    struct HeatmapPoint: Identifiable {
        let id: String
        let coordinate: CLLocationCoordinate2D
        let intensity: Int
        let maxIntensity: Int

        init(coordinate: CLLocationCoordinate2D, intensity: Int, maxIntensity: Int) {
            self.id = String(format: "%.5f,%.5f", coordinate.latitude, coordinate.longitude)
            self.coordinate = coordinate
            self.intensity = intensity
            self.maxIntensity = maxIntensity
        }
    }

    struct AggregatedFootprint: Identifiable {
        let id: String
        let coordinate: CLLocationCoordinate2D
        let totalDuration: TimeInterval
        let representative: Footprint
        let footprints: [Footprint]
        let placeCount: Int
        /// The latest footprint's first photo, resolved with the grouping.
        var latestPhotoAssetID: String? = nil
    }



    var heatmapPoints: [HeatmapPoint] = []

    var onTimelineItemTap: ((TimelineItem) -> Void)? = nil
    /// Hosts that present sheets from another window (Records) present the
    /// footprint group themselves; otherwise this map presents it.
    var onAggregatedFootprintTap: ((AggregatedFootprint) -> Void)? = nil
    var onPhotoTap: ((PHAsset) -> Void)? = nil
    var onUserLocationTap: (() -> Void)? = nil
    /// When set, a button above the location button restores the initial camera.
    var onResetCamera: (() -> Void)? = nil

    @Query(sort: \Place.name) private var allPlaces: [Place]
    @Query(sort: [SortDescriptor(\ActivityType.sortOrder), SortDescriptor(\ActivityType.name)]) private var allActivities: [ActivityType]

    init(
        cameraPosition: Binding<MapCameraPosition>,
        rendersLiveMap: Bool = true,
        isInteractive: Bool = false,
        allowsGeneratedSnapshot: Bool = true,
        showsUserLocation: Bool = true,
        points: [CLLocationCoordinate2D] = [],
        mainAnnotationCoordinate: CLLocationCoordinate2D? = nil,
        mainAnnotationTitle: String? = nil,
        timelineItems: [TimelineItem] = [],
        photoAssets: [PHAsset] = [],
        heatmapPoints: [HeatmapPoint] = [],
        showsStandalonePhotos: Bool = false,
        prefersActivityIcons: Bool = false,
        condensesTransportOverview: Bool = false,
        clustersPlacesByMapScale: Bool = false,
        placeClusterRegion: MKCoordinateRegion? = nil,
        showsUserDefinedPlaceRadii: Bool = true,
        topContentInset: CGFloat = 0,
        bottomContentInset: CGFloat = 0,
        isMiniTimelineMode: Bool = false,
        selectedFootprintID: UUID? = nil,
        selectedFootprintCoordinate: CLLocationCoordinate2D? = nil,
        selectedTimeCoordinate: CLLocationCoordinate2D? = nil,
        timelineUpdateIdentifier: Int? = nil,
        onMapInteraction: ((MapInteractionType) -> Void)? = nil,
        showsMapControls: Bool = true,
        onTimelineItemTap: ((TimelineItem) -> Void)? = nil,
        onAggregatedFootprintTap: ((AggregatedFootprint) -> Void)? = nil,
        onPhotoTap: ((PHAsset) -> Void)? = nil,
        onUserLocationTap: (() -> Void)? = nil,
        onResetCamera: (() -> Void)? = nil
    ) {
        self._cameraPosition = cameraPosition
        self.rendersLiveMap = rendersLiveMap
        self.isInteractive = isInteractive
        self.allowsGeneratedSnapshot = allowsGeneratedSnapshot
        self.showsUserLocation = showsUserLocation
        self.points = points
        self.mainAnnotationCoordinate = mainAnnotationCoordinate
        self.mainAnnotationTitle = mainAnnotationTitle
        self.timelineItems = timelineItems
        self.photoAssets = photoAssets
        self.heatmapPoints = heatmapPoints
        self.showsStandalonePhotos = showsStandalonePhotos
        self.prefersActivityIcons = prefersActivityIcons
        self.condensesTransportOverview = condensesTransportOverview
        self.clustersPlacesByMapScale = clustersPlacesByMapScale
        self.placeClusterRegion = placeClusterRegion
        self.showsUserDefinedPlaceRadii = showsUserDefinedPlaceRadii
        self.topContentInset = topContentInset
        self.bottomContentInset = bottomContentInset
        self.isMiniTimelineMode = isMiniTimelineMode
        self.selectedFootprintID = selectedFootprintID
        self.selectedFootprintCoordinate = selectedFootprintCoordinate
        self.selectedTimeCoordinate = selectedTimeCoordinate
        self.timelineUpdateIdentifier = timelineUpdateIdentifier
        self.onMapInteraction = onMapInteraction
        self.showsMapControls = showsMapControls
        self.onTimelineItemTap = onTimelineItemTap
        self.onAggregatedFootprintTap = onAggregatedFootprintTap
        self.onPhotoTap = onPhotoTap
        self.onUserLocationTap = onUserLocationTap
        self.onResetCamera = onResetCamera
    }

    @State private var snapshotImage: UIImage?
    @State private var placeClusterVisibleRegion: MKCoordinateRegion?
    @State private var snapshotTask: Task<Void, Never>?
    @State private var isSnapshotLoading = false
    @State private var snapshotLoadFailed = false
    @State private var lastSnapshotSize: CGSize = .zero
    @State private var lastSnapshotCacheKey: String? = nil

    @State private var selectedAggregatedFootprint: AggregatedFootprint?
    @State private var footprintSelectedFromGroup: Footprint?
    @State private var interactiveMapReady = false
    @State private var interactiveActivationTask: Task<Void, Never>?
    @State private var liveMapPhotoImages: [String: UIImage] = [:]
    @State private var transportVisibleRegion: MKCoordinateRegion?
    /// Transport icon positions mid-way along the on-screen part of each
    /// route, computed off the main thread after each camera move.
    @State private var visibleTransportMidpoints: [UUID: CLLocationCoordinate2D] = [:]
    /// Transport icons hidden because they are near a same-type icon on screen.
    @State private var mergedTransportIconIDs: Set<UUID> = []
    @State private var transportMapWidth: CGFloat = 0
    // Review transport data, computed in background tasks and only read here.
    @State private var reviewTransportGeometry = DFKReviewTransportGeometry()
    @State private var reviewVisibleSegments: [DFKReviewTransportLine] = []
    /// Visible transport icons, selected off main for the current camera.
    @State private var reviewTransportIcons: [DFKTransportIconPoint] = []
    // Map content and footprint groups, built off main per input revision.
    @State private var mapContent = DFKMapContent()
    @State private var inferredRoutesRevision = TransportRouteCompletion.revision
    @State private var contentFootprints: [Footprint] = []
    @State private var aggregatedFootprints: [AggregatedFootprint] = []
    @State private var validAggregatedFootprints: [AggregatedFootprint] = []
    @State private var aggregatedSourceKey: String?
    @State private var liveMapPhotoAssetIDs: [String] = []
    @State private var liveMapPhotoAssetKey = 0
    @Environment(\.colorScheme) private var colorScheme

    private var hasVisibleContent: Bool {
        // Before the first content build, fall back to the raw inputs.
        let hasPhotos = mapContent.key == nil ? (showsStandalonePhotos && !photoAssets.isEmpty) : !validPhotoAnnotations.isEmpty
        let hasHeatmap = mapContent.key == nil ? !heatmapPoints.isEmpty : !validHeatmapPoints.isEmpty
        return !points.isEmpty ||
        validMainAnnotationCoordinate != nil ||
        !timelineItems.isEmpty ||
        hasPhotos ||
        hasHeatmap ||
        showsUserLocation
    }

    private var userDefinedPlaces: [DFKMapPlaceCircle] {
        mapContent.userDefinedPlaces
    }

    private var currentTopSafeAreaInset: CGFloat {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            if let keyWindow = windowScene.windows.first(where: { $0.isKeyWindow }) {
                return keyWindow.safeAreaInsets.top
            }
        }
        return 0
    }

    private var transportItems: [DFKMapTransportDisplay] {
        mapContent.transports
    }

    /// The sampled trajectory overview belongs only to Review. The footprint
    /// map must always render its own Transport records and inferred gaps.
    private var usesReviewTransportOverview: Bool {
        condensesTransportOverview && clustersPlacesByMapScale
    }

    private var renderedTransportSegments: [TransportLineSegment] {
        guard usesReviewTransportOverview else { return mapContent.transportSegments }
        return reviewTransportGeometry.segments
    }

    private var reviewTransportGeometryKey: String {
        guard usesReviewTransportOverview else { return "off" }
        return mapContent.key.map { String($0) } ?? "pending"
    }

    private var reviewTransportVisibleKey: String {
        guard let region = transportVisibleRegion ?? placeClusterRegion else { return "\(reviewTransportGeometry.key ?? "")#none" }
        return String(
            format: "%@#%.5f,%.5f,%.5f,%.5f#%.0f",
            reviewTransportGeometry.key ?? "",
            region.center.latitude, region.center.longitude, region.span.latitudeDelta, region.span.longitudeDelta,
            transportMapWidth
        )
    }

    /// Rebuilds the review transport geometry off the main thread whenever
    /// the timeline items change.
    private func refreshReviewTransportGeometry() async {
        let key = reviewTransportGeometryKey
        guard usesReviewTransportOverview, mapContent.key != nil else { return }
        let transports = mapContent.transports
        let task = Task.detached(priority: .userInitiated) {
            DFKReviewTransportGeometry.build(key: key, transports: transports)
        }
        let geometry = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        guard !Task.isCancelled, key == reviewTransportGeometryKey else { return }
        reviewTransportGeometry = geometry
    }

    /// Picks the transport lines and icons for the area on screen, off the
    /// main thread; anything off screen is left out.
    private func refreshReviewVisibleTransport() async {
        guard usesReviewTransportOverview,
              reviewTransportGeometry.key != nil,
              let region = transportVisibleRegion ?? placeClusterRegion else { return }
        let geometry = reviewTransportGeometry
        let baseCell = AppConfig.shared.reviewMapTrajectoryBaseCellDegrees
        let culls = isInteractive && transportVisibleRegion != nil
        let viewWidth = isInteractive ? transportMapWidth : 0
        let diameter = transportIconSize
        let task = Task.detached(priority: .userInitiated) {
            (
                segments: geometry.visibleSegments(in: region, baseCell: baseCell),
                icons: geometry.iconPoints(in: region, culls: culls, viewWidth: viewWidth, diameter: diameter)
            )
        }
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        guard !Task.isCancelled, geometry.key == reviewTransportGeometry.key else { return }
        reviewVisibleSegments = result.segments
        reviewTransportIcons = result.icons
    }

    private var renderedTransportAnnotationItems: [DFKMapTransportDisplay] {
        mapContent.annotationTransports
    }

    private var visibleTransportMidpointKey: String {
        guard isInteractive, !usesReviewTransportOverview, let region = transportVisibleRegion else { return "\(mapContent.key ?? 0)#none" }
        return String(
            format: "%ld#%.5f,%.5f,%.5f,%.5f#%.0f",
            mapContent.key ?? 0,
            region.center.latitude, region.center.longitude, region.span.latitudeDelta, region.span.longitudeDelta,
            transportMapWidth
        )
    }

    /// Moves each transport icon to the middle of the visible part of its
    /// route and merges nearby same-type icons, off the main thread.
    private func refreshVisibleTransportMidpoints() async {
        guard isInteractive, !usesReviewTransportOverview, let region = transportVisibleRegion else {
            visibleTransportMidpoints = [:]
            mergedTransportIconIDs = []
            return
        }
        let routes = renderedTransportAnnotationItems.map {
            (id: $0.id, coordinates: $0.coordinates, midpoint: $0.midpoint, type: $0.transport.currentType.rawValue)
        }
        let viewWidth = transportMapWidth
        let diameter = transportIconSize
        let result = await Task.detached(priority: .userInitiated) {
            var midpoints: [UUID: CLLocationCoordinate2D] = [:]
            for route in routes {
                midpoints[route.id] = route.coordinates.visibleDistanceMidpoint(in: region)
            }
            let placed = routes.compactMap { route in
                (midpoints[route.id] ?? route.midpoint).map { (id: route.id, coordinate: $0, type: route.type) }
            }
            let kept = MapTransportIconMerge.keptIndices(
                coordinates: placed.map(\.coordinate),
                types: placed.map(\.type),
                region: region,
                viewWidth: viewWidth,
                diameter: diameter
            )
            let keptIDs = Set(kept.map { placed[$0].id })
            return (midpoints: midpoints, merged: Set(placed.map(\.id)).subtracting(keptIDs))
        }.value
        guard !Task.isCancelled else { return }
        visibleTransportMidpoints = result.midpoints
        mergedTransportIconIDs = result.merged
    }

    private var displayedTransportIconPoints: [DFKTransportIconPoint] {
        reviewTransportIcons
    }

    private var validMainAnnotationCoordinate: CLLocationCoordinate2D? {
        guard let mainAnnotationCoordinate, mainAnnotationCoordinate.isRenderableMapCoordinate else { return nil }
        return mainAnnotationCoordinate
    }

    private var validPhotoAnnotations: [(asset: PHAsset, coordinate: CLLocationCoordinate2D)] {
        mapContent.photoAnnotations
    }

    private var validHeatmapPoints: [HeatmapPoint] {
        mapContent.heatmapPoints
    }

    private var interactiveRegion: MKCoordinateRegion? {
        var bounds = mapContent.interactiveBounds
        if let selectedTimeCoordinate, selectedTimeCoordinate.isRenderableMapCoordinate {
            bounds.add(selectedTimeCoordinate)
        }

        if bounds.isEmpty,
           showsUserLocation,
           let lastLoc = LocationManager.shared.lastLocation?.coordinate,
           lastLoc.isRenderableMapCoordinate {
            bounds.add(lastLoc)
        }

        return bounds.region(paddingFactor: 1.4)
    }

    /// Changes whenever the UIKit mini map's annotations or overlays would.
    private var stableMapContentToken: Int {
        var hasher = DFKMapKeyHasher()
        hasher.combine(mapContent.key ?? 0)
        hasher.combine(aggregatedSourceKey)
        hasher.combine(colorScheme == .dark)
        hasher.combine(validMainAnnotationCoordinate)
        hasher.combine(allActivities.count)
        for activity in allActivities {
            hasher.combine(activity.id)
            hasher.combine(activity.name)
            hasher.combine(activity.icon)
            hasher.combine(activity.colorHex)
        }
        return hasher.intValue
    }

    private var shouldDrawStandalonePhotosInSnapshot: Bool {
        mapContent.drawsStandalonePhotosInSnapshot
    }

    private func latestPhotoAssetID(for aggregated: AggregatedFootprint) -> String? {
        // 直接从足迹数据中提取，不依赖异步加载的 photoAssets 数组，确保渲染及时
        aggregated.latestPhotoAssetID
    }

    /// The region places are clustered on; nil when the map does not cluster.
    private var placeClusteringRegion: MKCoordinateRegion? {
        guard clustersPlacesByMapScale else { return nil }
        return placeClusterVisibleRegion ?? placeClusterRegion
    }

    private var placeClusteringRegionToken: String {
        guard let region = placeClusteringRegion else { return "none" }
        return String(
            format: "%.5f,%.5f,%.5f,%.5f",
            region.center.latitude, region.center.longitude, region.span.latitudeDelta, region.span.longitudeDelta
        )
    }

    private func aggregationKey(contentRevision: Int) -> String {
        "\(contentRevision)|\(placeClusteringRegionToken)"
    }

    /// Cheap fingerprints of every input the map content depends on, hashed
    /// from scalar fields (no string building). `content` is exact and drives
    /// the background rebuild; `snapshot` keeps the snapshot cache's historic
    /// precision (4 decimals, ongoing stays ignore their moving end time).
    private func mapInputRevisions(includeInferredRoutes: Bool = true) -> (content: Int, snapshot: Int) {
        // Full Review supplies a revision for the published range result.
        // Camera and clustering updates must not reread every SwiftData
        // footprint (including its decoded photo IDs) to rediscover that the
        // input is unchanged. Other maps retain their existing fingerprints.
        if isInteractive, usesReviewTransportOverview, let timelineUpdateIdentifier {
            var revision = DFKMapKeyHasher()
            if includeInferredRoutes { revision.combine(inferredRoutesRevision) }
            revision.combine(timelineUpdateIdentifier)
            revision.combine(timelineItems.count)
            revision.combine(allPlaces.count)
            revision.combine(photoAssets.count)
            revision.combine(points.count)
            revision.combine(heatmapPoints.count)
            revision.combine(mainAnnotationCoordinate)
            revision.combine(selectedFootprintID)
            revision.combine(selectedFootprintCoordinate)
            for flag in [clustersPlacesByMapScale, showsStandalonePhotos, showsUserDefinedPlaceRadii] {
                revision.combine(flag)
            }
            return (revision.intValue, revision.intValue)
        }
        var content = DFKMapKeyHasher()
        var snapshot = DFKMapKeyHasher()
        if includeInferredRoutes {
            content.combine(inferredRoutesRevision)
            snapshot.combine(inferredRoutesRevision)
        }
        for item in timelineItems {
            switch item {
            case .footprint(let footprint):
                let photoAssetIDs = footprint.photoAssetIDs
                let latitude = footprint.latitude
                let longitude = footprint.longitude
                content.combine(1)
                content.combine(footprint.footprintID)
                content.combine(footprint.startTime)
                content.combine(footprint.endTime)
                content.combine(latitude)
                content.combine(longitude)
                content.combine(footprint.placeID)
                content.combine(footprint.locationHash)
                content.combine(footprint.address)
                content.combine(footprint.countryCode)
                content.combine(footprint.countryName)
                content.combine(footprint.cityName)
                content.combine(photoAssetIDs.count)
                content.combine(photoAssetIDs.first)
                content.combine(footprint.activityTypeValue)

                snapshot.combine(1)
                snapshot.combine(footprint.footprintID)
                snapshot.combine(Int(footprint.startTime.timeIntervalSince1970))
                // 正在记录的临时停留会随时间跳动 endTime，避免它触发每次快照重建。
                snapshot.combine(footprint.locationHash == "ONGOING_STAY" ? -1 : Int(footprint.endTime.timeIntervalSince1970))
                snapshot.combineRounded(latitude)
                snapshot.combineRounded(longitude)
                snapshot.combine(footprint.placeID)
                snapshot.combine(footprint.locationHash)
                snapshot.combine(footprint.address)
                snapshot.combine(footprint.countryCode)
                snapshot.combine(footprint.countryName)
                snapshot.combine(footprint.cityName)
                snapshot.combine(photoAssetIDs.count)
                snapshot.combine(photoAssetIDs.first)
                snapshot.combine(footprint.activityTypeValue)
            case .transport(let transport):
                let points = transport.points
                let samples = [points.first, points.isEmpty ? nil : points[points.count / 2], points.last]
                content.combine(2)
                content.combine(transport.id)
                content.combine(transport.startTime)
                content.combine(transport.endTime)
                content.combine(transport.currentType.rawValue)
                content.combine(transport.distance)
                content.combine(points.count)
                content.combine(transport.pathPoints.count)
                samples.forEach { content.combine($0) }

                snapshot.combine(2)
                snapshot.combine(transport.id)
                snapshot.combine(Int(transport.startTime.timeIntervalSince1970))
                snapshot.combine(Int(transport.endTime.timeIntervalSince1970))
                snapshot.combine(transport.currentType.rawValue)
                snapshot.combine(points.count)
                snapshot.combine(transport.pathPoints.count)
                samples.forEach { snapshot.combineRounded($0) }
            }
        }

        content.combine(allPlaces.count)
        snapshot.combine(allPlaces.count)
        for place in allPlaces {
            content.combine(place.placeID)
            content.combine(place.name)
            content.combine(place.latitude)
            content.combine(place.longitude)
            content.combine(Double(place.radius))
            content.combine(place.isUserDefined)
            snapshot.combine(place.placeID)
            snapshot.combine(place.name)
            snapshot.combineRounded(place.latitude)
            snapshot.combineRounded(place.longitude)
            snapshot.combine(Double(place.radius))
            snapshot.combine(place.isUserDefined)
        }

        content.combine(points.count)
        for point in [points.first, points.isEmpty ? nil : points[points.count / 2], points.last] {
            content.combine(point)
        }
        snapshot.combine(points.count)
        points.prefix(12).forEach { snapshot.combineRounded($0) }

        content.combine(photoAssets.count)
        snapshot.combine(photoAssets.count)
        for (index, asset) in photoAssets.enumerated() {
            content.combine(asset.localIdentifier)
            if index < 8 {
                snapshot.combine(asset.localIdentifier)
            }
        }

        content.combine(heatmapPoints.count)
        snapshot.combine(heatmapPoints.count)
        for point in heatmapPoints {
            content.combine(point.id)
            content.combine(point.intensity)
            content.combine(point.maxIntensity)
            snapshot.combine(point.id)
            snapshot.combine(point.intensity)
            snapshot.combine(point.maxIntensity)
        }

        content.combine(mainAnnotationCoordinate)
        snapshot.combineRounded(mainAnnotationCoordinate)
        content.combine(selectedFootprintID)
        snapshot.combine(selectedFootprintID)
        content.combine(selectedFootprintCoordinate)
        snapshot.combineRounded(selectedFootprintCoordinate)
        for flag in [clustersPlacesByMapScale, usesReviewTransportOverview, showsStandalonePhotos, showsUserDefinedPlaceRadii] {
            content.combine(flag)
            snapshot.combine(flag)
        }
        return (content.intValue, snapshot.intValue)
    }

    /// Reads the inputs as plain values, builds the map content off main and
    /// stores it; body only reads the result.
    private func refreshMapContent(revision: Int) async {
        var footprints: [Footprint] = []
        var transports: [Transport] = []
        for item in timelineItems {
            switch item {
            case .footprint(let footprint):
                footprints.append(footprint)
            case .transport(let transport):
                transports.append(transport)
            }
        }
        let footprintInputs = footprints.map { footprint in
            DFKMapFootprintInput(
                footprintID: footprint.footprintID,
                latitude: footprint.latitude,
                longitude: footprint.longitude,
                duration: footprint.duration,
                startTime: footprint.startTime,
                placeID: footprint.placeID,
                locationHash: footprint.locationHash,
                address: footprint.address,
                countryCode: footprint.countryCode,
                countryName: footprint.countryName,
                cityName: footprint.cityName,
                firstPhotoAssetID: footprint.photoAssetIDs.first
            )
        }
        let placeInputs = allPlaces.map { place in
            DFKMapPlaceInput(
                placeID: place.placeID,
                name: place.name,
                latitude: place.latitude,
                longitude: place.longitude,
                radius: Double(place.radius),
                isUserDefined: place.isUserDefined
            )
        }
        let request = DFKMapContentBuilder.Request(
            key: revision,
            footprints: footprintInputs,
            places: placeInputs,
            transports: transports,
            points: points,
            mainAnnotationCoordinate: mainAnnotationCoordinate,
            photoAssets: photoAssets,
            heatmapPoints: heatmapPoints,
            showsStandalonePhotos: showsStandalonePhotos,
            showsUserDefinedPlaceRadii: showsUserDefinedPlaceRadii,
            clustersPlacesByMapScale: clustersPlacesByMapScale,
            usesReviewTransportOverview: usesReviewTransportOverview,
            selectedFootprintID: selectedFootprintID,
            selectedFootprintCoordinate: selectedFootprintCoordinate
        )
        let content = await Task.detached(priority: .userInitiated) {
            DFKMapContentBuilder.build(request)
        }.value
        guard !Task.isCancelled else { return }
        contentFootprints = footprints
        mapContent = content
    }

    /// Groups the built places for the current cluster region off main, then
    /// maps footprint indices back to the models.
    private func refreshAggregatedFootprints() async {
        guard let contentKey = mapContent.key else { return }
        let content = mapContent
        let footprints = contentFootprints
        let region = placeClusteringRegion
        let sourceKey = aggregationKey(contentRevision: contentKey)
        let result = await Task.detached(priority: .userInitiated) { () -> (groups: [DFKMapFootprintGroup], photoIDs: [String], photoKey: Int) in
            let groups = DFKMapContentBuilder.aggregatedGroups(
                places: content.placeGroups,
                footprints: content.footprints,
                region: region
            )
            let footprintIDs = groups.compactMap(\.latestPhotoAssetID)
            let standaloneIDs = content.photoAnnotations.map { $0.asset.localIdentifier }
            let photoIDs = Array(Set(footprintIDs + standaloneIDs)).sorted()
            var hasher = DFKMapKeyHasher()
            photoIDs.forEach { hasher.combine($0) }
            return (groups, photoIDs, hasher.intValue)
        }.value
        guard !Task.isCancelled, mapContent.key == contentKey, footprints.count == content.footprints.count else { return }
        let aggregated = result.groups.map { group in
            AggregatedFootprint(
                id: group.id,
                coordinate: group.coordinate,
                totalDuration: group.totalDuration,
                representative: footprints[group.representativeIndex],
                footprints: group.memberIndices.map { footprints[$0] },
                placeCount: group.placeCount,
                latestPhotoAssetID: group.latestPhotoAssetID
            )
        }
        aggregatedFootprints = aggregated
        validAggregatedFootprints = aggregated.filter { $0.coordinate.isRenderableMapCoordinate }
        liveMapPhotoAssetIDs = result.photoIDs
        liveMapPhotoAssetKey = result.photoKey
        aggregatedSourceKey = sourceKey
    }

    var body: some View {
        GeometryReader { geometry in
            let isValidSize = geometry.size.width > 1 && geometry.size.height > 1
            let revisions = mapInputRevisions()
            let isAggregationCurrent = aggregatedSourceKey == aggregationKey(contentRevision: revisions.content)

            ZStack {
                Group {
                    if isInteractive && isValidSize && rendersLiveMap && interactiveMapReady {
                        if isMiniTimelineMode {
                            StableInteractiveMapView(
                                region: interactiveRegion,
                                showsUserLocation: showsUserLocation,
                                userDefinedPlaces: userDefinedPlaces,
                                transportItems: transportItems,
                                aggregatedFootprints: validAggregatedFootprints,
                                photoAnnotations: validPhotoAnnotations,
                                heatmapPoints: validHeatmapPoints,
                                mainAnnotationCoordinate: validMainAnnotationCoordinate,
                                selectedTimeCoordinate: selectedTimeCoordinate,
                                allActivities: allActivities,
                                colorScheme: colorScheme,
                                contentToken: stableMapContentToken,
                                onFootprintTap: handleFootprintTap(for:),
                                onTransportTap: { transport in
                                    onTimelineItemTap?(.transport(transport))
                                },
                                onPhotoTap: { asset in
                                    onPhotoTap?(asset)
                                },
                                onUserLocationTap: onUserLocationTap
                            )
                        } else {
                            Map(position: $cameraPosition) {
                                if showsUserDefinedPlaceRadii {
                                    ForEach(userDefinedPlaces) { place in
                                        MapCircle(center: place.coordinate, radius: max(5, min(place.radius, 10_000)))
                                            .foregroundStyle(Color.orange.opacity(0.1))
                                            .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                                    }
                                }

                                transportMapContent()

                                ForEach(validAggregatedFootprints) { aggregated in
                                    Annotation("", coordinate: aggregated.coordinate, anchor: .bottom) {
                                        aggregatedAnnotationContent(for: aggregated)
                                            .mapAnnotationLayer(MapAnnotationLayer.footprint)
                                            .onTapGesture {
                                                handleFootprintTap(for: aggregated)
                                            }
                                    }
                                }

                                ForEach(validPhotoAnnotations, id: \.asset.localIdentifier) { entry in
                                    Annotation("", coordinate: entry.coordinate, anchor: .bottom) {
                                        Button {
                                            onPhotoTap?(entry.asset)
                                        } label: {
                                            photoAnnotationContent(for: entry.asset)
                                                .mapAnnotationLayer(MapAnnotationLayer.photo)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }

                                ForEach(validHeatmapPoints) { point in
                                    Annotation("", coordinate: point.coordinate) {
                                        heatmapAnnotationContent(for: point)
                                    }
                                }

                                if let coordinate = validMainAnnotationCoordinate {
                                    Annotation(mainAnnotationTitle ?? "", coordinate: coordinate) {
                                        Circle()
                                            .fill(Color.dfkAccent)
                                            .frame(width: isInteractive ? 18 : 14, height: isInteractive ? 18 : 14)
                                            .overlay(Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 2))
                                    }
                                }

                                if let coordinate = selectedTimeCoordinate, coordinate.isRenderableMapCoordinate {
                                    Annotation("", coordinate: coordinate) {
                                        Circle()
                                            .fill(Color.orange)
                                            .frame(width: 16, height: 16)
                                            .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
                                    }
                                }

                                if showsUserLocation {
                                    UserAnnotation()
                                }
                            }
                            .id(timelineUpdateIdentifier ?? 0)
                            .mapStyle(.standard(elevation: .automatic, emphasis: .muted))
                            .onMapCameraChange(frequency: .onEnd) { context in
                                transportVisibleRegion = context.region
                                if clustersPlacesByMapScale {
                                    placeClusterVisibleRegion = context.region
                                }
                            }
                            // Handle taps on the map surface itself. Native map
                            // controls are subviews and must keep their own taps
                            // without forwarding them to the host's collapse action.
                            .simultaneousGesture(
                                TapGesture().onEnded { onMapInteraction?(.tap) },
                                including: .gesture
                            )
                            .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { _ in onMapInteraction?(.pan) })
                            .simultaneousGesture(MagnificationGesture().onChanged { _ in onMapInteraction?(.zoom) })
                            .mapControls {
                                if showsMapControls {
                                    if showsUserLocation {
                                        MapUserLocationButton()
                                    }
                                    MapCompass()
                                    MapScaleView()
                                }
                            }
                            .safeAreaPadding(.top, currentTopSafeAreaInset)
                            .overlay(alignment: .topTrailing) {
                                if showsMapControls, let onResetCamera {
                                    Button(action: onResetCamera) {
                                        Image(systemName: "viewfinder")
                                            .font(.system(size: 17, weight: .semibold))
                                            .frame(width: 32, height: 32)
                                    }
                                    .mapLocationButtonStyle()
                                    .buttonBorderShape(.circle)
                                    .tint(.primary)
                                    .accessibilityLabel("恢复视野")
                                    // MapKit's location button (44pt) starts 16pt below
                                    // the padded safe area; sit one 12pt control gap
                                    // above it, matching the gap down to the compass.
                                    .padding(.top, max(0, currentTopSafeAreaInset + 16 - 12 - 44))
                                    .padding(.trailing, 16)
                                }
                            }
                        }
                    } else {
                        snapshotContent(for: geometry.size)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .sheet(item: $selectedAggregatedFootprint, onDismiss: {
                guard let footprint = footprintSelectedFromGroup else { return }
                footprintSelectedFromGroup = nil
                onTimelineItemTap?(.footprint(footprint))
            }) { aggregated in
                FootprintGroupSheet(aggregated: aggregated, allPlaces: allPlaces) { footprint in
                    footprintSelectedFromGroup = footprint
                    selectedAggregatedFootprint = nil
                }
            }
            .onAppear {
                guard isInteractive else { return }
                interactiveActivationTask?.cancel()
                interactiveMapReady = false
                interactiveActivationTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 180_000_000)
                    if Task.isCancelled { return }
                    interactiveMapReady = true
                }
            }
            .task(id: revisions.content) {
                await refreshMapContent(revision: revisions.content)
            }
            .task(id: mapInputRevisions(includeInferredRoutes: false).content) {
                // Open/range changes enqueue once. Route-completion revisions
                // redraw geometry without cancelling admission or retrying failures again.
                let items = timelineItems
                let transports = await Task.detached(priority: .utility) {
                    items.compactMap { item -> Transport? in
                        guard case .transport(let transport) = item else { return nil }
                        return transport
                    }
                }.value
                guard !Task.isCancelled else { return }
                await TransportRouteCompletion.prepare(transports)
            }
            .onReceive(NotificationCenter.default.publisher(for: TransportRouteCompletion.didChange)) { _ in
                // Live maps can redraw each route. Snapshot cards must finish
                // their first frame instead of restarting for every queued gap.
                guard isInteractive else { return }
                inferredRoutesRevision = TransportRouteCompletion.revision
            }
            .onReceive(NotificationCenter.default.publisher(for: TransportRouteCompletion.didFinishBatch)) { _ in
                guard !isInteractive else { return }
                inferredRoutesRevision = TransportRouteCompletion.revision
            }
            .task(id: "\(mapContent.key ?? 0)|\(mapContent.key == nil)|\(placeClusteringRegionToken)") {
                await refreshAggregatedFootprints()
            }
            .task(id: isInteractive ? nil : "\(snapshotCacheKey(for: geometry.size, snapshotRevision: revisions.snapshot))#generate:\(allowsGeneratedSnapshot)#ready:\(isAggregationCurrent)") {
                guard !isInteractive else { return }
                loadSnapshot(for: geometry.size, forceWidgetRefresh: false)
            }
            .onChange(of: colorScheme) { _, _ in
                guard !isInteractive else { return }
                snapshotTask?.cancel()
                snapshotImage = nil
                snapshotLoadFailed = false
                loadSnapshot(for: geometry.size, forceWidgetRefresh: false)
            }
            .task(id: reviewTransportGeometryKey) {
                await refreshReviewTransportGeometry()
            }
            .task(id: reviewTransportVisibleKey) {
                await refreshReviewVisibleTransport()
            }
            .task(id: visibleTransportMidpointKey) {
                await refreshVisibleTransportMidpoints()
            }
            .onChange(of: geometry.size.width, initial: true) { _, width in
                transportMapWidth = width
            }
            .task(id: liveMapPhotoAssetKey) {
                guard isInteractive else { return }
                await loadLiveMapPhotoImages()
            }
            .onDisappear {
                interactiveActivationTask?.cancel()
                interactiveMapReady = false
                snapshotTask?.cancel()
                isSnapshotLoading = false
            }
        }
    }

    private func handleFootprintTap(for aggregated: AggregatedFootprint) {
        if aggregated.footprints.count > 1 {
            if let onAggregatedFootprintTap {
                onAggregatedFootprintTap(aggregated)
            } else {
                selectedAggregatedFootprint = aggregated
            }
            return
        }

        guard let footprint = aggregated.footprints.first else { return }
        onTimelineItemTap?(.footprint(footprint))
    }

    @ViewBuilder
    private func snapshotContent(for size: CGSize) -> some View {
        if let snapshotImage {
            Image(uiImage: snapshotImage)
                .resizable()
                .scaledToFill()
                .clipped()
        } else {
            placeholderView
        }
    }

    private var placeholderView: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(uiColor: .secondarySystemBackground),
                    Color(uiColor: .tertiarySystemBackground)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(spacing: 8) {
                Image(systemName: hasVisibleContent ? "map" : "map.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.secondary.opacity(0.55))

                if !hasVisibleContent {
                    Text("暂无地图数据")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if isSnapshotLoading || (isInteractive && !interactiveMapReady) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.secondary)
                } else if snapshotLoadFailed {
                    VStack(spacing: 6) {
                        Text("地图加载失败")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Button("重试") {
                            triggerSnapshotRetry()
                        }
                        .font(.caption2)
                    }
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.secondary)
                }
            }
        }
        .clipped()
    }

    private func formatDuration(_ duration: TimeInterval) -> (number: String, unit: String) {
        let totalMinutes = Int(duration / 60)
        if totalMinutes < 60 {
            return ("\(max(1, totalMinutes))", "分钟")
        }
        let hours = Double(totalMinutes) / 60.0
        if hours >= 10.0 {
            return ("\(Int(round(hours)))", "小时")
        }
        let formatted = String(format: "%g", (hours * 10).rounded() / 10)
        return (formatted, "小时")
    }

    @ViewBuilder
    private func aggregatedAnnotationContent(for aggregated: AggregatedFootprint) -> some View {
        if clustersPlacesByMapScale {
            reviewPlaceAnnotationContent(for: aggregated)
        } else {
            standardFootprintAnnotationContent(for: aggregated)
        }
    }

    @ViewBuilder
    private func reviewPlaceAnnotationContent(for aggregated: AggregatedFootprint) -> some View {
        // Zoomed in to a single place, it is just a footprint: show it the
        // way every footprint map does, with its activity icon.
        if aggregated.placeCount == 1 {
            standardFootprintAnnotationContent(for: aggregated, showsPhoto: false)
        } else {
            DFKReviewPlaceMapMarker(
                placeCount: aggregated.placeCount,
                photoImage: latestPhotoAssetID(for: aggregated).flatMap { liveMapPhotoImages[$0] }
            )
        }
    }

    private func standardFootprintAnnotationContent(for aggregated: AggregatedFootprint, showsPhoto: Bool? = nil) -> some View {
        let fp = aggregated.representative
        let isSelected = aggregated.footprints.contains { $0.footprintID == selectedFootprintID }
        let constantScale: CGFloat = 1.32
        let baseSize: CGFloat = isInteractive ? 25 : 20
        let size = isMiniTimelineMode ? 11 : baseSize * constantScale
        let activity = fp.getActivityType(from: allActivities)
        let activityColor = activity?.color ?? Color.gray
        let iconColor: Color = .white
        let iconName = activity?.icon ?? FootprintIconDefaults.card
        let iconSize: CGFloat = isMiniTimelineMode ? 9 : (activity?.icon == nil ? 18 : 10) * constantScale
        let durationTuple = formatDuration(aggregated.totalDuration)
        let fontSize = isInteractive ? 6.5 * constantScale : 5.5 * constantScale

        let photoImage = (showsPhoto ?? !prefersActivityIcons)
            ? latestPhotoAssetID(for: aggregated).flatMap { liveMapPhotoImages[$0] }
            : nil
        return DFKFootprintMapMarker(
            size: size,
            constantScale: constantScale,
            activityColor: activityColor,
            iconColor: iconColor,
            iconName: iconName,
            iconSize: iconSize,
            photoImage: photoImage,
            durationTuple: isMiniTimelineMode || aggregated.totalDuration < AppConfig.shared.stayDurationThreshold ? nil : durationTuple,
            fontSize: fontSize
        )
        .scaleEffect(isSelected ? 1.5 : 1.0, anchor: .bottom)
        .contentShape(Rectangle())
        .animation(.spring(response: 0.6, dampingFraction: 0.7), value: selectedFootprintID)
    }

    private var transportIconSize: CGFloat {
        isMiniTimelineMode ? 7 : (isInteractive ? 18 : 14)
    }

    @ViewBuilder
    private func transportAnnotationContent(for display: DFKMapTransportDisplay) -> some View {
        let transport = display.transport
        let size = transportIconSize
        let iconSize: CGFloat = isMiniTimelineMode ? 4 : (isInteractive ? 9 : 7)
        
        let transportIcon = ZStack {
            Circle()
                .fill(Color(uiColor: .systemBackground))
                .frame(width: size, height: size)
                .overlay(Circle().stroke(Color.dfkAccent, lineWidth: 1.2))

            Image(systemName: transport.currentType.sfSymbol)
                .font(.system(size: iconSize, weight: .bold))
                .foregroundColor(Color.dfkAccent)
                .scaleEffect(x: display.travelsWest ? -1 : 1, y: 1)
        }
        .contentShape(Circle())

        if let onTimelineItemTap {
            transportIcon
                .onTapGesture {
                    onTimelineItemTap(.transport(transport))
                }
        } else {
            transportIcon
        }
    }

    private func transportOverviewIcon(_ point: DFKTransportIconPoint) -> some View {
        // Same size as the footprint map's interactive transport icons.
        Circle()
            .fill(Color(uiColor: .systemBackground))
            .frame(width: 18, height: 18)
            .overlay(Circle().stroke(Color.dfkAccent, lineWidth: 1.2))
            .overlay {
                Image(systemName: point.type.sfSymbol)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.dfkAccent)
                    .scaleEffect(x: point.travelsWest ? -1 : 1, y: 1)
            }
    }

    @MapContentBuilder
    private func transportMapContent() -> some MapContent {
        if usesReviewTransportOverview {
            ForEach(reviewVisibleSegments) { segment in
                MapPolyline(segment.polyline)
                    .stroke(
                        Color.dfkAccent.opacity(segment.isDashed ? 0.4 : 0.65),
                        style: StrokeStyle(
                            lineWidth: segment.isDashed ? 1 : 2.5,
                            lineCap: .round,
                            lineJoin: .round,
                            dash: segment.isDashed ? [4, 4] : []
                        )
                    )
            }

            ForEach(displayedTransportIconPoints) { point in
                Annotation("", coordinate: point.coordinate) {
                    transportOverviewIcon(point)
                        .mapAnnotationLayer(MapAnnotationLayer.transport)
                }
            }
        } else {
            ForEach(renderedTransportSegments) { segment in
                MapPolyline(coordinates: segment.coordinates)
                    .stroke(
                        Color.dfkAccent.opacity(segment.isDashed ? 0.4 : 0.7),
                        style: StrokeStyle(
                            lineWidth: segment.isDashed ? 1 : (isInteractive ? 3 : 2),
                            lineCap: .round,
                            lineJoin: .round,
                            dash: segment.isDashed ? [4, 4] : []
                        )
                    )
            }

            ForEach(renderedTransportAnnotationItems) { display in
                if !mergedTransportIconIDs.contains(display.id),
                   let coord = visibleTransportMidpoints[display.id] ?? display.midpoint {
                    Annotation("", coordinate: coord) {
                        transportAnnotationContent(for: display)
                            .mapAnnotationLayer(MapAnnotationLayer.transport)
                    }
                }
            }
        }
    }



    @MapContentBuilder
    private func photoAnnotations() -> some MapContent {
        ForEach(photoAssets, id: \.localIdentifier) { asset in
            if let coord = asset.location?.gcj02.coordinate {
                Annotation("", coordinate: coord, anchor: .bottom) {
                    photoAnnotationContent(for: asset)
                }
            }
        }
    }

    private func heatmapAnnotationContent(for point: HeatmapPoint) -> some View {
        let rawRatio = Double(point.intensity) / Double(max(1, point.maxIntensity))
        let ratio = pow(rawRatio, 0.4)
        let color: Color = {
            if point.maxIntensity <= 1 {
                return .orange
            } else if ratio < 0.25 {
                return .orange
            } else if ratio < 0.85 {
                return .red
            } else {
                return .dfkDeepRed
            }
        }()

        let baseSize: CGFloat = isInteractive ? 30 : 14
        let multiplier: CGFloat = isInteractive ? 8 : 3
        let maxSize: CGFloat = isInteractive ? 80 : 30
        let size = CGFloat(max(baseSize, min(maxSize, CGFloat(point.intensity) * multiplier)))

        return Circle()
            .fill(
                RadialGradient(
                    colors: [color.opacity(0.7), color.opacity(0.15)],
                    center: .center,
                    startRadius: 0,
                    endRadius: size / 2
                )
            )
            .frame(width: size, height: size)
    }

    @ViewBuilder
    private func photoAnnotationContent(for asset: PHAsset) -> some View {
        let size: CGFloat = isInteractive ? 60 : 46
        let cornerRadius: CGFloat = isInteractive ? 8 : 6
        let tipHeight: CGFloat = isInteractive ? 10 : 8
        let contentInset: CGFloat = 4
        let contentSize = size - contentInset * 2
        let content = ZStack(alignment: .top) {
            PhotoMapMarkerShape(cornerRadius: cornerRadius, tipHeight: tipHeight)
                .fill(Color(uiColor: .systemBackground))
                .shadow(color: .black.opacity(0.18), radius: 3, x: 0, y: 2)
                .frame(width: size, height: size + tipHeight)

            ZStack {
                Color(uiColor: .systemGray6)
                if let image = liveMapPhotoImages[asset.localIdentifier] {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "photo")
                        .font(.caption)
                        .foregroundColor(Color(uiColor: .systemGray))
                }
            }
            .frame(width: contentSize, height: contentSize)
            .clipShape(RoundedRectangle(cornerRadius: max(2, cornerRadius - 2), style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: max(2, cornerRadius - 2), style: .continuous)
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 0.8)
            }
            .offset(y: contentInset)
        }
        .overlay {
            PhotoMapMarkerShape(cornerRadius: cornerRadius, tipHeight: tipHeight)
                .stroke(Color(uiColor: .systemBackground), lineWidth: 1.5)
                .frame(width: size, height: size + tipHeight)
        }
        .frame(width: size, height: size + tipHeight)
        .contentShape(Rectangle())

        if let onPhotoTap {
            content
                .onTapGesture {
                    onPhotoTap(asset)
                }
        } else {
            content
        }
    }

    private func snapshotCacheKey(for size: CGSize, snapshotRevision: Int) -> String {
        let w = Int(size.width / 10) * 10
        let h = Int(size.height / 10) * 10
        let sizeKey = "\(w)x\(h)"
        let styleKey = colorScheme == .dark ? "dark" : "light"
        let insetKey = "inset:\(Int(topContentInset.rounded())):\(Int(bottomContentInset.rounded()))"
        let routeStyleKey = usesReviewTransportOverview
            ? "review-routes-share-style-v3:\(reviewTransportGeometry.key ?? "pending"):\(reviewTransportIcons.count)"
            : "standard-transport-routes-dashed-v3"
        if let timelineUpdateIdentifier {
            return [
                FootprintIconDefaults.mapSnapshotVersion,
                sizeKey,
                styleKey,
                insetKey,
                routeStyleKey,
                "timeline:\(timelineUpdateIdentifier)",
                "routes:\(inferredRoutesRevision)",
                showsUserLocation ? "user" : "nouser"
            ].joined(separator: "#")
        }

        // Footprints, transports, places, photos, heatmap, annotation and
        // selection are covered by the input fingerprint; the cluster grid
        // depends on the region it is laid out on.
        let contentKey = "content-v2:\(String(snapshotRevision, radix: 36))"
        let placeClusterKey = clustersPlacesByMapScale ? "place-clusters:\(placeClusteringRegionToken)" : "no-place-clusters"
        return [FootprintIconDefaults.mapSnapshotVersion, sizeKey, styleKey, insetKey, routeStyleKey, showsUserDefinedPlaceRadii ? "place-radii" : "no-place-radii", contentKey, placeClusterKey, showsUserLocation ? "user" : "nouser"].joined(separator: "#")
    }

    private func loadSnapshot(for size: CGSize, forceWidgetRefresh: Bool = false) {
        lastSnapshotSize = size

        guard size.width > 1, size.height > 1, hasVisibleContent else {
            isSnapshotLoading = false
            snapshotLoadFailed = false
            snapshotImage = nil
            return
        }

        let revisions = mapInputRevisions()
        let cacheKey = snapshotCacheKey(for: size, snapshotRevision: revisions.snapshot)
        let isContentCurrent = aggregatedSourceKey == aggregationKey(contentRevision: revisions.content)
        if !forceWidgetRefresh, let cached = DFKMapSnapshotCache.shared.memoryImage(for: cacheKey) {
            snapshotTask?.cancel()
            isSnapshotLoading = false
            snapshotLoadFailed = false
            lastSnapshotCacheKey = cacheKey
            snapshotImage = cached
            return
        }

        snapshotTask?.cancel()
        // 保留上一帧，避免频繁刷新时出现闪白/占位图跳变。
        snapshotTask = Task { @MainActor in
            if !forceWidgetRefresh, let cached = await DFKMapSnapshotCache.shared.imageAsync(for: cacheKey) {
                if Task.isCancelled { return }
                isSnapshotLoading = false
                snapshotLoadFailed = false
                lastSnapshotCacheKey = cacheKey
                snapshotImage = cached
                return
            }
            if Task.isCancelled { return }

            guard allowsGeneratedSnapshot else {
                isSnapshotLoading = false
                snapshotLoadFailed = false
                snapshotImage = nil
                return
            }

            // The content for these inputs is still being built off main; the
            // snapshot task runs again once it is ready.
            guard isContentCurrent else {
                isSnapshotLoading = true
                snapshotLoadFailed = false
                return
            }

            isSnapshotLoading = true
            snapshotLoadFailed = false
            guard let image = await buildSnapshotImageWithTimeout(size: size, timeoutSeconds: 12) else {
                if Task.isCancelled { return }
                isSnapshotLoading = false
                snapshotLoadFailed = true
                return
            }
            if Task.isCancelled { return }
            DFKMapSnapshotCache.shared.setImage(image, for: cacheKey)
            lastSnapshotCacheKey = cacheKey
            snapshotImage = image
            isSnapshotLoading = false
            snapshotLoadFailed = false
        }
    }

    private func triggerSnapshotRetry() {
        snapshotTask?.cancel()
        snapshotImage = nil
        isSnapshotLoading = false
        snapshotLoadFailed = false
        if lastSnapshotSize.width > 1, lastSnapshotSize.height > 1 {
            loadSnapshot(for: lastSnapshotSize, forceWidgetRefresh: true)
        }
    }

    private func buildSnapshotImageWithTimeout(size: CGSize, timeoutSeconds: UInt64) async -> UIImage? {
        await withTaskGroup(of: UIImage?.self) { group in
            group.addTask {
                await buildSnapshotImage(size: size)
            }

            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                return nil
            }

            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    /// Photos, map tiles and drawing all run off main; only the SwiftUI
    /// marker images (ImageRenderer) are rendered here on the main actor.
    @MainActor
    private func buildSnapshotImage(size: CGSize) async -> UIImage? {
        guard let region = snapshotRegion(for: size) else { return nil }

        let aggregated = aggregatedFootprints
        let footprintPhotoIDs = Array(Set(aggregated.compactMap { latestPhotoAssetID(for: $0) }))
        let standalonePhotoIDs = Array(Set(photoAssets.map(\.localIdentifier)))
        let footprintPhotoImages = await Task.detached(priority: .userInitiated) {
            await DFKMapPhotoImageLoader.images(for: footprintPhotoIDs, targetSize: CGSize(width: 88, height: 88), highQuality: true)
        }.value
        let standalonePhotoImages = await Task.detached(priority: .userInitiated) {
            await DFKMapPhotoImageLoader.images(for: standalonePhotoIDs, targetSize: CGSize(width: 80, height: 80), highQuality: true)
        }.value

        let scale = UIScreen.main.scale
        let options = MKMapSnapshotter.Options()
        options.region = region
        options.size = size
        options.scale = scale
        options.traitCollection = UITraitCollection(
            userInterfaceStyle: colorScheme == .dark ? .dark : .light
        )

        let snapshotter = MKMapSnapshotter(options: options)
        guard let snapshot = try? await snapshotter.start() else { return nil }
        if Task.isCancelled { return nil }

        let renderedFootprintMarkers: [(coordinate: CLLocationCoordinate2D, image: UIImage)] = aggregated.compactMap { aggregated in
            let footprint = aggregated.representative
            let activity = footprint.getActivityType(from: allActivities)
            let constantScale: CGFloat = 1.32
            let size: CGFloat = 20 * constantScale
            let marker: AnyView
            if clustersPlacesByMapScale, aggregated.placeCount > 1 {
                marker = AnyView(DFKReviewPlaceMapMarker(
                    placeCount: aggregated.placeCount,
                    photoImage: latestPhotoAssetID(for: aggregated).flatMap { footprintPhotoImages[$0] }
                ))
            } else {
                marker = AnyView(DFKFootprintMapMarker(
                    size: size,
                    constantScale: constantScale,
                    activityColor: activity?.color ?? .gray,
                    iconColor: .white,
                    iconName: activity?.icon ?? FootprintIconDefaults.card,
                    iconSize: (activity?.icon == nil ? 18 : 10) * constantScale,
                    // A single review place is drawn as its footprint's activity icon.
                    photoImage: prefersActivityIcons || clustersPlacesByMapScale
                        ? nil
                        : latestPhotoAssetID(for: aggregated).flatMap { footprintPhotoImages[$0] },
                    durationTuple: aggregated.totalDuration >= AppConfig.shared.stayDurationThreshold
                        ? formatDuration(aggregated.totalDuration)
                        : nil,
                    fontSize: 5.5 * constantScale
                ))
            }
            let imageRenderer = ImageRenderer(content: marker.environment(\.colorScheme, colorScheme))
            imageRenderer.scale = scale
            guard let image = imageRenderer.uiImage else { return nil }
            return (aggregated.coordinate, image)
        }

        let standalonePhotos: [(coordinate: CLLocationCoordinate2D, image: UIImage)] = shouldDrawStandalonePhotosInSnapshot
            ? validPhotoAnnotations.compactMap { entry in
                standalonePhotoImages[entry.asset.localIdentifier].map { (coordinate: entry.coordinate, image: $0) }
            }
            : []
        let drawing = DFKMapSnapshotDrawing(
            snapshot: snapshot,
            region: region,
            size: size,
            scale: scale,
            isDark: colorScheme == .dark,
            themeColor: UIColor(named: "AccentColor") ?? .systemTeal,
            deepRedColor: UIColor(Color.dfkDeepRed),
            placeCircles: mapContent.snapshotPlaceCircles,
            usesReviewTransportOverview: usesReviewTransportOverview,
            segments: renderedTransportSegments,
            iconPoints: displayedTransportIconPoints,
            annotationTransports: renderedTransportAnnotationItems,
            footprintMarkers: renderedFootprintMarkers,
            heatmapPoints: heatmapPoints,
            standalonePhotos: standalonePhotos,
            mainAnnotationCoordinate: mainAnnotationCoordinate
        )
        return await Task.detached(priority: .userInitiated) {
            drawing.render()
        }.value
    }

    private func snapshotRegion(for size: CGSize) -> MKCoordinateRegion? {
        var bounds = mapContent.snapshotBounds
        if bounds.isEmpty, showsUserLocation, let lastLoc = LocationManager.shared.lastLocation?.coordinate {
            bounds.add(lastLoc)
        }

        guard var region = bounds.region(paddingFactor: 1.6) else { return nil }
        if size.width > size.height {
            region.span.longitudeDelta *= 1.5
        }
        let verticalContentInset = topContentInset + bottomContentInset
        if verticalContentInset > 0, size.height > verticalContentInset {
            let visibleFraction = (size.height - verticalContentInset) / size.height
            let originalLatitudeDelta = region.span.latitudeDelta
            region.span.latitudeDelta = originalLatitudeDelta / visibleFraction
            region.center.latitude += region.span.latitudeDelta
                * ((topContentInset - bottomContentInset) / size.height)
                / 2
        }
        return region
    }

    @MainActor
    private func loadLiveMapPhotoImages() async {
        let assetIDs = liveMapPhotoAssetIDs
        guard !assetIDs.isEmpty else {
            liveMapPhotoImages = [:]
            return
        }

        let neededIDs = assetIDs.filter { liveMapPhotoImages[$0] == nil }
        if !neededIDs.isEmpty {
            let loadedImages = await Task.detached(priority: .userInitiated) {
                await DFKMapPhotoImageLoader.images(for: neededIDs, targetSize: CGSize(width: 120, height: 120), highQuality: false)
            }.value
            if Task.isCancelled { return }
            if !loadedImages.isEmpty {
                liveMapPhotoImages.merge(loadedImages, uniquingKeysWith: { _, latest in latest })
            }
        }

        let visibleIDs = Set(assetIDs)
        liveMapPhotoImages = liveMapPhotoImages.filter { visibleIDs.contains($0.key) }
    }


}

/// Footprints at one place, as a native sheet. The caller dismisses it and
/// opens the selected footprint once the dismissal finishes.
struct FootprintGroupSheet: View {
    let aggregated: DFKMapView.AggregatedFootprint
    let allPlaces: [Place]
    let onFootprintSelected: (Footprint) -> Void
    @Environment(\.dismiss) private var dismiss

    private var title: String {
        let representative = aggregated.representative
        if let matchedPlace = allPlaces.first(where: { $0.placeID == representative.placeID && $0.isUserDefined }) {
            return matchedPlace.name
        }
        if let address = representative.address, !address.isEmpty {
            return address
        }
        return "同地点足迹"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(aggregated.footprints) { footprint in
                        FootprintCardView(
                            footprint: footprint,
                            allPlaces: allPlaces,
                            showTimeline: false,
                            disableContextMenu: true,
                            showsTimeAsTitle: true
                        ) { selected, _ in
                            onFootprintSelected(selected)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 2) {
                        Text(title)
                            .font(.headline)
                            .lineLimit(1)
                        Text("共 \(aggregated.footprints.count) 条足迹")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark").dfkToolbarDismissIcon()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

private struct StableInteractiveMapView: UIViewRepresentable {
    private static let controlsStackTag = 9000
    private static let userTrackingButtonTag = 9001
    private static let compassButtonTag = 9002
    private static let scaleViewTag = 9003

    let region: MKCoordinateRegion?
    let showsUserLocation: Bool
    let userDefinedPlaces: [DFKMapPlaceCircle]
    let transportItems: [DFKMapTransportDisplay]
    let aggregatedFootprints: [DFKMapView.AggregatedFootprint]
    let photoAnnotations: [(asset: PHAsset, coordinate: CLLocationCoordinate2D)]
    let heatmapPoints: [DFKMapView.HeatmapPoint]
    let mainAnnotationCoordinate: CLLocationCoordinate2D?
    let selectedTimeCoordinate: CLLocationCoordinate2D?
    let allActivities: [ActivityType]
    let colorScheme: ColorScheme
    /// Identifies the annotation/overlay content; unchanged means no rebuild.
    let contentToken: Int
    let onFootprintTap: (DFKMapView.AggregatedFootprint) -> Void
    let onTransportTap: (Transport) -> Void
    let onPhotoTap: (PHAsset) -> Void
    let onUserLocationTap: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = SafeMKMapView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        mapView.delegate = context.coordinator
        mapView.mapType = .standard
        mapView.showsCompass = false
        mapView.showsScale = false
        mapView.isRotateEnabled = true
        mapView.isPitchEnabled = true
        mapView.register(MKAnnotationView.self, forAnnotationViewWithReuseIdentifier: Coordinator.annotationReuseIdentifier)

        let controlsStack = UIStackView()
        controlsStack.tag = Self.controlsStackTag
        controlsStack.axis = .vertical
        controlsStack.alignment = .trailing
        controlsStack.spacing = 12
        controlsStack.translatesAutoresizingMaskIntoConstraints = false

        // Custom location button (replaces MKUserTrackingButton so we can intercept taps)
        let locationButton = UIButton(type: .system)
        locationButton.tag = Self.userTrackingButtonTag
        locationButton.setImage(UIImage(systemName: "location.fill"), for: .normal)
        locationButton.tintColor = UIColor.systemBlue
        locationButton.translatesAutoresizingMaskIntoConstraints = false
        locationButton.addTarget(context.coordinator, action: #selector(Coordinator.didTapLocationButton), for: .touchUpInside)
        controlsStack.addArrangedSubview(Self.makeCircularControlContainer(for: locationButton))

        let compassButton = MKCompassButton(mapView: mapView)
        compassButton.tag = Self.compassButtonTag
        compassButton.compassVisibility = .adaptive
        compassButton.translatesAutoresizingMaskIntoConstraints = false
        controlsStack.addArrangedSubview(Self.makeCircularControlContainer(for: compassButton))

        mapView.addSubview(controlsStack)

        let scaleView = MKScaleView(mapView: mapView)
        scaleView.tag = Self.scaleViewTag
        scaleView.scaleVisibility = .adaptive
        scaleView.legendAlignment = .trailing
        scaleView.translatesAutoresizingMaskIntoConstraints = false
        mapView.addSubview(scaleView)

        NSLayoutConstraint.activate([
            controlsStack.trailingAnchor.constraint(equalTo: mapView.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            controlsStack.topAnchor.constraint(equalTo: mapView.topAnchor, constant: topSafeAreaInset + 16),
            scaleView.trailingAnchor.constraint(equalTo: mapView.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            scaleView.bottomAnchor.constraint(equalTo: mapView.safeAreaLayoutGuide.bottomAnchor, constant: -16)
        ])

        if let region {
            mapView.region = region
        }

        return mapView
    }

    private var topSafeAreaInset: CGFloat {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            if let keyWindow = windowScene.windows.first(where: { $0.isKeyWindow }) {
                return keyWindow.safeAreaInsets.top
            }
        }
        return 0
    }

    static func dismantleUIView(_ mapView: MKMapView, coordinator: Coordinator) {
        coordinator.overlayStyles.removeAll()
        coordinator.footprintsByID.removeAll()
        coordinator.transportsByID.removeAll()
        coordinator.photosByID.removeAll()
        coordinator.lastContentToken = nil
        coordinator.selectedTimeAnnotation = nil
        coordinator.transportIconTask?.cancel()
        coordinator.transportIconRoutes.removeAll()

        mapView.delegate = nil

        let overlays = mapView.overlays
        let annotations = mapView.annotations.filter { !($0 is MKUserLocation) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak mapView] in
            guard let mapView else { return }
            mapView.removeOverlays(overlays)
            mapView.removeAnnotations(annotations)
        }
    }

    private static func makeCircularControlContainer(for control: UIView) -> UIView {
        let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
        blurView.clipsToBounds = true
        blurView.layer.cornerRadius = 22
        blurView.layer.cornerCurve = .continuous
        blurView.layer.borderWidth = 0.5
        blurView.layer.borderColor = UIColor.white.withAlphaComponent(0.35).cgColor
        blurView.translatesAutoresizingMaskIntoConstraints = false

        blurView.contentView.addSubview(control)
        NSLayoutConstraint.activate([
            blurView.widthAnchor.constraint(equalToConstant: 44),
            blurView.heightAnchor.constraint(equalToConstant: 44),
            control.centerXAnchor.constraint(equalTo: blurView.contentView.centerXAnchor),
            control.centerYAnchor.constraint(equalTo: blurView.contentView.centerYAnchor),
            control.widthAnchor.constraint(lessThanOrEqualTo: blurView.contentView.widthAnchor),
            control.heightAnchor.constraint(lessThanOrEqualTo: blurView.contentView.heightAnchor)
        ])

        return blurView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        context.coordinator.parent = self
        mapView.showsUserLocation = showsUserLocation
        if let trackingButton = mapView.viewWithTag(Self.userTrackingButtonTag) as? MKUserTrackingButton {
            trackingButton.isHidden = !showsUserLocation
        }
        if let controlsStack = mapView.viewWithTag(Self.controlsStackTag) as? UIStackView {
            controlsStack.isHidden = !showsUserLocation
        }
        if let scaleView = mapView.viewWithTag(Self.scaleViewTag) as? MKScaleView {
            scaleView.isHidden = !showsUserLocation
        }

        if let region, context.coordinator.shouldApply(region: region, to: mapView.region) {
            mapView.setRegion(region, animated: false)
        }

        updateSelectedTimeAnnotation(in: mapView, coordinator: context.coordinator)

        // Rebuilding every annotation on each SwiftUI update is costly; only
        // do it when the content itself changed.
        guard context.coordinator.lastContentToken != contentToken else { return }
        context.coordinator.lastContentToken = contentToken

        context.coordinator.overlayStyles.removeAll()
        context.coordinator.footprintsByID = Dictionary(aggregatedFootprints.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        context.coordinator.transportsByID = Dictionary(transportItems.map { ($0.transport.id.uuidString, $0.transport) }, uniquingKeysWith: { first, _ in first })
        context.coordinator.photosByID = Dictionary(photoAnnotations.map { ($0.asset.localIdentifier, $0.asset) }, uniquingKeysWith: { first, _ in first })

        let selectedTimeAnnotation = context.coordinator.selectedTimeAnnotation
        let removableAnnotations = mapView.annotations.filter { annotation in
            !(annotation is MKUserLocation) && annotation !== selectedTimeAnnotation
        }
        mapView.removeAnnotations(removableAnnotations)
        mapView.removeOverlays(mapView.overlays)
        context.coordinator.transportIconRoutes.removeAll()

        for place in userDefinedPlaces {
            let circle = MKCircle(center: place.coordinate, radius: max(5, min(place.radius, 10_000)))
            context.coordinator.overlayStyles[ObjectIdentifier(circle)] = OverlayStyle(
                strokeColor: UIColor.orange.withAlphaComponent(0.35),
                fillColor: UIColor.orange.withAlphaComponent(0.12),
                lineWidth: 1
            )
            mapView.addOverlay(circle)
        }

        for display in transportItems {
            let segments = display.segments
            guard !segments.isEmpty else { continue }

            for segment in segments {
                let line = MKPolyline(coordinates: segment.coordinates, count: segment.coordinates.count)
                context.coordinator.overlayStyles[ObjectIdentifier(line)] = OverlayStyle(
                    strokeColor: UIColor(Color.dfkAccent).withAlphaComponent(segment.isDashed ? 0.4 : 0.8),
                    fillColor: nil,
                    lineWidth: segment.isDashed ? 1.4 : 3,
                    dashPattern: segment.isDashed ? [8 as NSNumber, 8 as NSNumber] : nil
                )
                mapView.addOverlay(line)
            }

            if let midpoint = display.midpoint {
                let annotation = MapImageAnnotation(
                    coordinate: midpoint,
                    kind: .transport(display.transport.id.uuidString),
                    image: context.coordinator.cachedImage(key: "t:\(display.transport.currentType.sfSymbol):\(display.travelsWest):\(colorScheme == .dark)") {
                        Coordinator.transportImage(
                            symbolName: display.transport.currentType.sfSymbol,
                            travelsWest: display.travelsWest
                        )
                    }
                )
                context.coordinator.transportIconRoutes.append((annotation, display.coordinates, midpoint, display.transport.currentType.rawValue))
                mapView.addAnnotation(annotation)
            }
        }
        context.coordinator.refreshTransportIconPositions(in: mapView)

        let iconColor: UIColor = colorScheme == .dark ? .black : .white
        for aggregated in aggregatedFootprints {
            let activity = aggregated.representative.getActivityType(from: allActivities)
            let symbolName = activity?.icon ?? FootprintIconDefaults.card
            mapView.addAnnotation(MapImageAnnotation(
                coordinate: aggregated.coordinate,
                kind: .footprint(aggregated.id),
                image: context.coordinator.cachedImage(key: "f:\(symbolName):\(activity?.colorHex ?? "none"):\(colorScheme == .dark)") {
                    Coordinator.footprintImage(
                        symbolName: symbolName,
                        color: UIColor(activity?.color ?? Color.secondary.opacity(0.5)),
                        iconColor: iconColor
                    )
                }
            ))
        }

        for entry in photoAnnotations {
            mapView.addAnnotation(MapImageAnnotation(
                coordinate: entry.coordinate,
                kind: .photo(entry.asset.localIdentifier),
                image: context.coordinator.cachedImage(key: "photo:\(colorScheme == .dark)") { Coordinator.photoImage() },
                centerOffset: Coordinator.photoCenterOffset
            ))
        }

        for point in heatmapPoints {
            mapView.addAnnotation(MapImageAnnotation(
                coordinate: point.coordinate,
                kind: .heatmap(point.id),
                image: Coordinator.heatmapImage(point: point)
            ))
        }

        if let mainAnnotationCoordinate {
            mapView.addAnnotation(MapImageAnnotation(
                coordinate: mainAnnotationCoordinate,
                kind: .main,
                image: Coordinator.mainMarkerImage()
            ))
        }
    }

    /// The scrubbed time marker moves on its own, without rebuilding the rest.
    private func updateSelectedTimeAnnotation(in mapView: MKMapView, coordinator: Coordinator) {
        let target = selectedTimeCoordinate.flatMap { $0.isRenderableMapCoordinate ? $0 : nil }
        if let existing = coordinator.selectedTimeAnnotation {
            if let target,
               existing.coordinate.latitude == target.latitude,
               existing.coordinate.longitude == target.longitude {
                return
            }
            mapView.removeAnnotation(existing)
            coordinator.selectedTimeAnnotation = nil
        }
        guard let target else { return }
        let annotation = MapImageAnnotation(
            coordinate: target,
            kind: .selectedTime,
            image: coordinator.cachedImage(key: "selectedTime:\(colorScheme == .dark)") { Coordinator.selectedTimeImage() }
        )
        coordinator.selectedTimeAnnotation = annotation
        mapView.addAnnotation(annotation)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        static let annotationReuseIdentifier = "StableInteractiveMapAnnotation"
        static let photoCenterOffset = CGPoint(x: 0, y: -17)

        var parent: StableInteractiveMapView
        var overlayStyles: [ObjectIdentifier: OverlayStyle] = [:]
        var footprintsByID: [String: DFKMapView.AggregatedFootprint] = [:]
        var transportsByID: [String: Transport] = [:]
        var photosByID: [String: PHAsset] = [:]
        
        var lastUpdateIdentifier: Int? = -1
        var lastSelectedCoordinateStr: String = ""
        var lastContentToken: Int?
        var selectedTimeAnnotation: MapImageAnnotation?
        /// Transport icons with their routes, moved to the middle of the
        /// visible part of each route after every camera move; nearby
        /// same-type icons are merged into one.
        var transportIconRoutes: [(annotation: MapImageAnnotation, coordinates: [CLLocationCoordinate2D], midpoint: CLLocationCoordinate2D, type: String)] = []
        var transportIconTask: Task<Void, Never>?
        private var imageCache: [String: UIImage] = [:]

        func cachedImage(key: String, make: () -> UIImage) -> UIImage {
            if let image = imageCache[key] { return image }
            let image = make()
            imageCache[key] = image
            return image
        }

        init(_ parent: StableInteractiveMapView) {
            self.parent = parent
        }

        @objc func didTapLocationButton() {
            parent.onUserLocationTap?()
        }


        func shouldApply(region: MKCoordinateRegion, to current: MKCoordinateRegion) -> Bool {
            let latDiff = abs(region.center.latitude - current.center.latitude)
            let lonDiff = abs(region.center.longitude - current.center.longitude)
            let latDeltaDiff = abs(region.span.latitudeDelta - current.span.latitudeDelta)
            let lonDeltaDiff = abs(region.span.longitudeDelta - current.span.longitudeDelta)
            return latDiff > 0.0001 || lonDiff > 0.0001 || latDeltaDiff > 0.0001 || lonDeltaDiff > 0.0001
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            refreshTransportIconPositions(in: mapView)
        }

        /// Computes the visible midpoints and merges off the main thread,
        /// then only moves and hides the existing annotations.
        func refreshTransportIconPositions(in mapView: MKMapView) {
            transportIconTask?.cancel()
            let entries = transportIconRoutes
            guard !entries.isEmpty else { return }
            let region = mapView.region
            let viewWidth = mapView.bounds.width
            let routes = entries.map { (coordinates: $0.coordinates, midpoint: $0.midpoint, type: $0.type) }
            let diameter = Coordinator.transportImageSize
            transportIconTask = Task { @MainActor [weak mapView] in
                let result = await Task.detached(priority: .userInitiated) {
                    let positions = routes.map { $0.coordinates.visibleDistanceMidpoint(in: region) ?? $0.midpoint }
                    let kept = Set(MapTransportIconMerge.keptIndices(
                        coordinates: positions,
                        types: routes.map(\.type),
                        region: region,
                        viewWidth: viewWidth,
                        diameter: diameter
                    ))
                    return (positions: positions, kept: kept)
                }.value
                guard !Task.isCancelled else { return }
                for (index, (entry, position)) in zip(entries, result.positions).enumerated() {
                    if entry.annotation.coordinate.latitude != position.latitude || entry.annotation.coordinate.longitude != position.longitude {
                        entry.annotation.coordinate = position
                    }
                    let isMerged = !result.kept.contains(index)
                    entry.annotation.isMerged = isMerged
                    mapView?.view(for: entry.annotation)?.isHidden = isMerged
                }
            }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            let style = overlayStyles[ObjectIdentifier(overlay)]

            if let circle = overlay as? MKCircle {
                let renderer = MKCircleRenderer(circle: circle)
                renderer.strokeColor = style?.strokeColor ?? UIColor.orange.withAlphaComponent(0.35)
                renderer.fillColor = style?.fillColor
                renderer.lineWidth = style?.lineWidth ?? 1
                return renderer
            }

            if let polyline = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = style?.strokeColor ?? UIColor(Color.dfkAccent)
                renderer.lineWidth = style?.lineWidth ?? 5
                renderer.lineCap = .round
                renderer.lineJoin = .round
                renderer.lineDashPattern = style?.dashPattern
                return renderer
            }

            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let annotation = annotation as? MapImageAnnotation else { return nil }
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: Self.annotationReuseIdentifier, for: annotation)
            view.annotation = annotation
            view.image = annotation.image
            view.canShowCallout = false
            view.centerOffset = annotation.centerOffset
            
            // zPriority only controls annotation decluttering. Use the view layer
            // itself to enforce the visual stack: transport < footprint < photo.
            view.isHidden = annotation.isMerged
            switch annotation.kind {
            case .transport:
                view.zPriority = .min
                view.displayPriority = .defaultLow
                view.layer.zPosition = MapAnnotationLayer.transport
            case .footprint:
                view.zPriority = .max
                view.displayPriority = .required
                view.layer.zPosition = MapAnnotationLayer.footprint
            case .photo, .heatmap, .main, .selectedTime:
                view.zPriority = .max
                view.displayPriority = .required
                view.layer.zPosition = MapAnnotationLayer.photo
            }
            
            return view
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            defer {
                if let annotation = view.annotation {
                    mapView.deselectAnnotation(annotation, animated: false)
                }
            }

            guard let annotation = view.annotation as? MapImageAnnotation else { return }

            switch annotation.kind {
            case .footprint(let id):
                if let footprint = footprintsByID[id] {
                    parent.onFootprintTap(footprint)
                }
            case .transport(let id):
                if let transport = transportsByID[id] {
                    parent.onTransportTap(transport)
                }
            case .photo(let id):
                if let asset = photosByID[id] {
                    parent.onPhotoTap(asset)
                }
            case .heatmap, .main, .selectedTime:
                break
            }
        }

        static func footprintImage(symbolName: String, color: UIColor, iconColor: UIColor) -> UIImage {
            let size = CGSize(width: 24, height: 24)
            let renderer = UIGraphicsImageRenderer(size: size)
            return renderer.image { context in
                let rect = CGRect(origin: .zero, size: size)
                color.setFill()
                context.cgContext.fillEllipse(in: rect)

                let iconSize = CGSize(width: 28 * 0.55, height: 28 * 0.55)
                let iconOrigin = CGPoint(x: (size.width - iconSize.width) / 2, y: (size.height - iconSize.height) / 2)
                UIImage(systemName: symbolName)?
                    .withTintColor(iconColor, renderingMode: .alwaysOriginal)
                    .draw(in: CGRect(origin: iconOrigin, size: iconSize))
            }
        }

        static let transportImageSize: CGFloat = 20

        static func transportImage(symbolName: String, travelsWest: Bool) -> UIImage {
            let size = CGSize(width: transportImageSize, height: transportImageSize)
            let renderer = UIGraphicsImageRenderer(size: size)
            return renderer.image { context in
                let rect = CGRect(origin: .zero, size: size)
                let path = UIBezierPath(ovalIn: rect)
                UIColor.systemBackground.setFill()
                path.fill()
                UIColor(Color.dfkAccent).setStroke()
                path.lineWidth = 1.2
                path.stroke()

                if let sourceImage = UIImage(systemName: symbolName) {
                    let iconImage = travelsWest ? sourceImage.withHorizontallyFlippedOrientation() : sourceImage
                    iconImage
                        .withTintColor(UIColor(Color.dfkAccent), renderingMode: .alwaysOriginal)
                        .draw(in: CGRect(x: 5, y: 5, width: 10, height: 10))
                }
            }
        }


        static func photoImage() -> UIImage {
            let bodySize: CGFloat = 28
            let tipHeight: CGFloat = 6
            let size = CGSize(width: bodySize, height: bodySize + tipHeight)
            let renderer = UIGraphicsImageRenderer(size: size)
            return renderer.image { context in
                let markerRect = CGRect(origin: .zero, size: size)
                let path = UIBezierPath.photoMapMarkerPath(in: markerRect, cornerRadius: 6, tipHeight: tipHeight)
                context.cgContext.saveGState()
                context.cgContext.setShadow(offset: CGSize(width: 0, height: 2), blur: 3, color: UIColor.black.withAlphaComponent(0.18).cgColor)
                UIColor.systemBackground.setFill()
                path.fill()
                context.cgContext.restoreGState()

                UIColor.systemBackground.setStroke()
                path.lineWidth = 1.2
                path.stroke()

                UIImage(systemName: "photo.fill")?
                    .withTintColor(UIColor(Color.dfkAccent), renderingMode: .alwaysOriginal)
                    .draw(in: CGRect(x: 7, y: 7, width: 14, height: 14))
            }
        }

        static func mainMarkerImage() -> UIImage {
            let size = CGSize(width: 14, height: 14)
            let renderer = UIGraphicsImageRenderer(size: size)
            return renderer.image { context in
                let rect = CGRect(origin: .zero, size: size)
                UIColor(Color.dfkAccent).setFill()
                context.cgContext.fillEllipse(in: rect)
                UIColor.systemBackground.setStroke()
                context.cgContext.setLineWidth(1.5)
                context.cgContext.strokeEllipse(in: rect.insetBy(dx: 0.75, dy: 0.75))
            }
        }

        static func heatmapImage(point: DFKMapView.HeatmapPoint) -> UIImage {
            let rawRatio = Double(point.intensity) / Double(max(1, point.maxIntensity))
            let ratio = pow(rawRatio, 0.4)
            let color: UIColor = {
                if point.maxIntensity <= 1 {
                    return .orange
                } else if ratio < 0.25 {
                    return .orange
                } else if ratio < 0.85 {
                    return .red
                } else {
                    return UIColor(Color.dfkDeepRed)
                }
            }()
            let sizeValue = max(14.0, min(30.0, CGFloat(point.intensity) * 3))
            let size = CGSize(width: sizeValue, height: sizeValue)
            let renderer = UIGraphicsImageRenderer(size: size)
            return renderer.image { context in
                let rect = CGRect(origin: .zero, size: size)
                context.cgContext.setFillColor(color.withAlphaComponent(0.45).cgColor)
                context.cgContext.fillEllipse(in: rect)
            }
        }

        static func selectedTimeImage() -> UIImage {
            let size = CGSize(width: 14, height: 14)
            let renderer = UIGraphicsImageRenderer(size: size)
            return renderer.image { context in
                let rect = CGRect(origin: .zero, size: size)
                UIColor.systemRed.setFill()
                context.cgContext.fillEllipse(in: rect)
                UIColor.systemBackground.setStroke()
                context.cgContext.setLineWidth(2)
                context.cgContext.strokeEllipse(in: rect.insetBy(dx: 1, dy: 1))
            }
        }
    }
}

private struct OverlayStyle {
    let strokeColor: UIColor
    let fillColor: UIColor?
    let lineWidth: CGFloat
    var dashPattern: [NSNumber]? = nil
}

private final class MapImageAnnotation: NSObject, MKAnnotation {
    enum Kind {
        case footprint(String)
        case transport(String)
        case photo(String)
        case heatmap(String)
        case main
        case selectedTime
    }

    let kind: Kind
    dynamic var coordinate: CLLocationCoordinate2D
    let image: UIImage
    let centerOffset: CGPoint
    /// A transport icon hidden behind a nearby same-type icon.
    var isMerged = false

    init(coordinate: CLLocationCoordinate2D, kind: Kind, image: UIImage, centerOffset: CGPoint = .zero) {
        self.coordinate = coordinate
        self.kind = kind
        self.image = image
        self.centerOffset = centerOffset
    }
}

/// Map annotation stacking shared by every map: transport < footprint < photo.
enum MapAnnotationLayer {
    static let transport: CGFloat = 0
    static let footprint: CGFloat = 10
    static let photo: CGFloat = 20
}

/// SwiftUI `Annotation` has no z-order control and MapKit stacks annotation
/// views by screen position, so set the hosting annotation view's layer
/// zPosition the same way the UIKit map does.
private struct MapAnnotationLayerSetter: UIViewRepresentable {
    let zPosition: CGFloat

    func makeUIView(context: Context) -> LayerView {
        let view = LayerView()
        view.isUserInteractionEnabled = false
        view.zPosition = zPosition
        return view
    }

    func updateUIView(_ view: LayerView, context: Context) {
        view.zPosition = zPosition
        view.apply()
    }

    final class LayerView: UIView {
        var zPosition: CGFloat = 0

        override func didMoveToWindow() {
            super.didMoveToWindow()
            apply()
        }

        func apply() {
            var ancestor = superview
            while let view = ancestor {
                if view is MKAnnotationView {
                    view.layer.zPosition = zPosition
                    return
                }
                ancestor = view.superview
            }
        }
    }
}

extension View {
    func mapAnnotationLayer(_ zPosition: CGFloat) -> some View {
        background(MapAnnotationLayerSetter(zPosition: zPosition))
    }
}

/// Nearby same-type transport icons are shown as one at the configured spacing.
enum MapTransportIconMerge {
    /// Indices of the icons to draw, in input order: an icon is dropped when
    /// it is within the configured diameter ratio of a kept same-type icon.
    static func keptIndices(points: [CGPoint], types: [String], diameter: CGFloat) -> [Int] {
        let mergeDistance = diameter * CGFloat(AppConfig.shared.mapTransportIconMergeDiameterRatio)
        var kept: [Int] = []
        for index in points.indices {
            let isNearby = kept.contains { other in
                types[other] == types[index] &&
                    hypot(points[other].x - points[index].x, points[other].y - points[index].y) < mergeDistance
            }
            if !isNearby { kept.append(index) }
        }
        return kept
    }

    /// The same for a live map showing `region` across `viewWidth` points.
    /// Pure map-point math, so it runs off the main thread.
    static func keptIndices(
        coordinates: [CLLocationCoordinate2D],
        types: [String],
        region: MKCoordinateRegion,
        viewWidth: CGFloat,
        diameter: CGFloat
    ) -> [Int] {
        let west = MKMapPoint(CLLocationCoordinate2D(latitude: region.center.latitude, longitude: region.center.longitude - region.span.longitudeDelta / 2))
        let east = MKMapPoint(CLLocationCoordinate2D(latitude: region.center.latitude, longitude: region.center.longitude + region.span.longitudeDelta / 2))
        var mapWidth = east.x - west.x
        if mapWidth <= 0 { mapWidth += MKMapSize.world.width }
        guard mapWidth > 0, viewWidth > 0 else { return Array(coordinates.indices) }
        let scale = Double(viewWidth) / mapWidth
        let points = coordinates.map { coordinate -> CGPoint in
            let point = MKMapPoint(coordinate)
            return CGPoint(x: point.x * scale, y: point.y * scale)
        }
        return keptIndices(points: points, types: types, diameter: diameter)
    }
}

extension Array where Element == CLLocationCoordinate2D {
    /// Whether the route's destination is west of its origin. Normalize the
    /// longitude delta so routes crossing the antimeridian keep their actual
    /// travel direction.
    var travelsWest: Bool {
        guard let first, let last, count >= 2 else { return false }
        var longitudeDelta = last.longitude - first.longitude
        if longitudeDelta > 180 { longitudeDelta -= 360 }
        if longitudeDelta < -180 { longitudeDelta += 360 }
        return longitudeDelta < 0
    }

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
    
    /// 计算基于地理距离的中点，确保图标在路径的长度中点
    var distanceMidpoint: CLLocationCoordinate2D? {
        guard count >= 2 else { return first }
        
        // 1. 计算总距离和各段累计距离
        var totalDistance: Double = 0
        var segmentDistances: [Double] = [0]
        
        for i in 0..<count-1 {
            let p1 = CLLocation(latitude: self[i].latitude, longitude: self[i].longitude)
            let p2 = CLLocation(latitude: self[i+1].latitude, longitude: self[i+1].longitude)
            let d = p1.distance(from: p2)
            totalDistance += d
            segmentDistances.append(totalDistance)
        }
        
        if totalDistance == 0 { return self[count / 2] }
        
        // 2. 找到距离上的中点
        let midDistance = totalDistance / 2
        
        for i in 0..<count-1 {
            if midDistance >= segmentDistances[i] && midDistance <= segmentDistances[i+1] {
                // 在这一段内进行插值
                let distInSegment = midDistance - segmentDistances[i]
                let segmentTotalDist = segmentDistances[i+1] - segmentDistances[i]
                let fraction = segmentTotalDist > 0 ? distInSegment / segmentTotalDist : 0
                
                return CLLocationCoordinate2D(
                    latitude: self[i].latitude + (self[i+1].latitude - self[i].latitude) * fraction,
                    longitude: self[i].longitude + (self[i+1].longitude - self[i].longitude) * fraction
                )
            }
        }
        return self[count / 2]
    }
    
    /// 路线在可见范围内的距离中点：把路线裁到范围内，取最长一段连续可见路线的
    /// 中点，让交通图标始终落在屏幕内的线条中间。整条路线可见时等同于
    /// `distanceMidpoint`；完全不可见时返回 nil。
    func visibleDistanceMidpoint(in region: MKCoordinateRegion) -> CLLocationCoordinate2D? {
        let minLatitude = region.center.latitude - region.span.latitudeDelta / 2
        let maxLatitude = region.center.latitude + region.span.latitudeDelta / 2
        let minLongitude = region.center.longitude - region.span.longitudeDelta / 2
        let maxLongitude = region.center.longitude + region.span.longitudeDelta / 2
        guard count >= 2 else {
            guard let first,
                  first.latitude >= minLatitude, first.latitude <= maxLatitude,
                  first.longitude >= minLongitude, first.longitude <= maxLongitude else { return nil }
            return first
        }

        // Liang–Barsky clipping of one segment; endpoints left untouched are
        // returned exactly so consecutive pieces join into one run.
        func clipped(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> (CLLocationCoordinate2D, CLLocationCoordinate2D)? {
            let dx = b.longitude - a.longitude
            let dy = b.latitude - a.latitude
            var t0 = 0.0
            var t1 = 1.0
            for (p, q) in [(-dx, a.longitude - minLongitude), (dx, maxLongitude - a.longitude),
                           (-dy, a.latitude - minLatitude), (dy, maxLatitude - a.latitude)] {
                if p == 0 {
                    if q < 0 { return nil }
                    continue
                }
                let r = q / p
                if p < 0 {
                    if r > t1 { return nil }
                    t0 = Swift.max(t0, r)
                } else {
                    if r < t0 { return nil }
                    t1 = Swift.min(t1, r)
                }
            }
            func point(_ t: Double) -> CLLocationCoordinate2D {
                if t == 0 { return a }
                if t == 1 { return b }
                return CLLocationCoordinate2D(latitude: a.latitude + dy * t, longitude: a.longitude + dx * t)
            }
            return (point(t0), point(t1))
        }

        func length(_ run: [CLLocationCoordinate2D]) -> Double {
            zip(run, run.dropFirst()).reduce(0) { total, pair in
                total + CLLocation(latitude: pair.0.latitude, longitude: pair.0.longitude)
                    .distance(from: CLLocation(latitude: pair.1.latitude, longitude: pair.1.longitude))
            }
        }

        var longestRun: [CLLocationCoordinate2D] = []
        var longestLength = -1.0
        var run: [CLLocationCoordinate2D] = []
        func closeRun() {
            guard run.count >= 2 else { return }
            let runLength = length(run)
            if runLength > longestLength {
                longestLength = runLength
                longestRun = run
            }
        }
        for index in 0..<(count - 1) {
            guard let piece = clipped(self[index], self[index + 1]) else {
                closeRun()
                run = []
                continue
            }
            if let last = run.last, last.latitude == piece.0.latitude, last.longitude == piece.0.longitude {
                run.append(piece.1)
            } else {
                closeRun()
                run = [piece.0, piece.1]
            }
        }
        closeRun()
        return longestRun.distanceMidpoint
    }

    /// 寻找给定坐标点在该数组中距离最近的元素索引
    func indexOfClosestPoint(to target: CLLocationCoordinate2D) -> Int {
        var minDistanceSq = Double.infinity
        var index = 0
        for (i, p) in enumerated() {
            let dLat = p.latitude - target.latitude
            let dLon = p.longitude - target.longitude
            let distSq = dLat * dLat + dLon * dLon
            if distSq < minDistanceSq {
                minDistanceSq = distSq
                index = i
            }
        }
        return index
    }
    
    /// 从当前轨迹中截取从 start 点到 end 点对应的子路段
    func subpath(from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D) -> [CLLocationCoordinate2D] {
        guard count >= 2 else { return [] }
        let startIndex = self.indexOfClosestPoint(to: start)
        let endIndex = self.indexOfClosestPoint(to: end)
        
        let lower = Swift.min(startIndex, endIndex)
        let upper = Swift.max(startIndex, endIndex)
        
        guard upper - lower >= 1 else { return [] }
        return Array(self[lower...upper])
    }
}


extension CLLocationCoordinate2D {
    var isRenderableMapCoordinate: Bool {
        latitude.isFinite && longitude.isFinite && CLLocationCoordinate2DIsValid(self)
    }
}

private struct DFKFootprintMapMarker: View {
    let size: CGFloat
    let constantScale: CGFloat
    let activityColor: Color
    let iconColor: Color
    let iconName: String
    let iconSize: CGFloat
    let photoImage: UIImage?
    var centerText: String? = nil
    /// Small second line under `centerText`, such as "个足迹".
    var centerCaption: String? = nil
    let durationTuple: (number: String, unit: String)?
    let fontSize: CGFloat

    var body: some View {
        ZStack(alignment: .top) {
            MapPinTeardropShape()
                .fill(Color(uiColor: .systemBackground))
                .shadow(color: .black.opacity(0.15), radius: 2, x: 0, y: 2)
                .frame(width: size, height: size * 1.2)

            Circle()
                .fill(
                    LinearGradient(
                        colors: [activityColor, activityColor.darker(by: 0.20)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: size - 5, height: size - 5)
                .offset(y: 2.5)

            if let photoImage {
                Image(uiImage: photoImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size - 3, height: size - 3)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(activityColor, lineWidth: 1.5))
                    .offset(y: 1.5)
            } else if let centerText, let centerCaption {
                // Centred in the coloured circle as one two-line block.
                VStack(spacing: 0) {
                    Text(centerText)
                        .font(.system(size: iconSize * 0.8, weight: .bold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.55)
                    Text(centerCaption)
                        .font(.system(size: iconSize * 0.4, weight: .semibold))
                        .lineLimit(1)
                        .opacity(0.9)
                }
                .foregroundStyle(iconColor)
                .frame(width: size - 9, height: size - 5)
                .offset(y: 2.5)
            } else if let centerText {
                Text(centerText)
                    .font(.system(size: iconSize, weight: .bold, design: .rounded))
                    .foregroundStyle(iconColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                    .frame(width: size - 8, height: size - 8)
                    .offset(y: 4)
            } else {
                Image(systemName: iconName)
                    .font(.system(size: iconSize, weight: .bold))
                    .foregroundStyle(iconColor)
                    .frame(width: size, height: size)
            }

            if let durationTuple {
                HStack(alignment: .lastTextBaseline, spacing: 0) {
                    Text(durationTuple.number)
                        .font(.system(size: fontSize, weight: .bold, design: .rounded))
                    Text(durationTuple.unit)
                        .font(.system(size: fontSize * 0.75, weight: .bold, design: .rounded))
                }
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .foregroundStyle(activityColor.darker(by: 0.30))
                .padding(.horizontal, 2)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(uiColor: .systemBackground))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(activityColor, lineWidth: 0.5)
                )
                .offset(y: size - 6 * constantScale)
            }
        }
        .padding(2 * constantScale)
        .frame(width: size + 4 * constantScale, height: size * 1.2 + 4 * constantScale)
        .contentShape(Rectangle())
    }
}

private struct DFKReviewPlaceMapMarker: View {
    let placeCount: Int
    let photoImage: UIImage?

    var body: some View {
        DFKFootprintMapMarker(
            size: 36,
            constantScale: 1.32,
            activityColor: Color.dfkAccent,
            iconColor: .white,
            iconName: "mappin",
            iconSize: placeCount > 1 ? 15 : 14,
            photoImage: placeCount == 1 ? photoImage : nil,
            centerText: placeCount > 1 ? "\(placeCount)" : nil,
            centerCaption: placeCount > 1 ? "个足迹" : nil,
            durationTuple: nil,
            fontSize: 8
        )
    }
}

struct MapPinTeardropShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard rect.width > 0 && rect.height > 0 else {
            path.addEllipse(in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return path
        }

        let radius = rect.width / 2
        let center = CGPoint(x: rect.midX, y: rect.minY + radius)
        path.addArc(center: center, radius: radius, startAngle: .degrees(140), endAngle: .degrees(40), clockwise: false)
        let bottomY = rect.maxY - 1.5
        path.addLine(to: CGPoint(x: rect.midX + 1.5, y: bottomY))
        path.addArc(center: CGPoint(x: rect.midX, y: bottomY), radius: 1.5, startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
        path.closeSubpath()
        return path
    }
}

private struct PhotoMapMarkerShape: Shape {
    let cornerRadius: CGFloat
    let tipHeight: CGFloat
    var tipWidth: CGFloat = 14

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard rect.width > 0 && rect.height > 0 else {
            path.addRect(CGRect(x: 0, y: 0, width: 1, height: 1))
            return path
        }

        let bodyHeight = max(0, rect.height - tipHeight)
        let bodyRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: bodyHeight)
        let radius = min(cornerRadius, bodyRect.width / 2, bodyRect.height / 2)
        let clampedTipWidth = min(tipWidth, rect.width * 0.5)

        path.move(to: CGPoint(x: bodyRect.minX + radius, y: bodyRect.minY))
        path.addLine(to: CGPoint(x: bodyRect.maxX - radius, y: bodyRect.minY))
        path.addQuadCurve(to: CGPoint(x: bodyRect.maxX, y: bodyRect.minY + radius), control: CGPoint(x: bodyRect.maxX, y: bodyRect.minY))
        path.addLine(to: CGPoint(x: bodyRect.maxX, y: bodyRect.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: bodyRect.maxX - radius, y: bodyRect.maxY), control: CGPoint(x: bodyRect.maxX, y: bodyRect.maxY))
        path.addLine(to: CGPoint(x: rect.midX + clampedTipWidth / 2, y: bodyRect.maxY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.midX - clampedTipWidth / 2, y: bodyRect.maxY))
        path.addLine(to: CGPoint(x: bodyRect.minX + radius, y: bodyRect.maxY))
        path.addQuadCurve(to: CGPoint(x: bodyRect.minX, y: bodyRect.maxY - radius), control: CGPoint(x: bodyRect.minX, y: bodyRect.maxY))
        path.addLine(to: CGPoint(x: bodyRect.minX, y: bodyRect.minY + radius))
        path.addQuadCurve(to: CGPoint(x: bodyRect.minX + radius, y: bodyRect.minY), control: CGPoint(x: bodyRect.minX, y: bodyRect.minY))
        path.closeSubpath()

        return path
    }
}

private extension UIBezierPath {
    static func photoMapMarkerPath(in rect: CGRect, cornerRadius: CGFloat, tipHeight: CGFloat, tipWidth: CGFloat = 14) -> UIBezierPath {
        let path = UIBezierPath()
        guard rect.width > 0 && rect.height > 0 else {
            return UIBezierPath(rect: CGRect(x: 0, y: 0, width: 1, height: 1))
        }

        let bodyHeight = max(0, rect.height - tipHeight)
        let bodyRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: bodyHeight)
        let radius = min(cornerRadius, bodyRect.width / 2, bodyRect.height / 2)
        let clampedTipWidth = min(tipWidth, rect.width * 0.5)

        path.move(to: CGPoint(x: bodyRect.minX + radius, y: bodyRect.minY))
        path.addLine(to: CGPoint(x: bodyRect.maxX - radius, y: bodyRect.minY))
        path.addQuadCurve(to: CGPoint(x: bodyRect.maxX, y: bodyRect.minY + radius), controlPoint: CGPoint(x: bodyRect.maxX, y: bodyRect.minY))
        path.addLine(to: CGPoint(x: bodyRect.maxX, y: bodyRect.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: bodyRect.maxX - radius, y: bodyRect.maxY), controlPoint: CGPoint(x: bodyRect.maxX, y: bodyRect.maxY))
        path.addLine(to: CGPoint(x: rect.midX + clampedTipWidth / 2, y: bodyRect.maxY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.midX - clampedTipWidth / 2, y: bodyRect.maxY))
        path.addLine(to: CGPoint(x: bodyRect.minX + radius, y: bodyRect.maxY))
        path.addQuadCurve(to: CGPoint(x: bodyRect.minX, y: bodyRect.maxY - radius), controlPoint: CGPoint(x: bodyRect.minX, y: bodyRect.maxY))
        path.addLine(to: CGPoint(x: bodyRect.minX, y: bodyRect.minY + radius))
        path.addQuadCurve(to: CGPoint(x: bodyRect.minX + radius, y: bodyRect.minY), controlPoint: CGPoint(x: bodyRect.minX, y: bodyRect.minY))
        path.close()

        return path
    }
}

extension Color {
    func darker(by percentage: CGFloat = 0.15) -> Color {
        var h: CGFloat = 0
        var s: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        guard UIColor(self).getHue(&h, saturation: &s, brightness: &b, alpha: &a) else {
            return self
        }
        return Color(hue: Double(h), saturation: Double(s), brightness: Double(max(b - percentage, 0.0)), opacity: Double(a))
    }

}

private extension View {
    @ViewBuilder
    func mapLocationButtonStyle() -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
                .buttonBorderShape(.circle)
        }
    }
}
