import SwiftUI
import SwiftData
import CoreData
import Photos
import BackgroundTasks
import PhotosUI
import WidgetKit
import Aptabase


// Brand Theme Extensions
extension Color {
    static let dfkAccent = Color("AccentColor")
    static let dfkHighlight = Color(red: 1.0, green: 0.757, blue: 0.027) // #FFC107
    static let dfkCandidate = Color(red: 0.69, green: 0.745, blue: 0.773) // #B0BEC5
    static let dfkDeepRed = Color(red: 0.7, green: 0.0, blue: 0.0)
    static let dfkBackground = Color(uiColor: .systemBackground)
    static let dfkMainText = Color(uiColor: .label)
    static let dfkSecondaryText = Color(uiColor: .secondaryLabel)
}

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    
    /// BGAppRefreshTask 标识符，必须与 Info.plist 中的 BGTaskSchedulerPermittedIdentifiers 一致
    static let bgRefreshTaskID = "com.ct106.difangke.locationKeepAlive"
    
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        // Initialize Aptabase Analytics
        Aptabase.shared.initialize(appKey: AppConfig.shared.aptabaseAppKey)
        Aptabase.shared.trackEvent("app_started")
        
        // 注册远程通知是激活 iCloud 实时同步的关键，它能让设备及时收到云端的变更推送
        application.registerForRemoteNotifications()
        
        // 设置通知代理以响应通知点击
        UNUserNotificationCenter.current().delegate = self
        
        // ── 核心修复：无论前台还是后台启动，都立即激活 Significant Location Monitoring ──
        // 这是 iOS 唯一可以在 App 被系统杀死后自动重新启动的机制之一。
        // 必须在 didFinishLaunching 中调用，否则系统杀掉进程后不会因位置变化重新拉起。
        let isTrackingEnabled = UserDefaults.standard.object(forKey: "isTrackingEnabled") as? Bool ?? true
        if isTrackingEnabled {
            // 提前触发 LocationManager 单例初始化（内部会配置 CLLocationManager 并开启 Visit 监听）
            let _ = LocationManager.shared
            // 确保 Significant Location Changes 独立于 startTracking() 存在
            LocationManager.shared.ensureSignificantMonitoringActive()
            print("[AppDelegate] Significant location monitoring activated at launch.")
        }
        
        // ── 检测是否为系统因位置变化而重新启动的后台启动 ──
        if let _ = launchOptions?[.location] {
            print("[AppDelegate] ⚡ App relaunched by system due to location change!")
            // 强制启动完整追踪（包括 startUpdatingLocation、Region Monitoring 等）
            if isTrackingEnabled {
                LocationManager.shared.startTracking()
            }
        }
        
        // ── 注册 BGAppRefreshTask：定期唤醒以确保定位服务不被系统回收 ──
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.bgRefreshTaskID, using: nil) { task in
            guard let refreshTask = task as? BGAppRefreshTask else { return }
            self.handleBackgroundRefresh(task: refreshTask)
        }
        scheduleBackgroundRefresh()
        
        return true
    }
    
    // MARK: - BGAppRefreshTask 处理
    
    /// 调度下一次后台刷新（系统会在适当时机唤醒，通常 15 分钟 ~ 数小时不等）
    func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.bgRefreshTaskID)
        // 请求最早 15 分钟后执行（系统会根据用户使用模式智能调度）
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
            print("[AppDelegate] BGAppRefreshTask scheduled successfully.")
        } catch {
            print("[AppDelegate] Failed to schedule BGAppRefreshTask: \(error)")
        }
    }
    
    /// 后台刷新任务执行体：确认定位服务仍在运行，并重新调度下一次刷新
    private func handleBackgroundRefresh(task: BGAppRefreshTask) {
        print("[AppDelegate] ⏰ BGAppRefreshTask fired!")
        
        // 立即调度下一次，保持周期性唤醒
        scheduleBackgroundRefresh()
        
        task.expirationHandler = {
            print("[AppDelegate] BGAppRefreshTask expired.")
        }
        
        let isTrackingEnabled = UserDefaults.standard.object(forKey: "isTrackingEnabled") as? Bool ?? true
        if isTrackingEnabled {
            Task { @MainActor in
                // 确保定位服务仍然活跃
                LocationManager.shared.ensureSignificantMonitoringActive()
                
                // 如果定位更新已停止（系统可能在极端内存压力下停止），重新启动
                if !LocationManager.shared.isTracking {
                    print("[AppDelegate] Tracking was stopped, restarting...")
                    LocationManager.shared.startTracking()
                }
                
                // 请求一次精确定位，让系统知道我们仍需要位置服务
                LocationManager.shared.requestSingleLocation()
                
                task.setTaskCompleted(success: true)
            }
        } else {
            task.setTaskCompleted(success: true)
        }
    }
    
    // MARK: - 应用生命周期
    
    func applicationDidEnterBackground(_ application: UIApplication) {
        // 每次进入后台时重新调度后台刷新任务
        scheduleBackgroundRefresh()
    }
    
    // 处理用户点击通知进入 App 的行为
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        
        if let type = userInfo["type"] as? String, type == "highlight_footprint",
           let timestamp = userInfo["date"] as? Double {
            
            let date = Date(timeIntervalSince1970: timestamp)
            let idString = userInfo["footprintID"] as? String
            let footprintID = idString != nil ? UUID(uuidString: idString!) : nil
            
            // 核心修复：直接将 deepLinkDate 存入单例，防止冷启动时 NotificationCenter 丢失消息
            let dayStart = Calendar.current.startOfDay(for: date)
            LocationManager.shared.deepLinkDate = dayStart
            if let fid = footprintID {
                LocationManager.shared.deepLinkFootprintID = fid
            }
            
            // 使用 NotificationCenter 发送内部跳转通知 (供已在前台的 UI 捕获)
            var notificationInfo: [String: Any] = ["date": date]
            if let fid = footprintID {
                notificationInfo["footprintID"] = fid
            }
            
            NotificationCenter.default.post(
                name: NSNotification.Name("DFKDeepLinkNotification"),
                object: nil,
                userInfo: notificationInfo
            )
        }
        
        completionHandler()
    }
}

