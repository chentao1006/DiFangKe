import Foundation
import CoreLocation

// Add TimelineItem enum
enum TimelineItem: Identifiable {
    case footprint(Footprint)
    case transport(Transport)
    
    var id: String {
        switch self {
        case .footprint(let f): return f.footprintID.uuidString
        case .transport(let t): return t.id.uuidString
        }
    }
    
    var startTime: Date {
        switch self {
        case .footprint(let f): return f.startTime
        case .transport(let t): return t.endTime // Reverse order usually, but let's see
        }
    }
    
    // Use for sorting
    var chronologicalStartTime: Date {
        switch self {
        case .footprint(let f): return f.startTime
        case .transport(let t): return t.startTime
        }
    }
}

// Lite versions for thread-safe background building
struct FootprintLite {
    let startTime: Date
    let endTime: Date
    let latitude: Double
    let longitude: Double
    let footprintID: UUID
    let placeID: UUID?
    let title: String
    let address: String?
    let status: FootprintStatus
    let footprintLocations: [CLLocationCoordinate2D]
    let isTitleEditedByHand: Bool
    let date: Date
    let duration: TimeInterval
    let photoAssetIDs: [String]
    let reason: String?
    let isHighlight: Bool?
    let aiAnalyzed: Bool
    let activityTypeValue: String?
}

struct PlaceLite {
    let placeID: UUID
    let name: String
    let latitude: Double
    let longitude: Double
    let radius: Int
    let isIgnored: Bool
    let isUserDefined: Bool
    let isPriority: Bool
    let address: String?
}

struct OverrideLite {
    let startTime: Date
    let endTime: Date
    let isDeleted: Bool
    let vehicleType: String
    let startLocationOverride: String?
    let endLocationOverride: String?
}

class TimelineBuilder {
    // MARK: - Lite Conversion Helpers (Non-isolated to be used in background tasks)
    static func convertToFootprintLite(_ fp: Footprint) -> FootprintLite {
        FootprintLite(
            startTime: fp.startTime,
            endTime: fp.endTime,
            latitude: fp.latitude,
            longitude: fp.longitude,
            footprintID: fp.footprintID,
            placeID: fp.placeID,
            title: fp.title,
            address: fp.address,
            status: fp.status,
            footprintLocations: fp.footprintLocations,
            isTitleEditedByHand: fp.isTitleEditedByHand,
            date: fp.date,
            duration: fp.duration,
            photoAssetIDs: fp.photoAssetIDs,
            reason: fp.reason,
            isHighlight: fp.isHighlight,
            aiAnalyzed: fp.aiAnalyzed,
            activityTypeValue: fp.activityTypeValue
        )
    }

    static func convertToPlaceLite(_ p: Place) -> PlaceLite {
        PlaceLite(
            placeID: p.placeID,
            name: p.name,
            latitude: p.latitude,
            longitude: p.longitude,
            radius: Int(p.radius),
            isIgnored: p.isIgnored,
            isUserDefined: p.isUserDefined,
            isPriority: p.isPriority,
            address: p.address
        )
    }

    static func convertToOverrideLite(_ o: TransportManualSelection) -> OverrideLite {
        OverrideLite(
            startTime: o.startTime,
            endTime: o.endTime,
            isDeleted: o.isDeleted,
            vehicleType: o.vehicleType,
            startLocationOverride: o.startLocationOverride,
            endLocationOverride: o.endLocationOverride
        )
    }

    /// Cache to prevent UI flickering when switching back to previously viewed dates
    @MainActor static var timelineCache: [Date: [TimelineItem]] = [:]
    
