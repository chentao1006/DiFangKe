import SwiftUI
import CoreLocation
import CloudKit

struct RawLogsManagerView: View {
    @AppStorage(RawLocationStore.autoBackupEnabledKey) private var isAutoBackupEnabled = true

    @State private var files: [RawFileItem] = []
    
    @State private var isBackingUp = false
    @State private var backupStatus: String?
    @State private var isExportingAll = false
    @State private var exportAllURL: URL?
    @State private var showingExportAllShareSheet = false
    @State private var exportAllError: String?
    @State private var isSelecting = false
    @State private var selectedFileURLs = Set<URL>()
    @State private var pendingDeletionURLs: [URL] = []
    @State private var showingDeleteConfirmation = false
    @State private var pendingDeletionKind: LocalDeletionKind = .selection
    @State private var isDeleting = false
    @State private var deleteError: String?
    @State private var localDeletionNotice: String?
    @State private var cloudSummary: RawLocationStore.CloudStorageSummary?
    @State private var isLoadingCloudSummary = false
    @State private var cloudManagementError: String?
    @State private var isDeletingCloudData = false
    @State private var rangeOperation: RawDataRangeOperation?
    @State private var pendingCloudDeletionRange: ClosedRange<Date>?
    @State private var showingCloudDeletionConfirmation = false
    
    @Environment(LocationManager.self) private var locationManager
    
