import SwiftUI
import CoreLocation
import CloudKit

struct RawLogsManagerView: View {
    @AppStorage(RawLocationStore.autoBackupEnabledKey) private var isAutoBackupEnabled = true

    @State private var files: [RawFileItem] = []
    
    @State private var isBackingUp = false
    @State private var operationStatus: (operation: RawDataRangeOperation, message: String)?
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
    @State private var cloudSummary: RawLocationStore.CloudStorageSummary?
    @State private var isLoadingCloudSummary = false
    @State private var cloudManagementError: String?
    @State private var isDeletingCloudData = false
    @State private var rangeOperation: RawDataRangeOperation?
    
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
                
                statusMessage(for: .backup)
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
                statusMessage(for: .restore)

                Button(role: .destructive) {
                    presentRangeOperation(.deleteCloud)
                } label: {
                    Label("批量删除云端备份", systemImage: "icloud.slash")
                }
                .disabled(isDeletingCloudData)
                statusMessage(for: .deleteCloud)
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
                        Label("批量删除本地数据", systemImage: "calendar.badge.minus")
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
            RawDataRangePicker(operation: operation, files: files) { start, end in
                Task { await performCloudRangeOperation(operation, from: start, through: end) }
            } onDelete: { selection in
                if operation == .deleteCloud { isDeletingCloudData = true } else { isDeleting = true }
                defer {
                    if operation == .deleteCloud { isDeletingCloudData = false } else { isDeleting = false }
                }
                switch try await selection.value.targets {
                case .cloud(let ids):
                    let count = try await RawLocationStore.shared.deleteCloudTrajectories(recordIDs: ids)
                    operationStatus = (.deleteCloud, "已删除 \(count) 个云端备份文件，本地轨迹未受影响")
                    await loadCloudSummary()
                case .local(let urls):
                    try await deleteFiles(urls)
                }
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

    @ViewBuilder
    private func statusMessage(for operation: RawDataRangeOperation) -> some View {
        if let status = operationStatus, status.operation == operation {
            Text(status.message)
                .font(.caption)
                .foregroundColor(.blue)
        }
    }

    private func presentRangeOperation(_ operation: RawDataRangeOperation) {
        rangeOperation = operation
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
                operationStatus = (.backup, "备份完成：共备份 \(count) 个文件")
                await loadCloudSummary()
            case .restore:
                let report = try await RawLocationStore.shared.restoreCloudTrajectories(
                    from: startDate,
                    through: endDate
                )
                operationStatus = (.restore, "恢复完成：新增 \(report.restoredCount) 个，跳过本地已有 \(report.skippedExistingCount) 个")
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
        pendingDeletionURLs = fileURLs
        showingDeleteConfirmation = true
    }

    private var localDeletionConfirmationTitle: String {
        pendingDeletionURLs.count == 1
            ? "删除这个轨迹文件？"
            : "删除所选的 \(pendingDeletionURLs.count) 个轨迹文件？"
    }

    private let localDeletionConfirmationMessage = "将永久删除此设备上的所选原始轨迹文件。不会删除已提取的足迹或云端备份，也不会从 iCloud 自动恢复。"

    private func deletePendingFiles() {
        let fileURLs = pendingDeletionURLs
        guard !fileURLs.isEmpty else { return }
        pendingDeletionURLs.removeAll()
        Task {
            isDeleting = true
            defer { isDeleting = false }
            do { try await deleteFiles(fileURLs) }
            catch { deleteError = error.localizedDescription }
        }
    }

    @MainActor
    private func deleteFiles(_ urls: [URL]) async throws {
        guard !urls.isEmpty else { return }
        do {
            try await RawLocationStore.shared.deleteLocalFiles(at: urls)
            await loadFiles()
            selectedFileURLs.subtract(urls)
            locationManager.refreshAvailableRawDates()
            if files.isEmpty { endSelection() }
        } catch {
            await loadFiles()
            throw error
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
        case .deleteCloud: "批量删除云端备份"
        case .deleteLocal: "批量删除本地轨迹"
        }
    }

    var isDeletion: Bool { self == .deleteCloud || self == .deleteLocal }

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
            "只删除早于截止日期的云端备份，不影响本地文件。"
        case .deleteLocal:
            "只删除早于截止日期的本地原始轨迹，不影响云端备份或已生成足迹。"
        }
    }
}

private struct RawDeletionPreview {
    enum Targets {
        case cloud([CKRecord.ID])
        case local([URL])

        var count: Int {
            switch self {
            case .cloud(let ids): ids.count
            case .local(let urls): urls.count
            }
        }
    }

    let period: RawDeletionPeriod
    let cutoff: String
    let targets: Targets
    let bytes: Int64?

    @concurrent
    static func load(period: RawDeletionPeriod, cloud: Bool, files: [RawFileItem]) async throws -> Self {
        guard let date = period.cutoff(on: Date()) else { throw CocoaError(.formatting) }
        let cutoff = RawLocationStore.DeletionCutoff(date: date)
        if cloud {
            let ids = try await RawLocationStore.shared.cloudDeletionIDs(before: cutoff)
            return Self(period: period, cutoff: cutoff.day, targets: .cloud(ids), bytes: nil)
        }
        let matches = files.filter { cutoff.includes(String($0.dateString.prefix(10))) }
        return Self(period: period, cutoff: cutoff.day, targets: .local(matches.map(\.url)),
                    bytes: matches.reduce(0) { $0 + $1.size })
    }

