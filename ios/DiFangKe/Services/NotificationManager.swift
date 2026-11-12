import Foundation
import UserNotifications
import BackgroundTasks
import UIKit

class NotificationManager {
    static let shared = NotificationManager()
    private let newFootprintActivityCategoryID = "dfk.newFootprintActivity"
    static let liveActivityRecoveryNotificationID = "currentLiveActivityRecovery"
    private let preparedDailySummaryDateKey = "preparedDailySummaryDate"
    private let preparedDailySummaryBodyKey = "preparedDailySummaryBody"
    private let preparedDailySummaryOverviewKey = "preparedDailySummaryOverview"
    private let preparedDailySummaryStatsKey = "preparedDailySummaryStats"
    private let dailySummaryAttemptFingerprintKey = "dailySummaryAttemptFingerprint"
    static let dailySummaryBackgroundTaskID = "com.ct106.difangke.summary"
    @MainActor private var dailySummaryPreparationTask: Task<Void, Never>?
    @MainActor private var scheduledDailySummaryDate: Date?
    @MainActor private var preparingDailySummaryDate: Date?
    @MainActor private var preparedDailySummaryBody: (date: Date, body: String, overview: String?, stats: String?)?

    private init() {}

    @MainActor
    private func preparedDailySummary(for date: Date) -> (date: Date, body: String, overview: String?, stats: String?)? {
        let calendar = Calendar.current
        guard let fireDate = dailySummaryFireDate(on: date), date < fireDate else { return nil }
        if let preparedDailySummaryBody,
           calendar.isDate(preparedDailySummaryBody.date, inSameDayAs: date) {
            return preparedDailySummaryBody
        }

        let defaults = UserDefaults.standard
        guard let storedDate = defaults.object(forKey: preparedDailySummaryDateKey) as? Date,
              calendar.isDate(storedDate, inSameDayAs: date),
              let body = defaults.string(forKey: preparedDailySummaryBodyKey),
              !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let restored = (
            date: storedDate,
            body: body,
            overview: defaults.string(forKey: preparedDailySummaryOverviewKey),
            stats: defaults.string(forKey: preparedDailySummaryStatsKey)
        )
        preparedDailySummaryBody = restored
        return restored
    }

    @MainActor
    private func savePreparedDailySummary(body: String, overview: String?, stats: String) {
        let date = Date()
        preparedDailySummaryBody = (date, body, overview, stats)
        let defaults = UserDefaults.standard
        defaults.set(date, forKey: preparedDailySummaryDateKey)
        defaults.set(body, forKey: preparedDailySummaryBodyKey)
        defaults.set(stats, forKey: preparedDailySummaryStatsKey)
        if let overview, !overview.isEmpty {
            defaults.set(overview, forKey: preparedDailySummaryOverviewKey)
        } else {
            defaults.removeObject(forKey: preparedDailySummaryOverviewKey)
        }
    }

    private func factualDailySummaryBody(
        from prepared: (date: Date, body: String, overview: String?, stats: String?)
    ) -> String? {
        let stats = prepared.stats ?? prepared.body
            .split(separator: "\n")
            .map(String.init)
            .last(where: { $0.hasPrefix("今日在 ") })
        guard let stats, !stats.isEmpty else { return nil }
        return "忙碌的一天结束了，快来看看你今天留下的足迹吧。\n\(stats)"
    }

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

