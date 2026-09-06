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
        var transportsRewritten = 0
        var activityTypesDeleted = 0

        var didChange: Bool {
            placesDeleted > 0 || footprintReferencesRewritten > 0 || footprintsDeleted > 0 || transportsDeleted > 0 || transportsRewritten > 0 || activityTypesDeleted > 0
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
        print("[DataDeduplication] deleted places=\(report.placesDeleted), rewrittenFootprints=\(report.footprintReferencesRewritten), deletedFootprints=\(report.footprintsDeleted), deletedTransports=\(report.transportsDeleted), rewrittenTransports=\(report.transportsRewritten), deletedActivityTypes=\(report.activityTypesDeleted)")
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
        if report.didChange {
            do {
                try context.save()
            } catch {
                print("[DataDeduplication] transport cleanup save failed: \(error)")
            }
        }
        // Callers use a positive result to refresh timeline queries. A route
        // split/trim is equally visible even when no object was deleted.
        return max(report.transportsDeleted, report.transportsRewritten > 0 ? 1 : 0)
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
        if report.didChange {
            do {
                try context.save()
                print("[TimelineAuto] removed \(report.transportsDeleted) duplicate transport(s) for \(startOfDay)")
            } catch {
                print("[TimelineAuto] failed to save duplicate transport cleanup: \(error)")
            }
        }
        return max(report.transportsDeleted, report.transportsRewritten > 0 ? 1 : 0)
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
        let originalRecords = transports
            .filter { $0.statusRaw != "ignored" }
            .sorted { $0.startTime < $1.startTime }
        let originalIDs = Set(originalRecords.map(\.recordID))
        var originalSnapshots: [UUID: (Date, Date, Data)] = [:]
        for record in originalRecords {
            // Avoid trapping if damaged legacy data contains a repeated ID. The
            // route comparison below still evaluates the individual objects.
            originalSnapshots[record.recordID] = (record.startTime, record.endTime, record.pointsData)
        }

        // Apply manual ownership before grouping. A trip crossing midnight must
        // still see a manual record whose start time belongs to the next day.
        let normalizedRecords = PersistentTimelineBuilder.preservingAutomaticRoutesOutsideManualIntervals(
            originalRecords, in: context
        )
        let retainedOriginalIDs = Set(normalizedRecords.map(\.recordID)).intersection(originalIDs)
        report.transportsDeleted += originalIDs.subtracting(retainedOriginalIDs).count
        let rewroteRetainedRecord = normalizedRecords.contains { record in
            guard let snapshot = originalSnapshots[record.recordID] else { return false }
            return snapshot.0 != record.startTime || snapshot.1 != record.endTime || snapshot.2 != record.pointsData
        }
        if normalizedRecords.count != originalRecords.count
            || Set(normalizedRecords.map(\.recordID)) != originalIDs
            || rewroteRetainedRecord {
            report.transportsRewritten += 1
        }

        // `day` on legacy records can be stale after an earlier boundary rewrite.
        // The actual interval is authoritative for deciding which trips may be
        // compared with each other.
        let groupedByDay = Dictionary(grouping: normalizedRecords) {
            Calendar.current.startOfDay(for: $0.startTime)
        }

        for (_, records) in groupedByDay {
            guard records.count >= 2 else { continue }

            let manuals = records.filter { $0.manualTypeRaw != nil }

            var parents = Array(records.indices)
            func root(of index: Int) -> Int {
                var current = index
                while parents[current] != current {
                    current = parents[current]
                }
                return current
            }

            for firstIndex in records.indices {
                guard records[firstIndex].manualTypeRaw == nil else { continue }
                for secondIndex in records.index(after: firstIndex)..<records.endIndex {
                    guard records[secondIndex].manualTypeRaw == nil else { continue }
                    let pairStart = min(records[firstIndex].startTime, records[secondIndex].startTime)
                    let pairEnd = max(records[firstIndex].endTime, records[secondIndex].endTime)
                    guard !manuals.contains(where: {
                        $0.startTime < pairEnd && $0.endTime > pairStart
                    }), PersistentTimelineBuilder.isSameAutomaticTrip(records[firstIndex], records[secondIndex]) else {
                        continue
                    }
                    let firstRoot = root(of: firstIndex)
                    let secondRoot = root(of: secondIndex)
                    if firstRoot != secondRoot {
                        parents[secondRoot] = firstRoot
                    }
                }
            }

            var groups: [Int: [TransportRecord]] = [:]
            for index in records.indices {
                groups[root(of: index), default: []].append(records[index])
            }

            for group in groups.values where group.count > 1 {
                guard let keeper = group.max(by: {
                    PersistentTimelineBuilder.hasBetterObservedRoute($1, than: $0)
                }) else { continue }
                let groupStart = group.map(\.startTime).min() ?? keeper.startTime
                let groupEnd = group.map(\.endTime).max() ?? keeper.endTime
                keeper.startTime = groupStart
                keeper.endTime = groupEnd
                let duration = groupEnd.timeIntervalSince(groupStart)
                keeper.averageSpeed = duration > 0 ? keeper.distance / duration : 0
                if let earliest = group.min(by: { $0.startTime < $1.startTime }),
                   earliest !== keeper,
                   !earliest.startLocation.isEmpty,
                   earliest.startLocation != "起点",
                   earliest.startLocation != "正在获取位置..." {
                    keeper.startLocation = earliest.startLocation
                }
                if let latest = group.max(by: { $0.endTime < $1.endTime }),
                   latest !== keeper,
                   !latest.endLocation.isEmpty,
                   latest.endLocation != "终点",
                   latest.endLocation != "正在获取位置..." {
                    keeper.endLocation = latest.endLocation
                }
                for duplicate in group where duplicate !== keeper {
                    context.delete(duplicate)
                    report.transportsDeleted += 1
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
