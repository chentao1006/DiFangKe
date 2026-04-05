import SwiftUI
import SwiftData
import CoreData
import Photos
import PhotosUI

// Brand Theme Extensions
extension Color {
    static let dfkAccent = Color("AccentColor")
    static let dfkHighlight = Color(red: 1.0, green: 0.757, blue: 0.027) // #FFC107
    static let dfkCandidate = Color(red: 0.69, green: 0.745, blue: 0.773) // #B0BEC5
    static let dfkBackground = Color(uiColor: .systemBackground)
    static let dfkMainText = Color(uiColor: .label)
    static let dfkSecondaryText = Color(uiColor: .secondaryLabel)
}

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        // 注册远程通知是激活 iCloud 实时同步的关键，它能让设备及时收到云端的变更推送
        application.registerForRemoteNotifications()
        return true
    }
}

@main
struct DiFangKeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var locationManager = LocationManager()
    @AppStorage("isFirstLaunch") private var isFirstLaunch = true
    @State private var showSplash = true
    
    // Setup SwiftData container
    static var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Footprint.self,
            Place.self,
            PlaceTag.self,
            TransportManualSelection.self
        ])
        
        // 提升存储版本号以解决之前的 Schema 冲突导致的死锁闪退
        let modelConfiguration = ModelConfiguration(
            "dfk_v4_stable",
            schema: schema, 
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .automatic
        )
        
        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            // 如果初始化失败（可能是因为本地老数据 Schema 完全不兼容），尝试回退到内存模式以保证 App 启动
            do {
                return try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
            } catch {
                fatalError("Complete failure creating ModelContainer: \(error)")
            }
        }
    }()

    var body: some Scene {
        WindowGroup {
            ZStack {
                if showSplash {
                    SplashScreenView()
                        .transition(.opacity)
                } else if isFirstLaunch {
                    OnboardingView(isFirstLaunch: $isFirstLaunch, locationManager: locationManager)
                        .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
                } else {
                    ContentView()
                        .environment(locationManager)
                        .onAppear {
                            let context = Self.sharedModelContainer.mainContext
                            locationManager.modelContext = context
                            PhotoService.shared.modelContext = context
                            
                            // Only start tracking if enabled in settings
                            if UserDefaults.standard.bool(forKey: "isTrackingEnabled") {
                                locationManager.startTracking()
                            }
                            
                            // Initialize Notifications with saved settings
                            let isEnabled = UserDefaults.standard.object(forKey: "isDailyNotificationEnabled") as? Bool ?? true
                            let hour = UserDefaults.standard.integer(forKey: "dailyNotificationHour")
                            let minute = UserDefaults.standard.integer(forKey: "dailyNotificationMinute")
                            
                            // User default for hour/minute can be 0, but if it has never been set, we want 21:00
                            let finalHour = UserDefaults.standard.object(forKey: "dailyNotificationHour") != nil ? hour : 21
                            
                            NotificationManager.shared.updateDailySummary(
                                isEnabled: isEnabled, 
                                hour: finalHour, 
                                minute: minute
                            )
                            
                            setupDefaultData(context: context)
                            
                            // 启动后恢复未完成的 AI 分析
                            if UserDefaults.standard.bool(forKey: "isAiAssistantEnabled") {
                                resumeUnfinishedAIAnalysis(context: context)
                            }
                        }
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.5), value: showSplash)
            .task {
                // 做必要的极简初始化检查，完成后立即消失
                withAnimation {
                    showSplash = false
                }
            }
        }
        .modelContainer(Self.sharedModelContainer)
    }
    
    private func setupDefaultData(context: ModelContext) {
        // Seed Place Tags
        let tagDescriptor = FetchDescriptor<PlaceTag>()
        if let ts = try? context.fetch(tagDescriptor), ts.isEmpty {
            let defaults = ["餐饮", "购物", "休息", "工作", "运动", "聚会", "旅行", "娱乐", "健身", "教育", "社交", "差旅"]
            for name in defaults {
                context.insert(PlaceTag(name: name))
            }
        }
        
        try? context.save()
    }
    
    private func resumeUnfinishedAIAnalysis(context: ModelContext) {
        // 查找所有尚未进行过 AI 分析（isHighlight 为 nil）的足迹
        let descriptor = FetchDescriptor<Footprint>(
            predicate: #Predicate<Footprint> { $0.isHighlight == nil },
            sortBy: [SortDescriptor(\.startTime, order: .reverse)]
        )
        
        Task {
            if let unanalyzed = try? context.fetch(descriptor), !unanalyzed.isEmpty {
                // 将首批 50 个待分析项加入队列，避免冷启动压力过大
                let targetBatch = Array(unanalyzed.prefix(50))
                OpenAIService.shared.enqueueFootprintsForAnalysis(targetBatch)
            }
        }
    }
}

