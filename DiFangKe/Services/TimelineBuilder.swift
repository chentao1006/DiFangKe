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
        case .transport(let t): return t.startTime
        }
    }
}

class TimelineBuilder {
    static func buildTimeline(for date: Date, footprints: [Footprint], allRawPoints: [CLLocation], allPlaces: [Place] = [], overrides: [TransportManualSelection] = []) -> [TimelineItem] {
        var items: [TimelineItem] = []
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!
        let now = Date()
        let dayLimit = min(endOfDay, now)
        
        let sortedFootprints = footprints
            .filter { $0.status != .ignored }
            .sorted { $0.startTime < $1.startTime }
        
        var currentTime = startOfDay
        
        // --- Process Footprints and Gaps ---
        for (index, fp) in sortedFootprints.enumerated() {
            // Gap before current footprint
            if fp.startTime > currentTime {
                fillGap(from: currentTime, to: fp.startTime, items: &items, allRawPoints: allRawPoints, sortedFootprints: sortedFootprints, currentIndex: index, allPlaces: allPlaces, overrides: overrides)
            }
            
            // Add Footprint
            items.append(.footprint(fp))
            currentTime = max(currentTime, fp.endTime)
        }
        
        // Final gap until now/end of day
        if dayLimit > currentTime {
            fillGap(from: currentTime, to: dayLimit, items: &items, allRawPoints: allRawPoints, sortedFootprints: sortedFootprints, currentIndex: sortedFootprints.count, allPlaces: allPlaces, overrides: overrides)
        }
        
        return items.reversed()
    }
    
    private static func fillGap(from start: Date, to end: Date, items: inout [TimelineItem], allRawPoints: [CLLocation], sortedFootprints: [Footprint], currentIndex: Int, allPlaces: [Place], overrides: [TransportManualSelection]) {
        let duration = end.timeIntervalSince(start)
        guard duration > 60 else { return } // Ignore gaps < 1 min
        
        let gapPoints = allRawPoints.filter { $0.timestamp >= start && $0.timestamp < end }
        
        if !gapPoints.isEmpty {
            var transports = extractTransports(gapPoints)
            
            // If movement was detected, add it
            if !transports.isEmpty {
                // Process all segments in the journey
                for i in 0..<transports.count {
                    let startCoord = transports[i].points.first
                    let endCoord = transports[i].points.last
                    
                    // 1. Resolve Start Location
                    if i == 0 && currentIndex > 0 {
                        // First segment: check previous footprint
                        let fp = sortedFootprints[currentIndex-1]
                        let fpLoc = CLLocation(latitude: fp.latitude, longitude: fp.longitude)
                        // Use a tighter 150m threshold for "strictly" matching POI
                        if let startCoord = startCoord, CLLocation(latitude: startCoord.latitude, longitude: startCoord.longitude).distance(from: fpLoc) < 150 {
                            transports[i] = transports[i].updatingStart(getLocationName(for: fp, allPlaces: allPlaces))
                        }
                    } 
                    
                    // If still generic, try Places
                    if transports[i].startLocation == "出发点", let startCoord = startCoord {
                        if let name = getNameForCoordinate(startCoord, allPlaces: allPlaces) {
                            transports[i] = transports[i].updatingStart(name)
                        } else if i > 0 {
                            // Inherit from previous end point
                            transports[i] = transports[i].updatingStart(transports[i-1].endLocation)
                        }
                    }
                    
                    // 2. Resolve End Location
                    if i == transports.count - 1 && currentIndex < sortedFootprints.count {
                        // Last segment: check next footprint
                        let fp = sortedFootprints[currentIndex]
                        let fpLoc = CLLocation(latitude: fp.latitude, longitude: fp.longitude)
                        if let endCoord = endCoord, CLLocation(latitude: endCoord.latitude, longitude: endCoord.longitude).distance(from: fpLoc) < 150 {
                            transports[i] = transports[i].updatingEnd(getLocationName(for: fp, allPlaces: allPlaces))
                        }
                    }
                    
                    // If still generic, try Places
                    if transports[i].endLocation == "目的地", let endCoord = endCoord {
                        if let name = getNameForCoordinate(endCoord, allPlaces: allPlaces) {
                            transports[i] = transports[i].updatingEnd(name)
                        } else if i < transports.count - 1 {
                             transports[i] = transports[i].updatingEnd("移动中")
                        }
                    }
                }
                
                // Final cleanup for any remaining placeholders
                for i in 0..<transports.count {
                    if transports[i].startLocation == "出发点" { transports[i] = transports[i].updatingStart("正在获取位置...") }
                    if transports[i].endLocation == "目的地" { transports[i] = transports[i].updatingEnd("正在获取位置...") }
                }
                
                // Apply manual overrides (Type changes or Deletion or Location Override)
                var activeTransports: [Transport] = []
                for transport in transports {
                    let midTime = transport.startTime.addingTimeInterval(transport.duration / 2)
                    if let override = overrides.first(where: { midTime >= $0.startTime && midTime <= $0.endTime }) {
                        if override.isDeleted {
                            // Don't add to active list
                            continue
                        }
                        
                        var updated = transport
                        if let type = TransportType(rawValue: override.vehicleType) {
                            updated.manualType = type
                        }
                        
                        // Apply location overrides
                        if let startOverride = override.startLocationOverride {
                            updated = updated.updatingStart(startOverride)
                        }
                        if let endOverride = override.endLocationOverride {
                            updated = updated.updatingEnd(endOverride)
                        }
                        
                        activeTransports.append(updated)
                    } else {
                        activeTransports.append(transport)
                    }
                }
                transports = activeTransports
                
                items.append(contentsOf: transports.map { .transport($0) })
            }
        }
    }
    