    static func buildTimeline(for date: Date, footprints: [FootprintLite], allRawPoints: [CLLocation], allPlaces: [PlaceLite] = [], overrides: [OverrideLite] = []) -> [TimelineItem] {
        var items: [TimelineItem] = []
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!
        let now = Date()
        let dayLimit = min(endOfDay, now)
        
        let sortedFootprints = footprints
            .filter { $0.status != .ignored }
            .sorted { $0.startTime < $1.startTime }
        
        // UI-level merging of consecutive footprints for the same location
        var finalizedSortedFootprints: [FootprintLite] = []
        for fp in sortedFootprints {
            if let last = finalizedSortedFootprints.last, shouldPerformUiMerge(last, fp) {
                // Create a temporary footprint that covers the combined range
                let combined = FootprintLite(
                    startTime: last.startTime,
                    endTime: max(last.endTime, fp.endTime),
                    latitude: last.latitude,
                    longitude: last.longitude,
                    footprintID: last.footprintID,
                    placeID: last.placeID,
                    title: last.title,
                    address: last.address,
                    status: last.status,
                    footprintLocations: last.footprintLocations + fp.footprintLocations,
                    isTitleEditedByHand: last.isTitleEditedByHand,
                    date: last.date,
                    duration: max(last.endTime, fp.endTime).timeIntervalSince(last.startTime),
                    photoAssetIDs: Array(Set(last.photoAssetIDs + fp.photoAssetIDs)),
                    reason: last.reason ?? fp.reason,
                    isHighlight: (last.isHighlight == true || fp.isHighlight == true),
                    aiAnalyzed: last.aiAnalyzed || fp.aiAnalyzed,
                    activityTypeValue: last.activityTypeValue ?? fp.activityTypeValue
                )
                finalizedSortedFootprints[finalizedSortedFootprints.count - 1] = combined
            } else {
                finalizedSortedFootprints.append(fp)
            }
        }
        
        var currentTime = startOfDay
        
        // --- Process Footprints and Gaps ---
        for (index, fp) in finalizedSortedFootprints.enumerated() {
            // Gap before current footprint
            if fp.startTime > currentTime {
                let gapPoints = TimelineBuilder.extractPoints(from: allRawPoints, start: currentTime, end: fp.startTime)
                fillGap(from: currentTime, to: fp.startTime, items: &items, gapPoints: gapPoints, sortedFootprints: finalizedSortedFootprints, currentIndex: index, allPlaces: allPlaces, overrides: overrides)
            }
            
            // Add Footprint (Convert back to real Footprint internally if needed, or keep it Lite)
            // For UI, we convert Lite back to temporary Footprint models
            let model = Footprint(
                footprintID: fp.footprintID,
                date: fp.date,
                startTime: fp.startTime,
                endTime: fp.endTime,
                footprintLocations: fp.footprintLocations,
                locationHash: "UI_LITE",
                duration: fp.duration,
                title: fp.title,
                reason: fp.reason,
                status: fp.status,
                isHighlight: fp.isHighlight,
                photoAssetIDs: fp.photoAssetIDs,
                address: fp.address,
                aiAnalyzed: fp.aiAnalyzed,
                activityTypeValue: fp.activityTypeValue
            )
            model.placeID = fp.placeID
            model.isTitleEditedByHand = fp.isTitleEditedByHand
            items.append(.footprint(model))
            
            currentTime = max(currentTime, fp.endTime)
        }
        
        // Final gap until now/end of day
        if dayLimit > currentTime {
            let gapPoints = TimelineBuilder.extractPoints(from: allRawPoints, start: currentTime, end: dayLimit)
            fillGap(from: currentTime, to: dayLimit, items: &items, gapPoints: gapPoints, sortedFootprints: finalizedSortedFootprints, currentIndex: finalizedSortedFootprints.count, allPlaces: allPlaces, overrides: overrides)
        }
        
        // Post-processing: Merge adjacent stationary items in the results
        return mergeAdjacentItems(items).reversed()
    }

