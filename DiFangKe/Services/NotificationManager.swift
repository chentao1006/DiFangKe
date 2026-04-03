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
    
    func getAuthorizationStatus(completion: @escaping (UNAuthorizationStatus) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                completion(settings.authorizationStatus)
            }
        }
    }
    
    // Dynamic scheduling based on Settings
    func updateDailySummary(isEnabled: Bool, hour: Int, minute: Int, body: String? = nil) {
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
        content.title = "今日足迹回顾"
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
    
    func refreshDailySummary(with footprints: [Footprint]) {
        let isEnabled = UserDefaults.standard.object(forKey: "isDailyNotificationEnabled") as? Bool ?? true
        guard isEnabled else { return }
        
        // Only refresh if footprints exist
        guard !footprints.isEmpty else { return }
        
        let hour = UserDefaults.standard.integer(forKey: "dailyNotificationHour")
        let minute = UserDefaults.standard.integer(forKey: "dailyNotificationMinute")
        let finalHour = UserDefaults.standard.object(forKey: "dailyNotificationHour") != nil ? hour : 21

        let descriptions = footprints.compactMap { fp -> String? in
            if fp.status == .ignored { return nil }
            return fp.title
        }
        
        guard !descriptions.isEmpty else { return }

        OpenAIService.shared.generateDailySummary(footprintDescriptions: descriptions) { summary in
            self.updateDailySummary(isEnabled: true, hour: finalHour, minute: minute, body: summary)
        }
    }

    func sendHighlightNotification(title: String, body: String) {
        let isEnabled = UserDefaults.standard.bool(forKey: "isHighlightNotificationEnabled")
        guard isEnabled else { return }
        
        let content = UNMutableNotificationContent()
        content.title = "✨ \(title)"
        content.body = body
        content.sound = .default
        
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil) // Trigger nil means immediate
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Failed to send highlight notification: \(error)")
            }
        }
    }
}