    var body: some View {
        List {
            Section(
                header: Text("iCloud 备份"),
                footer: Text("开启后会定期备份最近 \(AppConfig.shared.cloudRawTrajectoryAutoBackupLookbackDays) 天的数据。备份只会把此设备的本地轨迹复制到 iCloud，不会从云端下载或改写本地轨迹。")
            ) {
                Toggle("自动备份原始轨迹", isOn: $isAutoBackupEnabled)

                HStack {
                    VStack(alignment: .leading) {
                        Text("备份到云端")
                            .font(.headline)
                        if let lastBackup = RawLocationStore.shared.lastBackupDate {
                            Text("上次备份: \(lastBackup.formatted(.dateTime.month().day().hour().minute()))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            Text("尚未进行备份")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                    
                    if isBackingUp {
                        ProgressView()
                    } else {
                        Button("选择范围") {
                            presentRangeOperation(.backup)
                        }
                    }
                }
                
                if let status = backupStatus {
                    Text(status)
                        .font(.caption)
                        .foregroundColor(.blue)
                }
            }

            Section(header: Text("iCloud 存储"), footer: Text(cloudStorageFooter)) {
                HStack {
                    Label("云端轨迹备份", systemImage: "icloud")
                    Spacer()
                    if isLoadingCloudSummary {
                        ProgressView()
                    } else if let cloudSummary {
                        Text("\(cloudSummary.recordCount) 个")
                            .foregroundColor(.secondary)
                    } else {
                        Text("未读取")
                            .foregroundColor(.secondary)
                    }
                }

                Button {
                    Task { await loadCloudSummary() }
                } label: {
                    Label("刷新云端信息", systemImage: "arrow.clockwise")
                }
                .disabled(isLoadingCloudSummary || isDeletingCloudData)

                Button {
                    presentRangeOperation(.restore)
                } label: {
                    Label("按日期范围恢复到本地", systemImage: "icloud.and.arrow.down")
                }
                .disabled(isDeletingCloudData || isBackingUp)

                Button(role: .destructive) {
                    presentRangeOperation(.deleteCloud)
                } label: {
                    Label("按日期范围删除云端备份", systemImage: "icloud.slash")
                }
                .disabled(isDeletingCloudData)
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

                    Button(role: .destructive) {
                        presentRangeOperation(.deleteLocal)
                    } label: {
                        Label("按日期范围删除本地数据", systemImage: "calendar.badge.minus")
                    }
                    .disabled(isDeleting || isSelecting)

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
            if isSelecting {
                ToolbarItem(placement: .topBarLeading) {
                    Button(selectedFileURLs.count == files.count ? "取消全选" : "全选") {
                        toggleSelectAll()
                    }
                }
            }
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
        .task {
            await loadFiles()
            await loadCloudSummary()
        }
        .sheet(isPresented: $showingExportAllShareSheet) {
            if let exportAllURL {
                ActivityView(activityItems: [exportAllURL])
            }
        }
        .sheet(item: $rangeOperation) { operation in
            RawDataRangePicker(operation: operation) { startDate, endDate in
                rangeOperation = nil
                handleSelectedRange(operation, startDate: startDate, endDate: endDate)
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
            localDeletionConfirmationTitle,
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
            Text(localDeletionConfirmationMessage)
        }
        .alert("删除失败", isPresented: Binding(
            get: { deleteError != nil },
            set: { if !$0 { deleteError = nil } }
        )) {
            Button("确定", role: .cancel) { deleteError = nil }
        } message: {
            Text(deleteError ?? "")
        }
        .alert("无需清理", isPresented: Binding(
            get: { localDeletionNotice != nil },
            set: { if !$0 { localDeletionNotice = nil } }
        )) {
            Button("确定", role: .cancel) { localDeletionNotice = nil }
        } message: {
            Text(localDeletionNotice ?? "")
        }
        .confirmationDialog(
            "删除所选日期范围的云端备份？",
            isPresented: $showingCloudDeletionConfirmation,
            titleVisibility: .visible
        ) {
            Button("删除云端备份", role: .destructive) {
                guard let range = pendingCloudDeletionRange else { return }
                pendingCloudDeletionRange = nil
                Task { await deleteCloudData(from: range.lowerBound, through: range.upperBound) }
            }
            Button("取消", role: .cancel) { pendingCloudDeletionRange = nil }
        } message: {
            Text("只会删除所选日期范围内的云端备份，不会删除或改写本地轨迹。")
        }
        .alert("iCloud 操作失败", isPresented: Binding(
            get: { cloudManagementError != nil },
            set: { if !$0 { cloudManagementError = nil } }
        )) {
            Button("确定", role: .cancel) { cloudManagementError = nil }
        } message: {
            Text(cloudManagementError ?? "")
        }
    }

    private var cloudStorageFooter: String {
        guard let summary = cloudSummary else {
            return "云端备份不会自动下载或改写本地数据；只有您手动选择日期范围后才会恢复。"
        }
        var parts: [String] = []
        if let earliest = summary.earliestDateString, let latest = summary.latestDateString {
            parts.append("范围：\(earliest) 至 \(latest)。")
        }
        parts.append("实际占用以系统设置中的 iCloud 存储为准。")
        parts.append("云端备份不会自动下载或改写本地数据；只有您手动选择日期范围后才会恢复。")
        return parts.joined(separator: " ")
    }

    @MainActor
    private func loadCloudSummary() async {
        isLoadingCloudSummary = true
        defer { isLoadingCloudSummary = false }
        do {
            cloudSummary = try await RawLocationStore.shared.cloudStorageSummary()
        } catch let error as CKError where error.code == .unknownItem {
            cloudSummary = .init(recordCount: 0, earliestDateString: nil, latestDateString: nil)
        } catch {
            cloudManagementError = error.localizedDescription
        }
    }

    @MainActor
    private func deleteCloudData(from startDate: Date, through endDate: Date) async {
        isDeletingCloudData = true
        defer { isDeletingCloudData = false }
        do {
            let deletedCount = try await RawLocationStore.shared.deleteCloudTrajectories(
                from: startDate,
                through: endDate
            )
            backupStatus = "已删除 \(deletedCount) 个云端备份文件，本地轨迹未受影响"
            await loadCloudSummary()
        } catch {
            cloudManagementError = error.localizedDescription
        }
    }

    private func presentRangeOperation(_ operation: RawDataRangeOperation) {
        rangeOperation = operation
    }

    private func handleSelectedRange(
        _ operation: RawDataRangeOperation,
        startDate: Date,
        endDate: Date
    ) {
        let normalizedStart = min(startDate, endDate)
        let normalizedEnd = max(startDate, endDate)
        switch operation {
        case .backup, .restore:
            Task { await performCloudRangeOperation(operation, from: normalizedStart, through: normalizedEnd) }
        case .deleteCloud:
            pendingCloudDeletionRange = normalizedStart...normalizedEnd
            showingCloudDeletionConfirmation = true
        case .deleteLocal:
            requestLocalFilesDeletion(from: normalizedStart, through: normalizedEnd)
        }
    }

    @MainActor
    private func performCloudRangeOperation(
        _ operation: RawDataRangeOperation,
        from startDate: Date,
        through endDate: Date
    ) async {
        isBackingUp = true
        defer { isBackingUp = false }
        do {
            switch operation {
            case .backup:
                let count = try await RawLocationStore.shared.backupToiCloud(
                    from: startDate,
                    through: endDate
                )
                backupStatus = "备份完成：共备份 \(count) 个文件"
                await loadCloudSummary()
            case .restore:
                let report = try await RawLocationStore.shared.restoreCloudTrajectories(
                    from: startDate,
                    through: endDate
                )
                backupStatus = "恢复完成：新增 \(report.restoredCount) 个，跳过本地已有 \(report.skippedExistingCount) 个"
                await loadFiles()
                locationManager.refreshAvailableRawDates()
                await locationManager.refreshForRecordingDeviceChange()
            case .deleteCloud, .deleteLocal:
                break
            }
        } catch {
            cloudManagementError = error.localizedDescription
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

    private func toggleSelectAll() {
        if selectedFileURLs.count == files.count {
            selectedFileURLs.removeAll()
        } else {
            selectedFileURLs = Set(files.map(\.url))
        }
    }

    private func requestDeletion(of fileURLs: [URL]) {
        guard !fileURLs.isEmpty else { return }
        pendingDeletionKind = .selection
        pendingDeletionURLs = fileURLs
        showingDeleteConfirmation = true
    }

    private func requestLocalFilesDeletion(from startDate: Date, through endDate: Date) {
        let fileURLs = files.map(\.url)
        Task {
            let matchingURLs = await Task.detached(priority: .utility) {
                Self.fileURLs(fileURLs, from: startDate, through: endDate)
            }.value
            await MainActor.run {
                guard !matchingURLs.isEmpty else {
                    localDeletionNotice = "所选日期范围内没有本地轨迹数据。"
                    return
                }
                pendingDeletionKind = .range(Self.rangeText(from: startDate, through: endDate))
                pendingDeletionURLs = matchingURLs
                showingDeleteConfirmation = true
            }
        }
    }

    nonisolated private static func fileURLs(
        _ fileURLs: [URL],
        from startDate: Date,
        through endDate: Date
    ) -> [URL] {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let startString = formatter.string(from: min(startDate, endDate))
        let endString = formatter.string(from: max(startDate, endDate))
        return fileURLs.filter {
            let dateString = String($0.deletingPathExtension().lastPathComponent.prefix(10))
            return dateString >= startString && dateString <= endString
        }
    }

    nonisolated private static func rangeText(from startDate: Date, through endDate: Date) -> String {
        let start = min(startDate, endDate).formatted(.dateTime.year().month().day())
        let end = max(startDate, endDate).formatted(.dateTime.year().month().day())
        return start == end ? start : "\(start) 至 \(end)"
    }

    private var localDeletionConfirmationTitle: String {
        switch pendingDeletionKind {
        case .selection:
            pendingDeletionURLs.count == 1
                ? "删除这个轨迹文件？"
                : "删除所选的 \(pendingDeletionURLs.count) 个轨迹文件？"
        case .range(let rangeText):
            "删除 \(rangeText) 的 \(pendingDeletionURLs.count) 个文件？"
        }
    }

    private var localDeletionConfirmationMessage: String {
        let scope: String
        switch pendingDeletionKind {
        case .selection:
            scope = "将永久删除此设备上的所选原始轨迹文件。"
        case .range(let rangeText):
            scope = "将永久删除此设备上 \(rangeText) 的原始轨迹文件。"
        }
        return scope + " 不会删除已提取的足迹或云端备份，也不会从 iCloud 自动恢复。"
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
    
}

private enum LocalDeletionKind {
    case selection
    case range(String)
}

private enum RawDataRangeOperation: String, Identifiable {
    case backup
    case restore
    case deleteCloud
    case deleteLocal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .backup: "选择备份范围"
        case .restore: "选择恢复范围"
        case .deleteCloud: "选择云端删除范围"
        case .deleteLocal: "选择本地删除范围"
        }
    }

    var actionTitle: String {
        switch self {
        case .backup: "备份所选日期"
        case .restore: "恢复所选日期"
        case .deleteCloud, .deleteLocal: "继续删除"
        }
    }

    var explanation: String {
        switch self {
        case .backup:
            "把范围内现有的本地原始轨迹复制到 iCloud。"
        case .restore:
            "从 iCloud 下载范围内的备份；本地已有文件会跳过，不会覆盖。"
        case .deleteCloud:
            "只删除范围内的云端备份，不影响本地文件。"
        case .deleteLocal:
            "只删除范围内的本地原始轨迹，不影响云端备份或已生成足迹。"
        }
    }
}

private struct RawDataRangePicker: View {
    let operation: RawDataRangeOperation
    let onConfirm: (Date, Date) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var startDate: Date
    @State private var endDate: Date

    init(operation: RawDataRangeOperation, onConfirm: @escaping (Date, Date) -> Void) {
        self.operation = operation
        self.onConfirm = onConfirm
        let today = Calendar.current.startOfDay(for: Date())
        _endDate = State(initialValue: today)
        _startDate = State(
            initialValue: Calendar.current.date(byAdding: .month, value: -1, to: today) ?? today
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("开始日期", selection: $startDate, displayedComponents: .date)
                    DatePicker("结束日期", selection: $endDate, in: startDate..., displayedComponents: .date)
                } footer: {
                    Text(operation.explanation)
                }

                Section {
                    Button(role: operation == .deleteCloud || operation == .deleteLocal ? .destructive : nil) {
                        onConfirm(startDate, endDate)
                        dismiss()
                    } label: {
                        Text(operation.actionTitle)
                            .frame(maxWidth: .infinity)
                    }
                    .dfkPrimaryActionButtonStyle()
                }
            }
            .navigationTitle(operation.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .onChange(of: startDate) { _, newValue in
                if endDate < newValue { endDate = newValue }
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
