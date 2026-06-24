import SwiftUI
import CoreLocation
import SwiftData
import MapKit

struct FutureTripTimelineRow: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(LocationManager.self) private var locationManager
    let trip: FutureTrip
    let activityTypes: [ActivityType]

    private var activity: ActivityType? {
        guard let activityTypeValue = trip.activityTypeValue else { return nil }
        return activityTypes.first { $0.id.uuidString == activityTypeValue || $0.name == activityTypeValue }
    }

    private var icon: String {
        activity?.icon ?? "calendar"
    }

    private var tint: Color {
        activity?.color ?? .dfkAccent
    }
    
    private var distanceText: String? {
        guard let lastLocation = locationManager.lastLocation else { return nil }
        let tripLocation = CLLocation(latitude: trip.latitude, longitude: trip.longitude)
        let distance = lastLocation.distance(from: tripLocation)
        
        if distance < 500 {
            return "在附近"
        } else {
            return String(format: "%.1f 公里", distance / 1000)
        }
    }
    
    private var countdownText: String {
        let now = Date()
        if trip.arrivalDate > now {
            let components = Calendar.current.dateComponents([.day, .hour, .minute], from: now, to: trip.arrivalDate)
            let d = components.day ?? 0
            let h = components.hour ?? 0
            let m = components.minute ?? 0
            
            if d > 0 {
                return "\(d)天"
            } else if h > 0 {
                return "\(h)小时"
            } else if m > 0 {
                return "\(m)分钟"
            } else {
                return "即将到时"
            }
        } else {
            return "已到时间"
        }
    }

    private var countdownColor: Color {
        let now = Date()
        if trip.arrivalDate < now {
            return .red
        } else if Calendar.current.isDateInToday(trip.arrivalDate) {
            return .orange
        } else {
            return .secondary
        }
    }


    var body: some View {
        HStack(alignment: .top, spacing: ContinuousTimelineLayout.markerSpacing) {
            Text(trip.hasArrivalTime ? trip.arrivalDate.formatted(date: .omitted, time: .shortened) : "计划")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary.opacity(0.58))
                .frame(width: ContinuousTimelineLayout.timeColumnWidth, alignment: .leading)
                .padding(.top, 4)

            VStack(spacing: 0) {
                Image(systemName: icon)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(colorScheme == .dark ? .black : .white)
                    .frame(width: ContinuousTimelineLayout.markerSize, height: ContinuousTimelineLayout.markerSize)
                    .background(tint, in: Circle())
                    .opacity(0.58)

                Rectangle()
                    .fill(ContinuousTimelineLayout.lineColor.opacity(0.45))
                    .frame(width: 2)
                    .frame(maxHeight: .infinity)
            }
            .frame(width: ContinuousTimelineLayout.markerSize)

            VStack(alignment: .leading, spacing: 4) {
                Text(trip.placeName)
                    .font(.body.weight(.bold))
                    .foregroundStyle(.primary.opacity(0.58))
                    .lineLimit(1)

                if let activityName = activity?.name {
                    Text(activityName)
                        .font(.caption)
                        .foregroundStyle(.secondary.opacity(0.58))
                        .lineLimit(1)
                }

                if let notes = trip.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
                    Text(notes)
                        .font(.footnote)
                        .foregroundStyle(.secondary.opacity(0.76))
                        .lineLimit(5)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 1)

            Spacer(minLength: 0)
            
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: "timer")
                    Text(countdownText)
                }
                .font(.caption)
                .foregroundStyle(countdownColor)
                
                if let distance = distanceText {
                    HStack(spacing: 4) {
                        Image(systemName: "point.topleft.down.to.point.bottomright.curvepath.fill")
                        Text(distance)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 1)
        }
        .frame(minHeight: 52, alignment: .top)
        .padding(.bottom, ContinuousTimelineLayout.minItemSpacing)
    }
}

