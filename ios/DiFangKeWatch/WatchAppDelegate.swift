import WatchKit

/// Temporary instrumentation to find exactly where the background-update chain
/// breaks: app launch → background task delivery → WatchConnectivity receipt →
/// widget timeline reload. Each stage writes its own timestamp to the App Group
/// so WatchHomeView can show all of them at once instead of guessing from outside.
enum WatchDiagnostics {
    private static let groupID = "group.com.ct106.difangke"
    private static var defaults: UserDefaults? { UserDefaults(suiteName: groupID) }

    static func record(_ key: String, detail: String? = nil) {
        defaults?.set(Date(), forKey: "diag_\(key)_at")
        if let detail {
            defaults?.set(detail, forKey: "diag_\(key)_detail")
        }
    }

    static func date(_ key: String) -> Date? { defaults?.object(forKey: "diag_\(key)_at") as? Date }
    static func detail(_ key: String) -> String? { defaults?.string(forKey: "diag_\(key)_detail") }
}

/// `WKApplication.scheduleBackgroundRefresh` hard-crashes at call time if the app
/// has no `WKApplicationDelegate` implementing `handle(_:)` for background tasks —
/// this class exists solely to satisfy that requirement and drive the periodic wake
/// that keeps the complication from going stale (see the comment on `WatchStore`).
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    private static var pendingConnectivityTasks = [WKWatchConnectivityRefreshBackgroundTask]()
    private static var connectivityTaskTimeout: DispatchWorkItem?

    func applicationDidFinishLaunching() {
        WatchDiagnostics.record("appLaunch")
        // A complication/user-info delivery may launch the app while no
        // WindowGroup is created. Install the WCSession delegate here instead
        // of waiting for SwiftUI to build WatchHomeView's state object.
        WatchStore.shared.activateSession()
        Self.scheduleNextBackgroundRefresh()
    }

    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            if let connectivityTask = task as? WKWatchConnectivityRefreshBackgroundTask {
                // This firing at all proves watchOS woke the process for a
                // WatchConnectivity delivery. If this timestamp never advances
                // during a real test, the OS itself is not waking us — no
                // amount of tuning the transfer APIs on the phone side can fix that.
                WatchDiagnostics.record("backgroundTask", detail: "connectivity")
                // WatchConnectivity background delivery reaches this method before
                // WCSessionDelegate. Do not complete it yet: doing so suspends the
                // process before WatchStore can persist the new complication data.
                Self.pendingConnectivityTasks.append(connectivityTask)
                WatchStore.shared.activateSession()
                Self.scheduleConnectivityTaskTimeout()
                continue
            }

            guard let refreshTask = task as? WKApplicationRefreshBackgroundTask else {
                task.setTaskCompletedWithSnapshot(false)
                continue
            }
            WatchDiagnostics.record("backgroundTask", detail: "refresh")
            // The fallback wake must also establish the connectivity delegate.
            // SwiftUI may not construct a WindowGroup during this background run.
            WatchStore.shared.activateSession()
            // WatchStore already activated the WatchConnectivity session at launch;
            // waking the process is what lets it flush any application context the
            // phone sent while we were suspended. Linger briefly so that delivery —
            // and the resulting complication reload — lands before the task ends.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                Self.scheduleNextBackgroundRefresh()
                refreshTask.setTaskCompletedWithSnapshot(false)
            }
        }
    }

    /// Called by WatchStore only after a connectivity payload has been written to
    /// the App Group and WidgetKit has been asked to reload its timeline.
    static func completeConnectivityBackgroundTasks() {
        connectivityTaskTimeout?.cancel()
        connectivityTaskTimeout = nil
        let tasks = pendingConnectivityTasks
        pendingConnectivityTasks.removeAll()
        for task in tasks {
            task.setTaskCompletedWithSnapshot(false)
        }
    }

    private static func scheduleConnectivityTaskTimeout() {
        connectivityTaskTimeout?.cancel()
        let timeout = DispatchWorkItem {
            completeConnectivityBackgroundTasks()
        }
        connectivityTaskTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)
    }

    static func scheduleNextBackgroundRefresh() {
        WKApplication.shared().scheduleBackgroundRefresh(
            withPreferredDate: Date().addingTimeInterval(WatchStore.backgroundRefreshInterval),
            userInfo: nil
        ) { _ in }
    }
}