    private static func shouldPerformUiMerge(_ f1: FootprintLite, _ f2: FootprintLite) -> Bool {
        return checkMergeCondition(
            start1: f1.startTime, end1: f1.endTime, lat1: f1.latitude, lon1: f1.longitude, title1: f1.title, place1: f1.placeID, activity1: f1.activityTypeValue,
            start2: f2.startTime, end2: f2.endTime, lat2: f2.latitude, lon2: f2.longitude, title2: f2.title, place2: f2.placeID, activity2: f2.activityTypeValue
        )
    }

    private static func shouldPerformUiMerge(_ f1: Footprint, _ f2: Footprint) -> Bool {
        return checkMergeCondition(
            start1: f1.startTime, end1: f1.endTime, lat1: f1.latitude, lon1: f1.longitude, title1: f1.title, place1: f1.placeID, activity1: f1.activityTypeValue,
            start2: f2.startTime, end2: f2.endTime, lat2: f2.latitude, lon2: f2.longitude, title2: f2.title, place2: f2.placeID, activity2: f2.activityTypeValue
        )
    }

    private static func checkMergeCondition(
        start1: Date, end1: Date, lat1: Double, lon1: Double, title1: String, place1: UUID?, activity1: String?,
        start2: Date, end2: Date, lat2: Double, lon2: Double, title2: String, place2: UUID?, activity2: String?
    ) -> Bool {
        if start2.timeIntervalSince(end1) > 300 { return false }
        if let p1 = place1, let p2 = place2, p1 == p2 && activity1 == activity2 { return true }
        let loc1 = CLLocation(latitude: lat1, longitude: lon1)
        let loc2 = CLLocation(latitude: lat2, longitude: lon2)
        if loc1.distance(from: loc2) < 80 && title1 == title2 && activity1 == activity2 { return true }
        return false
    }

    private static func mergeAdjacentItems(_ items: [TimelineItem]) -> [TimelineItem] {
        var merged: [TimelineItem] = []
        for item in items {
            if let last = merged.last {
                switch (last, item) {
                case (.footprint(let f1), .footprint(let f2)):
                    if shouldPerformUiMerge(f1, f2) {
                        let combined = Footprint(
                            date: f1.date,
                            startTime: f1.startTime,
                            endTime: max(f1.endTime, f2.endTime),
                            footprintLocations: f1.footprintLocations + f2.footprintLocations,
                            locationHash: "UI_MERGE_FINAL",
                            duration: max(f1.endTime, f2.endTime).timeIntervalSince(f1.startTime),
                            title: f1.title,
                            status: f1.status,
                            address: f1.address,
                            activityTypeValue: f1.activityTypeValue
                        )
                        combined.placeID = f1.placeID
                        merged[merged.count - 1] = .footprint(combined)
                    } else {
                        merged.append(item)
                    }
                default:
                    merged.append(item)
                }
            } else {
                merged.append(item)
            }
        }
        return merged
    }
    
