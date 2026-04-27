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

    mutating func updateStartTime(_ newStart: Date) {
        switch self {
        case .footprint(let f):
            f.startTime = newStart
        case .transport(let t):
            self = .transport(t.updatingTimes(start: newStart, end: t.endTime))
        }
    }

    mutating func updateEndTime(_ newEnd: Date) {
        switch self {
        case .footprint(let f):
            f.endTime = newEnd
        case .transport(let t):
            self = .transport(t.updatingTimes(start: t.startTime, end: newEnd))
        }
    }
}

// Lite versions for thread-safe background building
struct FootprintLite: Sendable {
    let startTime: Date
    let endTime: Date
    let latitude: Double
    let longitude: Double
    let footprintID: UUID
    let placeID: UUID?
    let address: String?
    let status: FootprintStatus
    let footprintLocations: [CLLocationCoordinate2D]
    let isAddressEditedByHand: Bool
    let date: Date
    let duration: TimeInterval
    let photoAssetIDs: [String]
    let reason: String?
    let isHighlight: Bool?
    let maxDiameter: Double
    let aiAnalyzed: Bool
    let activityTypeValue: String?
}

struct PlaceLite: Sendable {
    let placeID: UUID
    let name: String
    let latitude: Double
    let longitude: Double
    let radius: Int
    let isIgnored: Bool
    let isUserDefined: Bool
    let isPriority: Bool
    let address: String?
    let category: String?
}

struct OverrideLite: Sendable {
    let startTime: Date
    let endTime: Date
    let isDeleted: Bool
    let vehicleType: String
    let startLocationOverride: String?
    let endLocationOverride: String?
}

