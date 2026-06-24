import Foundation
import SwiftData

@MainActor
enum DataDeduplicationService {
    struct Report {
        var placesDeleted = 0
        var footprintReferencesRewritten = 0
        var footprintsDeleted = 0
        var transportsDeleted = 0

        var didChange: Bool {
            placesDeleted > 0 || footprintReferencesRewritten > 0 || footprintsDeleted > 0 || transportsDeleted > 0
        }
    }

    static func run(context: ModelContext) -> Report {
        var report = Report()

        let places = (try? context.fetch(FetchDescriptor<Place>())) ?? []
        let footprints = (try? context.fetch(FetchDescriptor<Footprint>())) ?? []
        let transports = (try? context.fetch(FetchDescriptor<TransportRecord>())) ?? []

        print("[DataDeduplication] before places=\(places.count), footprints=\(footprints.count), transports=\(transports.count)")

        let placeRewriteMap = deduplicatePlaces(places, footprints: footprints, context: context, report: &report)
        let normalizedFootprints = rewriteFootprintPlaceReferences(footprints, placeRewriteMap: placeRewriteMap, report: &report)
        deduplicateFootprints(normalizedFootprints, context: context, report: &report)
        deduplicateTransports(transports, context: context, report: &report)

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
        print("[DataDeduplication] deleted places=\(report.placesDeleted), rewrittenFootprints=\(report.footprintReferencesRewritten), deletedFootprints=\(report.footprintsDeleted), deletedTransports=\(report.transportsDeleted)")
        print("[DataDeduplication] after places=\(remainingPlaces), footprints=\(remainingFootprints), transports=\(remainingTransports)")

        return report
    }

    private static func deduplicatePlaces(_ places: [Place], footprints: [Footprint], context: ModelContext, report: inout Report) -> [UUID: UUID] {
        let groups = Dictionary(grouping: places, by: { $0.cloneKey })
        let referencedPlaceIDs = Set(footprints.compactMap(\.placeID))
        var rewriteMap: [UUID: UUID] = [:]

        for group in groups.values where group.count > 1 {
            let sortedGroup = group.sorted { first, second in
                placeKeepScore(first, referencedPlaceIDs: referencedPlaceIDs) > placeKeepScore(second, referencedPlaceIDs: referencedPlaceIDs)
            }
            guard let keeper = sortedGroup.first else { continue }

            for duplicate in sortedGroup.dropFirst() {
                mergePlace(duplicate, into: keeper)
                rewriteMap[duplicate.placeID] = keeper.placeID
                context.delete(duplicate)
                report.placesDeleted += 1
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
        let groups = Dictionary(grouping: footprints, by: footprintCloneKey)
        for group in groups.values where group.count > 1 {
            let sortedGroup = group.sorted { first, second in
                footprintKeepScore(first) > footprintKeepScore(second)
            }
            guard let keeper = sortedGroup.first else { continue }

            for duplicate in sortedGroup.dropFirst() {
                mergeFootprint(duplicate, into: keeper)
                context.delete(duplicate)
                report.footprintsDeleted += 1
            }
        }
    }

    private static func deduplicateTransports(_ transports: [TransportRecord], context: ModelContext, report: inout Report) {
        let groups = Dictionary(grouping: transports, by: transportCloneKey)
        for group in groups.values where group.count > 1 {
            let sortedGroup = group.sorted { first, second in
                transportKeepScore(first) > transportKeepScore(second)
            }
            guard let keeper = sortedGroup.first else { continue }

            for duplicate in sortedGroup.dropFirst() {
                mergeTransport(duplicate, into: keeper)
                context.delete(duplicate)
                report.transportsDeleted += 1
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