    var summary: String {
        guard let bytes else { return "\(targets.count) 个文件" }
        return "\(targets.count) 个文件，共 \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
    }
}

private struct RawDataRangePicker: View {
    let operation: RawDataRangeOperation
    let files: [RawFileItem]
    let onDelete: (Task<RawDeletionPreview, Error>) async throws -> Void
    let onConfirm: (Date, Date) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var startDate: Date
    @State private var endDate: Date

    @State private var period = AppConfig.shared.rawDeletionPeriods.last
    @State private var preview: RawDeletionPreview?
    @State private var previewError: String?
    @State private var deleting = false
    @State private var deletionFailure: String?
    @State private var confirming = false
    @State private var pendingSelection: (period: RawDeletionPeriod, task: Task<RawDeletionPreview, Error>)?

    private func selectionTask(for period: RawDeletionPeriod) -> Task<RawDeletionPreview, Error> {
        if let pendingSelection, pendingSelection.period == period { return pendingSelection.task }
        pendingSelection?.task.cancel()
        let task = Task { try await RawDeletionPreview.load(period: period, cloud: operation == .deleteCloud, files: files) }
        pendingSelection = (period, task)
        return task
    }

    init(operation: RawDataRangeOperation, files: [RawFileItem], onConfirm: @escaping (Date, Date) -> Void,
         onDelete: @escaping (Task<RawDeletionPreview, Error>) async throws -> Void) {
        self.files = files
        self.onDelete = onDelete
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
                    if operation.isDeletion {
                        Picker("删除多久前的数据", selection: $period) {
                            ForEach(AppConfig.shared.rawDeletionPeriods, id: \.self) { option in
                                Text(option.label).tag(Optional(option))
                            }
                        }
                        if let preview, preview.period == period {
                            LabeledContent("早于此日期", value: preview.cutoff)
                            LabeledContent("将删除", value: preview.summary)
                        } else if let previewError {
                            Text(previewError).foregroundStyle(.secondary)
                        } else {
                            ProgressView("正在统计文件…")
                        }
                    } else {
                        DatePicker("开始日期", selection: $startDate, displayedComponents: .date)
                        DatePicker("结束日期", selection: $endDate, in: startDate..., displayedComponents: .date)
                    }
                } footer: {
                    Text(operation.explanation)
                }

                Section {
                    Button(role: operation.isDeletion ? .destructive : nil) {
                        if operation.isDeletion {
                            confirming = true
                        } else {
                            onConfirm(startDate, endDate)
                            dismiss()
                        }
                    } label: {
                        Group {
                            if deleting {
                                ProgressView("正在删除…")
                            } else {
                                Text(operation.actionTitle)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .dfkPrimaryActionButtonStyle()
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .disabled(operation.isDeletion && (period == nil || (preview?.period == period && preview?.targets.count == 0)))
                    .confirmationDialog(operation.title + "？", isPresented: $confirming, titleVisibility: .visible) {
                        Button("永久删除", role: .destructive) {
                            guard !deleting, let period else { return }
                            deleting = true
                            let selection = selectionTask(for: period)
                            pendingSelection = nil
                            Task {
                                do {
                                    try await onDelete(selection)
                                    dismiss()
                                } catch {
                                    deleting = false
                                    preview = nil
                                    previewError = "请重新确认要删除的文件。"
                                    deletionFailure = error.localizedDescription
                                }
                            }
                        }
                        Button("取消", role: .cancel) {}
                    } message: {
                        if let preview, preview.period == period {
                            Text("将永久删除早于 \(preview.cutoff) 的 \(preview.summary)。")
                        } else if let period {
                            Text("将永久删除\(period.label)的\(operation == .deleteCloud ? "云端备份" : "本地轨迹文件")。")
                        }
                    }
                }
            }
            .disabled(deleting)
            .task(id: period) {
                guard operation.isDeletion else { return }
                preview = nil
                previewError = nil
                guard let period else {
                    previewError = "无法读取删除期限。"
                    return
                }
                do {
                    let result = try await selectionTask(for: period).value
                    try Task.checkCancellation()
                    preview = result
                } catch {
                    if !Task.isCancelled {
                        pendingSelection = nil
                        previewError = "无法完成统计：\(error.localizedDescription)"
                    }
                }
            }
            .onDisappear { pendingSelection?.task.cancel() }
            .navigationTitle(operation.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .disabled(deleting)
                }
            }
            .onChange(of: startDate) { _, newValue in
                if endDate < newValue { endDate = newValue }
            }
        }
        .interactiveDismissDisabled(deleting)
        .alert("删除失败", isPresented: Binding(
            get: { deletionFailure != nil },
            set: { if !$0 { deletionFailure = nil } }
        )) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(deletionFailure ?? "")
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
