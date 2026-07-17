import Foundation
import SwiftUI
import SwiftData
import MapKit
import Photos
import WidgetKit

@MainActor
final class WidgetDataSyncManager {
    static let shared = WidgetDataSyncManager()
    // Keep this in sync with the widget reader. Bump it whenever the widget
    // renderer changes so WidgetKit cannot reuse an image drawn with old rules.
    static let snapshotFileVersion = "v13"

    /// Marker outlines are composited after MapKit renders the map, so they
    /// must use the snapshot's requested appearance instead of the app's
    /// current dynamic system color.
    private static func mapMarkerOutlineColor(for style: UIUserInterfaceStyle) -> UIColor {
        style == .dark ? .black : .white
    }

    private struct AggregatedFootprintSnapshot {
        let coordinate: CLLocationCoordinate2D
        let totalDuration: TimeInterval
        let representative: Footprint
        let latestPhotoAssetID: String?
    }

    private final class WidgetImageContinuation {
        private let lock = NSLock()
        private var didResume = false
        private let continuation: CheckedContinuation<UIImage?, Never>

        init(_ continuation: CheckedContinuation<UIImage?, Never>) {
            self.continuation = continuation
        }

        func resume(returning image: UIImage?) {
            lock.lock()
            guard !didResume else {
                lock.unlock()
                return
            }
            didResume = true
            lock.unlock()
            continuation.resume(returning: image)
        }
    }
    
    private var groupID: String { AppConfig.shared.appGroupID }
    private var container: ModelContainer?
    private let todaySyncMinimumInterval: TimeInterval = 90
    private let historySyncMinimumInterval: TimeInterval = 20 * 60
    private var lastTodaySyncAt: Date?
    private var isTodaySyncInFlight = false
    private var hasPendingTodaySync = false
    private var isHistorySyncInFlight = false
    private var onDemandOffsetsInFlight = Set<Int>()
    
    private init() {}
    
    /// 更新数据库容器
    func updateContainer(_ newContainer: ModelContainer) {
        self.container = newContainer
    }
    
    /// 同步过去 7 天的数据到小组件
    func syncAll() async {
        print("[WidgetSync] Starting sync for last 7 days...")
        ensureContainer()
        
        // 优先同步 0 (今天)，然后往回同步到 -6
        for offset in ((-6)...0).reversed() {
            await syncData(forOffset: offset)
        }
        
        WidgetCenter.shared.reloadAllTimelines()
        print("[WidgetSync] Sync complete.")
    }

    /// 同步过去 6 天的快照。今日快照仍走 syncTodayOnly，避免定位高频更新时重画 7 天地图。
    func syncRecentHistoryIfNeeded(force: Bool = false) async {
        guard !isHistorySyncInFlight else { return }

        let defaults = sharedDefaults()
        let now = Date()
        let lastHistorySyncAt = defaults?.double(forKey: "widgetHistorySyncAt") ?? 0
        if !force,
           lastHistorySyncAt > 0,
           now.timeIntervalSince1970 - lastHistorySyncAt < historySyncMinimumInterval {
            return
        }

        isHistorySyncInFlight = true
        defer {
            isHistorySyncInFlight = false
        }

        ensureContainer()
        guard container != nil else { return }

        let selectedOffset = (defaults?.value(forKey: "widgetDateOffset") as? Int) ?? 0
        var offsets: [Int] = []
        if selectedOffset < 0 && selectedOffset >= -6 {
            offsets.append(selectedOffset)
        }
        offsets.append(contentsOf: (-6 ... -1).reversed())

        var seenOffsets = Set<Int>()
        for offset in offsets where seenOffsets.insert(offset).inserted {
            await syncData(forOffset: offset)
            try? await Task.sleep(nanoseconds: 80_000_000)
        }

        defaults?.set(Date().timeIntervalSince1970, forKey: "widgetHistorySyncAt")
        WidgetCenter.shared.reloadAllTimelines()
    }
    
