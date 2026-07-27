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
                    let startDiff = abs(candidate.startTime.timeIntervalSince(keeper.startTime))
                    let endDiff = abs(candidate.endTime.timeIntervalSince(keeper.endTime))
                    // A pair merely occurring near each other is not enough: two
                    // short, back-to-back trips can legitimately be five minutes
                    // apart.  Automatic rebuild duplicates cover essentially the
                    // same interval, usually with a different inferred vehicle.
                    let overlap = max(0, min(candidate.endTime, keeper.endTime).timeIntervalSince(max(candidate.startTime, keeper.startTime)))
                    let shorterDuration = min(
                        candidate.endTime.timeIntervalSince(candidate.startTime),
                        keeper.endTime.timeIntervalSince(keeper.startTime)
                    )
                    let isSameTrip = startDiff <= 300 && endDiff <= 300 &&
                        shorterDuration > 0 && overlap / shorterDuration >= 0.8
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
