import Foundation
import UserNotifications
import BackgroundTasks

class NotificationManager {
    static let shared = NotificationManager()

    // Keep this in the app's normal defaults, not an in-memory LocationManager
    // property: notification refresh is entered from location updates, timeline
    // rebuilds, settings changes, and footprint edits, including after relaunch.
    private let dailySummaryAIRequestKey = "lastDailySummaryAIRequestTimestamp"
    private let legacyDailySummaryAIRequestKey = "lastDailySummaryAIRequestAt"
    private let dailySummaryOverviewKey = "dailyNotificationOverviewSummary"
    private let dailySummaryOverviewDateKey = "dailyNotificationOverviewSummaryDate"
    private let dailySummaryAIRequestLock = NSLock()
    
    private init() {}
    
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
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        
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

    func refreshDailySummary(footprintCount: Int, pointsCount: Int, mileage: Double, transportCount: Int = 0, overviewSummary: String? = nil) {
        let isEnabled = UserDefaults.standard.object(forKey: "isDailyNotificationEnabled") as? Bool ?? true
        guard isEnabled else { return }
        
        // Only refresh if footprints or points exist
        guard footprintCount > 0 || pointsCount > 0 else { return }
        
        let hour = UserDefaults.standard.integer(forKey: "dailyNotificationHour")
        let minute = UserDefaults.standard.integer(forKey: "dailyNotificationMinute")
        let finalHour = UserDefaults.standard.object(forKey: "dailyNotificationHour") != nil ? hour : 21

        let mileageStr = mileage < 1000 ? "\(Int(mileage))m" : String(format: "%.1fkm", mileage / 1000.0)
        let statsInfo = "今日留下 \(footprintCount) 个足迹，行程 \(mileageStr)。"
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

    func sendHighlightNotification(title: String, body: String, footprintID: UUID? = nil, date: Date) {
        // Keep this default in sync with SettingsView's @AppStorage default.  `bool(forKey:)`
        // returns false for a missing key, which previously made existing users whose toggle
        // had never been changed appear to have disabled highlight notifications.
        let isEnabled = UserDefaults.standard.object(forKey: "isHighlightNotificationEnabled") as? Bool ?? true
        guard isEnabled else { return }
        
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
                print("Failed to send highlight notification: \(error)")
            }
        }
    }

    func scheduleFutureTripNotification(for tripID: UUID, placeName: String, arrivalDate: Date, hasArrivalTime: Bool) {
        let isEnabled = UserDefaults.standard.object(forKey: "isFutureTripNotificationEnabled") as? Bool ?? true
        guard isEnabled else { return }
        
        if hasArrivalTime {
            let preNotificationDate = arrivalDate.addingTimeInterval(-3600)
            if preNotificationDate > Date() {
                scheduleSingleFutureTripNotification(tripID: tripID, placeName: placeName, notificationDate: preNotificationDate, identifierSuffix: "_pre", isAtTime: false, arrivalDate: arrivalDate, hasArrivalTime: true)
            }
            
            if arrivalDate > Date() {
                scheduleSingleFutureTripNotification(tripID: tripID, placeName: placeName, notificationDate: arrivalDate, identifierSuffix: "_at", isAtTime: true, arrivalDate: arrivalDate, hasArrivalTime: true)
            }
        } else {
            let notificationDate0 = Calendar.current.date(bySettingHour: 0, minute: 0, second: 0, of: arrivalDate) ?? arrivalDate
            if notificationDate0 > Date() {
                scheduleSingleFutureTripNotification(tripID: tripID, placeName: placeName, notificationDate: notificationDate0, identifierSuffix: "_0", isAtTime: false, arrivalDate: arrivalDate, hasArrivalTime: false)
            }
            
            let notificationDate9 = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: arrivalDate) ?? arrivalDate
            if notificationDate9 > Date() {
                scheduleSingleFutureTripNotification(tripID: tripID, placeName: placeName, notificationDate: notificationDate9, identifierSuffix: "_9", isAtTime: false, arrivalDate: arrivalDate, hasArrivalTime: false)
            }
        }
    }
    
    private func scheduleSingleFutureTripNotification(tripID: UUID, placeName: String, notificationDate: Date, identifierSuffix: String, isAtTime: Bool, arrivalDate: Date, hasArrivalTime: Bool) {
        let content = UNMutableNotificationContent()
        content.title = "行程提醒"
        
        if isAtTime {
            content.body = "您计划的时间已到，地点：\(placeName)。"
        } else {
            if hasArrivalTime {
                content.body = "您计划在 \(arrivalDate.formatted(date: .omitted, time: .shortened)) 到达 \(placeName)，还有 1 小时。"
            } else {
                content.body = "您计划在 今天 到达 \(placeName)。"
            }
        }
        
        content.sound = .default
        content.userInfo = ["type": "future_trip", "tripID": tripID.uuidString]
        
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: notificationDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        
        let request = UNNotificationRequest(identifier: "trip_\(tripID.uuidString)\(identifierSuffix)", content: content, trigger: trigger)
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Failed to schedule trip notification: \(error)")
            }
        }
    }
    
    func cancelFutureTripNotification(for tripID: UUID) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [
            "trip_\(tripID.uuidString)",
            "trip_\(tripID.uuidString)_pre",
            "trip_\(tripID.uuidString)_at",
            "trip_\(tripID.uuidString)_0",
            "trip_\(tripID.uuidString)_9"
        ])
    }
    
    func cancelAllFutureTripNotifications() {
        UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
            let tripIdentifiers = requests.filter { $0.identifier.hasPrefix("trip_") }.map { $0.identifier }
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: tripIdentifiers)
        }
    }
}
