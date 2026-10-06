import Foundation
import UserNotifications
import BackgroundTasks

class NotificationManager {
    static let shared = NotificationManager()
    private let newFootprintActivityCategoryID = "dfk.newFootprintActivity"

    // Keep this in the app's normal defaults, not an in-memory LocationManager
    // property: notification refresh is entered from location updates, timeline
    // rebuilds, settings changes, and footprint edits, including after relaunch.
    private let dailySummaryAIRequestKey = "lastDailySummaryAIRequestTimestamp"
    private let legacyDailySummaryAIRequestKey = "lastDailySummaryAIRequestAt"
    private let dailySummaryOverviewKey = "dailyNotificationOverviewSummary"
    private let dailySummaryOverviewDateKey = "dailyNotificationOverviewSummaryDate"
    private let dailySummaryAIRequestLock = NSLock()
    
    private init() {}

    func registerNotificationCategories() {
        let chooseAction = UNNotificationAction(identifier: "dfk.chooseActivity", title: "选择活动类型", options: [.foreground])
        let category = UNNotificationCategory(
            identifier: newFootprintActivityCategoryID,
            actions: [chooseAction],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().getNotificationCategories { categories in
            var updated = categories.filter { $0.identifier != self.newFootprintActivityCategoryID }
            updated.insert(category)
            UNUserNotificationCenter.current().setNotificationCategories(updated)
        }
    }
    
    func requestAuthorization(completion: ((Bool) -> Void)? = nil) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            DispatchQueue.main.async {
                if let error = error {
                    print("Notification permission error: \(error.localizedDescription)")
                }
                if granted {
                    let isEnabled = UserDefaults.standard.object(forKey: "isDailyNotificationEnabled") as? Bool ?? true
                    let hour = UserDefaults.standard.integer(forKey: "dailyNotificationHour")
                    let minute = UserDefaults.standard.integer(forKey: "dailyNotificationMinute")
                    let finalHour = UserDefaults.standard.object(forKey: "dailyNotificationHour") != nil ? hour : 21
                    self.updateDailySummary(isEnabled: isEnabled, hour: finalHour, minute: minute)
                }
                completion?(granted)
            }
        }
    }
    
    func refreshSettings() {
        let isEnabled = UserDefaults.standard.object(forKey: "isDailyNotificationEnabled") as? Bool ?? true
        let hour = UserDefaults.standard.integer(forKey: "dailyNotificationHour")
        let minute = UserDefaults.standard.integer(forKey: "dailyNotificationMinute")
        let finalHour = UserDefaults.standard.object(forKey: "dailyNotificationHour") != nil ? hour : 21
        self.updateDailySummary(isEnabled: isEnabled, hour: finalHour, minute: minute)
    }
    
    func getAuthorizationStatus(completion: @escaping (UNAuthorizationStatus) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                completion(settings.authorizationStatus)
            }
        }
    }
    
    // Dynamic scheduling based on Settings
    func updateDailySummary(isEnabled: Bool, hour: Int, minute: Int, title: String? = nil, body: String? = nil) {
        // A refreshed daily summary must not cancel other scheduled reminders
        // (past memories, etc.).  More importantly, cancelling
        // every request while the configured time is being reached can make
        // today's summary disappear before the system presents it.
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["dailySummary"])
        
        guard isEnabled else { 
            print("Notifications disabled by user.")
            return 
        }
        
        var dateComponents = DateComponents()
        dateComponents.hour = hour
        dateComponents.minute = minute
        
        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)
        
        let content = UNMutableNotificationContent()
        content.title = title ?? "每日足迹汇总"
        content.body = body ?? "忙碌的一天结束了，快来看看你今天留下的足迹吧。"
        content.sound = .default
        
        let request = UNNotificationRequest(identifier: "dailySummary", content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Failed to schedule notification: \(error)")
            } else {
                print("Successfully scheduled daily summary at \(hour):\(String(format: "%02d", minute)) with custom body: \(body != nil)")
            }
        }
    }
    
    func claimDailySummaryAIRequestIfNeeded() -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "isDailyNotificationEnabled") as? Bool ?? true,
              defaults.bool(forKey: "isAiAssistantEnabled") else { return false }

        // `object(forKey:) as? Date` silently treats a previously persisted
        // numeric/string value as missing.  That made each refresh path think
        // it owned a new one-hour window.  Store an explicit epoch timestamp
        // and migrate the older Date value once.
        dailySummaryAIRequestLock.lock()
        defer { dailySummaryAIRequestLock.unlock() }

        let now = Date().timeIntervalSince1970
        let lastRequest: TimeInterval
        if let timestamp = defaults.object(forKey: dailySummaryAIRequestKey) as? NSNumber {
            lastRequest = timestamp.doubleValue
        } else if let date = defaults.object(forKey: legacyDailySummaryAIRequestKey) as? Date {
            lastRequest = date.timeIntervalSince1970
        } else {
            lastRequest = 0
        }

        // Public capacity is shared and must be protected more aggressively.
        // A user-provided endpoint keeps the existing one-hour lower bound.
        let minimumInterval: TimeInterval = defaults.string(forKey: "aiServiceType") == "custom"
            ? 60 * 60
            : 3 * 60 * 60
        guard now - lastRequest >= minimumInterval else { return false }
        defaults.set(now, forKey: dailySummaryAIRequestKey)
        // Retain the legacy value for users who roll back to a preceding build.
        defaults.set(Date(timeIntervalSince1970: now), forKey: legacyDailySummaryAIRequestKey)
        return true
    }

    func refreshDailySummary(placeCount: Int, mileage: Double, transportCount: Int = 0, overviewSummary: String? = nil) {
        let isEnabled = UserDefaults.standard.object(forKey: "isDailyNotificationEnabled") as? Bool ?? true
        guard isEnabled else { return }
        
        // The daily summary is a view of persisted timeline facts. Raw location
        // samples must not make an otherwise empty day eligible for a summary.
        guard placeCount > 0 || transportCount > 0 else { return }
        
        let hour = UserDefaults.standard.integer(forKey: "dailyNotificationHour")
        let minute = UserDefaults.standard.integer(forKey: "dailyNotificationMinute")
        let finalHour = UserDefaults.standard.object(forKey: "dailyNotificationHour") != nil ? hour : 21

        let mileageStr = mileage < 1000 ? "\(Int(mileage))m" : String(format: "%.1fkm", mileage / 1000.0)
        let statsInfo = "今日在 \(placeCount) 个地点留下足迹，行程 \(mileageStr)。"
        let staticPreamble = "忙碌的一天结束了，快来看看你今天留下的足迹吧。"
        
        let isAiEnabled = UserDefaults.standard.bool(forKey: "isAiAssistantEnabled")
        let cachedOverview = cachedDailyOverviewSummary()
        let newOverview = overviewSummary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let effectiveOverview = newOverview.isEmpty ? cachedOverview : newOverview

        // A later location/settings refresh normally has no new AI result
        // because it is intentionally rate-limited.  Do not let that refresh
        // overwrite an already prepared notification with the static fallback.
        if !newOverview.isEmpty {
            cacheDailyOverviewSummary(newOverview)
        }
        
        let saysStayedHome = effectiveOverview?.contains("宅在家") == true || effectiveOverview?.contains("没出门") == true || effectiveOverview?.contains("在家休息") == true
        // Never let a stale/model-generated "stayed home" sentence contradict
        // recorded travel.  The factual stats remain visible either way.
        if isAiEnabled, let effectiveOverview, !effectiveOverview.isEmpty, !(transportCount > 0 && saysStayedHome) {
            let finalBody = "\(effectiveOverview)\n\(statsInfo)"
            self.updateDailySummary(isEnabled: true, hour: finalHour, minute: minute, title: "每日足迹汇总", body: finalBody)
        } else {
            self.updateDailySummary(isEnabled: true, hour: finalHour, minute: minute, title: "每日足迹汇总", body: "\(staticPreamble)\n\(statsInfo)")
        }
    }

    private func cachedDailyOverviewSummary() -> String? {
        let defaults = UserDefaults.standard
        guard let date = defaults.object(forKey: dailySummaryOverviewDateKey) as? Date,
              Calendar.current.isDateInToday(date),
              let summary = defaults.string(forKey: dailySummaryOverviewKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !summary.isEmpty else {
            return nil
        }
        return summary
    }

    private func cacheDailyOverviewSummary(_ summary: String) {
        let defaults = UserDefaults.standard
        defaults.set(summary, forKey: dailySummaryOverviewKey)
        defaults.set(Date(), forKey: dailySummaryOverviewDateKey)
    }

    func sendPastMemoriesNotification(title: String, body: String, footprintID: UUID? = nil, date: Date) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        
        var userInfo: [String: Any] = [
            "type": "highlight_footprint",
            "date": date.timeIntervalSince1970
        ]
        if let fid = footprintID {
            userInfo["footprintID"] = fid.uuidString
        }
        content.userInfo = userInfo
        
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Failed to send past-memories notification: \(error)")
            }
        }
    }

    /// The notification opens the saved footprint detail, where the complete activity picker
    /// is available. The persisted preference key is retained to preserve existing choices.
    func sendNewFootprintActivityNotification(title: String, body: String, footprintID: UUID, date: Date) {
        let isEnabled = UserDefaults.standard.object(forKey: "isHighlightNotificationEnabled") as? Bool ?? true
        guard isEnabled else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body + " 点此选择这次的活动类型。"
        content.sound = .default
        content.categoryIdentifier = newFootprintActivityCategoryID
        content.userInfo = [
            "type": "new_footprint_activity",
            "footprintID": footprintID.uuidString,
            "date": date.timeIntervalSince1970
        ]
        let request = UNNotificationRequest(identifier: "newFootprintActivity.\(footprintID.uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { print("Failed to send new-footprint activity notification: \(error)") }
        }
    }

    /// ActivityKit can't create a replacement Live Activity during an ordinary
    /// background location wake. Notify only when a confirmed tracking-state
    /// transition needs the user to reopen the app and restore it.
    func sendLiveActivityRecoveryNotification(isMoving: Bool) {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "isCurrentLiveActivityEnabled") == nil
                || defaults.bool(forKey: "isCurrentLiveActivityEnabled") else {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = isMoving ? "检测到正在移动" : "检测到正在停留"
        content.body = isMoving
            ? "点击查看当前行程。"
            : "点击查看当前足迹。"
        content.sound = .default
        content.userInfo = ["type": "resume_current_live_activity"]

        let request = UNNotificationRequest(
            identifier: "currentLiveActivityRecovery",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("Failed to send Live Activity recovery notification: \(error)")
            }
        }
    }

    /// The trip-plan feature has been removed. Older builds scheduled its
    /// reminders with a `trip_<uuid>[suffix]` identifier, so drop any that are
    /// still pending (or already delivered) so users stop receiving them.
    func removeLegacyTripNotifications() {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { requests in
            let identifiers = requests.map(\.identifier).filter { $0.hasPrefix("trip_") }
            guard !identifiers.isEmpty else { return }
            center.removePendingNotificationRequests(withIdentifiers: identifiers)
        }
        center.getDeliveredNotifications { notifications in
            let identifiers = notifications.map(\.request.identifier).filter { $0.hasPrefix("trip_") }
            guard !identifiers.isEmpty else { return }
            center.removeDeliveredNotifications(withIdentifiers: identifiers)
        }
    }
}
