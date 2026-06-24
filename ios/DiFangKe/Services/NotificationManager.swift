import Foundation
import UserNotifications
import BackgroundTasks

class NotificationManager {
    static let shared = NotificationManager()
    
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
    
    func refreshDailySummary(footprintCount: Int, pointsCount: Int, mileage: Double, overviewSummary: String? = nil) {
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
        
        if isAiEnabled, let overviewSummary, !overviewSummary.isEmpty {
            let finalBody = "\(overviewSummary)\n\(statsInfo)"
            self.updateDailySummary(isEnabled: true, hour: finalHour, minute: minute, title: "每日足迹汇总", body: finalBody)
        } else {
            self.updateDailySummary(isEnabled: true, hour: finalHour, minute: minute, title: "每日足迹汇总", body: "\(staticPreamble)\n\(statsInfo)")
        }
    }

    func sendHighlightNotification(title: String, body: String, footprintID: UUID? = nil, date: Date) {
        let isEnabled = UserDefaults.standard.bool(forKey: "isHighlightNotificationEnabled")
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
        
        let notificationDate: Date
        if hasArrivalTime {
            notificationDate = arrivalDate.addingTimeInterval(-3600)
        } else {
            notificationDate = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: arrivalDate) ?? arrivalDate
        }
        
        guard notificationDate > Date() else { return }
        
        let content = UNMutableNotificationContent()
        content.title = "行程提醒"
        content.body = "您计划在 \(hasArrivalTime ? arrivalDate.formatted(date: .omitted, time: .shortened) : "今天") 到达 \(placeName)。"
        content.sound = .default
        content.userInfo = ["type": "future_trip", "tripID": tripID.uuidString]
        
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: notificationDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        
        let request = UNNotificationRequest(identifier: "trip_\(tripID.uuidString)", content: content, trigger: trigger)
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Failed to schedule trip notification: \(error)")
            }
        }
    }
    
    func cancelFutureTripNotification(for tripID: UUID) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["trip_\(tripID.uuidString)"])
    }
    
    func cancelAllFutureTripNotifications() {
        UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
            let tripIdentifiers = requests.filter { $0.identifier.hasPrefix("trip_") }.map { $0.identifier }
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: tripIdentifiers)
        }
    }
}
