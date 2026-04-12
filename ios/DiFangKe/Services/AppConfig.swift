import Foundation

class AppConfig {
    static let shared = AppConfig()
    
    private var config: [String: Any] = [:]
    
    private init() {
        loadConfig()
    }
    
    private func loadConfig() {
        guard let path = Bundle.main.path(forResource: "Config", ofType: "plist"),
              let dict = NSDictionary(contentsOfFile: path) as? [String: Any] else {
            print("⚠️ AppConfig: Failed to load Config.plist, using default values.")
            return
        }
        self.config = dict
    }
    
    func string(forKey key: String, defaultValue: String = "") -> String {
        return config[key] as? String ?? defaultValue
    }
    
    func double(forKey key: String, defaultValue: Double = 0.0) -> Double {
        if let val = config[key] as? Double {
            return val
        }
        if let val = config[key] as? Float {
            return Double(val)
        }
        return defaultValue
    }
    
    func int(forKey key: String, defaultValue: Int = 0) -> Int {
        return config[key] as? Int ?? defaultValue
    }
    
    // --- 算法专用便捷访问属性 ---
    
    var stayDistanceThreshold: Double {
        double(forKey: "STAY_DISTANCE_THRESHOLD", defaultValue: 200.0)
    }
    
    var mergeDistanceThreshold: Double {
        double(forKey: "MERGE_DISTANCE_THRESHOLD", defaultValue: 250.0)
    }
    
    var stayMergeGapThreshold: Double {
        double(forKey: "STAY_MERGE_GAP_THRESHOLD", defaultValue: 300.0)
    }
    
    var stayDurationThreshold: Double {
        double(forKey: "STAY_DURATION_THRESHOLD", defaultValue: 600.0)
    }
    
    var transportMinDistanceThreshold: Double {
        double(forKey: "TRANSPORT_MIN_DISTANCE_THRESHOLD", defaultValue: 50.0)
    }
    
    var transportMinDurationThreshold: Double {
        double(forKey: "TRANSPORT_MIN_DURATION_THRESHOLD", defaultValue: 60.0)
    }
    
    var gapFillingThreshold: Double {
        double(forKey: "GAP_FILLING_THRESHOLD", defaultValue: 600.0)
    }
    
    var serviceSecret: String {
        string(forKey: "SERVICE_SECRET", defaultValue: "")
    }
    
    var publicServiceUrl: String {
        string(forKey: "PUBLIC_SERVICE_URL", defaultValue: "")
    }
    
    var habitTimeWindow: Int {
        int(forKey: "HABIT_TIME_WINDOW_MINUTES", defaultValue: 120)
    }
    
    var habitFrequencyThreshold: Int {
        int(forKey: "HABIT_FREQUENCY_THRESHOLD", defaultValue: 3)
    }
}
