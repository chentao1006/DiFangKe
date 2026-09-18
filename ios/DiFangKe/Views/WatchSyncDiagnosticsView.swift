import SwiftUI

/// Temporary diagnostics screen for tracking down why the Watch complication
/// isn't updating in the background. Reads the same trail WatchSyncManager
/// writes on every syncSnapshot() call, so a background-only failure can be
/// inspected here without a debugger attached.
struct WatchSyncDiagnosticsView: View {
    @State private var lines: [String] = []

    var body: some View {
        List {
            Section(footer: Text("每次 iPhone 尝试向手表同步数据时记录一行，最新的在最下面。用来确认 iPhone 端是否真的在后台尝试发送。")) {
                if lines.isEmpty {
                    Text("暂无记录").foregroundStyle(.secondary)
                } else {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                    }
                }
            }
            Button("清空记录") {
                UserDefaults.standard.removeObject(forKey: "diag_watchSync")
                lines = []
            }
        }
        .navigationTitle("手表同步诊断")
        .onAppear(perform: reload)
        .refreshable { reload() }
    }

    private func reload() {
        lines = (UserDefaults.standard.array(forKey: "diag_watchSync") as? [String]) ?? []
    }
}
