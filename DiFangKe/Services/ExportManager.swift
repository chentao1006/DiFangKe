import Foundation
import CoreLocation

class ExportManager {
    static func exportToJSON(footprints: [Footprint]) -> URL? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        
        // Simplified DTO for export
        struct FootprintDTO: Encodable {
            let id: UUID
            let date: Date
            let start: Date
            let end: Date
            let title: String
            let reason: String?
            let locations: [CLLocationCoordinate2D]
            
            enum CodingKeys: String, CodingKey {
                case id, date, start, end, title, reason, locations
            }
            
            // Re-define Codable for Coordinate
            struct Coordinate: Codable {
                let lat: Double
                let lon: Double
            }
            
            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(id, forKey: .id)
                try container.encode(date, forKey: .date)
                try container.encode(start, forKey: .start)
                try container.encode(end, forKey: .end)
                try container.encode(title, forKey: .title)
                try container.encode(reason, forKey: .reason)
                let coords = locations.map { Coordinate(lat: $0.latitude, lon: $0.longitude) }
                try container.encode(coords, forKey: .locations)
            }
        }
        
        let dtos = footprints.map { f in
            FootprintDTO(id: f.footprintID, date: f.date, start: f.startTime, end: f.endTime, title: f.title, reason: f.reason, locations: f.coordinates)
        }
        
        guard let data = try? encoder.encode(dtos) else { return nil }
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("DiFangKe_Export.json")
        try? data.write(to: tempURL)
        return tempURL
    }
}
