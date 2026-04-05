import Foundation
import SwiftData
import CoreLocation

@Observable
class TagService {
    static let shared = TagService()
    
    private init() {}
    
    /// 核心算法：基于物理距离 + 时间维度的双重智能筛选
    /// 仅保留在该位置及该时间段具有“规律性”的标签
    func findHistoricalTags(for lat: Double, longitude lon: Double, targetDate: Date = Date(), in context: ModelContext) -> [String] {
        let center = CLLocation(latitude: lat, longitude: lon)
        let inheritanceDistance: CLLocationDistance = 150.0
        
        // 1. 获取最近的 200 个足迹作为样本
        var descriptor = FetchDescriptor<Footprint>(
            sortBy: [SortDescriptor(\.startTime, order: .reverse)]
        )
        descriptor.fetchLimit = 200 
        
        guard let recent = try? context.fetch(descriptor) else { return [] }
        
        // 2. 时间维度权重统计
        var weightedFrequencies: [String: Double] = [:]
        var totalWeight: Double = 0.0
        var nearbyVisits = 0
        
        let targetCalendar = Calendar.current
        let targetHour = targetCalendar.component(.hour, from: targetDate)
        let targetIsWeekend = targetCalendar.isDateInWeekend(targetDate)
        
        for fp in recent {
            let fpLoc = CLLocation(latitude: fp.latitude, longitude: fp.longitude)
            if fpLoc.distance(from: center) <= inheritanceDistance {
                nearbyVisits += 1
                
                // 计算时间相似度权重 (0.1 ~ 1.0)
                let fpHour = targetCalendar.component(.hour, from: fp.startTime)
                let hourDiff = Double(min(abs(targetHour - fpHour), 24 - abs(targetHour - fpHour)))
                
                // 距离目标时间越近，权重越高 (0~12小时对应 1.0 ~ 0.0)
                var similarity = 1.0 - (hourDiff / 12.0)
                
                // 如果工作日/周末属性一致，增加权重（代表生活节奏的一致性）
                let fpIsWeekend = targetCalendar.isDateInWeekend(fp.startTime)
                if fpIsWeekend == targetIsWeekend {
                    similarity += 0.2
                }
                
                let weight = max(0.1, similarity)
                totalWeight += weight
                
                for tag in fp.tags {
                    weightedFrequencies[tag, default: 0.0] += weight
                }
                
                if nearbyVisits >= 30 { break } 
            }
        }
        
        // 只有当有足够样本时才进行推断
        guard nearbyVisits >= 2 && totalWeight > 0 else { return [] }
        
        // 3. 智能过滤：加权频率 > 40% 的标签被认为是“周期性规律”
        let stableTags = weightedFrequencies.filter { ($0.value / totalWeight) >= 0.4 }.map { $0.key }
        
        return stableTags.sorted()
    }
    
    /// 当删除一个全局标签时，同步清理所有足迹中的引用
    func deleteTag(_ tag: PlaceTag, in context: ModelContext, allFootprints: [Footprint]) {
        let nameToRemove = tag.name
        for footprint in allFootprints {
            if footprint.tags.contains(nameToRemove) {
                footprint.tags.removeAll(where: { $0 == nameToRemove })
            }
        }
        context.delete(tag)
        try? context.save()
    }
    
    /// 当重命名一个全局标签时，同步更新所有足迹中的引用
    /// 如果新名称已存在，则合并这两个标签
    func renameTag(oldName: String, newName: String, in tag: PlaceTag, allFootprints: [Footprint], in context: ModelContext) {
        let trimmedNewName = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmedNewName.isEmpty && trimmedNewName != oldName else { return }
        
        // 检查新名称是否已经存在
        let descriptor = FetchDescriptor<PlaceTag>()
        let allTags = (try? context.fetch(descriptor)) ?? []
        
        if allTags.contains(where: { $0.name == trimmedNewName }) {
            // 如果新名称已存在，删除当前的 tag (因为它将被合并到 existingTag 中)
            context.delete(tag)
        } else {
            // 如果不存在，直接重命名
            tag.name = trimmedNewName
        }
        
        // 同步更所有足迹
        for footprint in allFootprints {
            if let index = footprint.tags.firstIndex(of: oldName) {
                footprint.tags[index] = trimmedNewName
            }
        }
        
        try? context.save()
    }
    
    /// 清理并合并所有名称完全重复的标签
    func mergeDuplicateTags(in context: ModelContext) {
        let descriptor = FetchDescriptor<PlaceTag>(sortBy: [SortDescriptor(\.name)])
        guard let allTags = try? context.fetch(descriptor) else { return }
        
        var seenNames = Set<String>()
        for tag in allTags {
            if seenNames.contains(tag.name) {
                context.delete(tag)
            } else {
                seenNames.insert(tag.name)
            }
        }
        try? context.save()
    }
}