struct ActivityTypeLite: Sendable {
    let id: UUID
    let name: String
    let icon: String
    let colorHex: String
    let sortOrder: Int
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
            address: fp.address,
            status: fp.status,
            footprintLocations: fp.footprintLocations,
            isAddressEditedByHand: fp.isAddressEditedByHand,
            date: fp.date,
            duration: fp.duration,
            photoAssetIDs: fp.photoAssetIDs,
            reason: fp.reason,
            isHighlight: fp.isHighlight,
            maxDiameter: calculateMaxDiameter(fp.footprintLocations.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }), // Added for better merging
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
            address: p.address,
            category: p.category
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
        let isRawDataAvailable = allRawPoints.contains { $0.horizontalAccuracy > 0 && $0.horizontalAccuracy < AppConfig.shared.habitAnalysisAccuracyThreshold }
        var items: [TimelineItem] = []
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!
        let now = Date()
        
        // Calculate the actual end of available data for this day
        let lastRawTimestamp = allRawPoints.last?.timestamp
        let lastFootprintEndTime = footprints.map { $0.endTime }.max()
        let lastOverrideEndTime = overrides.map { $0.endTime }.max()
        let latestDataTime = [lastRawTimestamp, lastFootprintEndTime, lastOverrideEndTime]
            .compactMap { $0 }
            .max()
        
        let dayLimit: Date
        if calendar.isDateInToday(date) {
            dayLimit = min(endOfDay, now)
        } else {
            // For historical days, if there's data, stop at the last point; otherwise don't fill at all.
            dayLimit = latestDataTime.map { min(endOfDay, $0) } ?? startOfDay
        }
        
        let sortedFootprints = footprints
            .sorted { $0.startTime < $1.startTime }
            // 核心逻辑：使用配置调整的时间限制。但如果有照片，则视为原始事实保留且不作为垃圾过滤
            .filter { $0.duration >= AppConfig.shared.stayDurationThreshold || !$0.photoAssetIDs.isEmpty }
        
        // UI-level merging of consecutive footprints for the same location
        var finalizedSortedFootprints: [FootprintLite] = []
        for fp in sortedFootprints {
            if let last = finalizedSortedFootprints.last, shouldPerformUiMerge(last, fp) {
                // 核心修复：即使符合合并条件（距离近、时间近），如果中间有明显的原始轨迹位移，也不应合并
                let gapPoints = TimelineBuilder.extractPoints(from: allRawPoints, start: last.endTime, end: fp.startTime)
                let hasMovement = !gapPoints.isEmpty && hasSignificantMovement(between: last, and: fp, points: gapPoints)
                
                if !hasMovement {
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
                        address: (last.placeID != nil || last.isAddressEditedByHand) ? last.address : ((fp.placeID != nil || fp.isAddressEditedByHand) ? fp.address : last.address),
                        status: last.status,
                        footprintLocations: combinedLocations,
                        isAddressEditedByHand: last.isAddressEditedByHand || fp.isAddressEditedByHand,
                        date: last.date,
                        duration: max(last.endTime, fp.endTime).timeIntervalSince(last.startTime),
                        photoAssetIDs: Array(Set(last.photoAssetIDs + fp.photoAssetIDs)),
                        reason: last.reason ?? fp.reason,
                        isHighlight: (last.isHighlight == true || fp.isHighlight == true),
                        maxDiameter: 0, // Not strictly needed for UI Lite objects
                        aiAnalyzed: last.aiAnalyzed || fp.aiAnalyzed,
                        activityTypeValue: last.activityTypeValue ?? fp.activityTypeValue
                    )
                    finalizedSortedFootprints[finalizedSortedFootprints.count - 1] = combined
                } else {
                    finalizedSortedFootprints.append(fp)
                }
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
                fillGap(from: currentTime, to: fp.startTime, items: &items, gapPoints: gapPoints, sortedFootprints: finalizedSortedFootprints, currentIndex: index, allPlaces: allPlaces, overrides: overrides, isRawDataAvailable: isRawDataAvailable)
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
                    reason: fp.reason,
                    status: fp.status,
                    isHighlight: fp.isHighlight,
                    photoAssetIDs: fp.photoAssetIDs,
                    address: fp.address,
                    aiAnalyzed: fp.aiAnalyzed,
                    activityTypeValue: fp.activityTypeValue
                )
                model.placeID = fp.placeID
                model.isAddressEditedByHand = fp.isAddressEditedByHand
                
                // --- 衔接修复：防止足迹与其前面的交通/足迹重叠 ---
                if model.startTime < currentTime {
                    model.startTime = currentTime
                    if model.endTime < model.startTime { model.endTime = model.startTime.addingTimeInterval(AppConfig.shared.minStayDurationCorrection) }
                }
                
                items.append(.footprint(model))
            }
            
            currentTime = max(currentTime, fp.endTime)
        }
        
        // Final gap until now/end of day
        if dayLimit > currentTime {
            let gapPoints = TimelineBuilder.extractPoints(from: allRawPoints, start: currentTime, end: dayLimit)
            fillGap(from: currentTime, to: dayLimit, items: &items, gapPoints: gapPoints, sortedFootprints: finalizedSortedFootprints, currentIndex: finalizedSortedFootprints.count, allPlaces: allPlaces, overrides: overrides, isRawDataAvailable: isRawDataAvailable)
        }
        
        // Post-processing: Resolve overlaps to ensure continuous and non-overlapping timeline
        let resolvedItems = resolveTimelineOverlaps(items)
        
        // Final merge of adjacent stationary items if any were created during resolution
        let mergedItems = mergeAdjacentItems(resolvedItems)
        
        // --- 衔接优化：将交通的起止点名称与坐标对齐到前后足迹 ---
        let alignedItems = alignTransportLocations(mergedItems, allPlaces: allPlaces)
        
        return alignedItems.reversed()
    }

    private static func resolveTimelineOverlaps(_ items: [TimelineItem]) -> [TimelineItem] {
        guard !items.isEmpty else { return [] }
        
        // 首先按开始时间升序排列
        let sorted = items.sorted { $0.startTime < $1.startTime }
        var resolved: [TimelineItem] = []
        
        for i in 0..<sorted.count {
            var current = sorted[i]
            
            if let last = resolved.last {
                // 如果当前项的开始时间早于上一项的结束时间 -> 存在重叠
                if current.startTime < last.endTime {
                    // 足迹优先原则：如果上一项是足迹，当前项起始点推后
                    // 但通常为了保持连续性，直接将起始点对齐到上一项的结束点
                    current.updateStartTime(last.endTime)
                    
                    // 如果对齐后，当前项的持续时间变成了负数或极短，则跳过此项
                    if current.endTime <= current.startTime.addingTimeInterval(AppConfig.shared.tinyStayThreshold) {
                        continue
                    }
                }
            }
            resolved.append(current)
        }
        
        return resolved
    }

    /// 核心优化：遍历时间轴，将所有交通段的起点设置为上一个足迹点，终点设置为下一个足迹点
    static func alignTransportLocations(_ items: [TimelineItem], allPlaces: [PlaceLite]) -> [TimelineItem] {
        var result = items
        for i in 0..<result.count {
            guard case .transport(let t) = result[i] else { continue }
            
            var updatedT = t
            
            // 向前寻找最近的足迹点作为起点
            var prevFp: Footprint?
            for j in (0..<i).reversed() {
                if case .footprint(let fp) = result[j] {
                    // 核心修复：只有时间上足够接近，才认为是衔接关系
                    // 避免中间的足迹被删除后，前后的交通直接对跳衔接
                    if abs(t.startTime.timeIntervalSince(fp.endTime)) < AppConfig.shared.transportAlignmentThreshold {
                        prevFp = fp
                    }
                    break
                }
            }
            
            if let fp = prevFp {
                // 优先使用地点名称，其次是足迹自身的地址
                let matchedPlace = allPlaces.first(where: { $0.placeID == fp.placeID && $0.isUserDefined })
                let startName = matchedPlace?.name ?? fp.address ?? "未知地点"
                updatedT = updatedT.updatingStart(startName)
                
                // 强制对齐坐标
                var newPoints = updatedT.points
                let startCoord = CLLocationCoordinate2D(latitude: fp.latitude, longitude: fp.longitude)
                if newPoints.isEmpty {
                    newPoints = [startCoord]
                } else {
                    newPoints[0] = startCoord
                }
                updatedT = updatedT.updatingPoints(newPoints)
            }
            
            // 向后寻找最近的足迹点作为终点
            var nextFp: Footprint?
            for j in (i+1)..<result.count {
                if case .footprint(let fp) = result[j] {
                    // 核心修复：只有时间上足够接近，才认为是衔接关系
                    if abs(fp.startTime.timeIntervalSince(t.endTime)) < AppConfig.shared.transportAlignmentThreshold {
                        nextFp = fp
                    }
                    break
                }
            }
            
            if let fp = nextFp {
                // 优先使用地点名称，其次是足迹自身的地址
                let matchedPlace = allPlaces.first(where: { $0.placeID == fp.placeID && $0.isUserDefined })
                let endName = matchedPlace?.name ?? fp.address ?? "未知地点"
                updatedT = updatedT.updatingEnd(endName)
                
                // 强制对齐坐标
                var newPoints = updatedT.points
                let endCoord = CLLocationCoordinate2D(latitude: fp.latitude, longitude: fp.longitude)
                if newPoints.isEmpty {
                    newPoints.append(endCoord)
                } else if newPoints.count == 1 {
                    newPoints.append(endCoord)
                } else {
                    newPoints[newPoints.count - 1] = endCoord
                }
                updatedT = updatedT.updatingPoints(newPoints)
            }
            
            result[i] = .transport(updatedT)
        }
        return result
    }

    private static func shouldPerformUiMerge(_ f1: FootprintLite, _ f2: FootprintLite) -> Bool {
        return checkMergeCondition(
            start1: f1.startTime, end1: f1.endTime, lat1: f1.latitude, lon1: f1.longitude, addr1: f1.address, place1: f1.placeID, activity1: f1.activityTypeValue,
            start2: f2.startTime, end2: f2.endTime, lat2: f2.latitude, lon2: f2.longitude, addr2: f2.address, place2: f2.placeID, activity2: f2.activityTypeValue
        )
    }

    private static func shouldPerformUiMerge(_ f1: Footprint, _ f2: Footprint) -> Bool {
        return checkMergeCondition(
            start1: f1.startTime, end1: f1.endTime, lat1: f1.latitude, lon1: f1.longitude, addr1: f1.address, place1: f1.placeID, activity1: f1.activityTypeValue,
            start2: f2.startTime, end2: f2.endTime, lat2: f2.latitude, lon2: f2.longitude, addr2: f2.address, place2: f2.placeID, activity2: f2.activityTypeValue
        )
    }

    private static func checkMergeCondition(
        start1: Date, end1: Date, lat1: Double, lon1: Double, addr1: String?, place1: UUID?, activity1: String?,
        start2: Date, end2: Date, lat2: Double, lon2: Double, addr2: String?, place2: UUID?, activity2: String?
    ) -> Bool {
        if start2.timeIntervalSince(end1) > AppConfig.shared.stayMergeGapThreshold { return false }
        if let p1 = place1, let p2 = place2, p1 == p2 && activity1 == activity2 { return true }
        let loc1 = CLLocation(latitude: lat1, longitude: lon1)
        let loc2 = CLLocation(latitude: lat2, longitude: lon2)
        if loc1.distance(from: loc2) < AppConfig.shared.stayDistanceThreshold && addr1 == addr2 && activity1 == activity2 { return true }
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
                    
                    if isSamePlace || loc1.distance(from: loc2) < AppConfig.shared.mergeDistanceThreshold {
                        let combined = Footprint(
                            date: f1.date,
                            startTime: f1.startTime,
                            endTime: max(f1.endTime, f2.endTime),
                            footprintLocations: f1.footprintLocations + f2.footprintLocations,
                            locationHash: "UI_MERGE_FINAL",
                            duration: max(f1.endTime, f2.endTime).timeIntervalSince(f1.startTime),
                            status: (f1.status == .confirmed || f2.status == .confirmed) ? .confirmed : f1.status,
                            address: (f1.placeID != nil || f1.isAddressEditedByHand) ? f1.address : ((f2.placeID != nil || f2.isAddressEditedByHand) ? f2.address : f1.address),
                            activityTypeValue: f1.activityTypeValue ?? f2.activityTypeValue
                        )
                        combined.isAddressEditedByHand = f1.isAddressEditedByHand || f2.isAddressEditedByHand
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
    
    private static func fillGap(from start: Date, to end: Date, items: inout [TimelineItem], gapPoints: [CLLocation], sortedFootprints: [FootprintLite], currentIndex: Int, allPlaces: [PlaceLite], overrides: [OverrideLite], isRawDataAvailable: Bool) {
        let duration = end.timeIntervalSince(start)
        guard duration > 60 else { return } // Ignore gaps < 1 min
        
        if gapPoints.isEmpty {
            let isToday = Calendar.current.isDateInToday(start)
            // 核心防护：如果是历史日期且没有原始轨迹，不执行任何自动填充逻辑，保持真实空白
            guard isRawDataAvailable || isToday else { return }
            
            // Check for "Phantom Transports"
            handlePhantomTransports(from: start, to: end, items: &items, sortedFootprints: sortedFootprints, currentIndex: currentIndex, allPlaces: allPlaces, overrides: overrides)
            
            // 如果处理完“虚空交通”后，这段时间依然有幅空白，则执行强制桥接
            let lastItemEnd = items.last?.endTime ?? start
            if end.timeIntervalSince(lastItemEnd) > AppConfig.shared.stayDurationThreshold && !isOverrideDeleted(start: lastItemEnd, end: end, overrides: overrides) {
                bridgeDataGap(from: lastItemEnd, to: end, items: &items, sortedFootprints: sortedFootprints, currentIndex: currentIndex, allPlaces: allPlaces, isRawDataAvailable: isRawDataAvailable)
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
                
                // --- 核心修复：确保交通与前序项衔接 ---
                let gapBefore = t.startTime.timeIntervalSince(lastProcessedTime)
                if gapBefore >= AppConfig.shared.stayDurationThreshold {
                    let preStayCount = items.count
                    addStationaryStay(from: lastProcessedTime, to: t.startTime, gapPoints: gapPoints, items: &items, allPlaces: allPlaces)
                    
                    if items.count == preStayCount && !isOverrideDeleted(start: lastProcessedTime, end: t.startTime, overrides: overrides) {
                        addStationaryStay(from: lastProcessedTime, to: t.startTime, gapPoints: gapPoints, items: &items, allPlaces: allPlaces, ignoreDiameter: true, forceAdd: true)
                    }
                } else if gapBefore != 0 {
                    // 如果间隙很小，直接修正交通起点以保持衔接
                    t = t.updatingTimes(start: lastProcessedTime, end: t.endTime)
                }
                
                let startCoord = t.points.first
                let endCoord = t.points.last
                
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

                if t.startLocation == "起点" { t = t.updatingStart("正在获取位置...") }
                if t.endLocation == "终点" { t = t.updatingEnd("正在获取位置...") }

                if let ft = applyTransportOverrides(t, overrides: overrides) {
                    items.append(.transport(ft))
                    lastProcessedTime = ft.endTime
                }
            }
            
            // --- 核心修复：处理交通末尾与下一个足迹的衔接
            let isOngoing = isTodayView && end >= now.addingTimeInterval(-AppConfig.shared.ongoingStayGracePeriod)
            if !isOngoing && end.timeIntervalSince(lastProcessedTime) > 0 {
                addStationaryStay(from: lastProcessedTime, to: end, gapPoints: gapPoints, items: &items, allPlaces: allPlaces, forceAdd: true)
            }
            // No transports: fill the whole gap as a stay
            // --- 增强修复：如果虽然没识别出交通，但位移跨度很大，不应将其作为 Stay 填补，
            // 否则会造成前后的足迹被错误合并。此时应合成一段虚线交通。
            // 使用精度过滤后的点计算直径，防止 GPS 噪点干扰
            let filteredGapPoints = gapPoints.filter { $0.horizontalAccuracy > 0 && $0.horizontalAccuracy < AppConfig.shared.habitAnalysisAccuracyThreshold }
            let diameter = calculateMaxDiameter(filteredGapPoints)
            if diameter > max(AppConfig.shared.transportMinDistanceThreshold, AppConfig.shared.mergeDistanceThreshold) {
                if let startCoord = filteredGapPoints.first?.coordinate, let endCoord = filteredGapPoints.last?.coordinate {
                    addSynthesizedTransport(from: start, to: end, l1: startCoord, l2: endCoord, items: &items)
                }
            } else {
                addStationaryStay(from: lastProcessedTime, to: end, gapPoints: gapPoints, items: &items, allPlaces: allPlaces, forceAdd: true)
            }
        }
    }

    /// 当完全没有原始轨迹点时，根据位置变化逻辑桥接空白
    private static func bridgeDataGap(from start: Date, to end: Date, items: inout [TimelineItem], sortedFootprints: [FootprintLite], currentIndex: Int, allPlaces: [PlaceLite], isRawDataAvailable: Bool) {
        let duration = end.timeIntervalSince(start)
        let isToday = Calendar.current.isDateInToday(start)
        
        // 核心修复：如果是历史日期且完全没有原始轨迹点，则不应执行自动桥接（防止产生虚假记录）
        guard isRawDataAvailable || isToday else { return }
        
        // 只要时间超过交通门槛（通常为 60s），且有位移，就应考虑桥接
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
            if distance < AppConfig.shared.gapFillingMaxDistance {
                // 距离相近，认为是原地停留
                addStationaryStay(from: start, to: end, gapPoints: [], items: &items, allPlaces: allPlaces, coordinateOverride: l1.coordinate)
            } else if isRawDataAvailable {
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

    private static func addStationaryStay(from start: Date, to end: Date, gapPoints: [CLLocation], items: inout [TimelineItem], allPlaces: [PlaceLite], coordinateOverride: CLLocationCoordinate2D? = nil, ignoreDiameter: Bool = false, forceAdd: Bool = false) {
        let duration = end.timeIntervalSince(start)
        if !forceAdd {
            guard duration >= AppConfig.shared.stayDurationThreshold else { return } // 使用配置的停留时长门槛
        }
        
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
            fp.placeID = place.placeID
            fp.address = place.name
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
            return (midTime >= ov.startTime.addingTimeInterval(-AppConfig.shared.ongoingStayGracePeriod) && midTime <= ov.endTime.addingTimeInterval(AppConfig.shared.ongoingStayGracePeriod))
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
        let matchedPlace = allPlaces.first(where: { place in
            (place.placeID == footprint.placeID && place.isUserDefined) ||
            (place.isUserDefined && !footprint.isAddressEditedByHand && (place.name == footprint.address || place.address == footprint.address))
        })
        let displayText = matchedPlace?.name ?? footprint.address ?? "未知地点"
        return displayText
    }
    
    static func getPlaceForCoordinate(_ coordinate: CLLocationCoordinate2D, allPlaces: [PlaceLite]) -> PlaceLite? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        struct Match { let place: PlaceLite; let distance: Double }
        
        // 分两波匹配，第一波只看重要地点，且半径门槛稍微宽松一点以对抗 GPS 漂移
        let importantMatches: [Match] = allPlaces.compactMap { place in
            guard place.isUserDefined && !place.isIgnored else { return nil }
            let d = location.distance(from: CLLocation(latitude: place.latitude, longitude: place.longitude))
            // 重要地点：只要在半径 + 150m 漂移补偿范围内就算
            if d <= Double(place.radius) + 150.0 { return Match(place: place, distance: d) }
            return nil
        }.sorted { $0.distance < $1.distance }
        
        if let bestImportant = importantMatches.first {
            return bestImportant.place
        }
        
        // 如果没有重要地点，再看普通地点，半径门槛从严 (radius + 50m)
        let otherMatches: [Match] = allPlaces.compactMap { place in
            guard !place.isUserDefined && !place.isIgnored else { return nil }
            let d = location.distance(from: CLLocation(latitude: place.latitude, longitude: place.longitude))
            if d <= Double(place.radius) + 50.0 { return Match(place: place, distance: d) }
            return nil
        }.sorted { $0.distance < $1.distance }
        
        return otherMatches.first?.place
    }
    
    private static func extractTransports(_ points: [CLLocation]) -> [Transport] {
        // 先对原始点进行初步过滤，剔除精度极差（>300m）的噪点，避免大幅拉伸段跨度
        let filteredPoints = points.filter { $0.horizontalAccuracy > 0 && $0.horizontalAccuracy < AppConfig.shared.habitAnalysisAccuracyThreshold }
        guard filteredPoints.count >= 2 else { return [] }
        
        var transports: [Transport] = []
        var currentPoints: [CLLocation] = [filteredPoints[0]]
        var currentSegmentType: TransportType? = nil
        
        for i in 1..<filteredPoints.count {
            let p = filteredPoints[i]
            let prevP = filteredPoints[i-1]
            let timeGap = p.timestamp.timeIntervalSince(prevP.timestamp)
            
            // 只要时间点间隔超过配置的打断门槛，强行打断，进入下一段判断
            // 提高门槛是为了应对后台定位点变稀疏的情况，避免长距离移动被切碎抛弃
            if timeGap > AppConfig.shared.transportGapBreakThreshold {
                if let transport = finalizeTransport(currentPoints) { transports.append(transport) }
                currentPoints = [p]; currentSegmentType = nil; continue
            }

            // --- 增强：出发点静止识别 ---
            // 如果已经在当前段累积了一定时间，且之前一直处于静止状态，而当前点突然拉开了距离
            if currentPoints.count >= 2 {
                let segmentDuration = p.timestamp.timeIntervalSince(currentPoints.first!.timestamp)
                if segmentDuration > AppConfig.shared.transportDetectionSegmentDuration {
                    let diameter = calculateMaxDiameter(currentPoints)
                    let distFromStart = p.distance(from: currentPoints.first!)

                    // 允许更紧凑的停留范围和更短的跳出距离
                    if diameter < AppConfig.shared.stationaryDiameterThreshold && distFromStart > AppConfig.shared.stayExitDistanceThreshold {
                        if let transport = finalizeTransport(currentPoints) { transports.append(transport) }
                        currentPoints = [prevP, p]; currentSegmentType = nil; continue
                    }
                }
            }

            // --- 增强：中途或终点静止识别 ---
            if currentPoints.count > 8 && i % 5 == 0 {
                let recentWindow = Array(currentPoints[max(0, currentPoints.count-20)...(currentPoints.count-1)])
                let windowDuration = p.timestamp.timeIntervalSince(recentWindow.first!.timestamp)
                if windowDuration > AppConfig.shared.stationaryDetectionDurationThreshold {
                    let diameter = calculateMaxDiameter(recentWindow + [p])
                    if diameter < AppConfig.shared.stationaryDetectionMaxDiameter { // 静止半径进一步收紧
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
                    if let segType = currentSegmentType, isSignificantTypeChange(from: segType, to: wType) && wt > AppConfig.shared.transportTypeChangeDurationThreshold {
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
            case .ship: return 7
            }
        }
        return category(of: t1) != category(of: t2)
    }
    
    private static func finalizeTransport(_ points: [CLLocation]) -> Transport? {
        let distance = calculateDistance(points)
        if points.count < 3 && distance < AppConfig.shared.transportFinalizeMinDistance { return nil }
        guard points.count >= 2 else { return nil }
        
        let startLoc = points.first!
        let endLoc = points.last!
        let start = startLoc.timestamp
        let end = endLoc.timestamp
        let duration = end.timeIntervalSince(start)
        
        // --- 核心增强：路径鲁棒性校验 (Ratio Check) ---
        let displacement = endLoc.distance(from: startLoc)
        let ratio = displacement > 0 ? distance / displacement : distance
        
        // 如果路径总长度是直线位移的 10 倍以上，且位移本身很小（< 500m），大概率中间有点位发生了剧烈跳变
        if displacement < 500 && ratio > 10 && distance > 1000 {
            // 这种情况下，极有可能是 GPS 尖峰。
            // 我们尝试使用鲁棒距离（即只计算那些没有发生剧烈跳变的段落，或者直接改用位移作为估算）
            // 这里我们选择直接放弃这段极其可疑的交通，或者后续通过更精细的逻辑处理。
            // 暂时策略：如果漂移太严重，判定为无效交通（可能是原地停留时的巨大跳变）
            return nil
        }

        let averageSpeed = duration > 0 ? distance / duration : 0
        let kmh = averageSpeed * 3.6
        
        // 根据配置进行最基础判定
        if distance < AppConfig.shared.transportMinDistanceThreshold && 
           duration < AppConfig.shared.transportMinDurationThreshold { return nil }

        if duration < 60 && kmh < 3 { return nil } // 保持原有的极短距离高速过滤
        
        let maxDiameter = calculateMaxDiameter(points)
        // 增加对“室内漂移”的过滤：如果最大跨度极小且路径绕圈特别严重（比值 > 阈值），判定为原地漂移
        if maxDiameter < AppConfig.shared.transportMinDistanceThreshold && distance > maxDiameter * AppConfig.shared.driftRatioThreshold { return nil }
        
        // 如果虽然时间超过几分钟，但位移还是极小（小于 15 米），大概率是 GPS 抖动
        if distance < 15 { return nil }
        
        // 移除原有的 0.4 km/h 强制门槛，以便捕捉极慢的动作
        if averageSpeed < (AppConfig.shared.speedThresholdStationary / 3.6) { return nil } // 只要在走动就能捕捉到
        
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
    
    static func calculateDistance(_ points: [CLLocation]) -> Double {
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
            case .ship: return 7
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

    static func calculateMaxDiameter(_ pts: [CLLocationCoordinate2D]) -> Double {
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

    /// 核心判断逻辑：判断两个足迹中间是否发生了可以被视为交通的位移
    static func hasSignificantMovement(between f1: FootprintLite, and f2: FootprintLite, points: [CLLocation]) -> Bool {
        if points.isEmpty { return false }
        
        // 1. 检查直径（判定大跨度位移）
        let diameter = calculateMaxDiameter(points.map { $0.coordinate })
        // 只要中间轨迹的直径超过了交通识别的最低门槛，就认为有显著位移
        if diameter > AppConfig.shared.transportMinDistanceThreshold { return true }
        
        // 2. 检查是否有任何点位脱离了两者的核心停留区
        let loc1 = CLLocation(latitude: f1.latitude, longitude: f1.longitude)
        let loc2 = CLLocation(latitude: f2.latitude, longitude: f2.longitude)
        
        for p in points {
            let d1 = p.distance(from: loc1)
            let d2 = p.distance(from: loc2)
            // 如果点位距离两个足迹中心都超过了停留判定阈值，说明中间有外出动作
            if d1 > AppConfig.shared.stayDistanceThreshold && d2 > AppConfig.shared.stayDistanceThreshold {
                return true
            }
        }
        
        return false
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
    
    static func calculatePathDistance(_ points: [CodableCoordinate]) -> Double {
        var distance: Double = 0
        guard points.count >= 2 else { return 0 }
        for i in 0..<points.count - 1 {
            let p1 = CLLocation(latitude: points[i].lat, longitude: points[i].lon)
            let p2 = CLLocation(latitude: points[i+1].lat, longitude: points[i+1].lon)
            distance += p1.distance(from: p2)
        }
        return distance
    }
}

struct CodableCoordinate: Codable {
    let lat: Double
    let lon: Double
}

class PersistentTimelineBuilder {
    @MainActor
    private static var syncingDates: Set<Date> = []
    
    /// 分析历史数据，判断用户更习惯哪种车载/轨道方式（汽车、公交、摩托车、轨交）
    /// 排除目标日期，防止因用户正在修改当前数据而导致判定结果在“临界点”反复跳变
    private static func getPreferredAutomotiveType(in context: ModelContext, excluding date: Date) -> TransportType {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!
        
        var descriptor = FetchDescriptor<TransportRecord>(
            predicate: #Predicate { 
                $0.statusRaw != "ignored" && ($0.startTime < startOfDay || $0.startTime >= endOfDay)
            },
            sortBy: [SortDescriptor(\.startTime, order: .reverse)]
        )
        descriptor.fetchLimit = 150 
        
        let recent = (try? context.fetch(descriptor)) ?? []
        
        var counts: [TransportType: Int] = [.car: 0, .bus: 0, .motorcycle: 0, .subway: 0]
        for record in recent {
            let typeString = record.manualTypeRaw ?? record.typeRaw
            if let type = TransportType(rawValue: typeString), counts.keys.contains(type) {
                counts[type, default: 0] += 1
            }
        }
        
        return counts.max(by: { $0.value < $1.value })?.key ?? .car
    }
    
    /// 分析历史数据，判断用户更习惯自行车还是电动车
    private static func getPreferredCyclingType(in context: ModelContext, excluding date: Date) -> TransportType {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!
        
        var descriptor = FetchDescriptor<TransportRecord>(
            predicate: #Predicate { 
                $0.statusRaw != "ignored" && ($0.startTime < startOfDay || $0.startTime >= endOfDay)
            },
            sortBy: [SortDescriptor(\.startTime, order: .reverse)]
        )
        descriptor.fetchLimit = 150
        
        let recent = (try? context.fetch(descriptor)) ?? []
        let bikeCount = recent.filter { $0.typeRaw == TransportType.bicycle.rawValue || $0.manualTypeRaw == TransportType.bicycle.rawValue }.count
        let ebikeCount = recent.filter { $0.typeRaw == TransportType.ebike.rawValue || $0.manualTypeRaw == TransportType.ebike.rawValue }.count
        
        return bikeCount >= ebikeCount ? .bicycle : .ebike
    }

    @MainActor
    static func syncDay(date: Date, in context: ModelContext) async {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        
        // 防止重入
        guard !syncingDates.contains(startOfDay) else { return }
        syncingDates.insert(startOfDay)
        defer { syncingDates.remove(startOfDay) }
        
        let preferredAuto = getPreferredAutomotiveType(in: context, excluding: date)
        let preferredCycling = getPreferredCyclingType(in: context, excluding: date)
        
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!
        let isToday = calendar.isDateInToday(date)
        
        // 1. 获取当天所有的真实记录并排序（包括自动填充的记录，以防止无限循环）
        let fpDesc = FetchDescriptor<Footprint>(predicate: #Predicate {
            $0.startTime >= startOfDay && $0.startTime < endOfDay && $0.statusValue != "ignored"
        }, sortBy: [SortDescriptor(\.startTime)])
        let allFps = (try? context.fetch(fpDesc)) ?? []
        
        let tpDesc = FetchDescriptor<TransportRecord>(predicate: #Predicate {
            $0.startTime >= startOfDay && $0.startTime < endOfDay && $0.statusRaw != "ignored"
        }, sortBy: [SortDescriptor(\.startTime)])
        let allTps = (try? context.fetch(tpDesc)) ?? []
        
        // 合并并排序所有记录的时间区间
        struct TimeRange { let start: Date; let end: Date }
        var sortedRanges: [TimeRange] = []
        for fp in allFps { sortedRanges.append(TimeRange(start: fp.startTime, end: fp.endTime)) }
        for tp in allTps { sortedRanges.append(TimeRange(start: tp.startTime, end: tp.endTime)) }
        sortedRanges.sort { $0.start < $1.start }
        
        // 2. 加载锚点之后的原始点位
        let allRawPoints = await Task.detached {
            RawLocationStore.shared.loadAllDevicesLocations(for: date)
        }.value
        
        // 3. 核心改进：寻找未覆盖的缺口并填补，而不仅仅是追加
        var gaps: [TimeRange] = []
        var currentTime = startOfDay
        let now = Date()
        
        let lastRawTimestamp = allRawPoints.last?.timestamp
        let lastRangeEnd = sortedRanges.last?.end
        let latestDataTime = [lastRawTimestamp, lastRangeEnd].compactMap { $0 }.max()
        
        let upperLimit: Date
        if isToday {
            upperLimit = now
        } else {
            // 对于历史日期，如果没有数据，则不应有任何填充；如果有数据，则止于最后一条数据的时间点
            guard let latest = latestDataTime else { return } // 核心防护：历史日期若完全无点，直接结束同步
            upperLimit = min(endOfDay, latest)
        }
        
        // 如果是今天，获取正在进行的停留开始时间，避免将其作为正式记录生成
        let ongoingStart = isToday ? LocationManager.shared.potentialStopStartLocation?.timestamp : nil
        
        for range in sortedRanges {
            // 如果缺口大于门槛时间（例如 5 分钟），则视为需要填补的缺口
            if range.start > currentTime.addingTimeInterval(AppConfig.shared.gapFillingThreshold) {
                gaps.append(TimeRange(start: currentTime, end: range.start))
            }
            currentTime = max(currentTime, range.end)
        }
        
        // 补齐末尾缺口
        if currentTime < upperLimit.addingTimeInterval(-AppConfig.shared.gapFillingThreshold) {
            gaps.append(TimeRange(start: currentTime, end: upperLimit))
        }
        
        // 4. 对每个缺口进行处理
        for gap in gaps {
            if Task.isCancelled { break }
            
            // 过滤该缺口内的点位
            let gapPoints = allRawPoints.filter { point in
                if point.timestamp < gap.start || point.timestamp > gap.end { return false }
                // 核心防护：如果点位处于实时进行的停留时间之后，先跳过，让其留在实时状态中
                if let os = ongoingStart, point.timestamp >= os { return false }
                // 核心修复：过滤精度极差或无效的点，防止 GPS 漂移产生虚假交通
                if point.horizontalAccuracy <= 0 || point.horizontalAccuracy > AppConfig.shared.habitAnalysisAccuracyThreshold { return false }
                return true
            }
            
            if gapPoints.count >= 2 {
                await processPoints(points: gapPoints.sorted(by: { $0.timestamp < $1.timestamp }), date: date, context: context, preferredAuto: preferredAuto, preferredCycling: preferredCycling)
            }
        }
        
        try? context.save()
        
        // 5. 后置清理：合并可能因分片产生的小碎块，补齐微小缝隙
        await mergeConsecutiveFootprints(for: date, in: context, allRawPoints: allRawPoints, threshold: AppConfig.shared.mergeDistanceThreshold)
        await mergeConsecutiveTransports(for: date, in: context, preferredAuto: preferredAuto, preferredCycling: preferredCycling)
        await fillGapsBetweenItems(for: date, in: context, allRawPoints: allRawPoints, preferredAuto: preferredAuto, preferredCycling: preferredCycling)
        await snapTransportsToFootprints(for: date, in: context)
        try? context.save()
        // ----------------------------------------------------
        
        try? context.save()
        
        // 按用户要求：在此处（重置最后）调用合并逻辑
        await LocationManager.shared.consolidateFootprints(in: context, targetDate: date)
        
        startControlledAddressResolution(in: context)
    }


    @MainActor
    private static func fillGapAfterLastItem(for date: Date, lastEndTime: Date, in context: ModelContext) async {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        let now = Date()
        let endOfTargetDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!
        
        // 缝隙嗅探器的截止点：除了受限于当前时间，还要受限于本设备当前的“实时停留”起始点。
        // 如果正在停留，缝隙填充不应跨越到停留时间段内，否则会造成双重视图。
        let ongoingStart = calendar.isDateInToday(date) ? LocationManager.shared.potentialStopStartLocation?.timestamp : nil
        
        var syncLimit = min(now, endOfTargetDay)
        if let os = ongoingStart {
            syncLimit = min(syncLimit, os)
        }
        
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
            bridgeFp.address = previousFp?.address
            bridgeFp.placeID = previousFp?.placeID
            context.insert(bridgeFp)
        }
    }

    @MainActor
    private static func mergeConsecutiveTransports(for date: Date, in context: ModelContext, preferredAuto: TransportType = .car, preferredCycling: TransportType = .bicycle) async {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!
        
        let descriptor = FetchDescriptor<TransportRecord>(predicate: #Predicate {
            $0.startTime >= startOfDay && $0.startTime < endOfDay && $0.statusRaw != "ignored"
        }, sortBy: [SortDescriptor(\.startTime)])
        
        let tps = (try? context.fetch(descriptor)) ?? []
        guard tps.count >= 2 else { return }
        
        var i = 0
        while i < tps.count - 1 {
            let current = tps[i]
            let next = tps[i+1]
            
            let gap = next.startTime.timeIntervalSince(current.endTime)
            
            // --- 核心修复：要合并两段交通，必须确保中间没有足迹 ---
            // 注意：在 #Predicate 中不能直接访问 external object 的属性，需要先本地化变量
            let cEnd = current.endTime
            let nStart = next.startTime
            let fpDesc = FetchDescriptor<Footprint>(predicate: #Predicate {
                $0.startTime >= cEnd && $0.startTime < nStart && $0.statusValue != "ignored"
            })
            let hasFpBetween = ((try? context.fetch(fpDesc))?.count ?? 0) > 0
            
            // --- 核心修复：基于“分类兼容性”的智能合并 ---
            // 不再死板地要求 typeRaw 完全一致，而是看它们是否属于同一个大类
            func getCategory(_ type: TransportType) -> Int {
                switch type {
                case .slow, .running: return 1 // 步行/跑步类
                case .bicycle, .ebike: return 2 // 骑行类
                case .motorcycle, .bus, .car: return 3 // 车载类
                case .subway, .train, .airplane, .ship: return 4 // 长途/轨道类
                }
            }
            
            let currentType = TransportType(rawValue: current.typeRaw) ?? .slow
            let nextType = TransportType(rawValue: next.typeRaw) ?? .slow
            
            // --- 铁律保护：如果其中任一段是手动设置的，且两段类型不同，严禁自动合并 ---
            if (current.manualTypeRaw != nil || next.manualTypeRaw != nil) && current.typeRaw != next.typeRaw {
                i += 1
                continue
            }
            
            let isCompatible = getCategory(currentType) == getCategory(nextType)
            
            // If they are less than 15 minutes apart and no footprint in between, merge them!
            if gap >= -60 && gap <= 900 && !hasFpBetween && isCompatible {
                current.endTime = max(current.endTime, next.endTime)
                current.distance += next.distance
                let duration = current.endTime.timeIntervalSince(current.startTime)
                current.averageSpeed = duration > 0 ? current.distance / duration : 0
                // --- 异步获取合并段的健康和传感器数据 ---
                let mergedMetrics = await HealthManager.shared.fetchMetrics(from: current.startTime, to: current.endTime)
                let mergedMotionType = await HealthManager.shared.queryMostFrequentActivity(from: current.startTime, to: current.endTime)
                
                // 核心修复：如果其中一段有手动设置的类型，合并后优先继承手动类型，防止被自动识别覆盖
                if current.manualTypeRaw == nil && next.manualTypeRaw != nil {
                    current.manualTypeRaw = next.manualTypeRaw
                    current.typeRaw = next.typeRaw
                } else if current.manualTypeRaw == nil {
                    // 只有在两段都没有手动干预的情况下，才重新自动识别
                    current.typeRaw = TransportType.from(speed: current.averageSpeed, motionType: mergedMotionType, stepCount: mergedMetrics.steps, duration: current.endTime.timeIntervalSince(current.startTime), preferredAutomotive: preferredAuto, preferredCycling: preferredCycling).rawValue
                }
                
                if let decodedCurrent = try? JSONDecoder().decode([CodableCoordinate].self, from: current.pointsData),
                   let decodedNext = try? JSONDecoder().decode([CodableCoordinate].self, from: next.pointsData) {
                    let combined = decodedCurrent + decodedNext
                    if let newPtsData = try? JSONEncoder().encode(combined) {
                        current.pointsData = newPtsData
                    }
                }
                
                current.stepCount = (current.stepCount ?? 0) + (next.stepCount ?? 0)
                
                if next.endLocation != "终点" && next.endLocation != "正在获取位置..." && !next.endLocation.isEmpty {
                    current.endLocation = next.endLocation
                }
                
                next.statusRaw = "ignored"
                // 移除此处 save，统一在 syncDay 末尾 save，大幅减少 UI 抖动
                // try? context.save()
                
                // 递归调用时必须透传偏好参数，否则会使用默认值导致类型“乱掉”
                await mergeConsecutiveTransports(for: date, in: context, preferredAuto: preferredAuto, preferredCycling: preferredCycling)
                return
            }
            i += 1
        }
    }

    @MainActor
    private static func fillGapsBetweenItems(for date: Date, in context: ModelContext, allRawPoints: [CLLocation] = [], preferredAuto: TransportType = .car, preferredCycling: TransportType = .bicycle) async {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!
        
        let allPlaces = (try? context.fetch(FetchDescriptor<Place>())) ?? []
        
        let fpDesc = FetchDescriptor<Footprint>(predicate: #Predicate {
            $0.startTime >= startOfDay && $0.startTime < endOfDay && $0.statusValue != "ignored"
        }, sortBy: [SortDescriptor(\.startTime)])
        let fps = (try? context.fetch(fpDesc)) ?? []
        guard fps.count >= 2 else { return }
        
        let tpDesc = FetchDescriptor<TransportRecord>(predicate: #Predicate {
            $0.startTime >= startOfDay && $0.startTime < endOfDay && $0.statusRaw != "ignored"
        }, sortBy: [SortDescriptor(\.startTime)])
        let tps = (try? context.fetch(tpDesc)) ?? []
        
        for i in 0..<(fps.count - 1) {
            let currentFp = fps[i]
            let nextFp = fps[i+1]
            let gapStart = currentFp.endTime
            let gapEnd = nextFp.startTime
            let duration = gapEnd.timeIntervalSince(gapStart)
            
            if duration > 120 { // More than 2 minutes gap
                let hasTransport = tps.contains { t in
                    let intersectStart = max(gapStart, t.startTime)
                    let intersectEnd = min(gapEnd, t.endTime)
                    return intersectEnd.timeIntervalSince(intersectStart) > 60 
                }
                
                let loc1 = CLLocation(latitude: currentFp.latitude, longitude: currentFp.longitude)
                let loc2 = CLLocation(latitude: nextFp.latitude, longitude: nextFp.longitude)
                let straightDist = loc1.distance(from: loc2)
                
                // --- 核心修复：桥接缝隙时，优先查看该时段是否有原始轨迹点 ---
                let gapPoints = allRawPoints.filter { $0.timestamp >= gapStart && $0.timestamp <= gapEnd }
                let pathDist: Double
                let pts: [CodableCoordinate]
                
                if !gapPoints.isEmpty {
                    // Include the footprint centers in the path to ensure correct mileage
                    var combinedPoints = [CLLocation(latitude: currentFp.latitude, longitude: currentFp.longitude)]
                    combinedPoints.append(contentsOf: gapPoints)
                    combinedPoints.append(CLLocation(latitude: nextFp.latitude, longitude: nextFp.longitude))
                    pathDist = TimelineBuilder.calculateDistance(combinedPoints)
                    pts = combinedPoints.map { CodableCoordinate(lat: $0.coordinate.latitude, lon: $0.coordinate.longitude) }
                } else {
                    pathDist = straightDist
                    pts = [CodableCoordinate(lat: currentFp.latitude, lon: currentFp.longitude),
                           CodableCoordinate(lat: nextFp.latitude, lon: nextFp.longitude)]
                }


                // 使用配置中的阈值
                // 使用配置中的阈值。核心修复：桥接缝隙必须有原始轨迹点支撑，严禁在无点情况下凭空合成交通
                if !hasTransport && !gapPoints.isEmpty && pathDist > AppConfig.shared.transportMinDistanceThreshold {
                    let ptsData = (try? JSONEncoder().encode(pts)) ?? Data()
                    let speed = pathDist / duration
                    let currentLocName = getSimplifiedLocationName(for: currentFp, allPlaces: allPlaces)
                    let nextLocName = getSimplifiedLocationName(for: nextFp, allPlaces: allPlaces)
                    
                    // --- 异步获取健康和传感器数据 ---
                    let metrics = await HealthManager.shared.fetchMetrics(from: gapStart, to: gapEnd)
                    let motionType = await HealthManager.shared.queryMostFrequentActivity(from: gapStart, to: gapEnd)
                    let determinedType = TransportType.from(speed: speed, motionType: motionType, stepCount: metrics.steps, duration: duration, preferredAutomotive: preferredAuto, preferredCycling: preferredCycling)
                    
                    let tp = TransportRecord(
                        day: startOfDay,
                        startTime: gapStart,
                        endTime: gapEnd,
                        startLocation: currentLocName,
                        endLocation: nextLocName,
                        typeRaw: determinedType.rawValue,
                        distance: pathDist,
                        averageSpeed: speed,
                        pointsData: ptsData,
                        stepCount: metrics.steps
                    )
                    context.insert(tp)
                }
            }
        }
        try? context.save()
    }
    
    @MainActor
    private static func snapTransportsToFootprints(for date: Date, in context: ModelContext) async {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!
        
        let allPlaces = (try? context.fetch(FetchDescriptor<Place>())) ?? []
        
        let fpDesc = FetchDescriptor<Footprint>(predicate: #Predicate {
            $0.startTime >= startOfDay && $0.startTime < endOfDay && $0.statusValue != "ignored"
        }, sortBy: [SortDescriptor(\.startTime)])
        let fps = (try? context.fetch(fpDesc)) ?? []
        
        let tpDesc = FetchDescriptor<TransportRecord>(predicate: #Predicate {
            $0.startTime >= startOfDay && $0.startTime < endOfDay && $0.statusRaw != "ignored"
        }, sortBy: [SortDescriptor(\.startTime)])
        let tps = (try? context.fetch(tpDesc)) ?? []
        
        for tp in tps {
            var changed = false
            var decodedPoints: [CodableCoordinate] = []
            if let decoded = try? JSONDecoder().decode([CodableCoordinate].self, from: tp.pointsData) {
                decodedPoints = decoded
            }
            
            if let prevFp = fps.last(where: { $0.endTime <= tp.startTime + AppConfig.shared.snapTimeBuffer }) {
                let gap = tp.startTime.timeIntervalSince(prevFp.endTime)
                if gap >= 0 && gap < AppConfig.shared.transportAlignmentThreshold { 
                    tp.startTime = prevFp.endTime
                    let locName = getSimplifiedLocationName(for: prevFp, allPlaces: allPlaces)
                    if !locName.isEmpty && locName != "某地" {
                        tp.startLocation = locName
                    }
                    let fpCoord = CodableCoordinate(lat: prevFp.latitude, lon: prevFp.longitude)
                    if decodedPoints.first?.lat != fpCoord.lat || decodedPoints.first?.lon != fpCoord.lon {
                        decodedPoints.insert(fpCoord, at: 0)
                    }
                    changed = true
                }
            }
            
            if let nextFp = fps.first(where: { $0.startTime >= tp.endTime - AppConfig.shared.snapTimeBuffer }) {
                let gap = nextFp.startTime.timeIntervalSince(tp.endTime)
                if gap >= 0 && gap < AppConfig.shared.transportAlignmentThreshold {
                    tp.endTime = nextFp.startTime
                    let locName = getSimplifiedLocationName(for: nextFp, allPlaces: allPlaces)
                    if !locName.isEmpty && locName != "某地" {
                        tp.endLocation = locName
                    }
                    let fpCoord = CodableCoordinate(lat: nextFp.latitude, lon: nextFp.longitude)
                    if decodedPoints.last?.lat != fpCoord.lat || decodedPoints.last?.lon != fpCoord.lon {
                        decodedPoints.append(fpCoord)
                    }
                    changed = true
                }
            }
            
            if changed {
                if let newPtsData = try? JSONEncoder().encode(decodedPoints) {
                    tp.pointsData = newPtsData
                }
                tp.distance = TimelineBuilder.calculatePathDistance(decodedPoints)
                let duration = tp.endTime.timeIntervalSince(tp.startTime)
                if duration > 0 {
                    tp.averageSpeed = tp.distance / duration
                }
            }
        }
        try? context.save()
    }

    private static func getSimplifiedLocationName(for footprint: Footprint, allPlaces: [Place]) -> String {
        // 1. 优先使用已绑定的 PlaceID
        if let placeID = footprint.placeID, let place = allPlaces.first(where: { $0.placeID == placeID }) {
            return place.name
        }
        
        // 2. 如果没绑定 ID，但在重要地点范围内，也要优先使用地点名
        let coord = CLLocationCoordinate2D(latitude: footprint.latitude, longitude: footprint.longitude)
        let litePlaces = allPlaces.map { TimelineBuilder.convertToPlaceLite($0) }
        if let matched = TimelineBuilder.getPlaceForCoordinate(coord, allPlaces: litePlaces) {
            return matched.name
        }
        
        if let addr = footprint.address, !addr.isEmpty { return addr }
        return "未知位置"
    }



    
    @MainActor
    private static func mergeConsecutiveFootprints(for date: Date, in context: ModelContext, allRawPoints: [CLLocation], threshold: Double = 200) async {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!
        
        let descriptor = FetchDescriptor<Footprint>(predicate: #Predicate {
            $0.startTime >= startOfDay && $0.startTime < endOfDay && $0.statusValue != "ignored"
        }, sortBy: [SortDescriptor(\.startTime)])
        
        let fps = (try? context.fetch(descriptor)) ?? []
        let allPlaces = (try? context.fetch(FetchDescriptor<Place>())) ?? []
        guard fps.count >= 2 else { return }
        
        var i = 0
        while i < fps.count - 1 {
            let current = fps[i]
            let next = fps[i+1]
            
            let currentLoc = CLLocation(latitude: current.latitude, longitude: current.longitude)
            let nextLoc = CLLocation(latitude: next.latitude, longitude: next.longitude)
            let dist = currentLoc.distance(from: nextLoc)
            let gap = next.startTime.timeIntervalSince(current.endTime)
            
            // 确定是否为同一逻辑地点
            let isSameLogicalPlace = (current.placeID != nil && current.placeID == next.placeID)
            // 如果两个足迹距离小于阈值，且间隔小于配置的合并时长，则视作同一地点
            let mergeThreshold = isSameLogicalPlace ? max(threshold, AppConfig.shared.samePlaceMergeBonusThreshold) : threshold
            let mergeGapLimit = isSameLogicalPlace ? 3600.0 : AppConfig.shared.stayMergeGapThreshold

            if dist < mergeThreshold && gap < mergeGapLimit {
                // 核心修复：使用传入的原始点位检查是否有交通位移 (使用 Lite 转换进行更精细判定)
                let gapPoints = TimelineBuilder.extractPoints(from: allRawPoints, start: current.endTime, end: next.startTime)
                let currentLite = TimelineBuilder.convertToFootprintLite(current)
                let nextLite = TimelineBuilder.convertToFootprintLite(next)
                
                if !gapPoints.isEmpty && TimelineBuilder.hasSignificantMovement(between: currentLite, and: nextLite, points: gapPoints) {
                    i += 1
                    continue
                }
                
                // 如果两个都有照片且地点稍有不同，建议保留独立性，除非距离极近
                let bothHavePhotos = !current.photoAssetIDs.isEmpty && !next.photoAssetIDs.isEmpty
                if bothHavePhotos && dist > AppConfig.shared.stayDistanceThreshold {
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

                // 继承/合并地点信息
                if current.placeID == nil && next.placeID != nil {
                    current.placeID = next.placeID
                    current.address = next.address
                } else if current.placeID != nil && next.placeID == nil {
                    // Keep current
                }

                // 如果当前名称不包含地点名，但已知地点，同步名称
                if let pid = current.placeID, let matched = allPlaces.first(where: { $0.placeID == pid }) {
                    current.address = matched.name
                }

                // --- 核心修复：既然合并了，中间夹杂的任何微小交通（通常是漂移产生的）都应被清理 ---
                let midStart = current.endTime.addingTimeInterval(-AppConfig.shared.midPointSamplingOffset)
                let midEnd = next.startTime.addingTimeInterval(AppConfig.shared.midPointSamplingOffset)
                let tDesc = FetchDescriptor<TransportRecord>(predicate: #Predicate {
                    $0.startTime >= midStart && $0.endTime <= midEnd
                })
                if let overlappingTransports = try? context.fetch(tDesc) {
                    for t in overlappingTransports {
                        t.statusRaw = "ignored"
                    }
                }

                // 标记下一个为忽略 (逻辑上合并了)
                next.statusValue = "ignored"
                
                try? context.save()
                // 递归处理，直到没有可合并的
                await mergeConsecutiveFootprints(for: date, in: context, allRawPoints: allRawPoints, threshold: threshold)
                return
            }
            i += 1
        }
    }
    
    @MainActor
    private static func processPoints(points: [CLLocation], date: Date, context: ModelContext, preferredAuto: TransportType = .car, preferredCycling: TransportType = .bicycle) async {
        guard points.count >= 2 else { return }
        
        let startOfDay = Calendar.current.startOfDay(for: date)
        let allPlaces = (try? context.fetch(FetchDescriptor<Place>())) ?? []
        
        var lastFp: Footprint? = nil
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
                    // --- 核心修复：GPS 跳点容错 ---
                    // 如果这只是一个瞬时的跳点（例如 1秒内跳出 100米又立刻跳回来），不应打断当前的停留簇
                    var isSpike = false
                    if j + 1 < points.count {
                        let nextDist = points[j+1].distance(from: points[i])
                        if nextDist < AppConfig.shared.stayDistanceThreshold {
                            isSpike = true
                        }
                    }
                    
                    if isSpike {
                        j += 1 // 视为异常跳点，跳过它继续维持当前簇
                        continue
                    }
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
                
                // --- 异步获取健康数据 ---
                let metrics = await HealthManager.shared.fetchMetrics(from: fp.startTime, to: fp.endTime)
                fp.stepCount = metrics.steps
                fp.walkingDistance = metrics.distance
                fp.floorsAscended = metrics.floors
                
                let loc = clusterPoints.first!
                let litePlaces = allPlaces.map { TimelineBuilder.convertToPlaceLite($0) }
                if let matched = TimelineBuilder.getPlaceForCoordinate(loc.coordinate, allPlaces: litePlaces) {
                    fp.placeID = matched.placeID
                    fp.address = matched.name
                }
                context.insert(fp)
                lastFp = fp
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
                    let diameter = TimelineBuilder.calculateMaxDiameter(coords)
                    
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
                    
                    let litePlaces = allPlaces.map { TimelineBuilder.convertToPlaceLite($0) }
                    if let sMatch = TimelineBuilder.getPlaceForCoordinate(sLoc.coordinate, allPlaces: litePlaces) {
                        startName = sMatch.name
                    }
                    if let eMatch = TimelineBuilder.getPlaceForCoordinate(eLoc.coordinate, allPlaces: litePlaces) {
                        endName = eMatch.name
                    }

                    // Calculate distance including footprint connections if available
                    var augmentedPoints = transportPoints
                    if let last = lastFp {
                        augmentedPoints.insert(CLLocation(latitude: last.latitude, longitude: last.longitude), at: 0)
                        if startName == "起点" {
                            startName = last.address ?? "起点"
                        }
                    }
                    if k < points.count {
                        // Include the first point of the next cluster to complete the path
                        augmentedPoints.append(points[k])
                    }

                    let pathDist = TimelineBuilder.calculateDistance(augmentedPoints)
                    let avgSpeed = tEnd.timeIntervalSince(tStart) > 0 ? pathDist / tEnd.timeIntervalSince(tStart) : 0
                    
                    let augmentedPtsData = (try? JSONEncoder().encode(augmentedPoints.map { CodableCoordinate(lat: $0.coordinate.latitude, lon: $0.coordinate.longitude) })) ?? ptsData

                    // --- 异步获取健康和传感器数据 ---
                    let metrics = await HealthManager.shared.fetchMetrics(from: tStart, to: tEnd)
                    let motionType = await HealthManager.shared.queryMostFrequentActivity(from: tStart, to: tEnd)
                    let determinedType = TransportType.from(speed: avgSpeed, motionType: motionType, stepCount: metrics.steps, duration: tEnd.timeIntervalSince(tStart), preferredAutomotive: preferredAuto, preferredCycling: preferredCycling)
                    
                    let tp = TransportRecord(
                        day: startOfDay,
                        startTime: tStart,
                        endTime: tEnd,
                        startLocation: startName,
                        endLocation: endName,
                        typeRaw: determinedType.rawValue,
                        distance: pathDist,
                        averageSpeed: avgSpeed,
                        pointsData: augmentedPtsData,
                        stepCount: metrics.steps
                    )
                    
                    context.insert(tp)
                }
                i = k // 移动到下一个可能的停留点或末尾
            }
        }
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
            let lookback = Double(AppConfig.shared.habitAnalysisLookbackDays)
            let sevenDaysAgo = Date().addingTimeInterval(-lookback * 24 * 3600)
            
            // 1. 获取最近一周的所有足迹，然后在内存中精细化过滤，避开复杂的 #Predicate 宏
            let fpDesc = FetchDescriptor<Footprint>(predicate: #Predicate {
                $0.startTime > sevenDaysAgo
            })
            let recentFps = (try? context.fetch(fpDesc)) ?? []
            let pendingFps = recentFps.filter { 
                $0.address == nil || $0.address == ""
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
            a.startTime < b.startTime
        }
        
        let allPlaces = (try? context.fetch(FetchDescriptor<Place>())) ?? []
        let litePlaces = allPlaces.map { TimelineBuilder.convertToPlaceLite($0) }
        
        let alignedItems = TimelineBuilder.alignTransportLocations(items, allPlaces: litePlaces)
        
        return alignedItems.sorted { $0.startTime > $1.startTime }
    }
}