    private static func fillGap(from start: Date, to end: Date, items: inout [TimelineItem], gapPoints: [CLLocation], sortedFootprints: [FootprintLite], currentIndex: Int, allPlaces: [PlaceLite], overrides: [OverrideLite]) {
        let duration = end.timeIntervalSince(start)
        guard duration > 60 else { return } // Ignore gaps < 1 min
        guard !gapPoints.isEmpty else { return }
        
        let transports = extractTransports(gapPoints)
        let isTodayView = Calendar.current.isDateInToday(start)
        let now = Date()

        var lastProcessedTime = start
        
        if !transports.isEmpty {
            for i in 0..<transports.count {
                var t = transports[i]
                
                // Fill gap before transport with a stay (if > 5 mins)
                if t.startTime.timeIntervalSince(lastProcessedTime) > 300 {
                    addStationaryStay(from: lastProcessedTime, to: t.startTime, gapPoints: gapPoints, items: &items, allPlaces: allPlaces)
                }
                
                let startCoord = t.points.first
                let endCoord = t.points.last
                
                // Resolve locations for the transport
                if i == 0 && currentIndex > 0 {
                    let prevFp = sortedFootprints[currentIndex-1]
                    let fpLoc = CLLocation(latitude: prevFp.latitude, longitude: prevFp.longitude)
                    if let startCoord = startCoord, CLLocation(latitude: startCoord.latitude, longitude: startCoord.longitude).distance(from: fpLoc) < 150 {
                        t = t.updatingStart(getLocationName(for: prevFp, allPlaces: allPlaces))
                    }
                } 
                
                if t.startLocation == "起点", let startCoord = startCoord {
                    if let place = getPlaceForCoordinate(startCoord, allPlaces: allPlaces) {
                        t = t.updatingStart(place.name)
                    }
                }
                
                if i == transports.count - 1 && currentIndex < sortedFootprints.count {
                    let nextFp = sortedFootprints[currentIndex]
                    let fpLoc = CLLocation(latitude: nextFp.latitude, longitude: nextFp.longitude)
                    if let endCoord = endCoord, CLLocation(latitude: endCoord.latitude, longitude: endCoord.longitude).distance(from: fpLoc) < 150 {
                        t = t.updatingEnd(getLocationName(for: nextFp, allPlaces: allPlaces))
                    }
                }
                
                if t.endLocation == "终点", let endCoord = endCoord {
                    if let place = getPlaceForCoordinate(endCoord, allPlaces: allPlaces) {
                        t = t.updatingEnd(place.name)
                    }
                }

                // Final cleanup for placeholders
                if t.startLocation == "起点" { t = t.updatingStart("正在获取位置...") }
                if t.endLocation == "终点" { t = t.updatingEnd("正在获取位置...") }

                if let ft = applyTransportOverrides(t, overrides: overrides) {
                    let isOngoing = isTodayView && ft.endTime >= now.addingTimeInterval(-120)
                    if !isOngoing {
                        items.append(.transport(ft))
                        lastProcessedTime = ft.endTime
                    }
                }
            }
            
            let isOngoing = isTodayView && end >= now.addingTimeInterval(-120)
            if !isOngoing && end.timeIntervalSince(lastProcessedTime) > 300 {
                addStationaryStay(from: lastProcessedTime, to: end, gapPoints: gapPoints, items: &items, allPlaces: allPlaces)
            }
        } else {
            // No transports, but points exist: fill the whole gap as a stay
            let isOngoing = isTodayView && end >= now.addingTimeInterval(-120)
            if !isOngoing {
                addStationaryStay(from: start, to: end, gapPoints: gapPoints, items: &items, allPlaces: allPlaces)
            }
        }
    }

    private static func addStationaryStay(from start: Date, to end: Date, gapPoints: [CLLocation], items: inout [TimelineItem], allPlaces: [PlaceLite]) {
        let duration = end.timeIntervalSince(start)
        guard duration > 300 else { return } // Reject stays < 5 mins
        
        // Use binary search to find relevant points within the already filtered gapPoints
        let subPoints = extractPoints(from: gapPoints, start: start, end: end)
        guard !subPoints.isEmpty else { return }
        
        // Use the middle point as representative location
        let midpoint = subPoints[subPoints.count / 2].coordinate
        
        // Sample points to avoid too much data in Memory (for UI only)
        let sampledLocations = subPoints.enumerated()
            .filter { $0.offset % max(1, subPoints.count/20) == 0 }
            .map { $0.element.coordinate }
        
        let fp = Footprint(
            date: start,
            startTime: start,
            endTime: end,
            footprintLocations: sampledLocations.isEmpty ? [midpoint] : sampledLocations,
            locationHash: "GAP_STAY_\(Int(start.timeIntervalSince1970))",
            duration: duration,
            status: .candidate
        )
        
        if let place = getPlaceForCoordinate(midpoint, allPlaces: allPlaces) {
            fp.title = Footprint.generateRandomTitle(for: place.name, seed: Int(start.timeIntervalSince1970))
            fp.placeID = place.placeID
        } else {
            fp.title = "在某地停留" 
        }
        
        items.append(.footprint(fp))
    }

    
    private static func applyTransportOverrides(_ t: Transport, overrides: [OverrideLite]) -> Transport? {
        let midTime = t.startTime.addingTimeInterval(t.duration / 2)
        if let override = overrides.first(where: { 
            (midTime >= $0.startTime.addingTimeInterval(-1) && midTime <= $0.endTime.addingTimeInterval(1))
        }) {
            if override.isDeleted { return nil }
            var updated = t
            if let type = TransportType(rawValue: override.vehicleType) { updated.manualType = type }
            if let startOverride = override.startLocationOverride { updated = updated.updatingStart(startOverride) }
            if let endOverride = override.endLocationOverride { updated = updated.updatingEnd(endOverride) }
            return updated
        }
        return t
    }
    
