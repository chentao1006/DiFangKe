import WatchKit

/// `WKApplication.scheduleBackgroundRefresh` hard-crashes at call time if the app
/// has no `WKApplicationDelegate` implementing `handle(_:)` for background tasks —
/// this class exists solely to satisfy that requirement and drive the periodic wake
/// that keeps the complication from going stale (see the comment on `WatchStore`).
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    func applicationDidFinishLaunching() {
        Self.scheduleNextBackgroundRefresh()
    }

    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            guard let refreshTask = task as? WKApplicationRefreshBackgroundTask else {
                task.setTaskCompletedWithSnapshot(false)
                continue
            }
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

    static func scheduleNextBackgroundRefresh() {
        WKApplication.shared().scheduleBackgroundRefresh(
            withPreferredDate: Date().addingTimeInterval(WatchStore.backgroundRefreshInterval),
            userInfo: nil
        ) { _ in }
    }
}
