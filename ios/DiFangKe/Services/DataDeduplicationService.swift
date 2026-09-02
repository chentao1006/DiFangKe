import Foundation
import SwiftData
import CoreLocation

@MainActor
enum DataDeduplicationService {
    struct Report {
        var placesDeleted = 0
        var footprintReferencesRewritten = 0
        var footprintsDeleted = 0
        var transportsDeleted = 0
        var activityTypesDeleted = 0

        var didChange: Bool {
            placesDeleted > 0 || footprintReferencesRewritten > 0 || footprintsDeleted > 0 || transportsDeleted > 0 || activityTypesDeleted > 0
        }
    }

    static func run(context: ModelContext) -> Report {
        var report = Report()

        let places = (try? context.fetch(FetchDescriptor<Place>())) ?? []
        let footprints = (try? context.fetch(FetchDescriptor<Footprint>())) ?? []
        let transports = (try? context.fetch(FetchDescriptor<TransportRecord>())) ?? []
        let activityTypes = (try? context.fetch(FetchDescriptor<ActivityType>())) ?? []
        let futureTrips = (try? context.fetch(FetchDescriptor<FutureTrip>())) ?? []

        print("[DataDeduplication] before places=\(places.count), footprints=\(footprints.count), transports=\(transports.count), activityTypes=\(activityTypes.count)")

        let placeRewriteMap = deduplicatePlaces(places, footprints: footprints, context: context, report: &report)
        let normalizedFootprints = rewriteFootprintPlaceReferences(footprints, placeRewriteMap: placeRewriteMap, report: &report)
        deduplicateFootprints(normalizedFootprints, context: context, report: &report)
        deduplicateTransports(transports, context: context, report: &report)
        deduplicateActivityTypes(activityTypes, footprints: normalizedFootprints, futureTrips: futureTrips, context: context, report: &report)

        if report.didChange {
            do {
                try context.save()
            } catch {
                print("[DataDeduplication] save failed: \(error)")
            }
        }

        let remainingPlaces = (try? context.fetchCount(FetchDescriptor<Place>())) ?? -1
        let remainingFootprints = (try? context.fetchCount(FetchDescriptor<Footprint>())) ?? -1
        let remainingTransports = (try? context.fetchCount(FetchDescriptor<TransportRecord>())) ?? -1
        let remainingActivityTypes = (try? context.fetchCount(FetchDescriptor<ActivityType>())) ?? -1
        print("[DataDeduplication] deleted places=\(report.placesDeleted), rewrittenFootprints=\(report.footprintReferencesRewritten), deletedFootprints=\(report.footprintsDeleted), deletedTransports=\(report.transportsDeleted), deletedActivityTypes=\(report.activityTypesDeleted)")
        print("[DataDeduplication] after places=\(remainingPlaces), footprints=\(remainingFootprints), transports=\(remainingTransports), activityTypes=\(remainingActivityTypes)")

        return report
    }

    /// Safe to run during normal timeline rebuilding.  This intentionally only
    /// touches transport records, so a bad rebuild cannot make the timeline
    /// grow on every launch while leaving user places and footprints alone.
    @discardableResult
    static func deduplicateTransports(context: ModelContext) -> Int {
        var report = Report()
        let transports = (try? context.fetch(FetchDescriptor<TransportRecord>())) ?? []
        deduplicateTransports(transports, context: context, report: &report)
        if report.transportsDeleted > 0 {
            do {
                try context.save()
            } catch {
                print("[DataDeduplication] transport cleanup save failed: \(error)")
            }
        }
        return report.transportsDeleted
    }

    /// Cleans up only the records that can affect a rebuilt calendar day.  This
    /// is deliberately narrower than the launch-time maintenance pass: two
    /// automatic builders can observe different raw-point windows during one
    /// sync and leave adjacent copies of the same route behind.
    @discardableResult
    static func deduplicateTransports(intersecting date: Date, context: ModelContext) -> Int {
        let startOfDay = Calendar.current.startOfDay(for: date)
        let endOfDay = Calendar.current.date(byAdding: .day, value: 1, to: startOfDay) ?? startOfDay
        let descriptor = FetchDescriptor<TransportRecord>(predicate: #Predicate {
            $0.startTime < endOfDay && $0.endTime > startOfDay
        })

