import CoreLocation
import MapKit

extension Array where Element == CLLocationCoordinate2D {
    /// 计算基于地理距离的中点，确保图标在路径的长度中点
    var distanceMidpoint: CLLocationCoordinate2D? {
        guard count >= 2 else { return first }
        
        var totalDistance: Double = 0
        var segmentDistances: [Double] = [0]
        
        for i in 0..<count-1 {
            let p1 = CLLocation(latitude: self[i].latitude, longitude: self[i].longitude)
            let p2 = CLLocation(latitude: self[i+1].latitude, longitude: self[i+1].longitude)
            let d = p1.distance(from: p2)
            totalDistance += d
            segmentDistances.append(totalDistance)
        }
        
        if totalDistance == 0 { return self[count / 2] }
        
        let midDistance = totalDistance / 2
        
        for i in 0..<count-1 {
            if midDistance >= segmentDistances[i] && midDistance <= segmentDistances[i+1] {
                let distInSegment = midDistance - segmentDistances[i]
                let segmentTotalDist = segmentDistances[i+1] - segmentDistances[i]
                let fraction = segmentTotalDist > 0 ? distInSegment / segmentTotalDist : 0
                
                return CLLocationCoordinate2D(
                    latitude: self[i].latitude + (self[i+1].latitude - self[i].latitude) * fraction,
                    longitude: self[i].longitude + (self[i+1].longitude - self[i].longitude) * fraction
                )
            }
        }
        return self[count / 2]
    }
}
