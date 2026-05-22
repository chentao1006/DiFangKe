import Foundation

enum LocationAccuracyMode: String, CaseIterable, Identifiable {
    case automatic = "automatic"
    case high = "high"
    case balanced = "balanced"
    case powerSaving = "powerSaving"
    
    var id: String { self.rawValue }
    
    static let userDefaultsKey = "locationAccuracyMode"
    
    var title: String {
        switch self {
        case .automatic: return "自动 (推荐)"
        case .high: return "高精度"
        case .balanced: return "均衡"
        case .powerSaving: return "省电"
        }
    }
    
    var description: String {
        switch self {
        case .automatic: return "根据活动状态智能调整定位精度，兼顾轨迹质量与电池续航。"
        case .high: return "强制保持最高精度定位，轨迹最准但耗电量大。"
        case .balanced: return "使用标准精度，适合日常通勤记录。"
        case .powerSaving: return "仅在移动距离较大时记录，最大程度省电。"
        }
    }
}