        var report = Report()
        let transports = (try? context.fetch(descriptor)) ?? []
        deduplicateTransports(transports, context: context, report: &report)
        if report.transportsDeleted > 0 {
            do {
                try context.save()
                print("[TimelineAuto] removed \(report.transportsDeleted) duplicate transport(s) for \(startOfDay)")
            } catch {
                print("[TimelineAuto] failed to save duplicate transport cleanup: \(error)")
            }
        }
        return report.transportsDeleted
    }

    private static func deduplicatePlaces(_ places: [Place], footprints: [Footprint], context: ModelContext, report: inout Report) -> [UUID: UUID] {
        var rewriteMap: [UUID: UUID] = [:]
        var remainingPlaces = places
        let referencedPlaceIDs = Set(footprints.compactMap(\.placeID))
        
        while !remainingPlaces.isEmpty {
            let keeper = remainingPlaces.removeFirst()
            var duplicates: [Place] = []
            
            remainingPlaces.removeAll { candidate in
                let sameName = keeper.name == candidate.name
                let loc1 = CLLocation(latitude: keeper.latitude, longitude: keeper.longitude)
                let loc2 = CLLocation(latitude: candidate.latitude, longitude: candidate.longitude)
                // Same name and within 50 meters, or completely identical UUID
                if candidate.placeID == keeper.placeID || (sameName && loc1.distance(from: loc2) < 50) {
                    duplicates.append(candidate)
                    return true
                }
                return false
            }
            
            if !duplicates.isEmpty {
                var allVersions = [keeper] + duplicates
                allVersions.sort { placeKeepScore($0, referencedPlaceIDs: referencedPlaceIDs) > placeKeepScore($1, referencedPlaceIDs: referencedPlaceIDs) }
                
                let best = allVersions.first!
                
                for duplicate in allVersions.dropFirst() {
                    mergePlace(duplicate, into: best)
                    rewriteMap[duplicate.placeID] = best.placeID
                    context.delete(duplicate)
                    report.placesDeleted += 1
                }
            }
        }
        return rewriteMap
    }

    private static func rewriteFootprintPlaceReferences(_ footprints: [Footprint], placeRewriteMap: [UUID: UUID], report: inout Report) -> [Footprint] {
        guard !placeRewriteMap.isEmpty else { return footprints }

        for footprint in footprints {
            guard let placeID = footprint.placeID, let rewrittenID = placeRewriteMap[placeID] else { continue }
            footprint.placeID = rewrittenID
            report.footprintReferencesRewritten += 1
        }

        return footprints
    }

    private static func deduplicateFootprints(_ footprints: [Footprint], context: ModelContext, report: inout Report) {
        let groupedByDay = Dictionary(grouping: footprints) { Calendar.current.startOfDay(for: $0.date) }
        
        for (_, dayFootprints) in groupedByDay {
            var sorted = dayFootprints.sorted { $0.startTime < $1.startTime }
            while !sorted.isEmpty {
                let keeper = sorted.removeFirst()
                var duplicates: [Footprint] = []
                
                sorted.removeAll { candidate in
                    // A split is represented by two independently persisted
                    // `.manual` footprints.  Never turn either side of that
                    // user-authored boundary into a deduplication candidate,
                    // even when an older device syncs an overlapping snapshot.
                    guard keeper.status != .manual, candidate.status != .manual else {
                        return false
                    }
                    let startDiff = abs(candidate.startTime.timeIntervalSince(keeper.startTime))
                    let endDiff = abs(candidate.endTime.timeIntervalSince(keeper.endTime))
                    // Start and end within 5 minutes of each other
                    if startDiff <= 300 && endDiff <= 300 {
                        duplicates.append(candidate)
                        return true
                    }
                    return false
                }
                
                if !duplicates.isEmpty {
                    var allVersions = [keeper] + duplicates
                    allVersions.sort { footprintKeepScore($0) > footprintKeepScore($1) }
                    
                    let best = allVersions.first!
                    
                    for duplicate in allVersions.dropFirst() {
                        mergeFootprint(duplicate, into: best)
                        context.delete(duplicate)
                        report.footprintsDeleted += 1
                    }
                }
            }
        }
    }

    private static func deduplicateTransports(_ transports: [TransportRecord], context: ModelContext, report: inout Report) {
        let groupedByDay = Dictionary(grouping: transports) { Calendar.current.startOfDay(for: $0.day) }
        
        for (_, dayTransports) in groupedByDay {
            var sorted = dayTransports.sorted { $0.startTime < $1.startTime }
            while !sorted.isEmpty {
                let keeper = sorted.removeFirst()
                var duplicates: [TransportRecord] = []
                
                sorted.removeAll { candidate in
                    // A person cannot be taking two automatically detected modes
                    // of transport at once.  Rebuilds can describe the same raw
                    // route with slightly different boundaries when Health/Motion
                    // data arrives late, so endpoint proximity alone is too
                    // strict.  Two manual records are left alone, since they
                    // are explicit user edits.  When only one is manual, the
                    // scoring below keeps it and removes the automatic shadow.
                    guard keeper.manualTypeRaw == nil || candidate.manualTypeRaw == nil else {
                        return false
                    }
                    let isSameTrip = isSameAutomaticTrip(keeper, candidate)
                    if isSameTrip {
                        duplicates.append(candidate)
                        return true
                    }
                    return false
                }
                
                if !duplicates.isEmpty {
                    var allVersions = [keeper] + duplicates
                    allVersions.sort { transportKeepScore($0) > transportKeepScore($1) }
                    
                    let best = allVersions.first!
                    
                    for duplicate in allVersions.dropFirst() {
                        mergeTransport(duplicate, into: best)
                        context.delete(duplicate)
                        report.transportsDeleted += 1
                    }
                }
            }
        }
    }

    private static func deduplicateActivityTypes(_ activityTypes: [ActivityType], footprints: [Footprint], futureTrips: [FutureTrip], context: ModelContext, report: inout Report) {
        let groupedByName = Dictionary(grouping: activityTypes) { $0.name }
        
        for (_, group) in groupedByName where group.count > 1 {
            let sorted = group.sorted { first, second in
                if first.isSystem != second.isSystem { return first.isSystem }
                return first.sortOrder < second.sortOrder
            }
            
            let keeper = sorted.first!
            
            for duplicate in sorted.dropFirst() {
                let duplicateIDString = duplicate.id.uuidString
                let keeperIDString = keeper.id.uuidString
                
                for footprint in footprints where footprint.activityTypeValue == duplicateIDString {
                    footprint.activityTypeValue = keeperIDString
                    report.footprintReferencesRewritten += 1
                }
                
                for trip in futureTrips where trip.activityTypeValue == duplicateIDString {
                    trip.activityTypeValue = keeperIDString
                }
                
                context.delete(duplicate)
                report.activityTypesDeleted += 1
            }
        }
    }

    private static func mergePlace(_ duplicate: Place, into keeper: Place) {
        keeper.isPriority = keeper.isPriority || duplicate.isPriority
        keeper.isIgnored = keeper.isIgnored && duplicate.isIgnored
        keeper.isUserDefined = keeper.isUserDefined || duplicate.isUserDefined
        if keeper.address?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            keeper.address = duplicate.address
        }
        if keeper.category?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            keeper.category = duplicate.category
        }
        keeper.radius = max(keeper.radius, duplicate.radius)
    }

    private static func mergeFootprint(_ duplicate: Footprint, into keeper: Footprint) {
        if keeper.reason?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            keeper.reason = duplicate.reason
        }
        if keeper.address?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            keeper.address = duplicate.address
            keeper.isAddressEditedByHand = duplicate.isAddressEditedByHand
        }
        if keeper.placeID == nil {
            keeper.placeID = duplicate.placeID
        }
        if keeper.activityTypeValue == nil {
            keeper.activityTypeValue = duplicate.activityTypeValue
        }
        if keeper.isHighlight != true {
            keeper.isHighlight = duplicate.isHighlight
        }
        keeper.isPlaceSuggestionIgnored = keeper.isPlaceSuggestionIgnored || duplicate.isPlaceSuggestionIgnored
        keeper.aiAnalyzed = keeper.aiAnalyzed || duplicate.aiAnalyzed
        keeper.isAddressEditedByHand = keeper.isAddressEditedByHand || duplicate.isAddressEditedByHand
        keeper.aiScore = max(keeper.aiScore, duplicate.aiScore)
        keeper.stepCount = combinedOptionalMax(keeper.stepCount, duplicate.stepCount)
        keeper.walkingDistance = combinedOptionalMax(keeper.walkingDistance, duplicate.walkingDistance)
        keeper.floorsAscended = combinedOptionalMax(keeper.floorsAscended, duplicate.floorsAscended)

        var mergedPhotos = keeper.photoAssetIDs
        for photoID in duplicate.photoAssetIDs where !mergedPhotos.contains(photoID) {
            mergedPhotos.append(photoID)
        }
        keeper.photoAssetIDs = mergedPhotos

        var mergedMetadata = keeper.photoMetadata
        for metadata in duplicate.photoMetadata where !mergedMetadata.contains(metadata) {
            mergedMetadata.append(metadata)
        }
        keeper.photoMetadata = mergedMetadata
    }

    private static func mergeTransport(_ duplicate: TransportRecord, into keeper: TransportRecord) {
        if keeper.manualTypeRaw == nil {
            keeper.manualTypeRaw = duplicate.manualTypeRaw
        }
        if keeper.statusRaw != "active" {
            keeper.statusRaw = duplicate.statusRaw
        }
        keeper.stepCount = combinedOptionalMax(keeper.stepCount, duplicate.stepCount)
        keeper.distance = max(keeper.distance, duplicate.distance)
        keeper.averageSpeed = max(keeper.averageSpeed, duplicate.averageSpeed)
        if keeper.pointsData.isEmpty {
            keeper.pointsData = duplicate.pointsData
        }
    }

    private static func isSameAutomaticTrip(_ first: TransportRecord, _ second: TransportRecord) -> Bool {
        let overlap = max(0, min(first.endTime, second.endTime).timeIntervalSince(max(first.startTime, second.startTime)))
        let shorterDuration = min(
            first.endTime.timeIntervalSince(first.startTime),
            second.endTime.timeIntervalSince(second.startTime)
        )
        if shorterDuration > 0 && overlap / shorterDuration >= 0.8 {
            return true
        }

        // Some rebuild paths consume the same raw route from the two sides of a
        // gap.  That can leave adjacent records such as 19:03–19:20 and
        // 19:20–19:24 with identical paths, but with a start-time difference
        // greater than the old 15-minute cleanup window.  Compare the actual
        // route endpoints before treating them as one trip, so an immediate
        // return journey (whose endpoints are reversed) remains intact.
        let startDiff = abs(first.startTime.timeIntervalSince(second.startTime))
        let endDiff = abs(first.endTime.timeIntervalSince(second.endTime))
        let intervalGap: TimeInterval
        if first.endTime <= second.startTime {
            intervalGap = second.startTime.timeIntervalSince(first.endTime)
        } else if second.endTime <= first.startTime {
            intervalGap = first.startTime.timeIntervalSince(second.endTime)
        } else {
            intervalGap = 0
        }
        // Route geometry is intentionally a fallback for rebuild artifacts,
        // not a comparison for every pair of historical trips.  An unrelated
        // trip cannot be a duplicate when its boundaries are neither close nor
        // adjacent, so avoid decoding and comparing its full polyline.
        guard startDiff <= 20 * 60 || intervalGap <= 10 * 60 else {
            return false
        }
        guard first.distance > 0, second.distance > 0,
              abs(first.distance - second.distance) <= max(300, max(first.distance, second.distance) * 0.25),
              let firstPoints = try? JSONDecoder().decode([CodableCoordinate].self, from: first.pointsData),
              let secondPoints = try? JSONDecoder().decode([CodableCoordinate].self, from: second.pointsData),
              let firstStart = firstPoints.first, let firstEnd = firstPoints.last,
              let secondStart = secondPoints.first, let secondEnd = secondPoints.last else {
            return false
        }

        let startDistance = CLLocation(latitude: firstStart.lat, longitude: firstStart.lon)
            .distance(from: CLLocation(latitude: secondStart.lat, longitude: secondStart.lon))
        let endDistance = CLLocation(latitude: firstEnd.lat, longitude: firstEnd.lon)
            .distance(from: CLLocation(latitude: secondEnd.lat, longitude: secondEnd.lon))
        let hasSameRouteEndpoints = startDistance <= 250 && endDistance <= 250
        // Different rebuild passes can trim a different amount from the two
        // ends of the same raw route.  In that case endpoint-only matching
        // misses the walking/car shadow shown as two adjacent trips.  Require
        // substantial polyline overlap as the alternative: time and distance
        // alone must never collapse a real walk followed by a real drive.
        let hasSubstantialRouteOverlap: Bool = {
            guard firstPoints.count >= 2, secondPoints.count >= 2 else { return false }
            let firstRoute = firstPoints.map { CLLocation(latitude: $0.lat, longitude: $0.lon) }
            let secondRoute = secondPoints.map { CLLocation(latitude: $0.lat, longitude: $0.lon) }
            let tolerance = max(300, min(first.distance, second.distance) * 0.15)

            func distanceToRoute(_ point: CLLocation, _ route: [CLLocation]) -> CLLocationDistance {
                var best = CLLocationDistance.greatestFiniteMagnitude
                for index in 0..<(route.count - 1) {
                    let start = route[index]
                    let end = route[index + 1]
                    let dx = end.coordinate.longitude - start.coordinate.longitude
                    let dy = end.coordinate.latitude - start.coordinate.latitude
                    let lengthSquared = dx * dx + dy * dy
                    let ratio = lengthSquared == 0 ? 0 : max(0, min(1, ((point.coordinate.longitude - start.coordinate.longitude) * dx + (point.coordinate.latitude - start.coordinate.latitude) * dy) / lengthSquared))
                    let projected = CLLocation(latitude: start.coordinate.latitude + (end.coordinate.latitude - start.coordinate.latitude) * ratio,
                                               longitude: start.coordinate.longitude + (end.coordinate.longitude - start.coordinate.longitude) * ratio)
                    best = min(best, point.distance(from: projected))
                }
                return best
            }

            func coverage(_ route: [CLLocation], by otherRoute: [CLLocation]) -> Double {
                Double(route.filter { distanceToRoute($0, otherRoute) <= tolerance }.count) / Double(route.count)
            }
            let forwardCoverage = coverage(firstRoute, by: secondRoute)
            let reverseCoverage = coverage(secondRoute, by: firstRoute)
            if min(forwardCoverage, reverseCoverage) >= 0.7 {
                return true
            }

            // A delayed gap-fill can be a strict sub-route of the normal
            // automatic record it touches.  Treat that as a duplicate while
            // keeping independent nearby trips with different paths intact.
            return intervalGap <= 10 * 60 && max(forwardCoverage, reverseCoverage) >= 0.85
        }()
        guard hasSameRouteEndpoints || hasSubstantialRouteOverlap else { return false }

        // Normal retries have close boundaries.  The second branch covers the
        // split-window bug only when the two records touch (or nearly touch),
        // which is the signature in the reported duplicate route.
        return (startDiff <= 20 * 60 && endDiff <= 20 * 60)
            || intervalGap <= 10 * 60
    }

    private static func placeKeepScore(_ place: Place, referencedPlaceIDs: Set<UUID>) -> Int {
        var score = 0
        if referencedPlaceIDs.contains(place.placeID) { score += 100 }
        if place.isUserDefined { score += 50 }
        if place.isPriority { score += 20 }
        if !place.isIgnored { score += 10 }
        if !(place.address?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) { score += 5 }
        if !(place.category?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) { score += 3 }
        return score
    }

    private static func footprintKeepScore(_ footprint: Footprint) -> Int {
        var score = 0
        if footprint.status == .manual { score += 100 }
        if footprint.status == .confirmed { score += 50 }
        if footprint.isHighlight == true { score += 30 }
        if footprint.placeID != nil { score += 20 }
        if footprint.isAddressEditedByHand { score += 20 }
        score += min(footprint.photoAssetIDs.count, 20)
        score += min(footprint.photoMetadata.count, 20)
        if footprint.activityTypeValue != nil { score += 5 }
        if footprint.reason?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false { score += 5 }
        return score
    }

    private static func transportKeepScore(_ transport: TransportRecord) -> Int {
        var score = 0
        if transport.statusRaw == "active" { score += 20 }
        if transport.manualTypeRaw != nil { score += 10 }
        if transport.stepCount != nil { score += 5 }
        if !transport.pointsData.isEmpty { score += 5 }
        return score
    }

    private static func footprintCloneKey(_ footprint: Footprint) -> String {
        let date = Int(Calendar.current.startOfDay(for: footprint.date).timeIntervalSince1970.rounded())
        let start = Int(footprint.startTime.timeIntervalSince1970.rounded())
        let end = Int(footprint.endTime.timeIntervalSince1970.rounded())
        let latitude = Int((footprint.latitude * 100_000).rounded())
        let longitude = Int((footprint.longitude * 100_000).rounded())
        let place = footprint.placeID?.uuidString ?? ""
        return "fp|\(date)|\(start)|\(end)|\(latitude)|\(longitude)|\(place)|\(footprint.locationHash)"
    }

    private static func transportCloneKey(_ transport: TransportRecord) -> String {
        let day = Int(Calendar.current.startOfDay(for: transport.day).timeIntervalSince1970.rounded())
        let start = Int(transport.startTime.timeIntervalSince1970.rounded())
        let end = Int(transport.endTime.timeIntervalSince1970.rounded())
        let distance = Int(transport.distance.rounded())
        return "tp|\(day)|\(start)|\(end)|\(distance)|\(transport.startLocation)|\(transport.endLocation)|\(transport.typeRaw)|\(transport.manualTypeRaw ?? "")|\(transport.pointsData.count)"
    }

    private static func combinedOptionalMax<T: Comparable>(_ first: T?, _ second: T?) -> T? {
        switch (first, second) {
        case let (.some(first), .some(second)):
            return max(first, second)
        case let (.some(first), .none):
            return first
        case let (.none, .some(second)):
            return second
        case (.none, .none):
            return nil
        }
    }
}