    private static func getStraightPath(currentIndex: Int, sortedFootprints: [Footprint]) -> [CLLocationCoordinate2D] {
        if currentIndex > 0 && currentIndex < sortedFootprints.count {
            return [
                CLLocationCoordinate2D(latitude: sortedFootprints[currentIndex-1].latitude, longitude: sortedFootprints[currentIndex-1].longitude),
                CLLocationCoordinate2D(latitude: sortedFootprints[currentIndex].latitude, longitude: sortedFootprints[currentIndex].longitude)
            ]
        }
        return []
    }
    
    private static func getLocationName(for footprint: Footprint, allPlaces: [Place]) -> String {
        // 1. If it's a known place linked by placeID, use its name
        if let placeID = footprint.placeID, 
           let place = allPlaces.first(where: { $0.placeID == placeID }) {
            return place.name
        }
        
        // 2. If the user edited the title, keep it
        if footprint.isTitleEditedByHand {
            return footprint.title
        }
        
        // 3. Search by coordinates in allPlaces anyway (robust check)
        if let nearbyPlaceName = getNameForCoordinate(CLLocationCoordinate2D(latitude: footprint.latitude, longitude: footprint.longitude), allPlaces: allPlaces) {
            return nearbyPlaceName
        }
        
        // 4. Prefer existing title if it's not a generic placeholder
        if !footprint.title.isEmpty && footprint.title != "地点记录" && footprint.title != "正在获取位置..." {
            return footprint.title
        }
        
        // 5. Fallback to address
        if let addr = footprint.address, !addr.isEmpty {
            return addr
        }
        
        return "未知位置"
    }
    