struct OnboardingView: View {
    @Binding var isFirstLaunch: Bool
    let locationManager: LocationManager
    @State private var step = 0
    
    var body: some View {
        VStack {
            Spacer()
            
            if step == 0 {
                onboardingStep(
                    title: "记录走过的足迹",
                    description: "地方客需要后台位置权限以自动记录您的足迹，我们将为您在本地生成精美的足迹卡片。",
                    image: "location.circle.fill",
                    color: Color.dfkAccent,
                    buttonText: locationManager.isAlwaysAuthorized ? "已开启始终允许" : (locationManager.isAuthorized ? "去设置开启始终允许" : "允许获取位置")
                ) {
                    if locationManager.authStatus == .authorizedWhenInUse && !locationManager.isAlwaysAuthorized {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } else {
                        locationManager.requestPermission()
                    }
                }
                .onAppear {
                    if locationManager.isAlwaysAuthorized {
                        withAnimation {
                            step = 1
                        }
                    }
                }
                .onChange(of: locationManager.isAuthorized) { _, newValue in
                    if newValue {
                        UserDefaults.standard.set(true, forKey: "isTrackingEnabled")
                        locationManager.startTracking()
                        withAnimation {
                            step = 1
                        }
                    }
                }
                
                // 给已经授权了“使用期间”的用户一个前进选项，或者引导他们点击主按钮去设置
                if locationManager.isAuthorized && !locationManager.isAlwaysAuthorized {
                    Button("暂时仅在使用期间允许") {
                        withAnimation {
                            step = 1
                        }
                    }
                    .padding()
                    .foregroundColor(.secondary)
                }
            } else if step == 1 {
                onboardingStep(
                    title: "AI 智能分析",
                    description: "开启 AI 助手为您自动总结地点特色，让足迹更有个性和温度。此功能可随时在设置中关闭。",
                    image: "sparkles",
                    color: .purple,
                    buttonText: "开启 AI 智能分析"
                ) {
                    UserDefaults.standard.set(true, forKey: "isAiAssistantEnabled")
                    withAnimation {
                        isFirstLaunch = false
                    }
                }
                
                Button("以后再说") {
                    UserDefaults.standard.set(false, forKey: "isAiAssistantEnabled")
                    withAnimation {
                        isFirstLaunch = false
                    }
                }
                .padding(.top, 10)
                .foregroundColor(.secondary)
                
                Text("隐私受保护：AI 分析仅针对坐标和时长进行。我们将通过匿名处理进行概括，不涉及个人身份。")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 20)
                    .padding(.horizontal, 20)
            }
            
            Spacer()
        }
        .padding(30)
        .background(Color.dfkBackground)
    }
    
    func onboardingStep(title: String, description: String, image: String, color: Color, buttonText: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 30) {
            Image(systemName: image)
                .font(.system(size: 100))
                .foregroundColor(color)
            
            VStack(spacing: 12) {
                Text(title)
                    .font(.title.bold())
                
                Text(description)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
            }
            
            Button(action: action) {
                Text(buttonText)
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(color)
                    .cornerRadius(14)
            }
        }
    }
}

// 品牌开屏页
struct SplashScreenView: View {
    var body: some View {
        ZStack {
            Color.dfkBackground.ignoresSafeArea()
            VStack(spacing: 20) {
                Image(systemName: "map.fill")
                    .font(.system(size: 80))
                    .foregroundColor(.dfkAccent)
                Text("地方客")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundColor(.dfkAccent)
            }
        }
    }
}
