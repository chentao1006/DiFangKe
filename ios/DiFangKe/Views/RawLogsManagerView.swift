import SwiftUI
import CoreLocation

struct RawLogsManagerView: View {
    @AppStorage("isRawTrajectoryICloudSyncEnabled") private var isRawTrajectoryICloudSyncEnabled = true

    @State private var files: [RawFileItem] = []
    
    @State private var isSyncing = false
    @State private var syncStatus: String?
    @State private var isExportingAll = false
    @State private var exportAllURL: URL?
    @State private var showingExportAllShareSheet = false
    @State private var exportAllError: String?
    
    @Environment(LocationManager.self) private var locationManager
    
    var body: some View {
        List {
            Section(header: Text("iCloud 同步"), footer: Text("关闭后，此设备不会自动同步轨迹文件，也不能手动上传或下载轨迹文件。")) {
                Toggle("同步轨迹文件", isOn: $isRawTrajectoryICloudSyncEnabled)

                HStack {
                    VStack(alignment: .leading) {
                        Text("手动备份到云端")
                            .font(.headline)
                        if !isRawTrajectoryICloudSyncEnabled {
                            Text("轨迹文件同步已关闭")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else if let lastSync = RawLocationStore.shared.lastSyncDate {
                            Text("上次同步: \(lastSync.formatted(.dateTime.month().day().hour().minute()))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            Text("尚未进行同步")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                    
                    if isSyncing {
                        ProgressView()
                    } else {
                        Button("立即同步") {
                            Task {
                                await startSync()
                            }
                        }
                        .disabled(!isRawTrajectoryICloudSyncEnabled)
                    }
                }
                
                if let status = syncStatus {
                    Text(status)
                        .font(.caption)
                        .foregroundColor(.blue)
                }
            }
            
            Section(header: Text("本地轨迹文件"), footer: Text("这些文件记录了所有原始 GPS 坐标。足迹是从这些记录中提取的。")) {
                if files.isEmpty {
                    Text("暂无数据文件")
                        .foregroundColor(.secondary)
                } else {
                    Button {
                        exportAllFiles()
                    } label: {
                        HStack {
                            Label("导出全部", systemImage: "archivebox")
                            Spacer()
                            if isExportingAll {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isExportingAll)

                    ForEach(files) { file in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(file.dateString)
                                    .font(.headline)
                                Text("\(file.sizeFormatted) • \(file.pointCount) 个坐标点")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            
                            ShareLink(item: file.url) {
                                Image(systemName: "square.and.arrow.up")
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("轨迹文件")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: loadFiles)
        .sheet(isPresented: $showingExportAllShareSheet) {
            if let exportAllURL {
                ActivityView(activityItems: [exportAllURL])
            }
        }
        .alert("导出失败", isPresented: Binding(
            get: { exportAllError != nil },
            set: { if !$0 { exportAllError = nil } }
        )) {
            Button("确定", role: .cancel) { }
        } message: {
            Text(exportAllError ?? "")
        }
        .onChange(of: isRawTrajectoryICloudSyncEnabled) { _, newValue in
            if !newValue {
                syncStatus = nil
            }
            Task { @MainActor in
                await locationManager.refreshForRecordingDeviceChange()
            }
        }
    }

    private func exportAllFiles() {
        guard !files.isEmpty else { return }

        isExportingAll = true
        let fileURLs = files.map(\.url)

        Task {
            do {
                let archiveURL = try makeZipArchive(from: fileURLs)
                await MainActor.run {
                    exportAllURL = archiveURL
                    showingExportAllShareSheet = true
                    isExportingAll = false
                }
            } catch {
                await MainActor.run {
                    exportAllError = error.localizedDescription
                    isExportingAll = false
                }
            }
        }
    }

    private func makeZipArchive(from fileURLs: [URL]) throws -> URL {
        let fileManager = FileManager.default
        let exportRoot = fileManager.temporaryDirectory.appendingPathComponent("RawLocationsExport-\(UUID().uuidString)", isDirectory: true)
        let payloadDirectory = exportRoot.appendingPathComponent("RawLocations", isDirectory: true)

        try fileManager.createDirectory(at: payloadDirectory, withIntermediateDirectories: true)

        for fileURL in fileURLs {
            let destinationURL = payloadDirectory.appendingPathComponent(fileURL.lastPathComponent)
            try fileManager.copyItem(at: fileURL, to: destinationURL)
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let archiveURL = fileManager.temporaryDirectory.appendingPathComponent("DiFangKe_RawLocations_\(formatter.string(from: Date())).zip")
        if fileManager.fileExists(atPath: archiveURL.path) {
            try fileManager.removeItem(at: archiveURL)
        }

        var coordinatorError: NSError?
        var copyError: Error?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: payloadDirectory, options: .forUploading, error: &coordinatorError) { temporaryZipURL in
            do {
                try fileManager.copyItem(at: temporaryZipURL, to: archiveURL)
            } catch {
                copyError = error
            }
        }

        if let copyError {
            throw copyError
        }
        if let coordinatorError {
            throw coordinatorError
        }

        return archiveURL
    }
    
    @MainActor
    private func loadFiles() {
        let fileManager = FileManager.default
        let documentsDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let baseDirectory = documentsDirectory.appendingPathComponent("RawLocations")
        
        guard let contents = try? fileManager.contentsOfDirectory(at: baseDirectory, includingPropertiesForKeys: [.fileSizeKey]) else {
            return
        }
        
        self.files = contents.filter { $0.pathExtension == "csv" }.map { url in
            let attributes = try? fileManager.attributesOfItem(atPath: url.path)
            let size = attributes?[.size] as? Int64 ?? 0
            
            // 简单估算点数 (一行约 60-80 字符)
            var count = 0
            if let content = try? String(contentsOf: url, encoding: .utf8) {
                count = content.components(separatedBy: .newlines).filter { !$0.isEmpty }.count
            }
            
            return RawFileItem(
                url: url,
                dateString: url.deletingPathExtension().lastPathComponent,
                size: size,
                pointCount: count
            )
        }.sorted { $0.dateString > $1.dateString }
    }
    
    private func startSync() async {
        guard isRawTrajectoryICloudSyncEnabled else {
            syncStatus = "轨迹文件同步已关闭"
            return
        }

        isSyncing = true
        syncStatus = "正在同步文件..."
        
        do {
            let count = try await RawLocationStore.shared.syncToiCloud(onlyRecent: false)
            syncStatus = "同步成功：共同步 \(count) 个文件"
            loadFiles()
            locationManager.refreshAvailableRawDates()
        } catch {
            syncStatus = "同步失败：\(error.localizedDescription)"
        }
        
        isSyncing = false
        // 同步成功才自动隐藏，失败则一直显示供排查
        if let status = syncStatus, !status.contains("失败") {
            Task {
                try? await Task.sleep(nanoseconds: 3 * 1_000_000_000)
                if !isSyncing { syncStatus = nil }
            }
        }
    }
}

struct RawFileItem: Identifiable {
    let id = UUID()
    let url: URL
    let dateString: String
    let size: Int64
    let pointCount: Int
    
    var sizeFormatted: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}
