import SwiftUI
import SwiftData
import CoreLocation
import UniformTypeIdentifiers

struct DataManagerView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(LocationManager.self) private var locationManager
    @Query(sort: \Footprint.startTime, order: .reverse) private var allFootprints: [Footprint]
    @Query(sort: \Place.name) private var allPlaces: [Place]
    @Query(sort: \PlaceTag.name) private var allTags: [PlaceTag]
    
    @State private var showDeleteAlert = false
    @State private var showingExportFileExporter = false
    @State private var showingImportFilePicker = false
    @State private var exportData: Data?
    @State private var alertMessage = ""
    @State private var showAlert = false
    
    var body: some View {
        Form {
            Section(header: Text("备份与恢复")) {
                Button {
                    prepareExport()
                } label: {
                    Label("导出备份 (JSON)", systemImage: "square.and.arrow.up")
                }
                
                Button {
                    showingImportFilePicker = true
                } label: {
                    Label("导入数据", systemImage: "square.and.arrow.down")
                }
            }
            
            Section(header: Text("回收站")) {
                NavigationLink(destination: RecycleBinView()) {
                    Label("足迹回收站", systemImage: "trash.circle")
                }
            }
            
            Section(header: Text("危险操作"), footer: Text("彻底清空所有产生的足迹和自定义地点。")) {
                Button(role: .destructive, action: {
                    showDeleteAlert = true
                }) {
                    Text("彻底重置所有数据")
                }
                .alert("确认删除", isPresented: $showDeleteAlert) {
                    Button("删除", role: .destructive) { deleteAllData() }
                    Button("取消", role: .cancel) { }
                } message: {
                    Text("这将删除所有本地的足迹数据，操作不可逆！")
                }
            }
        }
        .navigationTitle("数据操作")
        .fileExporter(isPresented: $showingExportFileExporter, 
                      document: JSONDocument(data: exportData ?? Data()), 
                      contentType: .json, 
                      defaultFilename: "DiFangKe_Backup_\(Date().formatted(.dateTime.year().month().day())).json") { result in
            // Export handling
        }
        .fileImporter(isPresented: $showingImportFilePicker, 
                      allowedContentTypes: [.json], 
                      allowsMultipleSelection: false) { result in
            importData(from: result)
        }
        .alert("提示", isPresented: $showAlert) {
            Button("好的", role: .cancel) { }
        } message: {
            Text(alertMessage)
        }
    }
    
    private func prepareExport() {
        do {
            let data = try BackupService.shared.generateBackup(
                footprints: allFootprints, 
                places: allPlaces, 
                tags: allTags
            )
            self.exportData = data
            self.showingExportFileExporter = true
        } catch {
            self.alertMessage = "导出失败: \(error.localizedDescription)"
            self.showAlert = true
        }
    }
    
    private func importData(from result: Result<[URL], Error>) {
        do {
            let urls = try result.get()
            guard let url = urls.first else {
                self.alertMessage = "未选择任何文件。"
                self.showAlert = true
                return
            }
            
            let canAccess = url.startAccessingSecurityScopedResource()
            defer { if canAccess { url.stopAccessingSecurityScopedResource() } }
            
            let data = try Data(contentsOf: url)
            let report = try BackupService.shared.restoreBackup(data: data, context: modelContext)
            
            if report.total == 0 {
                self.alertMessage = "文件中未发现有效足迹数据。"
            } else {
                self.alertMessage = "导入完成！\n• 新增: \(report.new)\n• 跳过(已存在): \(report.skipped)\n• 总计: \(report.total)"
            }
            self.showAlert = true
            
        } catch {
            self.alertMessage = "导入失败: \(error.localizedDescription)"
            self.showAlert = true
        }
    }
    
    private func deleteAllData() {
        do {
            try modelContext.delete(model: Footprint.self)
            try modelContext.delete(model: Place.self)
            try modelContext.delete(model: PlaceTag.self)
            try modelContext.save()
            locationManager.allTodayPoints = []
            
            self.alertMessage = "所有数据已彻底清空。"
            self.showAlert = true
        } catch {
            self.alertMessage = "删除失败: \(error.localizedDescription)"
            self.showAlert = true
        }
    }
}

// MARK: - File Helpers