    private static func getNameForCoordinate(_ coordinate: CLLocationCoordinate2D, allPlaces: [Place], radius: Double = 150) -> String? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        
        let nearest = allPlaces
            .map { (place: $0, distance: location.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude))) }
            .filter { $0.distance < Double($0.place.radius) || $0.distance < 80 } // Use place radius or a small 80m buffer
            .sorted { $0.distance < $1.distance }
            .first
        
        return nearest?.place.name
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
            
            // 1. Split if time gap > 10 mins (Suggests a missing stay or signal loss)
            if timeGap > 10 * 60 {
                if let transport = finalizeTransport(currentPoints) {
                    transports.append(transport)
                }
                currentPoints = [p]
                currentSegmentType = nil
                continue
            }
            
            // 2. Intelligent segment splitting based on speed change
            // Window-based detection to avoid noise
            if currentPoints.count >= 5 {
                if currentSegmentType == nil {
                    let d = calculateDistance(currentPoints)
                    let t = currentPoints.last!.timestamp.timeIntervalSince(currentPoints.first!.timestamp)
                    currentSegmentType = TransportType.from(speed: t > 0 ? d / t : 0)
                }
                
                // Detection window: last 5-10 points to ensure stability
                let window = Array(points[max(0, i-6)...i])
                if window.count >= 4 {
                    let wd = calculateDistance(window)
                    let wt = window.last!.timestamp.timeIntervalSince(window.first!.timestamp)
                    let windowSpeed = wt > 0 ? wd / wt : 0
                    let windowType = TransportType.from(speed: windowSpeed)
                    
                    if let segType = currentSegmentType, isSignificantTypeChange(from: segType, to: windowType) {
                        // Only split if we have at least 1 minute of consistent speed change
                        // This allows separating car trips from subsequent walks.
                        let threshold: TimeInterval = 60 
                        
                        if wt > threshold {
                            if let transport = finalizeTransport(currentPoints) {
                                transports.append(transport)
                            }
                            currentPoints = [p]
                            currentSegmentType = nil
                            continue
                        }
                    }
                }
            }
            
            currentPoints.append(p)
        }
        
        if let transport = finalizeTransport(currentPoints) {
            transports.append(transport)
        }
        
        return mergeTransports(transports)
    }
    
    private static func isSignificantTypeChange(from t1: TransportType, to t2: TransportType) -> Bool {
        if t1 == t2 { return false }
        
        func category(of type: TransportType) -> Int {
            switch type {
            case .slow: return 1
            case .bicycle: return 2
            case .motorcycle, .car, .bus: return 3
            default: return 4 // train, airplane
            }
        }
        
        return category(of: t1) != category(of: t2)
    }
    
    private static func isSimilarType(_ t1: TransportType, _ t2: TransportType) -> Bool {
        func category(of type: TransportType) -> Int {
            switch type {
            case .slow: return 1
            case .bicycle: return 2
            case .motorcycle, .car, .bus: return 3
            default: return 4
            }
        }
        return category(of: t1) == category(of: t2)
    }
    
    private static func finalizeTransport(_ points: [CLLocation]) -> Transport? {
        guard points.count >= 3 else { return nil }
        
        let start = points.first!.timestamp
        let end = points.last! .timestamp
        let duration = end.timeIntervalSince(start)
        let distance = calculateDistance(points)
        let averageSpeed = duration > 0 ? distance / duration : 0
        let kmh = averageSpeed * 3.6
        
        // --- PROPOSED DRIFT FILTERS ---
        // 0. Hard distance floor: Any transport less than 100m is discarded
        if distance < 100 {
            return nil
        }
        
        // 1. Duration filter: Movements should generally last at least 5 minutes
        // Exception: If it's a fast motorized movement (e.g. 2 minutes at 60km/h), keep it.
        if duration < 5 * 60 && kmh < 15 {
            return nil
        }
        
        // 2. Max diameter filter: Most distant two points must be at least 100m apart
        // For short segments, this filters out drift.
        // For long segments (> 30 mins), we keep them even if the diameter is small
        // to avoid "disappearing" data when a stay was missed by the processor.
        let maxDiameter = calculateMaxDiameter(points)
        if maxDiameter < 100 && duration < 30 * 60 {
            return nil
        }
        
        // 3. Path distance filter: Total traveled path must be > 200m
        if distance < 200 && duration < 30 * 60 {
            return nil
        }
        
        // --- GENERAL ACCURACY FILTERS ---
        // Filter out very slow jitters that might pass diameter check over a long time
        // Only do this for shorter segments (< 30 min) to avoid losing long stays
        // 忽略极慢的“漂移型”交通（如在家走动或信号跳变）
        // 规则：如果平均时速低于 0.6km/h 且总距离较短，或者时速低于 0.5km/h 且时长较长
        if kmh < 0.6 || (kmh < 0.8 && distance < 2000) {
            return nil
        }
        
        let type = TransportType.from(speed: averageSpeed)
        
        return Transport(
            startTime: start,
            endTime: end,
            startLocation: "出发点", 
            endLocation: "目的地",
            type: type,
            distance: distance,
            averageSpeed: averageSpeed,
            points: points.map { $0.coordinate }
        )
    }
    
    private static func calculateMaxDiameter(_ points: [CLLocation]) -> Double {
        var maxD: Double = 0
        // Use a subset if point count is large for performance
        let step = max(1, points.count / 30)
        let sampled = points.enumerated().filter { $0.offset % step == 0 }.map { $0.element }
        
        for i in 0..<sampled.count {
            for j in i+1..<sampled.count {
                let d = sampled[i].distance(from: sampled[j])
                if d > maxD { maxD = d }
            }
        }
        return maxD
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
        
        var list = transports
        var changed = true
        var passCount = 0
        
        // Multi-pass merging to handle nested small segments
        while changed && passCount < 3 {
            changed = false
            var merged: [Transport] = []
            var i = 0
            while i < list.count {
                let curr = list[i]
                
                if i + 1 < list.count {
                    let next = list[i+1]
                    let d1 = curr.endTime.timeIntervalSince(curr.startTime)
                    let d2 = next.endTime.timeIntervalSince(next.startTime)
                    
                    // 1. Same Type OR Similar Category + Short -> Merge
                    // BUT: Only merge if the combined duration is reasonable or type is identical.
                    if curr.type == next.type || (isSimilarType(curr.type, next.type) && (d1 < 180 || d2 < 180)) {
                        list[i+1] = merge(curr, next)
                        i += 1
                        changed = true
                        continue
                    }
                    
                    // 2. Sandwich Merge: T1 and T3 are similar, T2 is a short "interruption" (like a red light)
                    if i + 2 < list.count {
                        let third = list[i+2]
                        if isSimilarType(curr.type, third.type) && d2 < 600 {
                            let combined = merge(merge(curr, next), third)
                            list[i+2] = combined
                            i += 2
                            changed = true
                            continue
                        }
                    }
                    
                    // 3. Extremely short segment (< 2 min) -> Always merge with the more likely neighbor
                    if d1 < 120 {
                        list[i+1] = merge(curr, next)
                        i += 1
                        changed = true
                        continue
                    }
                }
                
                merged.append(curr)
                i += 1
            }
            list = merged
            passCount += 1
        }
        
        return list
    }
    
    private static func merge(_ t1: Transport, _ t2: Transport) -> Transport {
        let d1 = t1.endTime.timeIntervalSince(t1.startTime)
        let d2 = t2.endTime.timeIntervalSince(t2.startTime)
        let totalTime = d1 + d2
        let totalDistance = t1.distance + t2.distance
        
        // Prefer the type of the longer, more definitive segment
        let type = d1 >= d2 ? t1.type : t2.type 
        
        let combinedPoints = t1.points + t2.points
        return Transport(
            startTime: t1.startTime,
            endTime: t2.endTime,
            startLocation: t1.startLocation,
            endLocation: t2.endLocation,
            type: type,
            distance: totalDistance,
            averageSpeed: totalTime > 0 ? totalDistance / totalTime : 0,
            points: combinedPoints
        )
    }
    
    // MARK: - Address Resolution
    static func resolveAddress(coordinate: CLLocationCoordinate2D, completion: @escaping (String) -> Void) {
        let geocoder = CLGeocoder()
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        
        // Add specific locale if needed
        geocoder.reverseGeocodeLocation(location) { placemarks, error in
            if let placemark = placemarks?.first {
                let name = placemark.name ?? placemark.thoroughfare ?? placemark.subLocality ?? placemark.locality ?? "位置"
                completion(name)
            } else {
                completion("未知位置")
            }
        }
    }
}