    func dailySummaryFireDate(on date: Date) -> Date? {
        let defaults = UserDefaults.standard
        let hour = defaults.object(forKey: "dailyNotificationHour") as? Int ?? 21
        let minute = defaults.integer(forKey: "dailyNotificationMinute")
        return Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: date)
    }

    /// Timing for initial scheduled preparation. Later structural changes are fingerprint-gated.
    var isDailySummaryPreparationDue: Bool {
        canPrepareDailySummary(allowEarly: false)
    }

    private func canPrepareDailySummary(
        allowEarly: Bool,
        allowingCompletedSummary: Bool = false,
        fingerprint: String? = nil
    ) -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "isDailyNotificationEnabled") as? Bool ?? true,
              defaults.bool(forKey: "isAiAssistantEnabled") else { return false }
        let now = Date()
        let leadTime = allowEarly ? AppConfig.shared.dailySummaryBackgroundPreparationLeadTime
            : AppConfig.shared.dailySummaryPreparationLeadTime
        guard let fireDate = dailySummaryFireDate(on: now),
              now < fireDate,
              now >= fireDate.addingTimeInterval(-leadTime) else {
            return false
        }
        if !allowingCompletedSummary,
           let completed = defaults.object(forKey: "dailySummaryCompletedDate") as? Date,
           Calendar.current.isDate(completed, inSameDayAs: now) { return false }
        if let attempted = defaults.object(forKey: "dailySummaryAttemptDate") as? Date,
           Calendar.current.isDate(attempted, inSameDayAs: now),
           defaults.string(forKey: dailySummaryAttemptFingerprintKey) == fingerprint {
            guard defaults.integer(forKey: "dailySummaryAttemptCount") < AppConfig.shared.dailySummaryMaxPreparationAttempts,
                  now.timeIntervalSince(attempted) >= AppConfig.shared.dailySummaryRetryInterval else { return false }
        }
        return true
    }

    /// Only notification preparation claims an attempt. Success, rather than merely entering
    /// the request path, completes the day. Failures have bounded retries per structural version.
    @MainActor
    func claimDailySummaryPreparation(
        for date: Date,
        allowEarly: Bool = false,
        allowingCompletedSummary: Bool = false,
        fingerprint: String? = nil
    ) -> Bool {
        guard Calendar.current.isDateInToday(date), preparingDailySummaryDate == nil,
              canPrepareDailySummary(
                allowEarly: allowEarly,
                allowingCompletedSummary: allowingCompletedSummary,
                fingerprint: fingerprint
              ) else { return false }
        let defaults = UserDefaults.standard
        let prior = defaults.object(forKey: "dailySummaryAttemptDate") as? Date
        let isSameAttempt = prior.map { Calendar.current.isDateInToday($0) } == true
            && defaults.string(forKey: dailySummaryAttemptFingerprintKey) == fingerprint
        let count = isSameAttempt
            ? defaults.integer(forKey: "dailySummaryAttemptCount") : 0
        defaults.set(count + 1, forKey: "dailySummaryAttemptCount")
        defaults.set(Date(), forKey: "dailySummaryAttemptDate")
        if let fingerprint {
            defaults.set(fingerprint, forKey: dailySummaryAttemptFingerprintKey)
        } else {
            defaults.removeObject(forKey: dailySummaryAttemptFingerprintKey)
        }
        preparingDailySummaryDate = date
        return true
    }

    func hasCompletedDailySummary(for date: Date) -> Bool {
        guard let completed = UserDefaults.standard.object(forKey: "dailySummaryCompletedDate") as? Date else {
            return false
        }
        return Calendar.current.isDate(completed, inSameDayAs: date)
    }

    @MainActor
    func finishDailySummaryPreparation(for date: Date, summary: String?) {
        preparingDailySummaryDate = nil
        if let summary, !summary.isEmpty {
            UserDefaults.standard.set(date, forKey: "dailySummaryCompletedDate")
        }
        scheduleDailySummaryPreparation(reschedule: true)
    }

    /// Actively reserve a foreground timer and the already-permitted background refresh task.
    /// A local notification's delivery itself does not execute application code.
    @MainActor
    func scheduleDailySummaryPreparation(reschedule: Bool = false) {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "isDailyNotificationEnabled") as? Bool ?? true,
              defaults.bool(forKey: "isAiAssistantEnabled") else {
            dailySummaryPreparationTask?.cancel()
            dailySummaryPreparationTask = nil
            scheduledDailySummaryDate = nil
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.dailySummaryBackgroundTaskID)
            return
        }
        guard preparingDailySummaryDate == nil else { return }
        let now = Date()
        guard var fireDate = dailySummaryFireDate(on: now) else { return }
        let completed = (defaults.object(forKey: "dailySummaryCompletedDate") as? Date)
            .map { Calendar.current.isDateInToday($0) } == true
        let exhausted = (defaults.object(forKey: "dailySummaryAttemptDate") as? Date)
            .map { Calendar.current.isDateInToday($0) } == true
            && defaults.integer(forKey: "dailySummaryAttemptCount") >= AppConfig.shared.dailySummaryMaxPreparationAttempts
        if fireDate <= now || completed || exhausted {
            guard let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now),
                  let nextFire = dailySummaryFireDate(on: tomorrow) else { return }
            fireDate = nextFire
        }
        guard reschedule || scheduledDailySummaryDate != fireDate else { return }
        dailySummaryPreparationTask?.cancel()
        scheduledDailySummaryDate = fireDate
        var preparationDate = fireDate.addingTimeInterval(-AppConfig.shared.dailySummaryPreparationLeadTime)
        if let attempted = defaults.object(forKey: "dailySummaryAttemptDate") as? Date,
           Calendar.current.isDate(attempted, inSameDayAs: fireDate) {
            preparationDate = max(preparationDate, attempted.addingTimeInterval(AppConfig.shared.dailySummaryRetryInterval))
        }
        let request = BGAppRefreshTaskRequest(identifier: Self.dailySummaryBackgroundTaskID)
        request.earliestBeginDate = max(now, preparationDate)
        do { try BGTaskScheduler.shared.submit(request) }
        catch { print("[DailySummary] Failed to schedule preparation: \(error)") }
        let delay = max(0, preparationDate.timeIntervalSinceNow)
        dailySummaryPreparationTask = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            catch { return }
            guard !Task.isCancelled else { return }
            self.dailySummaryPreparationTask = nil
            await LocationManager.shared.triggerNotificationSummaryRefresh(prepareAI: true)?.value
        }
    }
    
    // Dynamic scheduling based on Settings
    func updateDailySummary(isEnabled: Bool, hour: Int, minute: Int, title: String? = nil, body: String? = nil) {
        // A refreshed daily summary must not cancel other scheduled reminders
        // (past memories, etc.).  More importantly, cancelling
        // every request while the configured time is being reached can make
        // today's summary disappear before the system presents it.
        guard isEnabled else { 
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["dailySummary"])
            Task { @MainActor in self.scheduleDailySummaryPreparation() }
            print("Notifications disabled by user.")
            return 
        }
        
        var dateComponents = DateComponents()
        dateComponents.hour = hour
        dateComponents.minute = minute
        
        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)
        
        // Keep an already prepared body through settings refreshes; add() replaces the
        // matching identifier without a remove/add gap around the notification deadline.
        let content = UNMutableNotificationContent()
        content.title = title ?? "每日足迹汇总"
        content.body = body ?? "忙碌的一天结束了，快来看看你今天留下的足迹吧。"
        content.sound = .default
        
        Task { @MainActor in
            guard UserDefaults.standard.object(forKey: "isDailyNotificationEnabled") as? Bool ?? true else { return }
            if let prepared = self.preparedDailySummary(for: Date()) {
                if prepared.overview == nil || UserDefaults.standard.bool(forKey: "isAiAssistantEnabled") {
                    content.body = prepared.body
                } else if let factualBody = self.factualDailySummaryBody(from: prepared) {
                    content.body = factualBody
                }
            }
            self.scheduleDailySummaryPreparation()
            let request = UNNotificationRequest(identifier: "dailySummary", content: content, trigger: trigger)
            do {
                try await UNUserNotificationCenter.current().add(request)
                print("Successfully scheduled daily summary at \(hour):\(String(format: "%02d", minute)) with custom body: \(body != nil)")
            } catch {
                print("Failed to schedule notification: \(error)")
            }
        }
    }
    
    @MainActor
    func refreshDailySummary(placeCount: Int, mileage: Double, transportCount: Int = 0, overviewSummary: String? = nil) {
        let isEnabled = UserDefaults.standard.object(forKey: "isDailyNotificationEnabled") as? Bool ?? true
        guard isEnabled else { return }
        // Once today's reminder is due, don't replace tomorrow's reminder with today's facts.
        guard let fireDate = dailySummaryFireDate(on: Date()), Date() < fireDate else { return }
        
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
        // 统计始终独立更新；AI 概述复用到足迹或交通结构发生实质变化为止。
        let preparedOverview = preparedDailySummary(for: Date())?.overview
        let effectiveOverview = (overviewSummary ?? preparedOverview)?.trimmingCharacters(in: .whitespacesAndNewlines)
        
        let saysStayedHome = effectiveOverview?.contains("宅在家") == true || effectiveOverview?.contains("没出门") == true || effectiveOverview?.contains("在家休息") == true
        // Never let a stale/model-generated "stayed home" sentence contradict
        // recorded trip. The factual stats remain visible either way.
        if isAiEnabled, let effectiveOverview, !effectiveOverview.isEmpty, !(transportCount > 0 && saysStayedHome) {
            let finalBody = "\(effectiveOverview)\n\(statsInfo)"
            savePreparedDailySummary(body: finalBody, overview: effectiveOverview, stats: statsInfo)
            self.updateDailySummary(isEnabled: true, hour: finalHour, minute: minute, title: "每日足迹汇总", body: finalBody)
        } else {
            let finalBody = "\(staticPreamble)\n\(statsInfo)"
            savePreparedDailySummary(body: finalBody, overview: nil, stats: statsInfo)
            self.updateDailySummary(isEnabled: true, hour: finalHour, minute: minute, title: "每日足迹汇总", body: finalBody)
        }
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
        let kind: CurrentTrackingActivityKind = isMoving ? .transport : .footprint
        guard CurrentLiveActivitySettings.isEnabled(for: kind) else {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = isMoving ? "检测到正在移动" : "检测到正在停留"
        content.body = isMoving
            ? "点此查看当前行程，开启实时活动，持续追踪行程变化。"
            : "点此查看当前足迹，开启实时活动，持续追踪停留与出行。"
        content.sound = .default
        content.userInfo = ["type": "resume_current_live_activity"]

        let request = UNNotificationRequest(
            identifier: Self.liveActivityRecoveryNotificationID,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("Failed to send Live Activity recovery notification: \(error)")
                return
            }
            // The app may have become active while UserNotifications was
            // asynchronously adding this immediate request. Clear it after the
            // add completes as well, otherwise it can race the active callback.
            Task { @MainActor in
                guard UIApplication.shared.applicationState == .active else { return }
                self.removeLiveActivityRecoveryNotification()
            }
        }
    }

    /// Once the app is open, its Live Activity can recover directly. Remove only
    /// this recovery prompt and leave daily summaries and footprint alerts intact.
    func removeLiveActivityRecoveryNotification() {
        let center = UNUserNotificationCenter.current()
        let identifiers = [Self.liveActivityRecoveryNotificationID]
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
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
