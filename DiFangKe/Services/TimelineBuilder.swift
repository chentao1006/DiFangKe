import Foundation
import CoreLocation
import SwiftData

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
        case .transport(let t): return t.startTime
        }
    }
    
    var endTime: Date {
        switch self {
        case .footprint(let f): return f.endTime
        case .transport(let t): return t.endTime
        }
    }
    
    // Use for UI sorting consistency if needed
    var sortingTime: Date {
        switch self {
        case .footprint(let f): return f.startTime
        case .transport(let t): return t.endTime
        }
    }
    
    var icon: String {
        switch self {
        case .footprint(let f):
            // Note: In a real app, this should resolve the activity type icon
            return f.activityTypeValue ?? "mappin.and.ellipse"
        case .transport(let t):
            return t.currentType.icon
        }
    }
    
    // Helper to resolve icon with activity list
    func getIcon(allActivityTypes: [ActivityType]) -> String {
        switch self {
        case .footprint(let f):
            return f.getActivityType(from: allActivityTypes)?.icon ?? "mappin.and.ellipse"
        case .transport(let t):
            return t.currentType.icon
        }
    }
    
    func getColor(allActivityTypes: [ActivityType]) -> String {
        switch self {
        case .footprint(let f):
            return f.getActivityType(from: allActivityTypes)?.colorHex ?? ""
        case .transport:
            return "#8E8E93"
        }
    }
    
    var isTransport: Bool {
        if case .transport = self { return true }
        return false
    }
    
    var isHighlight: Bool {
        if case .footprint(let f) = self { return f.isHighlight == true }
        return false
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
            .sorted { $0.startTime < $1.startTime }
            // 核心逻辑：使用配置调整的时间限制。但如果有照片，则视为原始事实保留且不作为垃圾过滤
            .filter { $0.duration >= AppConfig.shared.stayDurationThreshold || !$0.photoAssetIDs.isEmpty }
        
        // UI-level merging of consecutive footprints for the same location
        var finalizedSortedFootprints: [FootprintLite] = []
        for fp in sortedFootprints {
            if let last = finalizedSortedFootprints.last, shouldPerformUiMerge(last, fp) {
                // Create a temporary footprint that covers the combined range
                let combinedLocations = last.footprintLocations + fp.footprintLocations
                let avgLat = combinedLocations.isEmpty ? last.latitude : (combinedLocations.map { $0.latitude }.reduce(0, +) / Double(combinedLocations.count))
                let avgLon = combinedLocations.isEmpty ? last.longitude : (combinedLocations.map { $0.longitude }.reduce(0, +) / Double(combinedLocations.count))

                let combined = FootprintLite(
                    startTime: last.startTime,
                    endTime: max(last.endTime, fp.endTime),
                    latitude: avgLat,
                    longitude: avgLon,
                    footprintID: last.footprintID,
                    placeID: last.placeID,
                    title: last.title,
                    address: last.address,
                    status: last.status,
                    footprintLocations: combinedLocations,
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
            
            if fp.status != .ignored {
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
            }
            
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
        if start2.timeIntervalSince(end1) > AppConfig.shared.stayMergeGapThreshold { return false }
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
                    let loc1 = CLLocation(latitude: f1.latitude, longitude: f1.longitude)
                    let loc2 = CLLocation(latitude: f2.latitude, longitude: f2.longitude)
                    let isSamePlace = (f1.placeID != nil && f1.placeID == f2.placeID)
                    
                    if isSamePlace || loc1.distance(from: loc2) < 200 {
                        let combined = Footprint(
                            date: f1.date,
                            startTime: f1.startTime,
                            endTime: max(f1.endTime, f2.endTime),
                            footprintLocations: f1.footprintLocations + f2.footprintLocations,
                            locationHash: "UI_MERGE_FINAL",
                            duration: max(f1.endTime, f2.endTime).timeIntervalSince(f1.startTime),
                            title: (f1.placeID != nil || f1.isTitleEditedByHand) ? f1.title : ((f2.placeID != nil || f2.isTitleEditedByHand) ? f2.title : f1.title),
                            status: (f1.status == .confirmed || f2.status == .confirmed) ? .confirmed : f1.status,
                            address: f1.address ?? f2.address,
                            activityTypeValue: f1.activityTypeValue ?? f2.activityTypeValue
                        )
                        combined.placeID = f1.placeID ?? f2.placeID
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
        
        if gapPoints.isEmpty {
            // Check for "Phantom Transports": user has manually defined segments on another device, 
            // but this device hasn't synced the raw trajectory points yet.
            // In this case, we synthesis a basic transport item to keep UI in sync.
            handlePhantomTransports(from: start, to: end, items: &items, sortedFootprints: sortedFootprints, currentIndex: currentIndex, allPlaces: allPlaces, overrides: overrides)
            
            // 如果处理完“虚空交通”后，这段时间依然有大片空白（>10分钟），则执行强制桥接，避免 UI 出现数小时空隙
            let lastItemEnd = items.last?.endTime ?? start
            if end.timeIntervalSince(lastItemEnd) > AppConfig.shared.stayDurationThreshold && !isOverrideDeleted(start: lastItemEnd, end: end, overrides: overrides) {
                bridgeDataGap(from: lastItemEnd, to: end, items: &items, sortedFootprints: sortedFootprints, currentIndex: currentIndex, allPlaces: allPlaces)
            }
            return
        }
        
        let transports = extractTransports(gapPoints)
        let isTodayView = Calendar.current.isDateInToday(start)
        let now = Date()

        var lastProcessedTime = start
        
        if !transports.isEmpty {
            for i in 0..<transports.count {
                var t = transports[i]
                
                // 停留识别门槛使用配置值
                if t.startTime.timeIntervalSince(lastProcessedTime) >= AppConfig.shared.stayDurationThreshold {
                    let preStayCount = items.count
                    addStationaryStay(from: lastProcessedTime, to: t.startTime, gapPoints: gapPoints, items: &items, allPlaces: allPlaces)
                    
                    // 如果常规识别失败，但跨度很大（>30分钟），强制补充一个停留，不留白
                    // 核心修复：强制补足前先检查用户是否手动删除了这段时间（Override）
                    if items.count == preStayCount && t.startTime.timeIntervalSince(lastProcessedTime) >= AppConfig.shared.stayDurationThreshold && !isOverrideDeleted(start: lastProcessedTime, end: t.startTime, overrides: overrides) {
                        addStationaryStay(from: lastProcessedTime, to: t.startTime, gapPoints: gapPoints, items: &items, allPlaces: allPlaces, ignoreDiameter: true)
                    }
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
                    items.append(.transport(ft))
                    lastProcessedTime = ft.endTime
                }
            }
            
            let isOngoing = isTodayView && end >= now.addingTimeInterval(-120)
            if !isOngoing && end.timeIntervalSince(lastProcessedTime) >= AppConfig.shared.stayDurationThreshold {
                let preStayCount = items.count
                addStationaryStay(from: lastProcessedTime, to: end, gapPoints: gapPoints, items: &items, allPlaces: allPlaces)
                
                // 尾部 fallback
                if items.count == preStayCount && end.timeIntervalSince(lastProcessedTime) >= AppConfig.shared.stayDurationThreshold && !isOverrideDeleted(start: lastProcessedTime, end: end, overrides: overrides) {
                    addStationaryStay(from: lastProcessedTime, to: end, gapPoints: gapPoints, items: &items, allPlaces: allPlaces, ignoreDiameter: true)
                }
            }
        } else {
            // No transports, but points exist: fill the whole gap as a stay
            let isOngoing = isTodayView && end >= now.addingTimeInterval(-120)
            // 虽然是“正在进行中”，但如果该停留已经持续了 15 分钟以上，也将其显示在时间轴列表中，避免出现大空白
            if !isOngoing || end.timeIntervalSince(lastProcessedTime) > 900 {
                let initialCount = items.count
                addStationaryStay(from: lastProcessedTime, to: end, gapPoints: gapPoints, items: &items, allPlaces: allPlaces)
                
                // 核心修复：如果常规识别（受限于漂移检查）失败了
                if items.count == initialCount && !isOverrideDeleted(start: lastProcessedTime, end: end, overrides: overrides) {
                    // 1. 如果时间跨度很大，强制生成一个停留
                    if end.timeIntervalSince(lastProcessedTime) >= AppConfig.shared.stayDurationThreshold {
                        addStationaryStay(from: lastProcessedTime, to: end, gapPoints: gapPoints, items: &items, allPlaces: allPlaces, ignoreDiameter: true)
                    } else if end.timeIntervalSince(lastProcessedTime) >= AppConfig.shared.transportMinDurationThreshold {
                        // 2. 如果时间不长但位移显著（导致 Stay 被拒绝），则尝试桥接成虚线交通
                        bridgeDataGap(from: lastProcessedTime, to: end, items: &items, sortedFootprints: sortedFootprints, currentIndex: currentIndex, allPlaces: allPlaces)
                    }
                }
            }
        }
    }

    /// 当完全没有原始轨迹点时，根据位置变化逻辑桥接空白
    private static func bridgeDataGap(from start: Date, to end: Date, items: inout [TimelineItem], sortedFootprints: [FootprintLite], currentIndex: Int, allPlaces: [PlaceLite]) {
        let duration = end.timeIntervalSince(start)
        // 核心修复：即使没点，只要时间超过交通门槛（30s），且有位移，就应强行桥接
        guard duration >= AppConfig.shared.transportMinDurationThreshold else { return }
        
        let loc1: CLLocation? = {
            if currentIndex > 0 {
                let fp = sortedFootprints[currentIndex - 1]
                return CLLocation(latitude: fp.latitude, longitude: fp.longitude)
            }
            return nil
        }()
        
        let loc2: CLLocation? = {
            if currentIndex < sortedFootprints.count {
                let fp = sortedFootprints[currentIndex]
                return CLLocation(latitude: fp.latitude, longitude: fp.longitude)
            }
            return nil
        }()
        
        if let l1 = loc1, let l2 = loc2 {
            let distance = l1.distance(from: l2)
            if distance < 300 {
                // 距离相近，认为是原地停留
                addStationaryStay(from: start, to: end, gapPoints: [], items: &items, allPlaces: allPlaces, coordinateOverride: l1.coordinate)
            } else {
                // 距离较远，且完全无点，合成一段虚线交通
                addSynthesizedTransport(from: start, to: end, l1: l1.coordinate, l2: l2.coordinate, items: &items)
            }
        } else if let l1 = loc1 {
            // 核心修复：如果是只有起点（由于是最后一段且后面没点）
            // 只有当这段时间后面还有别的内容（由上面的 if 闭环处理）或者是今天显示实时状态时，才应该守着起点。
            // 否则（历史日期且没点），不应强行补足到 0 点。
            let isToday = Calendar.current.isDateInToday(start)
            if isToday {
               addStationaryStay(from: start, to: end, gapPoints: [], items: &items, allPlaces: allPlaces, coordinateOverride: l1.coordinate)
            }
        } else if let l2 = loc2 {
            // 核心修复：只有终点（由于是开头的一段且前面没点）
            // 同样只有在今天显示实时状态时，才补全从 0 点出发的停留
            let isToday = Calendar.current.isDateInToday(start)
            if isToday {
                addStationaryStay(from: start, to: end, gapPoints: [], items: &items, allPlaces: allPlaces, coordinateOverride: l2.coordinate)
            }
        }
    }

    private static func addSynthesizedTransport(from start: Date, to end: Date, l1: CLLocationCoordinate2D, l2: CLLocationCoordinate2D, items: inout [TimelineItem]) {
        let loc1 = CLLocation(latitude: l1.latitude, longitude: l1.longitude)
        let loc2 = CLLocation(latitude: l2.latitude, longitude: l2.longitude)
        let distance = loc1.distance(from: loc2)
        let duration = end.timeIntervalSince(start)
        let speed = distance / max(1, duration)
        
        let t = Transport(
            startTime: start,
            endTime: end,
            startLocation: "接续起点",
            endLocation: "接续终点",
            type: TransportType.from(speed: speed),
            distance: distance,
            averageSpeed: speed,
            points: [l1, l2]
        )
        items.append(.transport(t))
    }

    /// Handles overrides that exist for a period where raw trajectory data is missing.
    private static func handlePhantomTransports(from start: Date, to end: Date, items: inout [TimelineItem], sortedFootprints: [FootprintLite], currentIndex: Int, allPlaces: [PlaceLite], overrides: [OverrideLite]) {
        // Find overrides where the midpoint falls within our gap
        let rangeOverrides = overrides.filter { ov in
            if ov.isDeleted { return false }
            let mid = ov.startTime.addingTimeInterval(ov.endTime.timeIntervalSince(ov.startTime) / 2)
            return mid >= start && mid <= end
        }
        
        for ov in rangeOverrides {
            // Synthesize basics
            var path: [CLLocationCoordinate2D] = []
            var dist: Double = 0
            
            // Try to connect the previous and next footprints for a map line
            if currentIndex > 0 && currentIndex < sortedFootprints.count {
                let prev = sortedFootprints[currentIndex - 1]
                let next = sortedFootprints[currentIndex]
                path = [
                    CLLocationCoordinate2D(latitude: prev.latitude, longitude: prev.longitude),
                    CLLocationCoordinate2D(latitude: next.latitude, longitude: next.longitude)
                ]
                dist = CLLocation(latitude: prev.latitude, longitude: prev.longitude)
                         .distance(from: CLLocation(latitude: next.latitude, longitude: next.longitude))
            } else if currentIndex > 0 {
                let prev = sortedFootprints[currentIndex - 1]
                path = [CLLocationCoordinate2D(latitude: prev.latitude, longitude: prev.longitude)]
            } else if currentIndex < sortedFootprints.count {
                let next = sortedFootprints[currentIndex]
                path = [CLLocationCoordinate2D(latitude: next.latitude, longitude: next.longitude)]
            }
            
            let type = TransportType(rawValue: ov.vehicleType) ?? .car
            let t = Transport(
                startTime: ov.startTime,
                endTime: ov.endTime,
                startLocation: ov.startLocationOverride ?? "正在同步轨迹...",
                endLocation: ov.endLocationOverride ?? "正在同步轨迹...",
                type: type,
                distance: dist,
                averageSpeed: dist / max(1, ov.endTime.timeIntervalSince(ov.startTime)),
                points: path,
                manualType: type
            )
            items.append(.transport(t))
        }
    }

    private static func addStationaryStay(from start: Date, to end: Date, gapPoints: [CLLocation], items: inout [TimelineItem], allPlaces: [PlaceLite], coordinateOverride: CLLocationCoordinate2D? = nil, ignoreDiameter: Bool = false) {
        let duration = end.timeIntervalSince(start)
        guard duration >= AppConfig.shared.stayDurationThreshold else { return } // 使用配置的停留时长门槛
        
        let subPoints = extractPoints(from: gapPoints, start: start, end: end)
        if subPoints.isEmpty && coordinateOverride == nil { return }
        
        if !ignoreDiameter && !subPoints.isEmpty {
            // --- 核心修复：增加最大跨度校验 ---
            // 为了对抗“大漂移”，采用鲁棒直径算法（忽略 10% 的离群点）
            let filteredSubPoints = subPoints.filter { $0.horizontalAccuracy > 0 && $0.horizontalAccuracy < 800 }
            let pointsForDiameter = filteredSubPoints.isEmpty ? subPoints : filteredSubPoints
            
            // 鲁棒直径比原始 bounding box 更有韧性
            let diameter = calculateRobustDiameter(pointsForDiameter)
            
            // 针对长时间停留（如 3 小时），漂移量可能非常大，因此阶梯式大幅增加阈值
            let threshold: Double = duration > 10800 ? 1500 : (duration > 3600 ? 1000 : (duration > 900 ? 500 : 250))
            
            if diameter > threshold { return }
        }
        
        // Use the geometric centroid as representative location
        let midpoint = coordinateOverride ?? {
            if subPoints.isEmpty { return CLLocationCoordinate2D(latitude: 0, longitude: 0) }
            let avgLat = subPoints.map { $0.coordinate.latitude }.reduce(0, +) / Double(subPoints.count)
            let avgLon = subPoints.map { $0.coordinate.longitude }.reduce(0, +) / Double(subPoints.count)
            return CLLocationCoordinate2D(latitude: avgLat, longitude: avgLon)
        }()
        
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
            let name = place.name
            fp.address = name
            fp.title = Footprint.generateRandomTitle(for: name, seed: Int(start.timeIntervalSince1970))
            fp.placeID = place.placeID
        } else {
            fp.title = Footprint.generateRandomTitle(for: "此处", seed: Int(start.timeIntervalSince1970))
        }
        
        items.append(.footprint(fp))
    }

    
    /// 检查指定时间范围内是否存在用户手动删除的记录（Overrides）
    private static func isOverrideDeleted(start: Date, end: Date, overrides: [OverrideLite]) -> Bool {
        return overrides.contains { ov in
            guard ov.isDeleted else { return false }
            let intersectStart = max(start, ov.startTime)
            let intersectEnd = min(end, ov.endTime)
            let intersectDuration = intersectEnd.timeIntervalSince(intersectStart)
            if intersectDuration > 0 {
                let minDuration = min(end.timeIntervalSince(start), ov.endTime.timeIntervalSince(ov.startTime))
                return intersectDuration >= minDuration * 0.3
            }
            return false
        }
    }

    private static func applyTransportOverrides(_ t: Transport, overrides: [OverrideLite]) -> Transport? {
        if let override = overrides.first(where: { ov in
            let intersectStart = max(t.startTime, ov.startTime)
            let intersectEnd = min(t.endTime, ov.endTime)
            let intersectDuration = intersectEnd.timeIntervalSince(intersectStart)
            
            if intersectDuration > 0 {
                let minDuration = min(t.duration, ov.endTime.timeIntervalSince(ov.startTime))
                if intersectDuration >= minDuration * 0.3 { return true }
            }
            let midTime = t.startTime.addingTimeInterval(t.duration / 2)
            return (midTime >= ov.startTime.addingTimeInterval(-120) && midTime <= ov.endTime.addingTimeInterval(120))
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
        // 先对原始点进行初步过滤，剔除精度极差（>300m）的噪点，避免大幅拉伸段跨度
        let filteredPoints = points.filter { $0.horizontalAccuracy > 0 && $0.horizontalAccuracy < 300 }
        guard filteredPoints.count >= 2 else { return [] }
        
        var transports: [Transport] = []
        var currentPoints: [CLLocation] = [filteredPoints[0]]
        var currentSegmentType: TransportType? = nil
        
        for i in 1..<filteredPoints.count {
            let p = filteredPoints[i]
            let prevP = filteredPoints[i-1]
            let timeGap = p.timestamp.timeIntervalSince(prevP.timestamp)
            
            // 只要时间点间隔超过 30 分钟，强行打断，进入下一段判断
            // 提高门槛是为了应对后台定位点变稀疏的情况，避免长距离移动被切碎抛弃
            if timeGap > 30 * 60 {
                if let transport = finalizeTransport(currentPoints) { transports.append(transport) }
                currentPoints = [p]; currentSegmentType = nil; continue
            }

            // --- 增强：出发点静止识别 ---
            // 如果已经在当前段累积了一定时间，且之前一直处于静止状态，而当前点突然拉开了距离
            if currentPoints.count >= 2 {
                let segmentDuration = p.timestamp.timeIntervalSince(currentPoints.first!.timestamp)
                if segmentDuration > 60 { // 进一步降低至 60s
                    let diameter = calculateMaxDiameter(currentPoints)
                    let distFromStart = p.distance(from: currentPoints.first!)

                    // 允许更紧凑的停留范围（70m）和更短的跳出距离（120m）
                    if diameter < 70 && distFromStart > 120 {
                        if let transport = finalizeTransport(currentPoints) { transports.append(transport) }
                        currentPoints = [prevP, p]; currentSegmentType = nil; continue
                    }
                }
            }

            // --- 增强：中途或终点静止识别 ---
            if currentPoints.count > 8 && i % 5 == 0 {
                let recentWindow = Array(currentPoints[max(0, currentPoints.count-20)...(currentPoints.count-1)])
                let windowDuration = p.timestamp.timeIntervalSince(recentWindow.first!.timestamp)
                if windowDuration > 480 { // 8 分钟内
                    let diameter = calculateMaxDiameter(recentWindow + [p])
                    if diameter < 160 { // 静止半径进一步收紧
                        if let transport = finalizeTransport(currentPoints) { transports.append(transport) }
                        // 将触发点 p 保留在下一段的起点
                        currentPoints = [p]; currentSegmentType = nil; continue
                    }
                }
            }
            
            if currentPoints.count >= 8 && i % 3 == 0 {
                if currentSegmentType == nil {
                    let d = calculateDistance(currentPoints)
                    let t = currentPoints.last!.timestamp.timeIntervalSince(currentPoints.first!.timestamp)
                    currentSegmentType = TransportType.from(speed: t > 0 ? d / t : 0)
                }
                let window = Array(filteredPoints[max(0, i-10)...i])
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
        let merged = mergeTransports(transports)
        
        // 最终过滤：等所有短小的交通记录尽可能合并成大段后，再把由于信号漂移产生的，且无法被融合的独立“毛刺”交通彻底剔除
        return merged.filter { t in
            if t.distance >= AppConfig.shared.transportMinDistanceThreshold { return true } // 位移达到阈值，保留
            if t.duration < AppConfig.shared.transportMinDurationThreshold { return false } // 持续时间不足，剔除
            return true
        }
    }
    
    private static func isSignificantTypeChange(from t1: TransportType, to t2: TransportType) -> Bool {
        func category(of type: TransportType) -> Int {
            switch type {
            case .slow, .running: return 1
            case .bicycle: return 2
            case .ebike, .motorcycle: return 3
            case .car, .bus, .subway: return 4
            case .train: return 5
            case .airplane: return 6
            }
        }
        return category(of: t1) != category(of: t2)
    }
    
    private static func finalizeTransport(_ points: [CLLocation]) -> Transport? {
        let distance = calculateDistance(points)
        if points.count < 3 && distance < 150 { return nil }
        guard points.count >= 2 else { return nil }
        
        let start = points.first!.timestamp
        let end = points.last!.timestamp
        let duration = end.timeIntervalSince(start)
        let averageSpeed = duration > 0 ? distance / duration : 0
        let kmh = averageSpeed * 3.6
        
        // 根据配置进行最基础判定
        if distance < AppConfig.shared.transportMinDistanceThreshold && 
           duration < AppConfig.shared.transportMinDurationThreshold { return nil }

        if duration < 60 && kmh < 3 { return nil } // 保持原有的极短距离高速过滤
        
        let maxDiameter = calculateMaxDiameter(points)
        // 增加对“室内漂移”的过滤：如果最大跨度极小且路径绕圈特别严重（比值 > 3），判定为原地漂移
        if maxDiameter < AppConfig.shared.transportMinDistanceThreshold && distance > maxDiameter * 3.0 { return nil }
        
        // 如果虽然时间超过几分钟，但位移还是极小（小于 15 米），大概率是 GPS 抖动
        if distance < 15 { return nil }
        
        // 移除原有的 0.4 km/h 强制门槛，以便捕捉极慢的动作
        if kmh < 0.2 { return nil } // 调低至 0.2 km/h，几乎只要在走动就能捕捉到
        
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
    
    private static func calculateRobustDiameter(_ points: [CLLocation]) -> Double {
        guard points.count > 1 else { return 0 }
        
        // 计算质心
        let latSum = points.reduce(0.0) { $0 + $1.coordinate.latitude }
        let lonSum = points.reduce(0.0) { $0 + $1.coordinate.longitude }
        let center = CLLocation(latitude: latSum / Double(points.count), longitude: lonSum / Double(points.count))
        
        // 计算所有点到质心的距离并排序
        let distances = points.map { $0.distance(from: center) }.sorted()
        
        // 取第 90 百分位距离作为半径参考，乘以 2 得到直径近似值
        // 这能大幅过滤掉少数离群的“大漂移”点
        let percentileIndex = Int(Double(distances.count) * 0.90)
        return distances[percentileIndex] * 2.0
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
        func cat(of type: TransportType) -> Int {
            switch type {
            case .slow, .running: return 1
            case .bicycle: return 2
            case .ebike, .motorcycle: return 3
            case .car, .bus, .subway: return 4
            case .train: return 5
            case .airplane: return 6
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

class PersistentTimelineBuilder {
    @MainActor
    private static var syncingDates: Set<Date> = []

    @MainActor
    static func syncDay(date: Date, in context: ModelContext) async {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        
        // 防止重入
        guard !syncingDates.contains(startOfDay) else { return }
        syncingDates.insert(startOfDay)
        defer { syncingDates.remove(startOfDay) }
        
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!
        
        // 1. 获取当天的最后一条记录作为起始锚点 (不管是 confirmed, manual 还是 ignored)
        let fpDesc = FetchDescriptor<Footprint>(predicate: #Predicate {
            $0.startTime >= startOfDay && $0.startTime < endOfDay
        }, sortBy: [SortDescriptor(\.endTime, order: .reverse)])
        let lastFp = (try? context.fetch(fpDesc))?.first
        
        let tpDesc = FetchDescriptor<TransportRecord>(predicate: #Predicate {
            $0.startTime >= startOfDay && $0.startTime < endOfDay
        }, sortBy: [SortDescriptor(\.endTime, order: .reverse)])
        let lastTp = (try? context.fetch(tpDesc))?.first
        
        var lastEndTime = startOfDay
        if let lf = lastFp, let lt = lastTp {
            lastEndTime = max(lf.endTime, lt.endTime)
        } else if let lf = lastFp {
            lastEndTime = lf.endTime
        } else if let lt = lastTp {
            lastEndTime = lt.endTime
        }
        
        // 2. 加载锚点之后的原始点位
        let allRawPoints = await Task.detached {
            RawLocationStore.shared.loadAllDevicesLocations(for: date)
        }.value
        
        let newPoints = allRawPoints.filter { $0.timestamp > lastEndTime.addingTimeInterval(1) }.sorted(by: { $0.timestamp < $1.timestamp })
        
        // 3. 执行增量处理逻辑（仅追加）
        if !newPoints.isEmpty {
            await processPoints(points: newPoints, date: date, context: context)
            try? context.save() // 阶段一存盘：新识别的点位立刻可见
        }
        
        // 4. 合并可能因分片产生的小碎块 (从配置读取阈值)
        await mergeConsecutiveFootprints(for: date, in: context, threshold: AppConfig.shared.mergeDistanceThreshold)
        try? context.save() // 阶段二存盘：合并后的结果
        
        // 5. 缝隙嗅探器：处理长时间不动的情况（如全天在家）
        // 核心修复：只有在当天确实有轨迹点（说明定位开启中）或者是今天（显示实时状态）时才补全。
        // 如果是历史日期且一个点都没有，或者是只有照片点，则不要强行补全到 0 点（除非是新的一天刚开始衔接）
        let hasAnyPoints = !allRawPoints.isEmpty
        let isToday = calendar.isDateInToday(date)
        if hasAnyPoints || isToday {
            await fillGapAfterLastItem(for: date, lastEndTime: lastEndTime, in: context)
        }
        try? context.save() // 阶段三存盘：填补的空白
        
        startControlledAddressResolution(in: context)
    }


    @MainActor
    private static func fillGapAfterLastItem(for date: Date, lastEndTime: Date, in context: ModelContext) async {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        let now = Date()
        let endOfTargetDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!
        let syncLimit = min(now, endOfTargetDay)
        
        let gap = syncLimit.timeIntervalSince(lastEndTime)
        
        // 核心兜底：如果是全天空白（从 0:00 开始且没有任何原始轨迹），坚决不自动生成覆盖全天的假足迹
        if lastEndTime == startOfDay && gap > 23 * 3600 { return }

        if gap >= AppConfig.shared.gapFillingThreshold { // 使用配置的缺口阈值
            // 尝试寻找该日期的上一个足迹，如果没有，寻找该日期之前的绝对最后一条记录
            var fpDesc = FetchDescriptor<Footprint>(predicate: #Predicate {
                $0.startTime < lastEndTime
            }, sortBy: [SortDescriptor(\.endTime, order: .reverse)])
            fpDesc.fetchLimit = 1
            
            let previousFp = (try? context.fetch(fpDesc))?.first
            
            let bridgeFp = Footprint(
                date: startOfDay,
                startTime: lastEndTime,
                endTime: syncLimit,
                footprintLocations: previousFp != nil ? [CLLocationCoordinate2D(latitude: previousFp!.latitude, longitude: previousFp!.longitude)] : [],
                locationHash: "stationary_fill",
                duration: gap,
                status: .confirmed
            )
            bridgeFp.title = previousFp?.title ?? Footprint.generateRandomTitle(for: "某地", seed: Int(lastEndTime.timeIntervalSince1970))
            bridgeFp.address = previousFp?.address
            bridgeFp.placeID = previousFp?.placeID
            context.insert(bridgeFp)
        }
    }


    
    @MainActor
    private static func mergeConsecutiveFootprints(for date: Date, in context: ModelContext, threshold: Double = 200) async {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!
        
        let descriptor = FetchDescriptor<Footprint>(predicate: #Predicate {
            $0.startTime >= startOfDay && $0.startTime < endOfDay && $0.statusValue != "ignored"
        }, sortBy: [SortDescriptor(\.startTime)])
        
        let fps = (try? context.fetch(descriptor)) ?? []
        guard fps.count >= 2 else { return }
        
        var i = 0
        while i < fps.count - 1 {
            let current = fps[i]
            let next = fps[i+1]
            
            let currentLoc = CLLocation(latitude: current.latitude, longitude: current.longitude)
            let nextLoc = CLLocation(latitude: next.latitude, longitude: next.longitude)
            let dist = currentLoc.distance(from: nextLoc)
            let gap = next.startTime.timeIntervalSince(current.endTime)
            
            // 如果两个足迹距离小于阈值，且间隔小于配置的合并时长，则视作同一地点
            // 改进：如果要合并，必须确保照片不丢失；或者如果其中一个带照片，则更谨慎对待
            if dist < threshold && gap < AppConfig.shared.stayMergeGapThreshold {
                // 如果两个都有照片且地点稍有不同，建议保留独立性，除非距离极近（<50m）
                let bothHavePhotos = !current.photoAssetIDs.isEmpty && !next.photoAssetIDs.isEmpty
                if bothHavePhotos && dist > 50 {
                    i += 1
                    continue
                }

                // 合并时间
                current.endTime = max(current.endTime, next.endTime)
                current.duration = current.endTime.timeIntervalSince(current.startTime)
                
                // 合并照片
                if !next.photoAssetIDs.isEmpty {
                    var combinedPhotos = current.photoAssetIDs
                    for pid in next.photoAssetIDs {
                        if !combinedPhotos.contains(pid) { combinedPhotos.append(pid) }
                    }
                    current.photoAssetIDs = combinedPhotos
                }

                // 如果当前没有名字但下一个有，继承名字
                if Footprint.isGenericTitle(current.title) && !Footprint.isGenericTitle(next.title) {
                    current.title = next.title
                    current.placeID = next.placeID
                }
                
                // 标记下一个为忽略 (逻辑上合并了)
                next.statusValue = "ignored"
                
                try? context.save()
                // 递归处理，直到没有可合并的
                await mergeConsecutiveFootprints(for: date, in: context, threshold: threshold)
                return
            }
            i += 1
        }
    }
    
    struct CodableCoordinate: Codable {
        let lat: Double
        let lon: Double
    }
    
    @MainActor
    private static func processPoints(points: [CLLocation], date: Date, context: ModelContext) async {
        guard points.count >= 2 else { return }
        
        let startOfDay = Calendar.current.startOfDay(for: date)
        let allPlaces = (try? context.fetch(FetchDescriptor<Place>())) ?? []
        
        var i = 0
        while i < points.count {
            // 1. 尝试寻找从 i 开始的一个“停留点簇”
            var j = i + 1
            var clusterPoints: [CLLocation] = [points[i]]
            
            while j < points.count {
                let dist = points[j].distance(from: points[i])
                // 如果点 j 距离起始点 i 在阈值以内，视为还在同一个停留簇中
                if dist < AppConfig.shared.stayDistanceThreshold {
                    clusterPoints.append(points[j])
                    j += 1
                } else {
                    // 点 j 已经离远了，分水岭出现
                    break
                }
            }
            
            let duration = clusterPoints.last!.timestamp.timeIntervalSince(clusterPoints.first!.timestamp)
            
            if duration >= AppConfig.shared.stayDurationThreshold {
                // 判定为足迹！
                let coords = clusterPoints.map { $0.coordinate }
                let fp = Footprint(
                    date: startOfDay,
                    startTime: clusterPoints.first!.timestamp,
                    endTime: clusterPoints.last!.timestamp,
                    footprintLocations: coords,
                    locationHash: "\(coords.first?.latitude ?? 0),\(coords.first?.longitude ?? 0)",
                    duration: duration,
                    status: .confirmed
                )
                
                let loc = clusterPoints.first!
                if let matched = allPlaces.min(by: { p1, p2 in
                    loc.distance(from: CLLocation(latitude: p1.latitude, longitude: p1.longitude)) <
                    loc.distance(from: CLLocation(latitude: p2.latitude, longitude: p2.longitude))
                }), loc.distance(from: CLLocation(latitude: matched.latitude, longitude: matched.longitude)) < Double(matched.radius) + 50 {
                    fp.title = Footprint.generateRandomTitle(for: matched.name, seed: Int(fp.startTime.timeIntervalSince1970))
                    fp.placeID = matched.placeID
                    fp.address = matched.address
                } else {
                    fp.title = Footprint.generateRandomTitle(for: "某地", seed: Int(fp.startTime.timeIntervalSince1970))
                }
                context.insert(fp)
                i = j // 跳过该簇
            } else {
                // i 及其后续一小段不足以构成停留，那么从 i 到下一个停留起始点之间就是交通
                // 寻找下一个能构成停留的起始点 k
                var k = j
                var transportPoints: [CLLocation] = [points[i]]
                
                while k < points.count {
                    // 预判从 k 开始是否有停留
                    var m = k + 1
                    var subCluster: [CLLocation] = [points[k]]
                    while m < points.count {
                        if points[m].distance(from: points[k]) < AppConfig.shared.stayDistanceThreshold {
                            subCluster.append(points[m])
                            m += 1
                        } else { break }
                    }
                    
                    if subCluster.last!.timestamp.timeIntervalSince(subCluster.first!.timestamp) >= AppConfig.shared.stayDurationThreshold {
                        // 发现下一个停留点簇了！k 是停留的开始，那么从 i 到 k 就是交通
                        break
                    } else {
                        // k 依然是在移动或者短暂停留，将其归入交通
                        transportPoints.append(points[k])
                        k += 1
                    }
                }
                
                if transportPoints.count >= 2 {
                    let tStart = transportPoints.first!.timestamp
                    let tEnd = transportPoints.last!.timestamp
                    let coords = transportPoints.map { $0.coordinate }
                    let codableCoords = coords.map { CodableCoordinate(lat: $0.latitude, lon: $0.longitude) }
                    let diameter = calculateMaxDiameter(coords)
                    
                    // 如果一段交通的位移和时间均不足以被计入，则跳过
                    if diameter < AppConfig.shared.transportMinDistanceThreshold {
                        if tEnd.timeIntervalSince(tStart) < AppConfig.shared.transportMinDurationThreshold {
                            i = k
                            continue
                        }
                    }

                    let ptsData = (try? JSONEncoder().encode(codableCoords)) ?? Data()
                    
                    var startName = "起点", endName = "终点"
                    let sLoc = transportPoints.first!
                    let eLoc = transportPoints.last!
                    
                    if let sMatch = allPlaces.min(by: { p1, p2 in sLoc.distance(from: CLLocation(latitude: p1.latitude, longitude: p1.longitude)) < sLoc.distance(from: CLLocation(latitude: p2.latitude, longitude: p2.longitude)) }),
                       sLoc.distance(from: CLLocation(latitude: sMatch.latitude, longitude: sMatch.longitude)) < 200 {
                        startName = sMatch.name
                    }
                    if let eMatch = allPlaces.min(by: { p1, p2 in eLoc.distance(from: CLLocation(latitude: p1.latitude, longitude: p1.longitude)) < eLoc.distance(from: CLLocation(latitude: p2.latitude, longitude: p2.longitude)) }),
                       eLoc.distance(from: CLLocation(latitude: eMatch.latitude, longitude: eMatch.longitude)) < 200 {
                        endName = eMatch.name
                    }

                    let avgSpeed = tEnd.timeIntervalSince(tStart) > 0 ? diameter / tEnd.timeIntervalSince(tStart) : 0
                    let tp = TransportRecord(
                        day: startOfDay,
                        startTime: tStart,
                        endTime: tEnd,
                        startLocation: startName,
                        endLocation: endName,
                        typeRaw: TransportType.from(speed: avgSpeed).rawValue,
                        distance: diameter,
                        averageSpeed: avgSpeed,
                        pointsData: ptsData
                    )
                    context.insert(tp)
                }
                i = k // 移动到下一个可能的停留点或末尾
            }
        }
    }
    
    private static func calculateMaxDiameter(_ pts: [CLLocationCoordinate2D]) -> Double {
        if pts.isEmpty { return 0 }
        var minLat = pts[0].latitude, maxLat = pts[0].latitude
        var minLon = pts[0].longitude, maxLon = pts[0].longitude
        for p in pts {
            minLat = min(minLat, p.latitude)
            maxLat = max(maxLat, p.latitude)
            minLon = min(minLon, p.longitude)
            maxLon = max(maxLon, p.longitude)
        }
        let p1 = CLLocation(latitude: minLat, longitude: minLon)
        let p2 = CLLocation(latitude: maxLat, longitude: maxLon)
        return p1.distance(from: p2)
    }

    // --- 地理编码限频解析器 ---
    @MainActor
    private static let geocoder = CLGeocoder()
    private static var isResolving = false

    @MainActor
    static func startControlledAddressResolution(in context: ModelContext) {
        guard !isResolving else { return }
        isResolving = true
        
        Task {
            let sevenDaysAgo = Date().addingTimeInterval(-7 * 24 * 3600)
            
            // 1. 获取最近一周的所有足迹，然后在内存中精细化过滤，避开复杂的 #Predicate 宏
            let fpDesc = FetchDescriptor<Footprint>(predicate: #Predicate {
                $0.startTime > sevenDaysAgo
            })
            let recentFps = (try? context.fetch(fpDesc)) ?? []
            let pendingFps = recentFps.filter { 
                $0.address == nil || $0.address == "" || Footprint.isGenericTitle($0.title)
            }
            
            // 2. 获取最近一周的所有交通记录
            let tpDesc = FetchDescriptor<TransportRecord>(predicate: #Predicate {
                $0.startTime > sevenDaysAgo
            })
            let recentTps = (try? context.fetch(tpDesc)) ?? []
            let pendingTps = recentTps.filter {
                $0.startLocation == "起点" || $0.endLocation == "终点" || $0.startLocation == "正在获取位置..."
            }
            
            // 按照时间倒序一个一个解
            for fp in pendingFps {
                let coord = CLLocationCoordinate2D(latitude: fp.latitude, longitude: fp.longitude)
                let addr = await resolveSingleAddress(coordinate: coord)
                if !addr.isEmpty {
                    fp.address = addr
                    if Footprint.isGenericTitle(fp.title) {
                        fp.title = Footprint.generateRandomTitle(for: addr, seed: Int(fp.startTime.timeIntervalSince1970))
                    }
                    try? context.save()
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000) // 每 2 秒查一个
            }
            
            for tp in pendingTps {
                if tp.startLocation == "起点" {
                    if let decoded = try? JSONDecoder().decode([CodableCoordinate].self, from: tp.pointsData), let first = decoded.first {
                        let coord = CLLocationCoordinate2D(latitude: first.lat, longitude: first.lon)
                        tp.startLocation = await resolveSingleAddress(coordinate: coord)
                    }
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                
                if tp.endLocation == "终点" {
                    if let decoded = try? JSONDecoder().decode([CodableCoordinate].self, from: tp.pointsData), let last = decoded.last {
                        let coord = CLLocationCoordinate2D(latitude: last.lat, longitude: last.lon)
                        tp.endLocation = await resolveSingleAddress(coordinate: coord)
                    }
                }
                try? context.save()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            
            isResolving = false
        }
    }

    private static func resolveSingleAddress(coordinate: CLLocationCoordinate2D) async -> String {
        return await withCheckedContinuation { continuation in
            let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            CLGeocoder().reverseGeocodeLocation(location) { placemarks, error in
                if let placemark = placemarks?.first {
                    let name = placemark.name ?? placemark.thoroughfare ?? placemark.subLocality ?? "未知地点"
                    continuation.resume(returning: name)
                } else {
                    continuation.resume(returning: "")
                }
            }
        }
    }
}

extension PersistentTimelineBuilder {
    @MainActor
    static func fetchTimeline(for date: Date, in context: ModelContext) -> [TimelineItem] {
        let startOfDay = Calendar.current.startOfDay(for: date)
        let endOfDay = Calendar.current.date(byAdding: .day, value: 1, to: startOfDay)!
        
        let fpDescriptor = FetchDescriptor<Footprint>(predicate: #Predicate {
            $0.startTime >= startOfDay && $0.startTime < endOfDay && $0.statusValue != "ignored"
        })
        let fps = (try? context.fetch(fpDescriptor)) ?? []
        
        let tpDescriptor = FetchDescriptor<TransportRecord>(predicate: #Predicate {
            $0.startTime >= startOfDay && $0.startTime < endOfDay && $0.statusRaw != "ignored"
        })
        let tps = (try? context.fetch(tpDescriptor)) ?? []
        
        var items: [TimelineItem] = []
        for fp in fps {
            items.append(.footprint(fp))
        }
        for tp in tps {
            var pts: [CLLocationCoordinate2D] = []
            if let decoded = try? JSONDecoder().decode([CodableCoordinate].self, from: tp.pointsData) {
                pts = decoded.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
            }
            let tType = TransportType(rawValue: tp.typeRaw) ?? .slow
            let mType = tp.manualTypeRaw != nil ? TransportType(rawValue: tp.manualTypeRaw!) : nil
            
            let t = Transport(
                id: tp.recordID,
                startTime: tp.startTime,
                endTime: tp.endTime,
                startLocation: tp.startLocation,
                endLocation: tp.endLocation,
                type: tType,
                distance: tp.distance,
                averageSpeed: tp.averageSpeed,
                points: pts,
                manualType: mType
            )
            items.append(.transport(t))
        }
        
        items.sort { a, b in
            let aStart: Date
            let bStart: Date
            switch a { case .footprint(let fp): aStart = fp.startTime; case .transport(let tp): aStart = tp.startTime }
            switch b { case .footprint(let fp): bStart = fp.startTime; case .transport(let tp): bStart = tp.startTime }
            return aStart > bStart
        }
        return items
    }
}
