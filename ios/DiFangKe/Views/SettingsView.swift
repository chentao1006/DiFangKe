import SwiftUI
import SwiftData
import StoreKit

struct SettingsView: View {
    @Environment(\.requestReview) private var requestReview
    @Environment(LocationManager.self) private var locationManager
    @AppStorage("isTrackingEnabled") private var isTrackingEnabled = true
    @Query(sort: \Place.name) private var allPlaces: [Place]
    @Query(sort: [SortDescriptor(\ActivityType.sortOrder)]) private var allActivities: [ActivityType]
    @AppStorage("isICloudSyncEnabled") private var isICloudSyncEnabled = false
    @AppStorage("raw_recording_source_device_id") private var rawRecordingSourceDeviceID = ""
    @AppStorage("isAiAssistantEnabled") private var isAiAssistantEnabled = false
    @AppStorage("isAutoPhotoLinkEnabled") private var isAutoPhotoLinkEnabled = true
    @AppStorage("aiServiceType") private var aiServiceType = "public"
    @AppStorage(LocationAccuracyMode.userDefaultsKey) private var locationAccuracyModeRaw = LocationAccuracyMode.automatic.rawValue

    private var useCurrentDeviceForRawRecordingBinding: Binding<Bool> {
        Binding(
            get: {
                rawRecordingSourceDeviceID == RawLocationStore.shared.currentDeviceIdentifier
            },
            set: { useCurrentDevice in
                let currentDeviceID = RawLocationStore.shared.currentDeviceIdentifier
                if useCurrentDevice {
                    rawRecordingSourceDeviceID = currentDeviceID
                    RawLocationStore.shared.setPreferredRecordingDeviceID(currentDeviceID)
                } else if rawRecordingSourceDeviceID == currentDeviceID {
                    rawRecordingSourceDeviceID = ""
                    RawLocationStore.shared.setPreferredRecordingDeviceID("")
                }
            }
        )
    }

    private var locationAccuracyModeBinding: Binding<LocationAccuracyMode> {
        Binding(
            get: { LocationAccuracyMode(rawValue: locationAccuracyModeRaw) ?? .automatic },
            set: { mode in
                locationAccuracyModeRaw = mode.rawValue
                locationManager.applyLocationAccuracyMode()
                if isTrackingEnabled {
                    locationManager.startTracking()
                }
            }
        )
    }

    private var selectedLocationAccuracyMode: LocationAccuracyMode {
        LocationAccuracyMode(rawValue: locationAccuracyModeRaw) ?? .automatic
    }
    
