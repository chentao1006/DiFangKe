import SwiftUI
import SwiftData
import CoreLocation
import UniformTypeIdentifiers

struct DataManagerView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(LocationManager.self) private var locationManager
    @Query(sort: \Footprint.startTime, order: .reverse) private var allFootprints: [Footprint]
    @Query(sort: \Place.name) private var allPlaces: [Place]
    
    @State private var showDeleteAlert = false
    @State private var showingExportFileExporter = false
    @State private var showingImportFilePicker = false
    @State private var exportData: Data?
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    @State private var showAlert = false
    
    var body: some View {
        Form {
            Section(header: Text("备份与恢复")) {
                Button {
                    prepareExport()
                } label: {
                    Label("导出备份", systemImage: "square.and.arrow.up")
                }
                
                Button {
                    showingImportFilePicker = true
                } label: {
                    Label("导入数据", systemImage: "square.and.arrow.down")
                }
            }
            
            Section(header: Text("数据轨迹 (Raw)"), footer: Text("所有经过脱敏处理的原始 GPS 坐标流，永久保存在本地。")) {
                let count = locationManager.allTodayPoints.count
                HStack {
                    Label("今日记录点数", systemImage: "location.circle")
                    Spacer()
                    Text("\(count) 个")
                        .foregroundColor(.secondary)
                }
                
                NavigationLink(destination: RawLogsManagerView()) {
                    Label("查看/导出轨迹原始日志", systemImage: "doc.text.magnifyingglass")
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
                    Text("清空所有数据")
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
        .alert(alertTitle, isPresented: $showAlert) {
            Button("确定", role: .cancel) { }
        } message: {
            Text(alertMessage)
        }
    }
    
    private func prepareExport() {
        do {
            let data = try BackupService.shared.generateBackup(
                footprints: allFootprints, 
                places: allPlaces
            )
            self.exportData = data
            self.showingExportFileExporter = true
        } catch {
            self.alertTitle = "导出失败"
            self.alertMessage = error.localizedDescription
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
            if report.total == 0 && report.newPlaces == 0 {
                self.alertTitle = "导入结果"
                self.alertMessage = "文件中未发现任何有效数据。"
            } else {
                self.alertTitle = "导入完成"
                var message = ""
                message += "• 足迹: 新增 \(report.new), 跳过 \(report.skipped)"
                
                if report.newPlaces > 0 || report.skippedPlaces > 0 {
                    message += "\n• 重要地点: 新增 \(report.newPlaces), 跳过 \(report.skippedPlaces)"
                }
                
                self.alertMessage = message
            }
            self.showAlert = true
            
        } catch {
            self.alertTitle = "导入失败"
            self.alertMessage = error.localizedDescription
            self.showAlert = true
        }
    }
    
    private func deleteAllData() {
        do {
            try modelContext.delete(model: Footprint.self)
            try modelContext.delete(model: Place.self)
            try modelContext.save()
            locationManager.allTodayPoints = []
            
            self.alertTitle = "数据清空"
            self.alertMessage = "所有数据已彻底清空。"
            self.showAlert = true
        } catch {
            self.alertTitle = "操作失败"
            self.alertMessage = error.localizedDescription
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
        let addr: String?
        let isHist: Bool?
    }
}

final class BackupService {
    static let shared = BackupService()
    
    func generateBackup(footprints: [Footprint], places: [Place]) throws -> Data {
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
                    addr: $0.address, 
                    isHist: $0.isHighlight
                ) 
            }
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
        let newPlaces: Int
        let skippedPlaces: Int
    }
    
    func restoreBackup(data: Data, context: ModelContext) throws -> RestoreReport {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(BackupDTO.self, from: data)
        
        // 2. Restore Places
        var newPlaces = 0
        var skippedPlaces = 0
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
                newPlaces += 1
            } else {
                skippedPlaces += 1
            }
        }
        
        // 3. Restore Footprints
        var newFootprints = 0
        var skippedFootprints = 0
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
                    address: f.addr
                )
                context.insert(footprint)
                newFootprints += 1
            } else {
                skippedFootprints += 1
            }
        }
        
        try context.save()
        return RestoreReport(
            total: backup.footprints.count, 
            new: newFootprints, 
            skipped: skippedFootprints,
            newPlaces: newPlaces,
            skippedPlaces: skippedPlaces
        )
    }
}

import UniformTypeIdentifiers
