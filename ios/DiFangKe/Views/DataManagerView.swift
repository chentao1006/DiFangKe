import SwiftUI
import SwiftData
import CoreLocation
import UniformTypeIdentifiers

struct DataManagerView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(LocationManager.self) private var locationManager
    @Query(sort: \Footprint.startTime, order: .reverse) private var allFootprints: [Footprint]
    @Query(sort: \Place.name) private var allPlaces: [Place]
    @Query(sort: \ActivityType.sortOrder) private var allActivities: [ActivityType]
    @Query(sort: \TransportRecord.startTime, order: .reverse) private var allTransports: [TransportRecord]
    
    @State private var showDeleteAlert = false
    @State private var showingExportFileExporter = false
    @State private var showingImportFilePicker = false
    @State private var exportURL: URL?
    @State private var showingShareSheet = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    @State private var showAlert = false
    @State private var isExporting = false
    
    var body: some View {
        ZStack {
            mainContent
            
            if isExporting {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text("正在准备备份文件...")
                        .font(.headline)
                        .foregroundColor(.white)
                }
                .padding(30)
                .background(RoundedRectangle(cornerRadius: 16).fill(Color(uiColor: .systemBackground).opacity(0.8)))
                .shadow(radius: 10)
            }
        }
    }
    
    private var mainContent: some View {
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
        .sheet(isPresented: $showingShareSheet) {
            if let url = exportURL {
                ActivityView(activityItems: [url])
            }
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
        isExporting = true
        
        Task {
            do {
                // Generate backup in background
                let data = try BackupService.shared.generateBackup(
                    footprints: allFootprints, 
                    places: allPlaces,
                    activities: allActivities,
                    transports: allTransports
                )
                
                let filename = "DiFangKe_Backup_\(Date().formatted(.dateTime.year().month().day())).json"
                let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
                try data.write(to: tempURL)
                
                await MainActor.run {
                    self.exportURL = tempURL
                    self.isExporting = false
                    self.showingShareSheet = true
                }
            } catch {
                await MainActor.run {
                    self.isExporting = false
                    self.alertTitle = "导出失败"
                    self.alertMessage = error.localizedDescription
                    self.showAlert = true
                }
            }
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
            // Delete all records via query to avoid potential SwiftData 1.0 compiler confusion with delete(model:)
            try modelContext.delete(model: Footprint.self, where: #Predicate<Footprint> { _ in true })
            try modelContext.delete(model: Place.self, where: #Predicate<Place> { _ in true })
            try modelContext.delete(model: ActivityType.self, where: #Predicate<ActivityType> { _ in true })
            try modelContext.delete(model: TransportRecord.self, where: #Predicate<TransportRecord> { _ in true })
            
            try modelContext.save()
            CloudSettingsManager.shared.triggerDataSyncPulse()
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

struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]
    let applicationActivities: [UIActivity]? = nil

    func makeUIViewController(context: UIViewControllerRepresentableContext<ActivityView>) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: activityItems, applicationActivities: applicationActivities)
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: UIViewControllerRepresentableContext<ActivityView>) {}
}

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
    let activityTypes: [ActivityTypeDTO]?
    let transports: [TransportDTO]?
    
    init(version: Int, places: [PlaceDTO], footprints: [FootprintDTO], activityTypes: [ActivityTypeDTO]?, transports: [TransportDTO]?) {
        self.version = version
        self.places = places
        self.footprints = footprints
        self.activityTypes = activityTypes
        self.transports = transports
    }
    
    struct PlaceDTO: Codable {
        let id: String
        let name: String
        let lat: Double
        let lon: Double
        let rad: Float
        let addr: String?
        let isPriority: Bool?
        let isIgnored: Bool?
        let isUserDefined: Bool?
        
        enum CodingKeys: String, CodingKey {
            case id, name, lat, lon, rad, addr
            case isPriority = "isPriority"
            case isIgnored = "isIgnored"
            case isUserDefined = "isUserDefined"
        }
    }
    
    struct FootprintDTO: Codable {
        let id: String
        let date: Date
        let start: Date
        let end: Date
        let lats: [Double]
        let lngs: [Double]
        let title: String
        let reason: String?
        let status: String
        let score: Float
        let placeID: String?
        let photos: [String]
        let addr: String?
        let isHighlight: Bool?
        let activityType: String?
        
        init(id: String, date: Date, start: Date, end: Date, lats: [Double], lngs: [Double], title: String, reason: String?, status: String, score: Float, placeID: String?, photos: [String], addr: String?, isHighlight: Bool?, activityType: String?) {
            self.id = id
            self.date = date
            self.start = start
            self.end = end
            self.lats = lats
            self.lngs = lngs
            self.title = title
            self.reason = reason
            self.status = status
            self.score = score
            self.placeID = placeID
            self.photos = photos
            self.addr = addr
            self.isHighlight = isHighlight
            self.activityType = activityType
        }
        
        enum CodingKeys: String, CodingKey {
            case id, date, start, end, lats, lngs, title, reason, status, score, photos, addr, placeID, activityType
            case isHighlight = "isHighlight"
        }
    }

    struct ActivityTypeDTO: Codable {
        let id: String
        let name: String
        let icon: String
        let colorHex: String
    }
    
    struct TransportDTO: Codable {
        let id: String
        let day: Date
        let start: Date
        let end: Date
        let from: String
        let to: String
        let type: String
        let dist: Double
        let speed: Double
        let pts: String
        let manualType: String?
        let status: String?
    }
}

final class BackupService {
    static let shared = BackupService()
    
    func generateBackup(footprints: [Footprint], places: [Place], activities: [ActivityType], transports: [TransportRecord]) throws -> Data {
        let dto = BackupDTO(
            version: 1,
            places: places.map { BackupDTO.PlaceDTO(id: $0.placeID.uuidString, name: $0.name, lat: $0.latitude, lon: $0.longitude, rad: $0.radius, addr: $0.address, isPriority: $0.isPriority, isIgnored: $0.isIgnored, isUserDefined: $0.isUserDefined) },
            footprints: footprints.map { f in
                BackupDTO.FootprintDTO(
                    id: f.footprintID.uuidString,
                    date: f.date,
                    start: f.startTime,
                    end: f.endTime,
                    lats: f.latitudeArray,
                    lngs: f.longitudeArray,
                    title: f.title,
                    reason: f.reason,
                    status: f.statusValue,
                    score: f.aiScore,
                    placeID: f.placeID?.uuidString,
                    photos: f.photoAssetIDs,
                    addr: f.address,
                    isHighlight: f.isHighlight,
                    activityType: f.activityTypeValue
                )
            },
            activityTypes: activities.map { BackupDTO.ActivityTypeDTO(id: $0.id.uuidString, name: $0.name, icon: $0.icon, colorHex: $0.colorHex) },
            transports: transports.map { t in
                BackupDTO.TransportDTO(
                    id: t.recordID.uuidString,
                    day: t.day,
                    start: t.startTime,
                    end: t.endTime,
                    from: t.startLocation,
                    to: t.endLocation,
                    type: t.typeRaw,
                    dist: t.distance,
                    speed: t.averageSpeed,
                    pts: String(data: t.pointsData, encoding: String.Encoding.utf8) ?? "[]",
                    manualType: t.manualTypeRaw,
                    status: t.statusRaw
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
            if let uuid = UUID(uuidString: p.id) {
                let descriptor = FetchDescriptor<Place>(predicate: #Predicate { $0.placeID == uuid })
                if (try? context.fetch(descriptor).first) == nil {
                    let place = Place(
                        placeID: uuid, 
                        name: p.name, 
                        coordinate: CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon), 
                        radius: p.rad, 
                        address: p.addr,
                        isUserDefined: p.isUserDefined ?? true
                    )
                    place.isIgnored = p.isIgnored ?? false
                    context.insert(place)
                    newPlaces += 1
                } else {
                    skippedPlaces += 1
                }
            }
        }
        
        // 3. Restore Footprints
        var newFootprints = 0
        var skippedFootprints = 0
        for f in backup.footprints {
            if let footprintUUID = UUID(uuidString: f.id) {
                let descriptor = FetchDescriptor<Footprint>(predicate: #Predicate { $0.footprintID == footprintUUID })
                if (try? context.fetch(descriptor).first) == nil {
                    let footprint = Footprint(
                        footprintID: footprintUUID,
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
                        isHighlight: f.isHighlight ?? false,
                        placeID: f.placeID != nil ? UUID(uuidString: f.placeID!) : nil,
                        photoAssetIDs: f.photos,
                        address: f.addr,
                        activityTypeValue: f.activityType
                    )
                    context.insert(footprint)
                    newFootprints += 1
                } else {
                    skippedFootprints += 1
                }
            }
        }
        
        // 4. Restore Activity Types
        if let activityDTOs = backup.activityTypes {
            for a in activityDTOs {
                if let uuid = UUID(uuidString: a.id) {
                    let descriptor = FetchDescriptor<ActivityType>(predicate: #Predicate { $0.id == uuid })
                    if (try? context.fetch(descriptor).first) == nil {
                        let activity = ActivityType(id: uuid, name: a.name, icon: a.icon, colorHex: a.colorHex)
                        context.insert(activity)
                    }
                }
            }
        }
        
        // 5. Restore Transports
        if let transportDTOs = backup.transports {
            for t in transportDTOs {
                if let uuid = UUID(uuidString: t.id) {
                    let descriptor = FetchDescriptor<TransportRecord>(predicate: #Predicate { $0.recordID == uuid })
                    if (try? context.fetch(descriptor).first) == nil {
                        let record = TransportRecord(
                            recordID: uuid,
                            day: t.day,
                            startTime: t.start,
                            endTime: t.end,
                            startLocation: t.from,
                            endLocation: t.to,
                            typeRaw: t.type,
                            distance: t.dist,
                            averageSpeed: t.speed,
                            pointsData: t.pts.data(using: String.Encoding.utf8) ?? Data()
                        )
                        record.manualTypeRaw = t.manualType
                        record.statusRaw = t.status ?? "active"
                        context.insert(record)
                    }
                }
            }
        }
        
        try context.save()
        CloudSettingsManager.shared.triggerDataSyncPulse()
        return RestoreReport(
            total: backup.footprints.count, 
            new: newFootprints, 
            skipped: skippedFootprints,
            newPlaces: newPlaces,
            skippedPlaces: skippedPlaces
        )
    }
}

