import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(LocationManager.self) private var locationManager
    @AppStorage("isTrackingEnabled") private var isTrackingEnabled = true
    @Query(sort: \Place.name) private var allPlaces: [Place]
    @Query(sort: [SortDescriptor(\ActivityType.sortOrder)]) private var allActivities: [ActivityType]
    @AppStorage("isICloudSyncEnabled") private var isICloudSyncEnabled = true
    @AppStorage("isAiAssistantEnabled") private var isAiAssistantEnabled = false
    @AppStorage("dailyNotificationHour") private var notificationHour: Int = 21
    @AppStorage("dailyNotificationMinute") private var notificationMinute: Int = 0
    @AppStorage("isDailyNotificationEnabled") private var isDailyNotificationEnabled = true
    @AppStorage("isHighlightNotificationEnabled") private var isHighlightNotificationEnabled = true
    @AppStorage("isAutoPhotoLinkEnabled") private var isAutoPhotoLinkEnabled = true
    @AppStorage("aiServiceType") private var aiServiceType = "public"
    
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
                
                Toggle("开启 iCloud 同步", isOn: $isICloudSyncEnabled)
                Toggle("自动关联照片到足迹", isOn: $isAutoPhotoLinkEnabled)
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
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .tint(.dfkAccent)
        .onAppear {
            NotificationManager.shared.getAuthorizationStatus { status in
                if status != .authorized && status != .provisional && status != .ephemeral {
                    // 如果系统没有授权通知，则内部状态应强制关闭，便于用户手动开启来触发权限申请
                    isDailyNotificationEnabled = false
                    isHighlightNotificationEnabled = false
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
