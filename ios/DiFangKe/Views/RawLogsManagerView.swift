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
    @State private var isSelecting = false
    @State private var selectedFileURLs = Set<URL>()
    @State private var pendingDeletionURLs: [URL] = []
    @State private var showingDeleteConfirmation = false
    @State private var isDeleting = false
    @State private var deleteError: String?
    
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
                    .disabled(isExportingAll || isSelecting)

                    ForEach(files) { file in
                        HStack {
                            if isSelecting {
                                Image(systemName: selectedFileURLs.contains(file.url) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selectedFileURLs.contains(file.url) ? Color.dfkAccent : Color.secondary)
                                    .accessibilityHidden(true)
                            }
                            VStack(alignment: .leading) {
                                Text(file.dateString)
                                    .font(.headline)
                                Text("\(file.sizeFormatted) • \(file.pointCount) 个坐标点")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            
                            if !isSelecting {
                                ShareLink(item: file.url) {
                                    Image(systemName: "square.and.arrow.up")
                                }
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard isSelecting else { return }
                            toggleSelection(for: file.url)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            if !isSelecting {
                                Button(role: .destructive) {
                                    requestDeletion(of: [file.url])
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("轨迹文件")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(isSelecting ? "完成" : "选择") {
                    isSelecting ? endSelection() : beginSelection()
                }
                .disabled(files.isEmpty && !isSelecting)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isSelecting {
                Button(role: .destructive) {
                    requestDeletion(of: Array(selectedFileURLs))
                } label: {
                    if isDeleting {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Label("删除 \(selectedFileURLs.count) 个文件", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                }
                .rawLogDeleteButtonStyle()
                .tint(.red)
                .disabled(selectedFileURLs.isEmpty || isDeleting)
                .padding(.horizontal, 24)
                .padding(.vertical, 10)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isSelecting)
        .task { await loadFiles() }
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
        .confirmationDialog(
            pendingDeletionURLs.count == 1 ? "删除这个轨迹文件？" : "删除所选的 \(pendingDeletionURLs.count) 个轨迹文件？",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                deletePendingFiles()
            }
            Button("取消", role: .cancel) {
                pendingDeletionURLs.removeAll()
            }
        } message: {
            Text("只会删除此设备上的原始轨迹文件，不会删除已提取的足迹。如果云端仍有副本，以后同步时可能会再次下载。")
        }
        .alert("删除失败", isPresented: Binding(
            get: { deleteError != nil },
            set: { if !$0 { deleteError = nil } }
        )) {
            Button("确定", role: .cancel) { deleteError = nil }
        } message: {
            Text(deleteError ?? "")
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

    private func beginSelection() {
        isSelecting = true
        selectedFileURLs.removeAll()
    }

    private func endSelection() {
        isSelecting = false
        selectedFileURLs.removeAll()
    }

    private func toggleSelection(for fileURL: URL) {
        if selectedFileURLs.contains(fileURL) {
            selectedFileURLs.remove(fileURL)
        } else {
            selectedFileURLs.insert(fileURL)
        }
    }

    private func requestDeletion(of fileURLs: [URL]) {
        guard !fileURLs.isEmpty else { return }
        pendingDeletionURLs = fileURLs
        showingDeleteConfirmation = true
    }

    private func deletePendingFiles() {
        let fileURLs = pendingDeletionURLs
        guard !fileURLs.isEmpty else { return }
        pendingDeletionURLs.removeAll()
        isDeleting = true

        Task {
            do {
                try await RawLocationStore.shared.deleteLocalFiles(at: fileURLs)
                await loadFiles()
                await MainActor.run {
                    selectedFileURLs.subtract(fileURLs)
                    locationManager.refreshAvailableRawDates()
                    if files.isEmpty {
                        endSelection()
                    }
                    isDeleting = false
                }
            } catch {
                await loadFiles()
                await MainActor.run {
                    deleteError = error.localizedDescription
                    isDeleting = false
                }
            }
        }
    }

    private func exportAllFiles() {
        guard !files.isEmpty else { return }

        isExportingAll = true
        let fileURLs = files.map(\.url)

        Task {
            do {
                // Copies and zips via NSFileCoordinator: file IO off main.
                let archiveURL = try await Task.detached(priority: .userInitiated) {
                    try Self.makeZipArchive(from: fileURLs)
                }.value
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

    nonisolated private static func makeZipArchive(from fileURLs: [URL]) throws -> URL {
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
    
    /// Lists the CSV files and counts their points off main, then assigns.
    @MainActor
    private func loadFiles() async {
        guard let items = await Task.detached(priority: .userInitiated, operation: { Self.scanFiles() }).value else { return }
        self.files = items
    }

    /// Nil when the directory cannot be read (the list is then left as is).
    nonisolated private static func scanFiles() -> [RawFileItem]? {
        let fileManager = FileManager.default
        let documentsDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let baseDirectory = documentsDirectory.appendingPathComponent("RawLocations")
        
        guard let contents = try? fileManager.contentsOfDirectory(at: baseDirectory, includingPropertiesForKeys: [.fileSizeKey]) else {
            return nil
        }
        
        return contents.filter { $0.pathExtension == "csv" }.map { url in
            let attributes = try? fileManager.attributesOfItem(atPath: url.path)
            let size = attributes?[.size] as? Int64 ?? 0
            
            return RawFileItem(
                url: url,
                dateString: url.deletingPathExtension().lastPathComponent,
                size: size,
                pointCount: nonEmptyLineCount(at: url)
            )
        }.sorted { $0.dateString > $1.dateString }
    }

    /// Non-empty lines, counted on the raw bytes without building a String:
    /// the same as splitting the (app-written UTF-8) CSV text on LF/CR and
    /// dropping empty pieces. Unreadable files count as 0.
    nonisolated private static func nonEmptyLineCount(at url: URL) -> Int {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return 0 }
        var count = 0
        var lineHasContent = false
        for byte in data {
            if byte == 0x0A || byte == 0x0D {
                if lineHasContent { count += 1 }
                lineHasContent = false
            } else {
                lineHasContent = true
            }
        }
        if lineHasContent { count += 1 }
        return count
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
            await loadFiles()
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
    let url: URL
    let dateString: String
    let size: Int64
    let pointCount: Int

    var id: URL { url }
    
    var sizeFormatted: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

private extension View {
    @ViewBuilder
    func rawLogDeleteButtonStyle() -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
        }
    }
}