struct JSONDocument: FileDocument {
    static var readableContentTypes: [UTType] = [.json]
    var data: Data = Data()
    
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = Data() }
    
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

// MARK: - Backup Service

struct BackupDTO: Codable {
    let version: Int
    let places: [PlaceDTO]
    let footprints: [FootprintDTO]
    let tags: [String]
    
    struct PlaceDTO: Codable {
        let id: UUID
        let name: String
        let lat: Double
        let lon: Double
        let rad: Float
        let addr: String?
    }
    
    struct FootprintDTO: Codable {
        let id: UUID
        let date: Date
        let start: Date
        let end: Date
        let lats: [Double]
        let lngs: [Double]
        let title: String
        let reason: String?
        let status: String
        let score: Float
        let placeID: UUID?
        let photos: [String]
        let tags: [String]
        let addr: String?
        let isHist: Bool?
    }
}

final class BackupService {
    static let shared = BackupService()
    
    func generateBackup(footprints: [Footprint], places: [Place], tags: [PlaceTag]) throws -> Data {
        let dto = BackupDTO(
            version: 1,
            places: places.map { BackupDTO.PlaceDTO(id: $0.placeID, name: $0.name, lat: $0.latitude, lon: $0.longitude, rad: $0.radius, addr: $0.address) },
            footprints: footprints.map { 
                BackupDTO.FootprintDTO(
                    id: $0.footprintID, 
                    date: $0.date, 
                    start: $0.startTime, 
                    end: $0.endTime, 
                    lats: $0.latitudeArray, 
                    lngs: $0.longitudeArray, 
                    title: $0.title, 
                    reason: $0.reason, 
                    status: $0.statusValue, 
                    score: $0.aiScore, 
                    placeID: $0.placeID, 
                    photos: $0.photoAssetIDs, 
                    tags: $0.tags, 
                    addr: $0.address, 
                    isHist: $0.isHighlight
                ) 
            },
            tags: tags.map { $0.name }
        )
        
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        return try encoder.encode(dto)
    }
    
    struct RestoreReport {
        let total: Int
        let new: Int
        let skipped: Int
    }
    
    func restoreBackup(data: Data, context: ModelContext) throws -> RestoreReport {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(BackupDTO.self, from: data)
        
        // 1. Restore Tags
        for tagName in backup.tags {
            let descriptor = FetchDescriptor<PlaceTag>(predicate: #Predicate { $0.name == tagName })
            if (try? context.fetch(descriptor).first) == nil {
                context.insert(PlaceTag(name: tagName))
            }
        }
        
        // 2. Restore Places
        for p in backup.places {
            let id = p.id
            let descriptor = FetchDescriptor<Place>(predicate: #Predicate { $0.placeID == id })
            if (try? context.fetch(descriptor).first) == nil {
                let place = Place(
                    placeID: p.id, 
                    name: p.name, 
                    coordinate: CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon), 
                    radius: p.rad, 
                    address: p.addr
                )
                context.insert(place)
            }
        }
        
        // 3. Restore Footprints
        var newCount = 0
        var skippedCount = 0
        for f in backup.footprints {
            let id = f.id
            let descriptor = FetchDescriptor<Footprint>(predicate: #Predicate { $0.footprintID == id })
            if (try? context.fetch(descriptor).first) == nil {
                let footprint = Footprint(
                    footprintID: f.id,
                    date: f.date,
                    startTime: f.start,
                    endTime: f.end,
                    footprintLocations: zip(f.lats, f.lngs).map { CLLocationCoordinate2D(latitude: $0, longitude: $1) },
                    locationHash: "RESTORED",
                    duration: f.end.timeIntervalSince(f.start),
                    title: f.title,
                    reason: f.reason,
                    status: FootprintStatus(rawValue: f.status) ?? .confirmed,
                    aiScore: f.score,
                    isHighlight: f.isHist,
                    placeID: f.placeID,
                    photoAssetIDs: f.photos,
                    tags: f.tags,
                    address: f.addr
                )
                context.insert(footprint)
                newCount += 1
            } else {
                skippedCount += 1
            }
        }
        
        try context.save()
        return RestoreReport(total: backup.footprints.count, new: newCount, skipped: skippedCount)
    }
}

import UniformTypeIdentifiers