    private static func getLocationName(for footprint: FootprintLite, allPlaces: [PlaceLite]) -> String {
        if let placeID = footprint.placeID, 
           let place = allPlaces.first(where: { $0.placeID == placeID }) {
            return place.name
        }
        if footprint.isTitleEditedByHand { return footprint.title }
        if let nearbyPlace = getPlaceForCoordinate(CLLocationCoordinate2D(latitude: footprint.latitude, longitude: footprint.longitude), allPlaces: allPlaces) {
            return nearbyPlace.name
        }
        if !footprint.title.isEmpty && footprint.title != "地点记录" && footprint.title != "正在获取位置..." { return footprint.title }
        if let addr = footprint.address, !addr.isEmpty { return addr }
        return "未知位置"
    }
    
    private static func getPlaceForCoordinate(_ coordinate: CLLocationCoordinate2D, allPlaces: [PlaceLite]) -> PlaceLite? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        struct Match { let place: PlaceLite; let distance: Double }
        let validMatches: [Match] = allPlaces.compactMap { place in
            if place.isIgnored { return nil }
            let d = location.distance(from: CLLocation(latitude: place.latitude, longitude: place.longitude))
            if d <= Double(place.radius) + 100.0 { return Match(place: place, distance: d) }
            return nil
        }
        let sorted = validMatches.sorted { p1, p2 in
            if p1.place.isUserDefined != p2.place.isUserDefined { return p1.place.isUserDefined }
            if p1.place.isPriority != p2.place.isPriority { return p1.place.isPriority }
            return p1.distance < p2.distance
        }
        return sorted.first?.place
    }
    
    private static func extractTransports(_ points: [CLLocation]) -> [Transport] {
        guard points.count >= 2 else { return [] }
        var transports: [Transport] = []
        var currentPoints: [CLLocation] = [points[0]]
        var currentSegmentType: TransportType? = nil
        
        for i in 1..<points.count {
            let p = points[i]
            let prevP = points[i-1]
            let timeGap = p.timestamp.timeIntervalSince(prevP.timestamp)
            
            if timeGap > 15 * 60 {
                if let transport = finalizeTransport(currentPoints) { transports.append(transport) }
                currentPoints = [p]; currentSegmentType = nil; continue
            }

            // Detect inactivity/stillness to split transport (e.g. user stopped moving for > 10 mins)
            // Increased threshold to 220m to account for GPS drift
            // Performance: Only check every 5 points to reduce overhead
            if currentPoints.count > 12 && i % 5 == 0 {
                let recentWindow = Array(currentPoints[max(0, currentPoints.count-25)...(currentPoints.count-1)])
                let windowDuration = p.timestamp.timeIntervalSince(recentWindow.first!.timestamp)
                if windowDuration > 600 { // 10 minutes
                    let diameter = calculateMaxDiameter(recentWindow + [p])
                    if diameter < 220 { // Moved less than 220m in 10 mins - likely stationary
                        if let transport = finalizeTransport(currentPoints) {
                            transports.append(transport)
                        }
                        currentPoints = [p]
                        currentSegmentType = nil
                        continue
                    }
                }
            }
            
            if currentPoints.count >= 8 && i % 3 == 0 {

                if currentSegmentType == nil {
                    let d = calculateDistance(currentPoints)
                    let t = currentPoints.last!.timestamp.timeIntervalSince(currentPoints.first!.timestamp)
                    currentSegmentType = TransportType.from(speed: t > 0 ? d / t : 0)
                }
                let window = Array(points[max(0, i-10)...i])
                if window.count >= 6 {
                    let wd = calculateDistance(window)
                    let wt = window.last!.timestamp.timeIntervalSince(window.first!.timestamp)
                    let wType = TransportType.from(speed: wt > 0 ? wd / wt : 0)
                    if let segType = currentSegmentType, isSignificantTypeChange(from: segType, to: wType) && wt > 180 {
                        if let transport = finalizeTransport(currentPoints) { transports.append(transport) }
                        currentPoints = [prevP, p]; currentSegmentType = nil; continue
                    }
                }
            }
            currentPoints.append(p)
        }
        if let transport = finalizeTransport(currentPoints) { transports.append(transport) }
        return mergeTransports(transports)
    }
    
    private static func isSignificantTypeChange(from t1: TransportType, to t2: TransportType) -> Bool {
        func category(of type: TransportType) -> Int {
            switch type {
            case .slow: return 1
            case .bicycle: return 2
            case .motorcycle, .car, .bus: return 3
            default: return 4
            }
        }
        return category(of: t1) != category(of: t2)
    }
    
    private static func finalizeTransport(_ points: [CLLocation]) -> Transport? {
        let distance = calculateDistance(points)
        if points.count < 3 && distance < 300 { return nil }
        guard points.count >= 2 else { return nil }
        
        let start = points.first!.timestamp
        let end = points.last!.timestamp
        let duration = end.timeIntervalSince(start)
        let averageSpeed = duration > 0 ? distance / duration : 0
        let kmh = averageSpeed * 3.6
        
        if distance < 50 { return nil }
        if duration < 60 && kmh < 3 { return nil }
        
        let maxDiameter = calculateMaxDiameter(points)
        // 增加对“室内漂移”的过滤：如果最大跨度较小且总路径过长（比值 > 2），判定为原地漂移而非位移
        if maxDiameter < 180 && distance > maxDiameter * 2.0 { return nil }
        
        if maxDiameter < 45 && duration < 30 * 60 { return nil }
        if maxDiameter < 100 && kmh < 1.5 { return nil } // 低速短距离位移不视为交通
        if kmh < 0.4 || (kmh < 0.6 && distance < 1000) { return nil }
        
        return Transport(
            startTime: start,
            endTime: end,
            startLocation: "起点", 
            endLocation: "终点",
            type: TransportType.from(speed: averageSpeed),
            distance: distance,
            averageSpeed: averageSpeed,
            points: points.map { $0.coordinate }
        )
    }
    
    private static func calculateMaxDiameter(_ points: [CLLocation]) -> Double {
        guard points.count > 1 else { return 0 }
        
        // Performance: Use O(N) bounding box diagonal as a fast upper-bound approximation for diameter
        // This is significantly faster than the O(N^2) sampling approach.
        var minLat = 90.0, maxLat = -90.0
        var minLon = 180.0, maxLon = -180.0
        
        for p in points {
            let c = p.coordinate
            if c.latitude < minLat { minLat = c.latitude }
            if c.latitude > maxLat { maxLat = c.latitude }
            if c.longitude < minLon { minLon = c.longitude }
            if c.longitude > maxLon { maxLon = c.longitude }
        }
        
        let p1 = CLLocation(latitude: minLat, longitude: minLon)
        let p2 = CLLocation(latitude: maxLat, longitude: maxLon)
        return p1.distance(from: p2)
    }
    
    private static func calculateDistance(_ points: [CLLocation]) -> Double {
        var distance: Double = 0
        guard points.count >= 2 else { return 0 }
        for i in 0..<points.count - 1 {
            distance += points[i].distance(from: points[i+1])
        }
        return distance
    }
    
    private static func mergeTransports(_ transports: [Transport]) -> [Transport] {
        guard transports.count > 1 else { return transports }
        var list = transports; var changed = true; var passCount = 0
        while changed && passCount < 3 {
            changed = false; var merged: [Transport] = []; var i = 0
            while i < list.count {
                let curr = list[i]
                if i + 1 < list.count {
                    let next = list[i+1]; let d1 = curr.duration; let d2 = next.duration
                    let timeGap = next.startTime.timeIntervalSince(curr.endTime)
                    
                    // Only merge if they are temporally close (< 10 mins)
                    if timeGap < 600 && (curr.type == next.type || (isSimilarType(curr.type, next.type) && (d1 < 180 || d2 < 180))) {
                        list[i+1] = merge(curr, next); i += 1; changed = true; continue
                    }
                    if i + 2 < list.count {
                        let third = list[i+2]
                        let gapToThird = third.startTime.timeIntervalSince(next.endTime)
                        if gapToThird < 600 && isSimilarType(curr.type, third.type) && d2 < 600 {
                            list[i+2] = merge(merge(curr, next), third); i += 2; changed = true; continue
                        }
                    }
                }

                merged.append(curr); i += 1
            }
            list = merged; passCount += 1
        }
        return list
    }
    
    private static func isSimilarType(_ t1: TransportType, _ t2: TransportType) -> Bool {
        func cat(of t: TransportType) -> Int {
            switch t {
            case .slow: return 1
            case .bicycle: return 2
            case .motorcycle, .car, .bus: return 3
            default: return 4
            }
        }
        return cat(of: t1) == cat(of: t2)
    }
    
    private static func merge(_ t1: Transport, _ t2: Transport) -> Transport {
        let totalTime = t1.duration + t2.duration
        let totalDist = t1.distance + t2.distance
        return Transport(
            startTime: t1.startTime, endTime: t2.endTime,
            startLocation: t1.startLocation, endLocation: t2.endLocation,
            type: t1.duration >= t2.duration ? t1.type : t2.type,
            distance: totalDist,
            averageSpeed: totalTime > 0 ? totalDist / totalTime : 0,
            points: t1.points + t2.points
        )
    }

    /// Optimized: Extract points using Binary Search to avoid O(N) filter calls
    static func extractPoints(from points: [CLLocation], start: Date, end: Date) -> [CLLocation] {
        guard !points.isEmpty else { return [] }
        
        // Find first index where timestamp >= start
        var low = 0
        var high = points.count
        while low < high {
            let mid = (low + high) / 2
            if points[mid].timestamp < start {
                low = mid + 1
            } else {
                high = mid
            }
        }
        let startIndex = low
        
        // Find first index where timestamp >= end
        low = startIndex
        high = points.count
        while low < high {
            let mid = (low + high) / 2
            if points[mid].timestamp < end {
                low = mid + 1
            } else {
                high = mid
            }
        }
        let endIndex = low
        
        if startIndex >= endIndex { return [] }
        return Array(points[startIndex..<endIndex])
    }

    static func resolveAddress(coordinate: CLLocationCoordinate2D, completion: @escaping (String) -> Void) {
        let geocoder = CLGeocoder()
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        geocoder.reverseGeocodeLocation(location) { placemarks, _ in
            if let placemark = placemarks?.first {
                let name = placemark.name ?? placemark.thoroughfare ?? placemark.subLocality ?? placemark.locality ?? "位置"
                completion(name)
            } else {
                completion("未知位置")
            }
        }
    }
}
