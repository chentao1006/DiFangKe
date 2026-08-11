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
    
    func lighter(by percentage: CGFloat = 0.15) -> Color {
        var h: CGFloat = 0
        var s: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        guard UIColor(self).getHue(&h, saturation: &s, brightness: &b, alpha: &a) else {
            return self
        }
        return Color(hue: Double(h), saturation: Double(max(s - percentage, 0.0)), brightness: Double(min(b + percentage, 1.0)), opacity: Double(a))
    }
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
        NotificationManager.shared.registerNotificationCategories()
        // The initial install path does not necessarily visit Settings or
        // receive a cloud-settings update.  Ensure the user's persisted daily
        // reminder is always present after launch.
        NotificationManager.shared.refreshSettings()
        
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
                await WidgetDataSyncManager.shared.syncTodayOnly()
                await WidgetDataSyncManager.shared.syncRecentHistoryIfNeeded()
                WatchSyncManager.shared.syncHourlyIfNeeded()
                
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

        if userInfo["type"] as? String == "new_footprint_activity",
           let footprintID = userInfo["footprintID"] as? String {
            Task { @MainActor in
                if response.actionIdentifier == "dfk.chooseActivity" {
                    WatchSyncManager.shared.requestActivityPicker(for: footprintID)
                } else if response.actionIdentifier.hasPrefix("dfk.activity.") {
                    let activityID = String(response.actionIdentifier.dropFirst("dfk.activity.".count))
                    WatchSyncManager.shared.applyActivityChange(footprintID: footprintID, activityID: activityID)
                }
            }
        }
        
        if let type = userInfo["type"] as? String {
            if type == "highlight_footprint",
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
                var notificationInfo: [String: Any] = ["type": "highlight_footprint", "date": date]
                if let fid = footprintID {
                    notificationInfo["footprintID"] = fid
                }
                
                NotificationCenter.default.post(
                    name: NSNotification.Name("DFKDeepLinkNotification"),
                    object: nil,
                    userInfo: notificationInfo
                )
                
            } else if type == "future_trip",
                      let tripIDString = userInfo["tripID"] as? String,
                      let tripID = UUID(uuidString: tripIDString) {
                
                LocationManager.shared.deepLinkFutureTripID = tripID
                
                let notificationInfo: [String: Any] = ["type": "future_trip", "tripID": tripIDString]
                NotificationCenter.default.post(
                    name: NSNotification.Name("DFKDeepLinkNotification"),
                    object: nil,
                    userInfo: notificationInfo
                )
            }
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
    @State private var foregroundWidgetSyncTask: Task<Void, Never>?
    @State private var backgroundWidgetSyncTask: Task<Void, Never>?
    @State private var watchHourlySyncTask: Task<Void, Never>?
    
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
                            OnboardingView(isFirstLaunch: $isFirstLaunch, locationManager: locationManager) {
                                await initializeModelContainer()
                            }
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

                                    // Clean up duplicates created by older builds
                                    // before the timeline reads them.  New rebuilds
                                    // are guarded at insertion time as well.
                                    if DataDeduplicationService.deduplicateTransports(context: context) > 0 {
                                        TimelineBuilder.timelineCache.removeAll()
                                        NotificationCenter.default.post(name: NSNotification.Name("FootprintDataChanged"), object: nil)
                                    }
                                    
                                    let isEnabled = UserDefaults.standard.object(forKey: "isTrackingEnabled") as? Bool ?? true
                                    if isEnabled {
                                        locationManager.startTracking()
                                    }
                                    
                                    setupDefaultData(context: context)
                                    WidgetDataSyncManager.shared.updateContainer(container)
                                    WatchSyncManager.shared.start(context: context)
                                    Task {
                                        try? await Task.sleep(nanoseconds: 8_000_000_000)
                                        await WidgetDataSyncManager.shared.syncRecentHistoryIfNeeded()
                                    }
                                }
                                .transition(.opacity)
                        }
                    }
                    .task {
                        // Tracking can be active while the splash or onboarding
                        // is still on screen.  Bind the data context here rather
                        // than waiting for TimelineView.onAppear, otherwise the
                        // automatic timeline recovery never starts in that path.
                        print("[TimelineAuto] binding model context from app root")
                        locationManager.modelContext = container.mainContext
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
                    backgroundWidgetSyncTask?.cancel()
                    backgroundWidgetSyncTask = nil
                    watchHourlySyncTask?.cancel()
                    watchHourlySyncTask = Task {
                        while !Task.isCancelled {
                            WatchSyncManager.shared.syncHourlyIfNeeded()
                            try? await Task.sleep(nanoseconds: 60 * 60 * 1_000_000_000)
                        }
                    }

                    let isEnabled = UserDefaults.standard.object(forKey: "isTrackingEnabled") as? Bool ?? true
                    if isEnabled {
                        locationManager.startTracking()
                    }
                    
                    // Do not generate MapKit widget snapshots on every foreground
                    // transition: a snapshot still tearing down can overlap an
                    // in-app map and trigger Metal's lifetime assertion. Location
                    // changes and the background refresh still update the widget.
                    if modelContainer != nil {
                        foregroundWidgetSyncTask?.cancel()
                        foregroundWidgetSyncTask = Task {
                            // Give location/data recovery enough time after an app open before
                            // publishing the Watch snapshot.
                            try? await Task.sleep(nanoseconds: 30_000_000_000)
                            guard !Task.isCancelled else { return }
                            WatchSyncManager.shared.syncSnapshot()
                        }
                    }
                } else if newPhase == .background {
                    foregroundWidgetSyncTask?.cancel()
                    foregroundWidgetSyncTask = nil
                    watchHourlySyncTask?.cancel()
                    watchHourlySyncTask = nil

                    if modelContainer != nil {
                        backgroundWidgetSyncTask?.cancel()
                        backgroundWidgetSyncTask = Task {
                            var bgTask: UIBackgroundTaskIdentifier = .invalid
                            bgTask = UIApplication.shared.beginBackgroundTask {
                                UIApplication.shared.endBackgroundTask(bgTask)
                                bgTask = .invalid
                            }
                            
                            await WidgetDataSyncManager.shared.syncTodayOnly()
                            await WidgetDataSyncManager.shared.syncRecentHistoryIfNeeded(force: true)
                            WatchSyncManager.shared.syncHourlyIfNeeded()
                            
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
        if UserDefaults.standard.object(forKey: "isICloudSyncEnabled") == nil {
            // Default to false during onboarding to keep the initial DB local
            return false
        }
        let isICloudSyncEnabled = UserDefaults.standard.bool(forKey: "isICloudSyncEnabled")
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
    var onRebuildContainer: () async -> Void
    @State private var step = 0
    @State private var isRestoringData = false
    
    var body: some View {
        VStack {
            Spacer()
            
            if step == 0 {
                onboardingStep(
                    title: "记录走过的足迹",
                    description: "为了能在后台自动为您记录走过的足迹，地方客需要获取完整的位置权限。\n\n接下来的授权分为两步：请您在此次弹窗中选择「使用 App 时允许」。在之后的使用中，如果系统再次弹窗询问，请务必选择「更改为始终允许」，以确保后台记录不会中断。",
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
                    title: "更精准的足迹判定",
                    description: "结合您的运动状态（步行、骑行等），地方客可以更准确地判断您何时停留或离开，极大节省电量并提高记录准确度。",
                    image: "figure.walk",
                    color: .orange,
                    buttonText: "继续"
                ) {
                    HealthManager.shared.requestAuthorization { _ in
                        withAnimation {
                            step = 2
                        }
                    }
                }
                
            } else if step == 2 {
                onboardingStep(
                    title: "及时回顾每一天",
                    description: "开启通知，我们会在每天结束时为您推送今天的足迹汇总，绝不发送无用垃圾信息。",
                    image: "bell.badge.fill",
                    color: .red,
                    buttonText: "开启通知"
                ) {
                    NotificationManager.shared.requestAuthorization { _ in
                        withAnimation {
                            step = 3
                        }
                    }
                }
                
                Button("暂不开启") {
                    withAnimation {
                        step = 3
                    }
                }
                .padding(.top, 10)
                .foregroundColor(.secondary)
                
            } else if step == 3 {
                onboardingStep(
                    title: "AI 智能分析",
                    description: "开启 AI 助手为您自动总结地点特色，让足迹更有个性和温度。此功能可随时在设置中关闭。",
                    image: "sparkles",
                    color: .purple,
                    buttonText: "开启 AI 智能分析"
                ) {
                    UserDefaults.standard.set(true, forKey: "isAiAssistantEnabled")
                    checkCloudDataAndProceed()
                }
                
                Button("暂不开启") {
                    UserDefaults.standard.set(false, forKey: "isAiAssistantEnabled")
                    checkCloudDataAndProceed()
                }
                .padding(.top, 10)
                .foregroundColor(.secondary)
                
                Text("隐私受保护：AI 分析仅针对坐标和时长进行。我们将通过匿名处理进行概括，不涉及个人身份。")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 20)
                    .padding(.horizontal, 20)
            } else if step == 4 {
                if isRestoringData {
                    VStack(spacing: 30) {
                        ProgressView()
                            .scaleEffect(1.5)
                        
                        VStack(spacing: 12) {
                            Text("正在初始化同步并恢复数据...")
                                .font(.headline)
                            
                            Text("这可能需要几分钟，数据将在后台持续下载。")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                        }
                    }
                } else {
                    onboardingStep(
                        title: "发现云端同步记录",
                        description: "在 iCloud 中发现了您之前的记录。是否要开启 iCloud 同步并恢复数据？",
                        image: "icloud.and.arrow.down",
                        color: .blue,
                        buttonText: "开启同步并恢复数据"
                    ) {
                        UserDefaults.standard.set(true, forKey: "isICloudSyncEnabled")
                        withAnimation {
                            isRestoringData = true
                        }
                        
                        Task {
                            await onRebuildContainer()
                            // Show loading for a few seconds for visual feedback
                            try? await Task.sleep(nanoseconds: 3_000_000_000)
                            await MainActor.run {
                                withAnimation {
                                    isFirstLaunch = false
                                }
                            }
                        }
                    }
                    
                    Button(action: {
                        UserDefaults.standard.set(false, forKey: "isICloudSyncEnabled")
                        withAnimation {
                            isFirstLaunch = false
                        }
                    }) {
                        Text("不，作为新设备使用")
                            .font(.headline)
                            .foregroundColor(.primary)
                            .frame(maxWidth: UIDevice.current.userInterfaceIdiom == .pad ? 350 : .infinity)
                            .padding()
                            .background(
                                RoundedRectangle(cornerRadius: 14)
                                    .fill(Color(UIColor.secondarySystemBackground).opacity(0.5))
                                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                            )
                    }
                    .padding(.top, 10)
                }
            }
            
            Spacer()
        }
        .padding(30)
        .background(Color.dfkBackground)
    }
    
    private func checkCloudDataAndProceed() {
        NSUbiquitousKeyValueStore.default.synchronize()
        
        let hasCloudData = NSUbiquitousKeyValueStore.default.object(forKey: "hasSeededDefaultData") != nil 
                           || NSUbiquitousKeyValueStore.default.object(forKey: "isICloudSyncEnabled") != nil
                           || NSUbiquitousKeyValueStore.default.object(forKey: "dataSyncPulse") != nil
        
        if hasCloudData {
            withAnimation {
                step = 4
            }
        } else {
            // New user, enable sync by default
            UserDefaults.standard.set(true, forKey: "isICloudSyncEnabled")
            Task {
                await onRebuildContainer()
                await MainActor.run {
                    withAnimation {
                        isFirstLaunch = false
                    }
                }
            }
        }
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
                    .frame(maxWidth: UIDevice.current.userInterfaceIdiom == .pad ? 350 : .infinity)
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(color.opacity(0.8))
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                    )
                    .shadow(color: color.opacity(0.3), radius: 10, x: 0, y: 5)
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
