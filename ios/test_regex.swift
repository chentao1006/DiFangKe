import Foundation

func cleanBasicSuffixes(from rawName: String) -> String? {
    var name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return nil }

    let strippingPatterns = [
        "\\d+\\s*[号弄室层楼栋座幢期区]",
        "[\\dA-Za-z一二三四五六七八九十]+[号楼栋座幢期区]",
        "[A-Za-z]\\s*[座栋区楼口]",
        "第?[一二三四五六七八九十\\d]+[单元部口]",
        "[东南西北]+门",
        "-\\s*.*$"
    ]

    for pattern in strippingPatterns {
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
            let range = NSRange(name.startIndex..., in: name)
            name = regex.stringByReplacingMatches(in: name, options: [], range: range, withTemplate: "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
    
    return name.isEmpty ? nil : name
}

func cleanAndFilterName(_ rawName: String) -> String? {
    guard let name = cleanBasicSuffixes(from: rawName) else { return nil }

    let finePatterns = [
        // 特定小地点及出入口
        "单元", "门牌", "入口", "出口", "门$", "站台", "公交站", "地铁口", "进站口", "出站口", "安检", "售票处", "检票口",
        
        // 零售与生活服务
        "柜台", "摊", "铺", "档口", "小卖部", "工作室", "修理", "维修", "营业厅", "门店",
        "分店", "便利店", "超市", "驿站", "快递", "中介", "洗衣", "美容", "美甲", "美发",
        "理发", "诊所", "药房", "药店", "公厕", "厕所", "洗手间", "ATM", "银行", "车行",
        "菜市场", "农贸市场", "菜场",
        
        // 餐饮与休闲
        "餐厅", "咖啡", "奶茶", "小店", "商铺", "快餐", "外卖", "茶饮", "甜品", "小吃",
        "烧烤", "火锅", "面馆", "粉店", "酒吧", "网吧", "烤肉", "料理", "大排档", "麻辣烫",
        "串串", "点心", "烘焙", "酒馆", "茶楼", "茶馆", "美食", "排骨", "鸭脖", "炸鸡", "汉堡", "炸串", "便当",
        
        // 排除所有以"店"结尾的名字，特赦"酒店"、"饭店"、"大店"
        "[^酒饭大]店$" 
    ]

    if finePatterns.contains(where: { name.range(of: $0, options: .regularExpression) != nil }) {
        return nil
    }

    return name
}

let testCases = [
    "国家大剧院",
    "首都体育馆",
    "万达影城(CBD店)",
    "第一人民医院",
    "清华大学",
    "故宫博物院",
    "奥林匹克森林公园",
    "北京展览馆",
    "北京展览馆1号门",
    "天安门广场",
    "朝阳大悦城",
    "海底捞火锅(望京店)",
    "工人体育场北门",
    "上海马戏城"
]

for tc in testCases {
    let result = cleanAndFilterName(tc) ?? "NIL"
    print("\(tc) -> \(result)")
}
