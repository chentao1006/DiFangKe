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
    @AppStorage("dailyNotificationHour") private var notificationHour: Int = 21
    @AppStorage("dailyNotificationMinute") private var notificationMinute: Int = 0
    @AppStorage("isDailyNotificationEnabled") private var isDailyNotificationEnabled = true
    @AppStorage("isHighlightNotificationEnabled") private var isHighlightNotificationEnabled = true
    @AppStorage("isPastMemoriesNotificationEnabled") private var isPastMemoriesNotificationEnabled = true
    @AppStorage("isFutureTripNotificationEnabled") private var isFutureTripNotificationEnabled = true
    @AppStorage("isAutoPhotoLinkEnabled") private var isAutoPhotoLinkEnabled = true
    @AppStorage("aiServiceType") private var aiServiceType = "public"
    @AppStorage(LocationAccuracyMode.userDefaultsKey) private var locationAccuracyModeRaw = LocationAccuracyMode.automatic.rawValue
    
    @State private var showingSettingsAlert = false
    
    private var notificationTime: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(bySettingHour: notificationHour, minute: notificationMinute, second: 0, of: Date()) ?? Date()
            },
            set: {
                let components = Calendar.current.dateComponents([.hour, .minute], from: $0)
                notificationHour = components.hour ?? 21
                notificationMinute = components.minute ?? 0
            }
        )
    }

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
                if isICloudSyncEnabled {
                    Toggle("以当前设备记录为准", isOn: useCurrentDeviceForRawRecordingBinding)
                }
                Toggle("自动关联照片到足迹", isOn: $isAutoPhotoLinkEnabled)
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

            Section(header: Text("推送通知")) {
                Toggle("每日足迹汇总", isOn: $isDailyNotificationEnabled)
                    .onChange(of: isDailyNotificationEnabled) { _, newValue in
                        if newValue {
                            NotificationManager.shared.requestAuthorization { granted in
                                if !granted {
                                    isDailyNotificationEnabled = false
                                    showingSettingsAlert = true
                                } else {
                                    updateNotifications()
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
                
                Toggle("精彩足迹提醒", isOn: $isHighlightNotificationEnabled)
                    .onChange(of: isHighlightNotificationEnabled) { _, newValue in
                        if newValue {
                            NotificationManager.shared.requestAuthorization { granted in
                                if !granted {
                                    isHighlightNotificationEnabled = false
                                    showingSettingsAlert = true
                                }
                            }
                        }
                    }
                
                Toggle("往年今日提醒", isOn: $isPastMemoriesNotificationEnabled)
                    .onChange(of: isPastMemoriesNotificationEnabled) { _, newValue in
                        if newValue {
                            NotificationManager.shared.requestAuthorization { granted in
                                if !granted {
                                    isPastMemoriesNotificationEnabled = false
                                    showingSettingsAlert = true
                                }
                            }
                        }
                    }
                
                Toggle("行程计划提醒", isOn: $isFutureTripNotificationEnabled)
                    .onChange(of: isFutureTripNotificationEnabled) { _, newValue in
                        if newValue {
                            NotificationManager.shared.requestAuthorization { granted in
                                if !granted {
                                    isFutureTripNotificationEnabled = false
                                    showingSettingsAlert = true
                                }
                            }
                        } else {
                            NotificationManager.shared.cancelAllFutureTripNotifications()
                        }
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
                    let email = "chentao1006@me.com"
                    let subject = "地方客（DiFangKe）意见反馈"
                    if let url = URL(string: "mailto:\(email)?subject=\(subject)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "") {
                        UIApplication.shared.open(url)
                    }
                }) {
                    HStack {
                        Text("反馈建议")
                        Spacer()
                        Text("chentao1006@me.com")
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
        .navigationBarTitleDisplayMode(.inline)
        .tint(.dfkAccent)
        .onAppear {
            NotificationManager.shared.getAuthorizationStatus { status in
                if status == .denied {
                    // 仅在系统权限明确被拒绝时，才同步将内部开关关闭
                    // 避免在 .notDetermined (尚未询问) 状态下误将用户默认开启的选项重置为关闭
                    isDailyNotificationEnabled = false
                    isHighlightNotificationEnabled = false
                    isPastMemoriesNotificationEnabled = false
                    isFutureTripNotificationEnabled = false
                }
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
    
    private func updateNotifications() {
        NotificationManager.shared.updateDailySummary(
            isEnabled: isDailyNotificationEnabled,
            hour: notificationHour,
            minute: notificationMinute
        )
        
        if isDailyNotificationEnabled {
            // If it's evening, try to get a real summary immediately
            let hour = Calendar.current.component(.hour, from: Date())
            if hour >= 18 {
                locationManager.triggerNotificationSummaryRefresh()
            }
        }
    }
}