    var body: some View {
        Form {

            Section(header: Text("隐私与记录")) {
                Toggle("开启定位记录", isOn: $isTrackingEnabled)
                    .onChange(of: isTrackingEnabled) { oldValue, newValue in
                        if newValue {
                            locationManager.startTracking()
                        } else {
                            locationManager.stopTracking()
#if canImport(ActivityKit)
                            if #available(iOS 16.1, *) {
                                CurrentLiveActivityManager.shared.stop()
                            }
#endif
                        }
                    }

                if isTrackingEnabled && locationManager.isAuthorized {
                    NavigationLink {
                        Form {
                            ForEach(LocationAccuracyMode.allCases) { mode in
                                Button {
                                    locationAccuracyModeBinding.wrappedValue = mode
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(mode.title)
                                                .foregroundColor(.primary)
                                            Text(mode.description)
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                                .multilineTextAlignment(.leading)
                                        }
                                        Spacer()
                                        if selectedLocationAccuracyMode == mode {
                                            Image(systemName: "checkmark")
                                                .foregroundColor(.dfkAccent)
                                        }
                                    }
                                }
                            }
                        }
                        .navigationTitle("定位精度")
                        .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        HStack {
                            Text("定位精度")
                            Spacer()
                            Text(selectedLocationAccuracyMode.title)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Toggle("开启 iCloud 同步", isOn: $isICloudSyncEnabled)
                if isTrackingEnabled && isICloudSyncEnabled {
                    Toggle("以当前设备记录为准", isOn: useCurrentDeviceForRawRecordingBinding)
                }
                Toggle("自动关联照片到足迹", isOn: $isAutoPhotoLinkEnabled)

                NavigationLink {
                    HealthSettingsView()
                } label: {
                    Text("Apple 健康")
                }

                NavigationLink {
                    LiveActivitySettingsView()
                } label: {
                    Text("实时活动")
                }
            }
            
            .task(id: rawRecordingSourceDeviceID) {
                await locationManager.refreshForRecordingDeviceChange()
            }
            .onChange(of: isICloudSyncEnabled) { _, _ in
                Task { @MainActor in
                    await locationManager.refreshForRecordingDeviceChange()
                }
            }
            Section(header: Text("地点管理")) {
                NavigationLink(destination: PlacesManagerView()) {
                    HStack {
                        Label {
                            Text("重要地点").foregroundColor(.primary)
                        } icon: {
                            Image(systemName: "mappin.circle").foregroundColor(.orange)
                        }
                        Spacer()
                        let importantCount = allPlaces.filter { $0.isUserDefined }.count
                        Text("\(importantCount)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                NavigationLink(destination: SavedPlacesView()) {
                    HStack {
                        Label {
                            Text("已保存地点").foregroundColor(.primary)
                        } icon: {
                            Image(systemName: "clock.arrow.circlepath").foregroundColor(.blue)
                        }
                        Spacer()
                        let savedCount = allPlaces.filter { !$0.isUserDefined && !$0.isIgnored }.count
                        Text("\(savedCount)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }

                NavigationLink(destination: IgnoredPlacesView()) {
                    HStack {
                        Label {
                            Text("已忽略地点").foregroundColor(.primary)
                        } icon: {
                            Image(systemName: "mappin.slash").foregroundColor(.secondary)
                        }
                        Spacer()
                        let ignoredCount = allPlaces.filter { $0.isIgnored && !$0.isUserDefined }.count
                        Text("\(ignoredCount)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                
                NavigationLink(destination: ActivityTypeSettingsView()) {
                    HStack {
                        Label {
                            Text("活动类型").foregroundColor(.primary)
                        } icon: {
                            Image(systemName: "tag.circle").foregroundColor(.green)
                        }
                        Spacer()
                        Text("\(allActivities.count)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Section {
                NavigationLink("推送通知") {
                    NotificationSettingsView()
                }
            }
            
            Section(header: Text("系统配置"), footer: Text("智能分析服务将根据您的地点历史自动建议标题。")) {
                Toggle("AI 智能辅助", isOn: $isAiAssistantEnabled)
                if isAiAssistantEnabled {
                    NavigationLink(destination: AiSettingsView()) {
                        HStack {
                            Text("AI 服务配置")
                            Spacer()
                            Text(aiServiceType == "custom" ? "自定义" : "公共服务")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            
            Section {
                NavigationLink("数据备份与清理") {
                    DataManagerView()
                }
            }

            Section(header: Text("关于")) {
                HStack {
                    Text("版本号")
                    Spacer()
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")
                        .foregroundColor(.secondary)
                }
                
                Button(action: {
                    if let url = URL(string: "https://ct106.com") {
                        UIApplication.shared.open(url)
                    }
                }) {
                    HStack {
                        Text("作者主页")
                        Spacer()
                        Text("ct106.com")
                            .foregroundColor(.secondary)
                    }
                }
                .foregroundColor(.primary)
                
                Button(action: {
                    if let url = URL(string: "https://github.com/chentao1006/DiFangKe/issues") {
                        UIApplication.shared.open(url)
                    }
                }) {
                    HStack {
                        Text("反馈建议")
                        Spacer()
                        Text("GitHub Issues")
                            .foregroundColor(.secondary)
                    }
                }
                .foregroundColor(.primary)
                
                Button(action: {
                    requestReview()
                }) {
                    Text("给个好评")
                }
                .foregroundColor(.dfkAccent)
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.large)
        .tint(.dfkAccent)
    }
}

private struct NotificationSettingsView: View {
    @Environment(LocationManager.self) private var locationManager
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("dailyNotificationHour") private var notificationHour: Int = 21
    @AppStorage("dailyNotificationMinute") private var notificationMinute: Int = 0
    @AppStorage("isDailyNotificationEnabled") private var isDailyNotificationEnabled = true
    @AppStorage("isHighlightNotificationEnabled") private var isHighlightNotificationEnabled = true
    @AppStorage("isPastMemoriesNotificationEnabled") private var isPastMemoriesNotificationEnabled = true
    @State private var showingSettingsAlert = false
    @State private var isSystemNotificationEnabled = false

    private var notificationTime: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(
                    bySettingHour: notificationHour,
                    minute: notificationMinute,
                    second: 0,
                    of: Date()
                ) ?? Date()
            },
            set: {
                let components = Calendar.current.dateComponents([.hour, .minute], from: $0)
                notificationHour = components.hour ?? 21
                notificationMinute = components.minute ?? 0
            }
        )
    }

    var body: some View {
        Form {
            Section {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    HStack {
                        Text("允许通知")
                            .foregroundStyle(.primary)
                        Spacer()
                        Toggle("", isOn: .constant(isSystemNotificationEnabled))
                            .labelsHidden()
                            .allowsHitTesting(false)
                    }
                    .contentShape(Rectangle())
                }
            } footer: {
                Text("通知总开关由系统管理，点此前往地方客的系统设置。")
            }

            if isSystemNotificationEnabled {
                Section("通知内容") {
                    Toggle("每日足迹汇总", isOn: $isDailyNotificationEnabled)
                        .onChange(of: isDailyNotificationEnabled) { _, newValue in
                            if newValue {
                                NotificationManager.shared.requestAuthorization { granted in
                                    if granted {
                                        updateNotifications()
                                    } else {
                                        isDailyNotificationEnabled = false
                                        showingSettingsAlert = true
                                    }
                                }
                            } else {
                                updateNotifications()
                            }
                        }
                    if isDailyNotificationEnabled {
                        DatePicker("通知时间", selection: notificationTime, displayedComponents: .hourAndMinute)
                            .onChange(of: notificationHour) { _, _ in updateNotifications() }
                            .onChange(of: notificationMinute) { _, _ in updateNotifications() }
                    }

                    Toggle("新地点足迹提醒", isOn: $isHighlightNotificationEnabled)
                        .onChange(of: isHighlightNotificationEnabled) { _, newValue in
                            requestAuthorizationIfNeeded(newValue) {
                                isHighlightNotificationEnabled = false
                            }
                        }

                    Toggle("往年今日提醒", isOn: $isPastMemoriesNotificationEnabled)
                        .onChange(of: isPastMemoriesNotificationEnabled) { _, newValue in
                            requestAuthorizationIfNeeded(newValue) {
                                isPastMemoriesNotificationEnabled = false
                            }
                        }
                }
            }
        }
        .navigationTitle("推送通知")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            refreshSystemNotificationStatus()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                refreshSystemNotificationStatus()
            }
        }
        .alert("需要通知权限", isPresented: $showingSettingsAlert) {
            Button("取消", role: .cancel) { }
            Button("前往设置") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
        } message: {
            Text("您已在系统中关闭了应用的通知权限，为及时收到足迹汇总提醒，请前往系统设置中开启。")
        }
    }

    private func refreshSystemNotificationStatus() {
        NotificationManager.shared.getAuthorizationStatus { status in
            isSystemNotificationEnabled = status == .authorized
                || status == .provisional
                || status == .ephemeral
        }
    }

    private func requestAuthorizationIfNeeded(_ isEnabled: Bool, onDenied: @escaping () -> Void) {
        guard isEnabled else { return }
        NotificationManager.shared.requestAuthorization { granted in
            guard !granted else { return }
            onDenied()
            showingSettingsAlert = true
        }
    }

    private func updateNotifications() {
        NotificationManager.shared.updateDailySummary(
            isEnabled: isDailyNotificationEnabled,
            hour: notificationHour,
            minute: notificationMinute
        )

        if isDailyNotificationEnabled,
           Calendar.current.component(.hour, from: Date()) >= 18 {
            locationManager.triggerNotificationSummaryRefresh()
        }
    }
}

private struct LiveActivitySettingsView: View {
    @Environment(LocationManager.self) private var locationManager
    @AppStorage(CurrentLiveActivitySettings.enabledKey) private var isEnabled = true
    @AppStorage(CurrentLiveActivitySettings.footprintEnabledKey) private var isFootprintEnabled = true
    @AppStorage(CurrentLiveActivitySettings.transportEnabledKey) private var isTransportEnabled = true
    @AppStorage(CurrentLiveActivitySettings.tripProgressEnabledKey) private var isTripProgressEnabled = true

    var body: some View {
        Form {
            Section {
                Toggle("实时活动", isOn: $isEnabled)
                    .onChange(of: isEnabled) { _, enabled in
                        updateCurrentLiveActivity(enabled: enabled)
                    }
            } footer: {
                Text("在锁屏和灵动岛显示实时状态")
            }

            if isEnabled {
                Section("显示内容") {
                    Toggle("地点停留", isOn: $isFootprintEnabled)
                        .onChange(of: isFootprintEnabled) { _, _ in
                            refreshCurrentLiveActivity()
                        }
                    Toggle("交通移动", isOn: $isTransportEnabled)
                        .onChange(of: isTransportEnabled) { _, _ in
                            refreshCurrentLiveActivity()
                        }
                    Toggle("出行进程", isOn: $isTripProgressEnabled)
                        .onChange(of: isTripProgressEnabled) { _, enabled in
#if canImport(ActivityKit)
                            guard #available(iOS 16.1, *) else { return }
                            if enabled {
                                TripScanManager.shared.refreshActiveTripProgress()
                            } else {
                                TripProgressLiveActivityManager.shared.stop()
                            }
#endif
                        }
                }
            }
        }
        .navigationTitle("实时活动")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func updateCurrentLiveActivity(enabled: Bool) {
#if canImport(ActivityKit)
        guard #available(iOS 16.1, *) else { return }
        if enabled {
            locationManager.checkLiveActivity(forceContentUpdate: true)
            TripScanManager.shared.refreshActiveTripProgress()
        } else {
            CurrentLiveActivityManager.shared.stop()
            TripProgressLiveActivityManager.shared.stop()
        }
#endif
    }

    private func refreshCurrentLiveActivity() {
#if canImport(ActivityKit)
        if #available(iOS 16.1, *) {
            locationManager.checkLiveActivity(forceContentUpdate: true)
            TripScanManager.shared.refreshActiveTripProgress()
        }
#endif
    }
}

private struct HealthSettingsView: View {
    @ObservedObject private var healthManager = HealthManager.shared

    var body: some View {
        Form {
            Section(footer: Text("地方客通过 HealthKit 从「健康」App 读取步数、步行距离和已爬楼层，用于区分步行与慢速交通，并在交通详情中显示步数，不会写入任何健康数据。可在「健康」App 中找到地方客并管理数据访问权限。")) {
                HStack {
                    Text("状态")
                    Spacer()
                    Text(statusText)
                        .foregroundColor(.secondary)
                }

                switch healthManager.authorizationRequestStatus {
                case .shouldRequest:
                    Button("连接 Apple 健康") {
                        healthManager.requestAuthorization { _ in }
                    }
                case .unnecessary:
                    Button("打开「健康」App 管理权限") {
                        if let url = URL(string: "x-apple-health://") {
                            UIApplication.shared.open(url)
                        }
                    }
                default:
                    EmptyView()
                }
            }
        }
        .navigationTitle("Apple 健康")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            healthManager.refreshAuthorizationRequestStatus()
        }
    }

    private var statusText: String {
        switch healthManager.authorizationRequestStatus {
        case .shouldRequest: return "未连接"
        case .unnecessary: return "已设置"
        default: return "不可用"
        }
    }
}