@main
struct DiFangKeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var locationManager = LocationManager.shared
    @AppStorage("isFirstLaunch") private var isFirstLaunch = true
    @State private var showSplash = true
    
    @State private var modelContainer: ModelContainer?
    
    init() {
        // We move the heavy ModelContainer initialization to a background task
        // but we need to ensure basic App setup is fast.
        print("[DiFangKeApp] Initializing...")
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let container = modelContainer {
                    ZStack {
                        if showSplash {
                            SplashScreenView()
                                .transition(.opacity)
                        } else if isFirstLaunch {
                            OnboardingView(isFirstLaunch: $isFirstLaunch, locationManager: locationManager)
                                .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
                        } else {
                            TimelineView()
                                .environment(locationManager)
                                .onAppear {
                                    CloudSettingsManager.shared.startSyncing()
                                    let context = container.mainContext
                                    locationManager.modelContext = context
                                    PhotoService.shared.modelContext = context
                                    OpenAIService.shared.modelContainer = container
                                    
                                    let isEnabled = UserDefaults.standard.object(forKey: "isTrackingEnabled") as? Bool ?? true
                                    if isEnabled {
                                        locationManager.startTracking()
                                    }
                                    
                                    setupDefaultData(context: context)
                                    WidgetDataSyncManager.shared.updateContainer(container)
                                }
                                .transition(.opacity)
                        }
                    }
                    .modelContainer(container)
                } else {
                    // While the model container is loading, show the splash screen
                    SplashScreenView()
                }
            }
            .animation(.easeInOut(duration: 0.8), value: showSplash)
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    let isEnabled = UserDefaults.standard.object(forKey: "isTrackingEnabled") as? Bool ?? true
                    if isEnabled {
                        locationManager.startTracking()
                    }
                    
                    // 前台启动后，延迟同步一下小组件，确保有足够时间生成图片
                    if modelContainer != nil {
                        Task {
                            try? await Task.sleep(nanoseconds: 3_000_000_000)
                            await WidgetDataSyncManager.shared.syncAll()
                        }
                    }
                } else if newPhase == .background {
                    if modelContainer != nil {
                        Task {
                            var bgTask: UIBackgroundTaskIdentifier = .invalid
                            bgTask = UIApplication.shared.beginBackgroundTask {
                                UIApplication.shared.endBackgroundTask(bgTask)
                                bgTask = .invalid
                            }
                            
                            await WidgetDataSyncManager.shared.syncAll()
                            
                            if bgTask != .invalid {
                                UIApplication.shared.endBackgroundTask(bgTask)
                                bgTask = .invalid
                            }
                        }
                    }
                    // 进入后台时重新调度 BGAppRefreshTask
                    (UIApplication.shared.delegate as? AppDelegate)?.scheduleBackgroundRefresh()
                }
            }
            .task {
                if modelContainer == nil {
                    await initializeModelContainer()
                }
                
                // 给初始化一点缓冲时间，让首页数据在后台能加载出一部分，避免首屏瞬间白屏或卡顿
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s 缓冲
                print("[DiFangKeApp] Dismissing splash screen...")
                withAnimation {
                    showSplash = false
                }
            }
        }
    }
    
    private func initializeModelContainer() async {
        // Existing installations were created with an unversioned SwiftData schema.
        // Keep opening that store directly so SwiftData can perform its normal
        // lightweight migration when FutureTrip is added.
        let schema = Schema([
            Footprint.self,
            Place.self,
            TransportManualSelection.self,
            ActivityType.self,
            DailyInsight.self,
            TransportRecord.self,
            FutureTrip.self
        ])
        
        let isFirstLaunch = !UserDefaults.standard.bool(forKey: "hasLaunchedBefore")
        let shouldEnableCloudKit = shouldUseCloudServices
        
        let modelConfiguration = ModelConfiguration(
            "dfk_v5_stable",
            schema: schema,
            isStoredInMemoryOnly: false,
            groupContainer: AppConfig.shared.appGroupID.isEmpty ? .none : .identifier(AppConfig.shared.appGroupID),
            cloudKitDatabase: shouldEnableCloudKit ? .automatic : .none
        )
        
        do {
            // 使用 Task.detached 确保在后台线程创建容器，绝对不阻塞主线程
            let container = try await Task.detached(priority: .userInitiated) {
                try ModelContainer(for: schema, configurations: [modelConfiguration])
            }.value
            await MainActor.run {
                FutureTripMigrationService.migrateLegacyTripsIfNeeded(context: ModelContext(container))
            }
            await MainActor.run {
                self.modelContainer = container
                UserDefaults.standard.set(shouldEnableCloudKit, forKey: "activeModelContainerUsesCloudKit")
                if isFirstLaunch {
                    UserDefaults.standard.set(true, forKey: "hasLaunchedBefore")
                }
                print("[DiFangKeApp] ModelContainer initialized successfully.")
            }
        } catch {
            print("SwiftData CRITICAL ERROR: \(error)")
            // Do not replace a failed persistent store with an empty in-memory
            // container. That makes all data appear deleted and risks users
            // creating new data against a non-persistent store.
        }
    }
    
    private var shouldUseCloudServices: Bool {
#if targetEnvironment(simulator)
        return false
#else
        let isICloudSyncEnabled = UserDefaults.standard.object(forKey: "isICloudSyncEnabled") as? Bool ?? true
        return isICloudSyncEnabled
#endif
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
                    buttonText: "继续"
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
                
                Button("暂不开启") {
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
    @State private var isVisible = false
    
    var body: some View {
        ZStack {
            Color.dfkBackground.ignoresSafeArea()
            Group {
                if UIImage(named: "AppLogo") != nil {
                    Image("AppLogo")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 120, height: 120)
                        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                } else {
                    // 兜底方案，防止资源加载失败导致空白
                    Image(systemName: "map.fill")
                        .font(.system(size: 80))
                        .foregroundColor(.dfkAccent)
                }
            }
            .scaleEffect(isVisible ? 1.0 : 0.8)
            .opacity(isVisible ? 1 : 0)
        }
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) {
                isVisible = true
            }
        }
    }
}
