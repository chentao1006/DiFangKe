import Foundation
import CoreLocation

let csvPath = "/Users/chentao/Projects/chentao1006/difangke/DiFangKe_RawPoints_2026-05-29.csv"
guard let content = try? String(contentsOfFile: csvPath, encoding: .utf8) else {
    print("Cannot read CSV")
    exit(1)
}

let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
let header = lines[0].components(separatedBy: ",")
let timeIdx = header.firstIndex(of: "timestamp_iso")!
let latIdx = header.firstIndex(of: "latitude")!
let lonIdx = header.firstIndex(of: "longitude")!
let accIdx = header.firstIndex(of: "horizontalAccuracy")!

let formatter = ISO8601DateFormatter()
formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

var points: [CLLocation] = []
for line in lines.dropFirst() {
    let cols = line.components(separatedBy: ",")
    if cols.count <= max(timeIdx, latIdx, lonIdx, accIdx) { continue }
    let date = formatter.date(from: cols[timeIdx]) ?? Date()
    let lat = Double(cols[latIdx]) ?? 0
    let lon = Double(cols[lonIdx]) ?? 0
    let acc = Double(cols[accIdx]) ?? 0
    let loc = CLLocation(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon), altitude: 0, horizontalAccuracy: acc, verticalAccuracy: 0, timestamp: date)
    points.append(loc)
}

print("Loaded \(points.count) points")

// simulate FootprintProcessor
let stayRadiusThreshold: Double = 100.0
let stayDurationThreshold: TimeInterval = 360.0

func calculateCenter(_ locations: [CLLocation]) -> CLLocationCoordinate2D {
    let avgLat = locations.map { $0.coordinate.latitude }.reduce(0, +) / Double(locations.count)
    let avgLon = locations.map { $0.coordinate.longitude }.reduce(0, +) / Double(locations.count)
    return CLLocationCoordinate2D(latitude: avgLat, longitude: avgLon)
}

func detectStayPoint(in locations: [CLLocation]) -> (Date, Date, Double)? {
    guard locations.count >= 2 else { return nil }
    let startTime = locations.first!.timestamp
    let endTime = locations.last!.timestamp
    let duration = endTime.timeIntervalSince(startTime)
    guard duration >= stayDurationThreshold else { return nil }
    
    let center = calculateCenter(locations)
    let centerLoc = CLLocation(latitude: center.latitude, longitude: center.longitude)
    let distances = locations.map { $0.distance(from: centerLoc) }.sorted()
    let percentileindex = Int(Double(distances.count) * 0.85)
    if distances[percentileindex] > stayRadiusThreshold { return nil }
    
    return (startTime, endTime, duration)
}

var queue: [CLLocation] = []
var results: [(Date, Date, Double)] = []

for location in points {
    queue.append(location)
    let analysisQueue = Array(queue)
    if analysisQueue.count > 1 {
        let center = calculateCenter(Array(analysisQueue.dropLast()))
        let centerLoc = CLLocation(latitude: center.latitude, longitude: center.longitude)
        let distToCenter = location.distance(from: centerLoc)
        
        if distToCenter > stayRadiusThreshold {
            if let candidate = detectStayPoint(in: Array(analysisQueue.dropLast())) {
                results.append(candidate)
                queue.removeAll { $0.timestamp <= candidate.1 }
            }
        }
    }
}

for r in results {
    print("Candidate: \(formatter.string(from: r.0)) to \(formatter.string(from: r.1))")
}
print("Queue count at end: \(queue.count)")

