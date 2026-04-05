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
    static func buildTimeline(for date: Date, footprints: [Footprint], allRawPoints: [CLLocation], overrides: [TransportManualSelection] = []) -> [TimelineItem] {
        var items: [TimelineItem] = []
        
        let sortedFootprints = footprints.sorted { $0.startTime < $1.startTime }
        var lastTime = Calendar.current.startOfDay(for: date)
        
        // Use footprints as location sources
        for (index, fp) in sortedFootprints.enumerated() {
            let gapStart = lastTime
            let gapEnd = fp.startTime
            
            if gapEnd.timeIntervalSince(gapStart) > 5 * 60 {
                let gapPoints = allRawPoints.filter { $0.timestamp >= gapStart && $0.timestamp < gapEnd }
                if !gapPoints.isEmpty {
                    var transports = extractTransports(gapPoints)
                    
                    // Assign start/end locations if adjacent to footprints
                    if !transports.isEmpty {
                        // First transport in this gap starts from previous location or start of day
                        if index > 0 {
                            transports[0] = transports[0].updatingStart(sortedFootprints[index-1].title)
                        }
                        // Last transport in this gap ends at current footprint
                        let lastIdx = transports.count - 1
                        transports[lastIdx] = transports[lastIdx].updatingEnd(fp.title)
                    }
                    
                    // Apply manual overrides
                    for i in 0..<transports.count {
                        if let override = overrides.first(where: { 
                            let mid = transports[i].startTime.addingTimeInterval(transports[i].endTime.timeIntervalSince(transports[i].startTime) / 2)
                            return mid >= $0.startTime && mid <= $0.endTime
                        }) {
                            if let type = TransportType(rawValue: override.vehicleType) {
                                transports[i].manualType = type
                            }
                        }
                    }
                    
                    items.append(contentsOf: transports.map { .transport($0) })
                }
            }
            
            items.append(.footprint(fp))
            lastTime = fp.endTime
        }
        
        // Gap after the last footprint
        let endOfDay = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: date))!
        let now = Date()
        let finalTime = min(endOfDay, now)
        
        if finalTime.timeIntervalSince(lastTime) > 5 * 60 {
            let gapPoints = allRawPoints.filter { $0.timestamp >= lastTime && $0.timestamp < finalTime }
            if !gapPoints.isEmpty {
                var transports = extractTransports(gapPoints)
                if !transports.isEmpty {
                    if let lastFP = sortedFootprints.last {
                        transports[0] = transports[0].updatingStart(lastFP.title)
                    }
                    
                    // Apply manual overrides
                    for i in 0..<transports.count {
                        if let override = overrides.first(where: { 
                            let mid = transports[i].startTime.addingTimeInterval(transports[i].endTime.timeIntervalSince(transports[i].startTime) / 2)
                            return mid >= $0.startTime && mid <= $0.endTime
                        }) {
                            if let type = TransportType(rawValue: override.vehicleType) {
                                transports[i].manualType = type
                            }
                        }
                    }
                    
                    items.append(contentsOf: transports.map { .transport($0) })
                }
            }
        }
        
        return items.reversed()
    }
    
    private static func extractTransports(_ points: [CLLocation]) -> [Transport] {
        guard points.count >= 2 else { return [] }
        
        var transports: [Transport] = []
        var currentPoints: [CLLocation] = [points[0]]
        
        for i in 1..<points.count {
            let p = points[i]
            let prevP = points[i-1]
            
            let timeGap = p.timestamp.timeIntervalSince(prevP.timestamp)
            
            // Split if time gap > 10 mins (suggests a missing stay or signal loss)
            if timeGap > 10 * 60 {
                if let transport = finalizeTransport(currentPoints) {
                    transports.append(transport)
                }
                currentPoints = [p]
            } else {
                currentPoints.append(p)
            }
        }
        
        if let transport = finalizeTransport(currentPoints) {
            transports.append(transport)
        }
        
        return mergeTransports(transports)
    }
    
    private static func finalizeTransport(_ points: [CLLocation]) -> Transport? {
        // Must have at least 10 points or a certain duration to be a reliable movement
        guard points.count >= 3 else { return nil }
        
        let start = points.first!.timestamp
        let end = points.last!.timestamp
        let duration = end.timeIntervalSince(start)
        let distance = calculateDistance(points)
        
        // --- 1. Aggressive Stationary/Drift Filter --- 
        // 1. Any movement less than 300 meters is ignored to avoid clutter and noise.
        // 2. If it's extremely slow (avg < 1km/h), it's definitely GPS noise while staying.
        let averageSpeed = duration > 0 ? distance / duration : 0
        
        if distance < 300 { 
            return nil 
        }
        
        if (averageSpeed * 3.6) < 1.0 && distance < 1000 {
            return nil // Staying still with a lot of GPS jitter over long time
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
    
    private static func calculateDistance(_ points: [CLLocation]) -> Double {
        var distance: Double = 0
        for i in 0..<points.count - 1 {
            distance += points[i].distance(from: points[i+1])
        }
        return distance
    }
    
    private static func mergeTransports(_ transports: [Transport]) -> [Transport] {
        guard transports.count > 1 else { return transports }
        
        var merged: [Transport] = []
        var i = 0
        while i < transports.count {
            var curr = transports[i]
            
            if (curr.endTime.timeIntervalSince(curr.startTime) < 2 * 60) && (i + 1 < transports.count) {
                let next = transports[i+1]
                curr = merge(curr, next)
                i += 2
                merged.append(curr)
            } else {
                merged.append(curr)
                i += 1
            }
        }
        return merged
    }
    
    private static func merge(_ t1: Transport, _ t2: Transport) -> Transport {
        let type = t2.type 
        let combinedPoints = t1.points + t2.points
        return Transport(
            startTime: t1.startTime,
            endTime: t2.endTime,
            startLocation: t1.startLocation,
            endLocation: t2.endLocation,
            type: type,
            distance: t1.distance + t2.distance,
            averageSpeed: (t1.averageSpeed + t2.averageSpeed) / 2,
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
