import SwiftUI

@main
struct DiFangKeWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var appDelegate
    @StateObject private var store = WatchStore()

    var body: some Scene {
        WindowGroup {
            WatchHomeView()
                .environmentObject(store)
        }
    }
}
