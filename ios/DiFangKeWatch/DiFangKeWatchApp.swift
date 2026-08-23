import SwiftUI

@main
struct DiFangKeWatchApp: App {
    @StateObject private var store = WatchStore()

    var body: some Scene {
        WindowGroup {
            WatchHomeView()
                .environmentObject(store)
                .tint(.teal)
        }
        .backgroundTask(.appRefresh(WatchStore.backgroundRefreshTaskID)) {
            await store.handleBackgroundRefresh()
        }
    }
}
