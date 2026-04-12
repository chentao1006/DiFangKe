import SwiftUI
import CoreLocation

struct RawLogsManagerView: View {
    @State private var files: [RawFileItem] = []
    
    @State private var isSyncing = false
    @State private var syncStatus: String?
    
    @Environment(LocationManager.self) private var locationManager
    
    var body: some View {
        List {
            Section(header: Text("iCloud 同步")) {
                HStack {
                    VStack(alignment: .leading) {
                        Text("手动备份到云端")
                            .font(.headline)
                        if let lastSync = RawLocationStore.shared.lastSyncDate {
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
        isSyncing = true
        syncStatus = "正在同步文件..."
        
        do {
            let count = try await RawLocationStore.shared.syncToiCloud()
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