    /// 仅同步今日数据 (用于位置更新等高频场景)
    func syncTodayOnly() async {
        if isTodaySyncInFlight {
            hasPendingTodaySync = true
            return
        }

        let now = Date()
        if let lastTodaySyncAt, now.timeIntervalSince(lastTodaySyncAt) < todaySyncMinimumInterval {
            return
        }

        isTodaySyncInFlight = true
        defer {
            isTodaySyncInFlight = false
        }

        ensureContainer()
        await syncData(forOffset: 0)
        lastTodaySyncAt = Date()
        WidgetCenter.shared.reloadAllTimelines()

        if hasPendingTodaySync {
            hasPendingTodaySync = false
            let followUpDelay = todaySyncMinimumInterval
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                try? await Task.sleep(nanoseconds: UInt64(followUpDelay * 1_000_000_000))
                await self.syncTodayOnly()
            }
        }
    }

    func syncOffsetOnDemand(_ offset: Int) async {
        guard !onDemandOffsetsInFlight.contains(offset) else { return }
        onDemandOffsetsInFlight.insert(offset)
        defer { onDemandOffsetsInFlight.remove(offset) }

        ensureContainer()
        await syncData(forOffset: offset)
        WidgetCenter.shared.reloadAllTimelines()
    }

    func snapshotImagesForOffset(_ offset: Int) async -> (light: UIImage?, dark: UIImage?) {
        let existing = readSnapshotImagesForOffset(offset)
        if existing.light != nil || existing.dark != nil {
            return existing
        }

        await syncOffsetOnDemand(offset)
        return readSnapshotImagesForOffset(offset)
    }

    func makeShareMapSnapshots(
        footprints: [Footprint],
        transports: [TransportRecord],
        activities: [ActivityType],
        size: CGSize = CGSize(width: 329, height: 119)
    ) async -> (light: UIImage?, dark: UIImage?) {
        let aggregatedFootprints = aggregatedFootprints(from: footprints)
        let footprintPhotoImages = await loadAggregatedFootprintPhotoImages(aggregatedFootprints, targetSide: 88)
        let decodedTransports = transports.compactMap { transport -> WidgetDecodedTransport? in
            guard let decoded = try? JSONDecoder().decode([CodableCoordinate].self, from: transport.pointsData),
                  !decoded.isEmpty else {
                return nil
            }
            let coordinates = decoded
                .map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
                .filter {
                    $0.latitude.isFinite &&
                    $0.longitude.isFinite &&
                    CLLocationCoordinate2DIsValid($0)
                }
            guard !coordinates.isEmpty else { return nil }
            return WidgetDecodedTransport(
                record: transport,
                coordinates: coordinates,
                segments: widgetTransportLineSegments(from: decoded)
            )
        }

        let allMapCoordinates = (footprints.flatMap(\.coordinates) + decodedTransports.flatMap(\.coordinates)).filter {
            $0.latitude.isFinite &&
            $0.longitude.isFinite &&
            CLLocationCoordinate2DIsValid($0)
        }
        guard !allMapCoordinates.isEmpty else { return (nil, nil) }

        let allActivities = activities
        let activitiesByID = Dictionary(allActivities.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { first, _ in first })
        let activitiesByName = Dictionary(allActivities.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })

        async let light = makeWidgetMapSnapshot(
            coordinates: allMapCoordinates,
            aggregatedFootprints: aggregatedFootprints,
            footprintPhotoImages: footprintPhotoImages,
            decodedTransports: decodedTransports,
            activitiesByID: activitiesByID,
            activitiesByName: activitiesByName,
            style: .light,
            size: size
        )
        async let dark = makeWidgetMapSnapshot(
            coordinates: allMapCoordinates,
            aggregatedFootprints: aggregatedFootprints,
            footprintPhotoImages: footprintPhotoImages,
            decodedTransports: decodedTransports,
            activitiesByID: activitiesByID,
            activitiesByName: activitiesByName,
            style: .dark,
            size: size
        )
        return await (light, dark)
    }

    private func makeWidgetMapSnapshot(
        coordinates: [CLLocationCoordinate2D],
        aggregatedFootprints: [AggregatedFootprintSnapshot],
        footprintPhotoImages: [String: UIImage],
        decodedTransports: [WidgetDecodedTransport],
        activitiesByID: [String: ActivityType],
        activitiesByName: [String: ActivityType],
        style: UIUserInterfaceStyle,
        size: CGSize
    ) async -> UIImage? {
        var minLat = coordinates[0].latitude
        var maxLat = coordinates[0].latitude
        var minLon = coordinates[0].longitude
        var maxLon = coordinates[0].longitude
        for point in coordinates {
            minLat = min(minLat, point.latitude)
            maxLat = max(maxLat, point.latitude)
            minLon = min(minLon, point.longitude)
            maxLon = max(maxLon, point.longitude)
        }

        let spanLat = max(0.005, (maxLat - minLat) * 2.0)
        let spanLon = max(0.005, (maxLon - minLon) * 2.8)
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2 + spanLat * 0.17, longitude: (minLon + maxLon) / 2),
            span: MKCoordinateSpan(latitudeDelta: spanLat, longitudeDelta: spanLon)
        )

        let options = MKMapSnapshotter.Options()
        options.region = region
        options.size = size
        options.scale = 3.0
        options.traitCollection = UITraitCollection(userInterfaceStyle: style)

        guard let snapshot = try? await MKMapSnapshotter(options: options).start() else {
            return nil
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 3.0
        let renderer = UIGraphicsImageRenderer(size: snapshot.image.size, format: format)
        return renderer.image { ctx in
            snapshot.image.draw(at: .zero)

            ctx.cgContext.setLineCap(.round)
            ctx.cgContext.setLineJoin(.round)
            let themeColor = UIColor(named: "AccentColor") ?? .systemTeal
            let markerOutlineColor = Self.mapMarkerOutlineColor(for: style)

            for transportSnapshot in decodedTransports {
                let clCoords = transportSnapshot.coordinates

                for segment in transportSnapshot.segments {
                    let points = segment.coordinates.map { snapshot.point(for: $0) }
                    guard points.count >= 2 else { continue }

                    ctx.cgContext.beginPath()
                    ctx.cgContext.move(to: points[0])
                    for point in points.dropFirst() {
                        ctx.cgContext.addLine(to: point)
                    }
                    ctx.cgContext.setStrokeColor(themeColor.withAlphaComponent(segment.isDashed ? 0.4 : 0.65).cgColor)
                    ctx.cgContext.setLineWidth(segment.isDashed ? 1.1 : 2.5)
                    ctx.cgContext.setLineDash(phase: 0, lengths: segment.isDashed ? [4, 4] : [])
                    ctx.cgContext.strokePath()
                }
                ctx.cgContext.setLineDash(phase: 0, lengths: [])

                if clCoords.count >= 2, let midCoord = clCoords.widgetMidpoint {
                    let midPoint = snapshot.point(for: midCoord)
                    let rect = CGRect(x: midPoint.x - 7, y: midPoint.y - 7, width: 14, height: 14)
                    let path = UIBezierPath(ovalIn: rect)

                    markerOutlineColor.setFill()
                    path.fill()
                    themeColor.setStroke()
                    path.lineWidth = 1.2
                    path.stroke()

                    let transportType = TransportType(rawValue: transportSnapshot.record.manualTypeRaw ?? transportSnapshot.record.typeRaw) ?? .slow
                    if let iconImage = UIImage(systemName: transportType.sfSymbol) {
                        let symbolSize: CGFloat = 8
                        let symbolRect = CGRect(
                            x: midPoint.x - symbolSize / 2,
                            y: midPoint.y - symbolSize / 2,
                            width: symbolSize,
                            height: symbolSize
                        )
                        iconImage.withTintColor(themeColor).drawAspectFit(in: symbolRect)
                    }
                }
            }

            let sortedFootprints = aggregatedFootprints.sorted { $0.coordinate.latitude > $1.coordinate.latitude }
            for aggregated in sortedFootprints {
                let footprint = aggregated.representative
                let point = snapshot.point(for: aggregated.coordinate)
                let radius: CGFloat = 9
                let center = CGPoint(x: point.x, y: point.y - radius * 1.4)

                let activity = footprint.activityTypeValue.flatMap { activitiesByID[$0] ?? activitiesByName[$0] }
                let activityColor = UIColor(hex: activity?.colorHex ?? "#8E8E93") ?? .gray
                let iconColor: UIColor = .white

                let pinPath = CGMutablePath()
                pinPath.addArc(center: center, radius: radius, startAngle: 140 * .pi / 180, endAngle: 40 * .pi / 180, clockwise: false)
                let bottomY = point.y - 1.5
                pinPath.addLine(to: CGPoint(x: center.x + 1.5, y: bottomY))
                pinPath.addArc(center: CGPoint(x: center.x, y: bottomY), radius: 1.5, startAngle: 0, endAngle: .pi, clockwise: false)
                pinPath.closeSubpath()

                ctx.cgContext.saveGState()
                ctx.cgContext.setShadow(
                    offset: CGSize(width: 0, height: 1.5),
                    blur: 1.5,
                    color: UIColor.black.withAlphaComponent(0.15).cgColor
                )
                ctx.cgContext.setFillColor(markerOutlineColor.cgColor)
                ctx.cgContext.addPath(pinPath)
                ctx.cgContext.fillPath()
                ctx.cgContext.restoreGState()

                let innerRadius = radius - 1.5
                let innerCenter = CGPoint(x: center.x, y: center.y + 0.5)
                let innerCirclePath = UIBezierPath(arcCenter: innerCenter, radius: innerRadius, startAngle: 0, endAngle: 2 * .pi, clockwise: true)

                ctx.cgContext.saveGState()
                innerCirclePath.addClip()
                let colors = [activityColor.withAlphaComponent(0.7).cgColor, activityColor.cgColor] as CFArray
                if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                    ctx.cgContext.drawLinearGradient(
                        gradient,
                        start: CGPoint(x: innerCenter.x, y: innerCenter.y - innerRadius),
                        end: CGPoint(x: innerCenter.x, y: innerCenter.y + innerRadius),
                        options: []
                    )
                } else {
                    activityColor.setFill()
                    innerCirclePath.fill()
                }
                ctx.cgContext.restoreGState()

                if let latestPhotoAssetID = aggregated.latestPhotoAssetID,
                   let photoImage = footprintPhotoImages[latestPhotoAssetID] {
                    let photoRadius = innerRadius + 0.5
                    let photoRect = CGRect(
                        x: innerCenter.x - photoRadius,
                        y: innerCenter.y - photoRadius,
                        width: photoRadius * 2,
                        height: photoRadius * 2
                    )
                    let clipPath = UIBezierPath(ovalIn: photoRect)
                    ctx.cgContext.saveGState()
                    clipPath.addClip()
                    photoImage.drawAspectFill(in: photoRect)
                    ctx.cgContext.restoreGState()
                    activityColor.setStroke()
                    clipPath.lineWidth = 1
                    clipPath.stroke()
                } else {
                    let iconName = activity?.icon ?? FootprintIconDefaults.map
                    if let iconImage = UIImage(systemName: iconName) {
                        let iconSize: CGFloat = 11
                        let iconRect = CGRect(
                            x: innerCenter.x - iconSize / 2,
                            y: innerCenter.y - iconSize / 2,
                            width: iconSize,
                            height: iconSize
                        )
                        iconImage.withTintColor(iconColor, renderingMode: .alwaysTemplate).draw(in: iconRect)
                    }
                }
            }
        }
    }

    private func readSnapshotImagesForOffset(_ offset: Int) -> (light: UIImage?, dark: UIImage?) {
        (
            readSnapshotImage(forOffset: offset, themeName: "light"),
            readSnapshotImage(forOffset: offset, themeName: "dark")
        )
    }

    private func readSnapshotImage(forOffset offset: Int, themeName: String) -> UIImage? {
        let url = getFileURL(forOffset: offset, sizeName: "medium", themeName: themeName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }
    
    private func ensureContainer() {
        if container == nil {
            let schema = Schema(DiFangKeSchemaV2.models)
            
            let config = ModelConfiguration(
                "dfk_v5_stable", 
                schema: schema, 
                groupContainer: groupID.isEmpty ? .none : .identifier(groupID),
                cloudKitDatabase: .none // 核心修复：强制禁用小组件同步容器的 CloudKit，防止与主 App 冲突
            )
            do {
                self.container = try ModelContainer(for: schema, migrationPlan: DiFangKeMigrationPlan.self, configurations: [config])
            } catch {
                print("[WidgetSync] Failed to create fallback container: \(error)")
            }
        }
    }

    private func aggregatedFootprints(from footprints: [Footprint]) -> [AggregatedFootprintSnapshot] {
        struct Bucket {
            var weightedLatitude: Double
            var weightedLongitude: Double
            var totalDuration: TimeInterval
            var representative: Footprint
            var latestPhotoAssetID: String?
            var latestPhotoEndTime: Date?
        }

        var buckets: [String: Bucket] = [:]
        var orderedKeys: [String] = []

        for footprint in footprints {
            let durationWeight = max(footprint.duration, 1)
            let key: String
            if let placeID = footprint.placeID {
                key = "place:\(placeID.uuidString)"
            } else if !footprint.locationHash.isEmpty {
                key = "hash:\(footprint.locationHash)"
            } else {
                key = String(format: "coord:%.5f,%.5f", footprint.latitude, footprint.longitude)
            }

            if var bucket = buckets[key] {
                bucket.weightedLatitude += footprint.latitude * durationWeight
                bucket.weightedLongitude += footprint.longitude * durationWeight
                bucket.totalDuration += footprint.duration
                if footprint.duration > bucket.representative.duration {
                    bucket.representative = footprint
                }
                if let latestPhotoAssetID = footprint.photoAssetIDs.last,
                   bucket.latestPhotoEndTime == nil || footprint.endTime >= bucket.latestPhotoEndTime! {
                    bucket.latestPhotoAssetID = latestPhotoAssetID
                    bucket.latestPhotoEndTime = footprint.endTime
                }
                buckets[key] = bucket
            } else {
                orderedKeys.append(key)
                buckets[key] = Bucket(
                    weightedLatitude: footprint.latitude * durationWeight,
                    weightedLongitude: footprint.longitude * durationWeight,
                    totalDuration: footprint.duration,
                    representative: footprint,
                    latestPhotoAssetID: footprint.photoAssetIDs.last,
                    latestPhotoEndTime: footprint.photoAssetIDs.isEmpty ? nil : footprint.endTime
                )
            }
        }

        return orderedKeys.compactMap { key in
            guard let bucket = buckets[key] else { return nil }
            let divisor = max(bucket.totalDuration, 1)
            let representative = bucket.representative
            return AggregatedFootprintSnapshot(
                coordinate: CLLocationCoordinate2D(
                    latitude: bucket.weightedLatitude / divisor,
                    longitude: bucket.weightedLongitude / divisor
                ),
                totalDuration: bucket.totalDuration,
                representative: representative,
                latestPhotoAssetID: bucket.latestPhotoAssetID
            )
        }
    }

    private func loadWidgetSnapshotAssetImage(assetID: String, targetSize: CGSize) async -> UIImage? {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return nil }

        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil)
        guard let asset = assets.firstObject else { return nil }

        return await withCheckedContinuation { continuation in
            let continuationBox = WidgetImageContinuation(continuation)
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = false
            options.deliveryMode = .fastFormat
            options.resizeMode = .exact

            PHImageManager.default().requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFill,
                options: options
            ) { image, _ in
                continuationBox.resume(returning: image)
            }
        }
    }

    private func loadAggregatedFootprintPhotoImages(_ aggregatedFootprints: [AggregatedFootprintSnapshot], targetSide: CGFloat) async -> [String: UIImage] {
        let assetIDs = Set(aggregatedFootprints.compactMap(\.latestPhotoAssetID))
        guard !assetIDs.isEmpty else { return [:] }

        var images: [String: UIImage] = [:]
        for assetID in assetIDs {
            if let image = await loadWidgetSnapshotAssetImage(assetID: assetID, targetSize: CGSize(width: targetSide, height: targetSide)) {
                images[assetID] = image
            }
        }
        return images
    }

    private struct WidgetTransportLineSegment {
        let coordinates: [CLLocationCoordinate2D]
        let isDashed: Bool
    }

    private struct WidgetDecodedTransport {
        let record: TransportRecord
        let coordinates: [CLLocationCoordinate2D]
        let segments: [WidgetTransportLineSegment]
    }

    private func widgetTransportLineSegments(from decoded: [CodableCoordinate]) -> [WidgetTransportLineSegment] {
        let validPoints = decoded.filter {
            $0.lat.isFinite &&
            $0.lon.isFinite &&
            CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon))
        }
        guard validPoints.count >= 2 else { return [] }

        var segments: [WidgetTransportLineSegment] = []
        var currentChunk = [CLLocationCoordinate2D(latitude: validPoints[0].lat, longitude: validPoints[0].lon)]
        var currentDashed: Bool?

        for index in 0..<(validPoints.count - 1) {
            let current = validPoints[index]
            let next = validPoints[index + 1]
            let isDashed: Bool
            if current.isSyntheticPadding == true || next.isSyntheticPadding == true {
                isDashed = true
            } else if let currentTime = current.timestamp, let nextTime = next.timestamp {
                isDashed = abs(nextTime.timeIntervalSince(currentTime)) > 3 * 60
            } else {
                isDashed = false
            }

            if currentDashed == nil {
                currentDashed = isDashed
            }

            let nextCoordinate = CLLocationCoordinate2D(latitude: next.lat, longitude: next.lon)
            if currentDashed == isDashed {
                currentChunk.append(nextCoordinate)
            } else {
                segments.append(WidgetTransportLineSegment(
                    coordinates: currentChunk.smoothed(),
                    isDashed: currentDashed == true
                ))
                currentChunk = [
                    CLLocationCoordinate2D(latitude: current.lat, longitude: current.lon),
                    nextCoordinate
                ]
                currentDashed = isDashed
            }
        }

        if currentChunk.count >= 2 {
            segments.append(WidgetTransportLineSegment(
                coordinates: currentChunk.smoothed(),
                isDashed: currentDashed == true
            ))
        }

        for i in 0..<segments.count {
            if segments[i].isDashed && segments[i].coordinates.count == 2 {
                let p0 = segments[i].coordinates[0]
                let p3 = segments[i].coordinates[1]
                
                var p0TangentPrev: CLLocationCoordinate2D? = nil
                if i > 0 && !segments[i-1].isDashed {
                    let prevSolid = segments[i-1].coordinates
                    if prevSolid.count >= 10 {
                        p0TangentPrev = prevSolid[prevSolid.count - 1 - Swift.min(prevSolid.count - 1, 10)]
                    } else if prevSolid.count >= 2 {
                        p0TangentPrev = prevSolid.first!
                    }
                }
                
                var p3TangentNext: CLLocationCoordinate2D? = nil
                if i < segments.count - 1 && !segments[i+1].isDashed {
                    let nextSolid = segments[i+1].coordinates
                    if nextSolid.count >= 10 {
                        p3TangentNext = nextSolid[Swift.min(nextSolid.count - 1, 10)]
                    } else if nextSolid.count >= 2 {
                        p3TangentNext = nextSolid.last!
                    }
                }
                
                let dLat0 = p0TangentPrev != nil ? p0.latitude - p0TangentPrev!.latitude : 0
                let dLon0 = p0TangentPrev != nil ? p0.longitude - p0TangentPrev!.longitude : 0
                let dLat3 = p3TangentNext != nil ? p3TangentNext!.latitude - p3.latitude : 0
                let dLon3 = p3TangentNext != nil ? p3TangentNext!.longitude - p3.longitude : 0
                
                let distLat = p3.latitude - p0.latitude
                let distLon = p3.longitude - p0.longitude
                let dist = sqrt(distLat*distLat + distLon*distLon)
                
                let len0 = sqrt(dLat0*dLat0 + dLon0*dLon0)
                let len3 = sqrt(dLat3*dLat3 + dLon3*dLon3)
                
                let scale0 = len0 > 0 ? (dist * 0.35) / len0 : 0
                let scale3 = len3 > 0 ? (dist * 0.35) / len3 : 0
                
                let c1 = CLLocationCoordinate2D(
                    latitude: p0.latitude + (len0 > 0 ? dLat0 * scale0 : distLat * 0.3),
                    longitude: p0.longitude + (len0 > 0 ? dLon0 * scale0 : distLon * 0.3)
                )
                let c2 = CLLocationCoordinate2D(
                    latitude: p3.latitude - (len3 > 0 ? dLat3 * scale3 : distLat * 0.3),
                    longitude: p3.longitude - (len3 > 0 ? dLon3 * scale3 : distLon * 0.3)
                )
                
                var bezierPoints: [CLLocationCoordinate2D] = []
                let steps = 20
                for j in 0...steps {
                    let t = Double(j) / Double(steps)
                    let u = 1.0 - t
                    let u2 = u * u
                    let u3 = u2 * u
                    let t2 = t * t
                    let t3 = t2 * t
                    
                    let lat = u3 * p0.latitude + 3.0 * u2 * t * c1.latitude + 3.0 * u * t2 * c2.latitude + t3 * p3.latitude
                    let lon = u3 * p0.longitude + 3.0 * u2 * t * c1.longitude + 3.0 * u * t2 * c2.longitude + t3 * p3.longitude
                    bezierPoints.append(CLLocationCoordinate2D(latitude: lat, longitude: lon))
                }
                
                segments[i] = WidgetTransportLineSegment(coordinates: bezierPoints, isDashed: true)
            }
        }

        return segments
    }
    
    private func syncData(forOffset offset: Int) async {
        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)
        let targetDate = calendar.date(byAdding: .day, value: offset, to: startOfToday) ?? startOfToday
        let startOfTargetDay = targetDate
        let endOfTargetDay = calendar.date(byAdding: .day, value: 1, to: startOfTargetDay) ?? startOfTargetDay.addingTimeInterval(86400)
        
        guard let container = self.container else { return }
        let context = container.mainContext
        
        do {
            // 1. 获取数据
            let descriptor = FetchDescriptor<Footprint>(
                predicate: #Predicate<Footprint> { 
                    $0.startTime < endOfTargetDay && $0.endTime >= startOfTargetDay && $0.statusValue != "ignored"
                }
            )
            let footprints = try context.fetch(descriptor)
            
            let transportDescriptor = FetchDescriptor<TransportRecord>(
                predicate: #Predicate<TransportRecord> {
                    $0.startTime < endOfTargetDay && $0.endTime >= startOfTargetDay && $0.statusRaw != "ignored"
                }
            )
            let transports = (try? context.fetch(transportDescriptor)) ?? []
            let allActivities = (try? context.fetch(FetchDescriptor<ActivityType>())) ?? []
            let aggregatedFootprints = aggregatedFootprints(from: footprints)
            let footprintPhotoImages = await loadAggregatedFootprintPhotoImages(aggregatedFootprints, targetSide: 88)
            let decodedTransports = transports.compactMap { transport -> WidgetDecodedTransport? in
                guard let decoded = try? JSONDecoder().decode([CodableCoordinate].self, from: transport.pointsData),
                      !decoded.isEmpty else {
                    return nil
                }
                let coordinates = decoded
                    .map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
                    .filter {
                        $0.latitude.isFinite &&
                        $0.longitude.isFinite &&
                        CLLocationCoordinate2DIsValid($0)
                    }
                return WidgetDecodedTransport(
                    record: transport,
                    coordinates: coordinates,
                    segments: widgetTransportLineSegments(from: decoded)
                )
            }
            let footprintCoordinates = footprints.flatMap(\.coordinates)
            let transportCoordinates = decodedTransports.flatMap(\.coordinates)
            let allMapCoordinates = (footprintCoordinates + transportCoordinates).filter {
                $0.latitude.isFinite &&
                $0.longitude.isFinite &&
                CLLocationCoordinate2DIsValid($0)
            }
            let activitiesByID = Dictionary(allActivities.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { first, _ in first })
            let activitiesByName = Dictionary(allActivities.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
            
            let defaults = sharedDefaults()
            let lastLat = defaults?.double(forKey: "lastLat") ?? 39.9042
            let lastLon = defaults?.double(forKey: "lastLon") ?? 116.4074
            
            // 2. 为不同尺寸和主题生成图片
            let sizes: [(name: String, size: CGSize)] = [
                ("small", CGSize(width: 155, height: 155)),
                ("medium", CGSize(width: 329, height: 155)),
                ("large", CGSize(width: 329, height: 345))
            ]
            let themes: [UIUserInterfaceStyle] = [.light, .dark]
            
            for s in sizes {
                for theme in themes {
                    let themeName = theme == .dark ? "dark" : "light"
                    
                    let region: MKCoordinateRegion
                    if !allMapCoordinates.isEmpty {
                        var minLat = allMapCoordinates[0].latitude; var maxLat = allMapCoordinates[0].latitude
                        var minLon = allMapCoordinates[0].longitude; var maxLon = allMapCoordinates[0].longitude
                        for p in allMapCoordinates {
                            minLat = min(minLat, p.latitude); maxLat = max(maxLat, p.latitude)
                            minLon = min(minLon, p.longitude); maxLon = max(maxLon, p.longitude)
                        }
                        
                        let spanLat = max(0.005, (maxLat - minLat) * 1.6)
                        let spanLon = max(0.005, (maxLon - minLon) * 1.6)
                        let finalSpanLon = s.name == "medium" ? spanLon * 1.5 : spanLon
                        
                        region = MKCoordinateRegion(
                            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
                            span: MKCoordinateSpan(latitudeDelta: spanLat, longitudeDelta: finalSpanLon)
                        )
                    } else {
                        region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: lastLat, longitude: lastLon), span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05))
                    }
                    
                    let options = MKMapSnapshotter.Options()
                    options.region = region
                    options.size = s.size
                    options.scale = 2.0
                    options.traitCollection = UITraitCollection(userInterfaceStyle: theme)
                    
                    let snapshotter = MKMapSnapshotter(options: options)
                    if let snapshot = try? await snapshotter.start() {
                        let format = UIGraphicsImageRendererFormat()
                        format.scale = 2.0
                        let renderer = UIGraphicsImageRenderer(size: snapshot.image.size, format: format)
                        let image = renderer.image { ctx in
                            snapshot.image.draw(at: .zero)
                            
                            // 绘制路线
                            ctx.cgContext.setLineCap(.round)
                            ctx.cgContext.setLineJoin(.round)
                            let themeColor = UIColor(named: "AccentColor") ?? .systemTeal
                            let markerOutlineColor = Self.mapMarkerOutlineColor(for: theme)
                            
                            for transportSnapshot in decodedTransports {
                                let clCoords = transportSnapshot.coordinates

                                for segment in transportSnapshot.segments {
                                    let points = segment.coordinates.map { snapshot.point(for: $0) }
                                    guard points.count >= 2 else { continue }

                                    ctx.cgContext.beginPath()
                                    ctx.cgContext.move(to: points[0])
                                    for i in 1..<points.count { ctx.cgContext.addLine(to: points[i]) }
                                    ctx.cgContext.setStrokeColor(
                                        themeColor.withAlphaComponent(segment.isDashed ? 0.4 : 0.65).cgColor
                                    )
                                    ctx.cgContext.setLineWidth(segment.isDashed ? 1.1 : 2.5)
                                    ctx.cgContext.setLineDash(phase: 0, lengths: segment.isDashed ? [4, 4] : [])
                                    ctx.cgContext.strokePath()
                                }
                                ctx.cgContext.setLineDash(phase: 0, lengths: [])

                                if clCoords.count >= 2, let midCoord = clCoords.widgetMidpoint {
                                    let midPoint = snapshot.point(for: midCoord)
                                    let rect = CGRect(x: midPoint.x - 7, y: midPoint.y - 7, width: 14, height: 14)
                                    let path = UIBezierPath(ovalIn: rect)

                                    markerOutlineColor.setFill()
                                    path.fill()
                                    themeColor.setStroke()
                                    path.lineWidth = 1.2
                                    path.stroke()

                                    let transportType = TransportType(rawValue: transportSnapshot.record.manualTypeRaw ?? transportSnapshot.record.typeRaw) ?? .slow
                                    if let iconImage = UIImage(systemName: transportType.sfSymbol) {
                                        let symbolSize: CGFloat = 8
                                        let symbolRect = CGRect(x: midPoint.x - symbolSize/2, y: midPoint.y - symbolSize/2, width: symbolSize, height: symbolSize)
                                        iconImage.withTintColor(themeColor).drawAspectFit(in: symbolRect)
                                    }
                                }
                            }
                            
                            // 绘制聚合足迹，按纬度从北到南排序，使得靠南的图标盖住靠北的图标
                            let sortedFootprints = aggregatedFootprints.sorted { $0.coordinate.latitude > $1.coordinate.latitude }
                            for aggregated in sortedFootprints {
                                let fp = aggregated.representative
                                let point = snapshot.point(for: aggregated.coordinate)
                                let radius: CGFloat = 9.0
                                let center = CGPoint(x: point.x, y: point.y - radius * 1.4)
                                
                                let activity = fp.activityTypeValue.flatMap { activitiesByID[$0] ?? activitiesByName[$0] }
                                let activityColor = UIColor(hex: activity?.colorHex ?? "#8E8E93") ?? .gray
                                let iconColor: UIColor = .white
                                
                                let pinPath = CGMutablePath()
                                pinPath.addArc(center: center, radius: radius, startAngle: 140 * .pi / 180, endAngle: 40 * .pi / 180, clockwise: false)
                                let bottomY = point.y - 1.5
                                pinPath.addLine(to: CGPoint(x: center.x + 1.5, y: bottomY))
                                pinPath.addArc(center: CGPoint(x: center.x, y: bottomY), radius: 1.5, startAngle: 0, endAngle: .pi, clockwise: false)
                                pinPath.closeSubpath()

                                ctx.cgContext.saveGState()
                                ctx.cgContext.setShadow(offset: CGSize(width: 0, height: 1.5), blur: 1.5, color: UIColor.black.withAlphaComponent(0.15).cgColor)
                                ctx.cgContext.setFillColor(markerOutlineColor.cgColor)
                                ctx.cgContext.addPath(pinPath)
                                ctx.cgContext.fillPath()
                                ctx.cgContext.restoreGState()

                                let innerRadius = radius - 1.5
                                let innerCenter = CGPoint(x: center.x, y: center.y + 0.5)
                                let innerCirclePath = UIBezierPath(arcCenter: innerCenter, radius: innerRadius, startAngle: 0, endAngle: 2 * .pi, clockwise: true)
                                
                                ctx.cgContext.saveGState()
                                innerCirclePath.addClip()
                                let colors = [activityColor.withAlphaComponent(0.7).cgColor, activityColor.cgColor] as CFArray
                                if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0.0, 1.0]) {
                                    ctx.cgContext.drawLinearGradient(gradient, start: CGPoint(x: innerCenter.x, y: innerCenter.y - innerRadius), end: CGPoint(x: innerCenter.x, y: innerCenter.y + innerRadius), options: [])
                                } else {
                                    activityColor.setFill()
                                    innerCirclePath.fill()
                                }
                                ctx.cgContext.restoreGState()

                                if let latestPhotoAssetID = aggregated.latestPhotoAssetID,
                                   let photoImage = footprintPhotoImages[latestPhotoAssetID] {
                                    let photoRadius = innerRadius + 0.5
                                    let photoRect = CGRect(x: innerCenter.x - photoRadius, y: innerCenter.y - photoRadius, width: photoRadius * 2, height: photoRadius * 2)
                                    let clipPath = UIBezierPath(ovalIn: photoRect)
                                    ctx.cgContext.saveGState()
                                    clipPath.addClip()
                                    photoImage.drawAspectFill(in: photoRect)
                                    ctx.cgContext.restoreGState()
                                    activityColor.setStroke()
                                    clipPath.lineWidth = 1.0
                                    clipPath.stroke()
                                } else {
                                    let iconName = activity?.icon ?? FootprintIconDefaults.map
                                    if let iconImage = UIImage(systemName: iconName) {
                                        let iconSize: CGFloat = 11.0
                                        let iconRect = CGRect(x: innerCenter.x - iconSize/2, y: innerCenter.y - iconSize/2, width: iconSize, height: iconSize)
                                        iconImage.withTintColor(iconColor, renderingMode: .alwaysTemplate).draw(in: iconRect)
                                    }
                                }
                            }
                        }
                        
                        // 保存图片
                        if let data = image.jpegData(compressionQuality: 0.8) {
                            let fileURL = getFileURL(forOffset: offset, sizeName: s.name, themeName: themeName)
                            try? data.write(to: fileURL)
                        }
                    }
                }
            }
            
            // 更新元数据
            let uniqueFootprintCount = Set(footprints.map { fp -> String in
                if let addr = fp.address, !addr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return addr
                }
                return fp.locationHash
            }).count
            defaults?.set(uniqueFootprintCount, forKey: "widgetCount_\(offset)")
            defaults?.set(Date().timeIntervalSince1970, forKey: "widgetUpdate_\(offset)")
            
        } catch {
            print("[WidgetSync] Sync error for offset \(offset): \(error)")
        }
    }
    
    private func getFileURL(forOffset offset: Int, sizeName: String, themeName: String) -> URL {
        let manager = FileManager.default
        let containerURL = manager.containerURL(forSecurityApplicationGroupIdentifier: groupID)
        let fileName = "widget_snapshot_\(sizeName)_\(themeName)_\(offset)_\(Self.snapshotFileVersion).jpg"
        return containerURL!.appendingPathComponent(fileName)
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

    private func sharedDefaults() -> UserDefaults? {
#if targetEnvironment(simulator)
        return .standard
#else
        return groupID.isEmpty ? .standard : (UserDefaults(suiteName: groupID) ?? .standard)
#endif
    }
}