struct FutureTripDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(LocationManager.self) private var locationManager
    @Query(sort: [SortDescriptor(\ActivityType.sortOrder), SortDescriptor(\ActivityType.name)]) private var allActivities: [ActivityType]

    let trip: FutureTrip
    var isInline: Bool = false
    @Binding var presentationDetent: PresentationDetent
    var onDismiss: (() -> Void)? = nil
    var onEdit: (() -> Void)? = nil
    
    @State private var showingAbandonAlert = false
    @State private var showingNavigationOptions = false
    
    private var isMinimized: Bool {
        isInline && presentationDetent == .height(88)
    }

    private var selectedActivityName: String {
        if let activityTypeValue = trip.activityTypeValue,
           let id = UUID(uuidString: activityTypeValue),
           let activity = allActivities.first(where: { $0.id == id }) {
            return activity.name
        }
        return "无活动类型"
    }
    
    private var selectedActivityIcon: String {
        if let activityTypeValue = trip.activityTypeValue,
           let id = UUID(uuidString: activityTypeValue),
           let activity = allActivities.first(where: { $0.id == id }) {
            return activity.icon
        }
        return "questionmark.circle.dashed"
    }

    private var selectedActivityColor: Color {
        if let activityTypeValue = trip.activityTypeValue,
           let id = UUID(uuidString: activityTypeValue),
           let activity = allActivities.first(where: { $0.id == id }) {
            return activity.color
        }
        return .secondary
    }

    private var distanceInMeters: CLLocationDistance? {
        guard let currentLoc = locationManager.lastLocation else { return nil }
        let tripLoc = CLLocation(latitude: trip.latitude, longitude: trip.longitude)
        return currentLoc.distance(from: tripLoc)
    }

    private var distanceText: String? {
        guard let d = distanceInMeters else { return nil }
        if d < 500 { return "在附近" }
        return String(format: "%.1f 公里", d / 1000.0)
    }

    private var fullCountdownText: String {
        let now = Date()
        if trip.arrivalDate < now {
            return "已到时间"
        }
        
        let diff = Calendar.current.dateComponents([.day, .hour, .minute], from: now, to: trip.arrivalDate)
        if let d = diff.day, d > 0 { return "\(d)天" }
        if let h = diff.hour, h > 0 { return "\(h)小时" }
        
        if trip.hasArrivalTime {
            if let m = diff.minute, m > 0 { return "\(m)分" }
            return "1分内"
        } else {
            return "<1小时"
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    headerContent
                    
                    if let notes = trip.notes, !notes.isEmpty {
                        notesSection(notes)
                            .padding(.horizontal, 24)
                            .padding(.top, 16)
                    }
                    
                    editButton
                        .padding(.horizontal, 24)
                        .padding(.top, 24)
                    
                    Spacer().frame(height: 30)
                }
                .contentShape(Rectangle())
            }
            .scrollDisabled(isInline && presentationDetent != .large)
            .navigationTitle(isMinimized ? "" : "行程计划")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if isMinimized {
                    ToolbarItem(placement: .principal) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                presentationDetent = .medium
                            }
                        } label: {
                            VStack(spacing: 2) {
                                Text(trip.placeName)
                                    .font(.headline)
                                    .lineLimit(1)
                                Text("行程计划")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(minWidth: 132, minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("展开行程计划")
                    }
                }
                
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        onDismiss?()
                        if !isInline { dismiss() }
                    } label: {
                        Image(systemName: "xmark").dfkToolbarDismissIcon()
                    }
                }
            }
            .alert("确认放弃计划？", isPresented: $showingAbandonAlert) {
                Button("放弃", role: .destructive) {
                    NotificationManager.shared.cancelFutureTripNotification(for: trip.id)
                    modelContext.delete(trip)
                    try? modelContext.save()
                    FutureTrip.postDidChangeNotification()
                    onDismiss?()
                    if !isInline { dismiss() }
                }
                Button("取消", role: .cancel) { }
            } message: {
                Text("删除后，该计划将不再出现。")
            }
            .confirmationDialog("选择导航应用", isPresented: $showingNavigationOptions, titleVisibility: .visible) {
                Button("苹果地图") {
                    let coordinate = CLLocationCoordinate2D(latitude: trip.latitude, longitude: trip.longitude)
                    let placemark = MKPlacemark(coordinate: coordinate)
                    let mapItem = MKMapItem(placemark: placemark)
                    mapItem.name = trip.placeName
                    mapItem.openInMaps()
                }
                
                if let url = URL(string: "iosamap://"), UIApplication.shared.canOpenURL(url) {
                    Button("高德地图") {
                        let name = trip.placeName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                        if let targetURL = URL(string: "iosamap://path?sourceApplication=DiFangKe&dlat=\(trip.latitude)&dlon=\(trip.longitude)&dname=\(name)&dev=0&t=0") {
                            UIApplication.shared.open(targetURL)
                        }
                    }
                }
                
                if let url = URL(string: "baidumap://"), UIApplication.shared.canOpenURL(url) {
                    Button("百度地图") {
                        let name = trip.placeName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                        if let targetURL = URL(string: "baidumap://map/direction?destination=latlng:\(trip.latitude),\(trip.longitude)|name:\(name)&mode=driving&coord_type=wgs84") {
                            UIApplication.shared.open(targetURL)
                        }
                    }
                }
                
                if let url = URL(string: "qqmap://"), UIApplication.shared.canOpenURL(url) {
                    Button("腾讯地图") {
                        let name = trip.placeName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                        if let targetURL = URL(string: "qqmap://map/routeplan?type=drive&to=\(name)&tocoord=\(trip.latitude),\(trip.longitude)") {
                            UIApplication.shared.open(targetURL)
                        }
                    }
                }
                
                if let url = URL(string: "comgooglemaps://"), UIApplication.shared.canOpenURL(url) {
                    Button("Google 地图") {
                        if let targetURL = URL(string: "comgooglemaps://?daddr=\(trip.latitude),\(trip.longitude)&directionsmode=driving") {
                            UIApplication.shared.open(targetURL)
                        }
                    }
                }
                
                Button("取消", role: .cancel) { }
            }
        }
    }
    
    private var headerContent: some View {
        Group {
            topStatusSection.padding(.horizontal, 24).padding(.top, 16)
            addressSection.padding(.horizontal, 24).padding(.top, 16)
            timeSection.padding(.horizontal, 24).padding(.top, 12)
        }
    }

    private var editButton: some View {
        Button {
            onEdit?()
        } label: {
            HStack {
                Image(systemName: "pencil")
                Text("编辑计划")
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)
            .background(Color.dfkAccent.opacity(0.1))
            .foregroundColor(.primary)
            .cornerRadius(12)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.dfkAccent.opacity(0.2), lineWidth: 1))
        }
    }
    
    private var countdownColor: Color {
        let now = Date()
        if trip.arrivalDate < now {
            return .red
        } else if Calendar.current.isDateInToday(trip.arrivalDate) {
            return .orange
        } else {
            return .primary
        }
    }

    private var topStatusSection: some View {
        VStack(spacing: 12) {
            if let d = distanceInMeters, d < 500 {
                HStack(spacing: 8) {
                    Button {
                        let today = Calendar.current.startOfDay(for: Date())
                        let descriptor = FetchDescriptor<Footprint>(predicate: #Predicate { $0.date >= today })
                        let recentFootprints = (try? modelContext.fetch(descriptor)) ?? []
                        
                        var matchedFootprint: Footprint? = nil
                        for fp in recentFootprints {
                            if fp.statusValue == "ignored" { continue }
                            if let fpPlaceID = fp.placeID, let tripPlaceID = trip.placeID, fpPlaceID == tripPlaceID {
                                matchedFootprint = fp
                                break
                            }
                            let fpLoc = CLLocation(latitude: fp.latitude, longitude: fp.longitude)
                            let tripLoc = CLLocation(latitude: trip.latitude, longitude: trip.longitude)
                            if fpLoc.distance(from: tripLoc) < 200 {
                                matchedFootprint = fp
                                break
                            }
                        }
                        
                        if let existing = matchedFootprint {
                            existing.activityTypeValue = trip.activityTypeValue
                            if let notes = trip.notes, !notes.isEmpty {
                                existing.reason = notes
                            }
                        } else {
                            let newFootprint = Footprint(
                                date: Date(),
                                startTime: Date(),
                                endTime: Date(),
                                footprintLocations: [CLLocationCoordinate2D(latitude: trip.latitude, longitude: trip.longitude)],
                                locationHash: "",
                                duration: 0,
                                reason: trip.notes,
                                status: .manual,
                                placeID: trip.placeID,
                                address: trip.placeName,
                                activityTypeValue: trip.activityTypeValue
                            )
                            modelContext.insert(newFootprint)
                        }
                        NotificationManager.shared.cancelFutureTripNotification(for: trip.id)
                        modelContext.delete(trip)
                        try? modelContext.save()
                        NotificationCenter.default.post(name: NSNotification.Name("FootprintDataChanged"), object: nil)
                        FutureTrip.postDidChangeNotification()
                        onDismiss?()
                        if !isInline { dismiss() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark")
                                .fontWeight(.bold)
                            Text("我已到达")
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(.ultraThinMaterial)
                        .background(Color.dfkAccent.opacity(0.15))
                        .foregroundColor(Color.dfkAccent)
                        .cornerRadius(12)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.dfkAccent.opacity(0.3), lineWidth: 1))
                    }
                    if trip.arrivalDate < Date() {
                        delayButton
                    }
                    abandonButton
                }
                .padding(.bottom, 8)
            } else {
                HStack(spacing: 8) {
                    navigateButton
                    if trip.arrivalDate < Date() {
                        delayButton
                        abandonButton
                    }
                }
                .padding(.bottom, 8)
            }
            
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 6) {
                    Image(systemName: "timer")
                    Text(fullCountdownText)
                }
                .font(.system(.title2, design: .rounded).bold())
                .foregroundStyle(countdownColor)
                
                Spacer()
                
                if let dist = distanceText {
                    HStack(spacing: 4) {
                        Image(systemName: "point.topleft.down.to.point.bottomright.curvepath.fill")
                        Text(dist)
                    }
                    .font(.title3.bold())
                    .foregroundStyle(.secondary)
                }
            }
        }
    }
    
    private var addressSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            detailMenuRow(
                title: nil,
                value: trip.placeName,
                valueColor: .primary,
                valueFont: .system(.title3, design: .rounded).bold(),
                textColor: .primary,
                textLineLimit: 2,
                leadingIcon: "mappin.and.ellipse"
            )
            
            if trip.activityTypeValue != nil {
                detailMenuRow(
                    title: nil,
                    value: selectedActivityName,
                    valueColor: selectedActivityColor,
                    valueFont: .system(size: 16, weight: .semibold, design: .rounded),
                    textColor: .primary,
                    iconFont: .system(size: 16, weight: .semibold),
                    leadingIcon: selectedActivityIcon
                )
            }
        }
    }
    
    private var timeSection: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "calendar")
                        .font(.system(size: 12))
                        .foregroundColor(Color.secondary)
                    Text(trip.arrivalDate.formatted(.dateTime.year().month().day().weekday()))
                        .font(.system(size: 14, design: .rounded))
                        .foregroundColor(Color.secondary)
                }
                if trip.hasArrivalTime {
                    HStack(spacing: 6) {
                        Image(systemName: "clock")
                            .font(.system(size: 12))
                            .foregroundColor(Color.secondary)
                        Text(trip.arrivalDate.formatted(date: .omitted, time: .shortened))
                            .font(.system(size: 14, design: .monospaced))
                            .foregroundColor(Color.secondary)
                    }
                }
            }
            Spacer(minLength: 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.04)))
    }
    
    private func notesSection(_ notes: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("备注").font(.system(size: 13, weight: .semibold)).foregroundColor(.secondary).padding(.leading, 8)
            
            Text(notes)
                .font(.body)
                .foregroundColor(.primary)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.secondary.opacity(0.05))
                )
        }
    }

    @ViewBuilder
    private func detailMenuRow(
        title: String?,
        value: String,
        valueColor: Color,
        valueFont: Font = .system(.title3, design: .rounded).bold(),
        textColor: Color? = nil,
        textLineLimit: Int = 2,
        textMinimumScaleFactor: CGFloat = 1,
        iconFont: Font = .system(size: 13, weight: .semibold),
        leadingIcon: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title, !title.isEmpty {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
            }

            HStack(alignment: .center, spacing: 12) {
                HStack(alignment: .center, spacing: 6) {
                    if let leadingIcon {
                        Image(systemName: leadingIcon)
                            .font(iconFont)
                            .foregroundColor(valueColor)
                    }

                    Text(value)
                        .font(valueFont)
                        .foregroundColor(textColor ?? valueColor)
                        .lineLimit(textLineLimit)
                        .minimumScaleFactor(textMinimumScaleFactor)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.05)))
        .contentShape(Rectangle())
    }
    
    private var delayButton: some View {
        Menu {
            let intervals: [(String, TimeInterval)] = [
                ("推迟5分钟", 5 * 60),
                ("推迟15分钟", 15 * 60),
                ("推迟1小时", 3600),
                ("推迟6小时", 6 * 3600),
                ("推迟1天", 24 * 3600)
            ]
            ForEach(intervals, id: \.1) { (label, amt) in
                Button(label) {
                    let base = max(Date(), trip.arrivalDate)
                    trip.arrivalDate = base.addingTimeInterval(amt)
                    NotificationManager.shared.scheduleFutureTripNotification(for: trip.id, placeName: trip.placeName, arrivalDate: trip.arrivalDate, hasArrivalTime: trip.hasArrivalTime)
                    try? modelContext.save()
                    FutureTrip.postDidChangeNotification()
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "clock.arrow.2.circlepath")
                Text("推迟")
                    .font(.subheadline.weight(.medium))
            }
            .padding(.horizontal, 16)
            .frame(height: 50)
            .background(.ultraThinMaterial)
            .background(Color.orange.opacity(0.1))
            .foregroundColor(.orange)
            .cornerRadius(12)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.orange.opacity(0.2), lineWidth: 1))
        }
    }
    
    private var abandonButton: some View {
        Button {
            showingAbandonAlert = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "xmark")
                Text("放弃")
                    .font(.subheadline.weight(.medium))
            }
            .padding(.horizontal, 16)
            .frame(height: 50)
            .background(.ultraThinMaterial)
            .background(Color.red.opacity(0.08))
            .foregroundColor(.red)
            .cornerRadius(12)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.red.opacity(0.15), lineWidth: 1))
        }
    }
    
    private var navigateButton: some View {
        Button {
            showingNavigationOptions = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "location.fill")
                Text("导航")
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(.ultraThinMaterial)
            .background(Color.dfkAccent.opacity(0.15))
            .foregroundColor(Color.dfkAccent)
            .cornerRadius(12)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.dfkAccent.opacity(0.3), lineWidth: 1))
        }
    }
}
