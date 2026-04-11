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

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        // 注册远程通知是激活 iCloud 实时同步的关键，它能让设备及时收到云端的变更推送
        application.registerForRemoteNotifications()
        
        // 设置通知代理以响应通知点击
        UNUserNotificationCenter.current().delegate = self
        return true
    }
    
    // 处理用户点击通知进入 App 的行为
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        
        if let type = userInfo["type"] as? String, type == "highlight_footprint",
           let idString = userInfo["footprintID"] as? String,
           let footprintID = UUID(uuidString: idString),
           let timestamp = userInfo["date"] as? Double {
            
            let date = Date(timeIntervalSince1970: timestamp)
            
            // 使用 NotificationCenter 发送内部跳转通知
            NotificationCenter.default.post(
                name: NSNotification.Name("DFKDeepLinkNotification"),
                object: nil,
                userInfo: ["footprintID": footprintID, "date": date]
            )
        }
        
        completionHandler()
    }
}

@main
struct DiFangKeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var locationManager = LocationManager()
    @AppStorage("isFirstLaunch") private var isFirstLaunch = true
    @State private var showSplash = true
    
    @State private var modelContainer: ModelContainer
    
    init() {
        let schema = Schema([
            Footprint.self,
            Place.self,
            TransportManualSelection.self,
            ActivityType.self,
            DailyInsight.self,
            TransportRecord.self
        ])
        
        // 检测是否需要暂停同步（卸载重装且尚未决定时）
        let isFirstLaunch = !UserDefaults.standard.bool(forKey: "hasLaunchedBefore")
        let kvs = NSUbiquitousKeyValueStore.default
        kvs.synchronize()
        let hasHistoricalData = kvs.bool(forKey: "hasSeededDefaultData")
        
        // 如果是重装且还没做过选择，先不要开启 CloudKit
        let shouldPauseSync = isFirstLaunch && hasHistoricalData && !UserDefaults.standard.bool(forKey: "isSyncChoiceMade")
        
        let modelConfiguration = ModelConfiguration(
            "dfk_v5_stable",
            schema: schema, 
            isStoredInMemoryOnly: false,
            cloudKitDatabase: shouldPauseSync ? .none : .automatic
        )
        
        do {
            self._modelContainer = State(initialValue: try ModelContainer(for: schema, configurations: [modelConfiguration]))
            if isFirstLaunch {
                UserDefaults.standard.set(true, forKey: "hasLaunchedBefore")
            }
        } catch {
            print("SwiftData CRITICAL ERROR: \(error)")
            self._modelContainer = State(initialValue: try! ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
        }
    }

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
                            CloudSettingsManager.shared.startSyncing()
                            let context = modelContainer.mainContext
                            locationManager.modelContext = context
                            PhotoService.shared.modelContext = context
                            OpenAIService.shared.modelContainer = modelContainer
                            
                            // Only start tracking if enabled in settings
                            if UserDefaults.standard.bool(forKey: "isTrackingEnabled") {
                                locationManager.startTracking()
                            }
                            
                            // ...
                            
                            setupDefaultData(context: context)
                        }
                        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("RefreshModelContainer"))) { _ in
                            refreshContainer()
                        }
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.5), value: showSplash)
            .task {
                // 给初始化一点缓冲时间，让首页数据在后台能加载出一部分，避免首屏瞬间白屏或卡顿
                try? await Task.sleep(nanoseconds: 800_000_000) // 0.8s 缓冲
                print("[DiFangKeApp] Dismissing splash screen...")
                withAnimation {
                    showSplash = false
                }
            }
        }
        .modelContainer(modelContainer)
    }
    
    private func refreshContainer() {
        let schema = Schema([
            Footprint.self, Place.self, TransportManualSelection.self, ActivityType.self, DailyInsight.self
        ])
        let modelConfiguration = ModelConfiguration(
            "dfk_v5_stable",
            schema: schema, 
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .automatic
        )
        if let newContainer = try? ModelContainer(for: schema, configurations: [modelConfiguration]) {
            self.modelContainer = newContainer
            
            // 重要：重置所有服务所持有的 Context
            let context = newContainer.mainContext
            locationManager.modelContext = context
            PhotoService.shared.modelContext = context
            OpenAIService.shared.modelContainer = newContainer
            
            print("[DiFangKeApp] ModelContainer Refreshed with CloudKit enabled.")
        }
    }
    
    private func setupDefaultData(context: ModelContext) {
        // First check if we've already performed seeding on this or another synced device
        if UserDefaults.standard.bool(forKey: "hasSeededDefaultData") {
            return
        }
        
        let descriptor = FetchDescriptor<ActivityType>()
        guard let count = try? context.fetchCount(descriptor) else { return }
        
        // Only seed if empty. If it's not empty, it's either already seeded or synced from cloud.
        if count == 0 {
            print("[Setup] Database is empty and seeding flag is false, seeding initial presets...")
            for preset in ActivityType.presets {
                context.insert(preset)
            }
            try? context.save()
            // Notify other devices about new data
            CloudSettingsManager.shared.triggerDataSyncPulse()
        }
        
        // After seeding (or confirming data exists), set flag permanently
        UserDefaults.standard.set(true, forKey: "hasSeededDefaultData")
        print("[Setup] Seeding marked as complete.")
    }
    
    private func resumeUnfinishedAIAnalysis(context: ModelContext) {
        // 查找最近 100 个尚未进行过 AI 分析的足迹
        var descriptor = FetchDescriptor<Footprint>(
            predicate: #Predicate<Footprint> { $0.aiAnalyzed == false },
            sortBy: [SortDescriptor(\.startTime, order: .reverse)]
        )
        descriptor.fetchLimit = 100
        
        let container = context.container
        Task.detached(priority: .background) {
            let backgroundContext = ModelContext(container)
            if let unanalyzed = try? backgroundContext.fetch(descriptor), !unanalyzed.isEmpty {
                // 将待分析项的 ID 加入队列，由 OpenAIService 自行 fetch，避免 context 失效
                let identifiers = unanalyzed.map { $0.footprintID }
                await OpenAIService.shared.enqueueFootprintsForAnalysis(identifiers)
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