// 辅助扩展
extension Array where Element == CLLocationCoordinate2D {
    var widgetMidpoint: CLLocationCoordinate2D? {
        guard !isEmpty else { return nil }
        if count == 1 { return first }
        
        var totalDist: Double = 0
        var segments: [Double] = [0]
        
        for i in 0..<count-1 {
            let p1 = CLLocation(latitude: self[i].latitude, longitude: self[i].longitude)
            let p2 = CLLocation(latitude: self[i+1].latitude, longitude: self[i+1].longitude)
            let d = p1.distance(from: p2)
            totalDist += d
            segments.append(totalDist)
        }
        
        if totalDist == 0 { return self[count/2] }
        let mid = totalDist / 2
        
        for i in 0..<count-1 {
            if mid >= segments[i] && mid <= segments[i+1] {
                let ratio = (mid - segments[i]) / (segments[i+1] - segments[i])
                return CLLocationCoordinate2D(
                    latitude: self[i].latitude + (self[i+1].latitude - self[i].latitude) * ratio,
                    longitude: self[i].longitude + (self[i+1].longitude - self[i].longitude) * ratio
                )
            }
        }
        return self[count/2]
    }
}

// 辅助方法：Hex 转 UIColor
extension UIColor {
    convenience init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")
        var rgb: UInt64 = 0
        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else { return nil }
        self.init(
            red: CGFloat((rgb & 0xFF0000) >> 16) / 255.0,
            green: CGFloat((rgb & 0x00FF00) >> 8) / 255.0,
            blue: CGFloat(rgb & 0x0000FF) / 255.0,
            alpha: 1.0
        )
    }
}

private extension UIImage {
    func drawAspectFill(in rect: CGRect) {
        guard size.width > 0, size.height > 0, rect.width > 0, rect.height > 0 else {
            draw(in: rect)
            return
        }

        let scale = max(rect.width / size.width, rect.height / size.height)
        let drawSize = CGSize(width: size.width * scale, height: size.height * scale)
        let drawRect = CGRect(
            x: rect.midX - drawSize.width / 2,
            y: rect.midY - drawSize.height / 2,
            width: drawSize.width,
            height: drawSize.height
        )
        draw(in: drawRect)
    }

    func drawAspectFit(in rect: CGRect) {
        guard size.width > 0, size.height > 0, rect.width > 0, rect.height > 0 else {
            draw(in: rect)
            return
        }

        let scale = min(rect.width / size.width, rect.height / size.height)
        let drawSize = CGSize(width: size.width * scale, height: size.height * scale)
        let drawRect = CGRect(
            x: rect.midX - drawSize.width / 2,
            y: rect.midY - drawSize.height / 2,
            width: drawSize.width,
            height: drawSize.height
        )
        draw(in: drawRect)
    }
}
