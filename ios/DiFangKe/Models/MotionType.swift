import Foundation

enum MotionType: String, Codable {
    case stationary = "stationary"
    case walking = "walking"
    case running = "running"
    case cycling = "cycling"
    case automotive = "automotive"
    case unknown = "unknown"
}
