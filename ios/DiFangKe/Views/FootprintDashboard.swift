import SwiftUI
import MapKit
import CoreMotion
import simd
import WeatherKit

private enum DashboardSample {
    case fix(CLLocation, CLLocation)
    case acceleration(SIMD3<Double>, time: TimeInterval, heading: Double, trueNorth: Bool)
}

private struct DashboardReading {
    var speed: Double?
    var kilometers = 0.0
    var average: Double?
    var highest: Double?
    var heading: Double?
    var altitude: Double?
    var ascent: Double?
    var routes = BrowseRouteBatch.empty
}

private struct DashboardMeter {
    var reading = DashboardReading()
    var previous: CLLocation?
    var lastFixTime: Date?
    var filteredAltitude: Double?
    var hasCourse = false
    var coordinates: [CLLocationCoordinate2D] = []
    var groundSpeed = 0.0
    var courseRadians = 0.0
    var motionVelocity = SIMD3<Double>.zero
    let decaySeconds = AppConfig.shared.double(forKey: "DASHBOARD_MOTION_DECAY_SECONDS")
    var motionTime: TimeInterval?
    let start: Date

    mutating func accept(_ sample: DashboardSample) {
        switch sample {
        case let .fix(location, mapped):
            guard location.timestamp.timeIntervalSince(start) >= -AppConfig.shared.currentLocationFreshnessThreshold,
                  location.timestamp > (previous?.timestamp ?? .distantPast),
                  location.horizontalAccuracy <= AppConfig.shared.maxGPSAccuracyFilter else { return }
            var speed = location.speed >= 0 ? location.speed : nil
            if let previous {
                let meters = location.distance(from: previous)
                let duration = location.timestamp.timeIntervalSince(previous.timestamp)
                if speed == nil { speed = meters / duration }
                if speed != 0 { reading.kilometers += meters / 1000 }
                reading.average = reading.kilometers * 3600 / location.timestamp.timeIntervalSince(start)
            }
            if location.timestamp >= start {
                previous = location
                coordinates.append(mapped.coordinate)
            }
            if coordinates.count >= 2 {
                let line = MKPolyline(coordinates: coordinates, count: coordinates.count)
                reading.routes = BrowseRouteBatch(lines: [.init(polyline: line, dashed: false)])
            }
            updateAltitude(location)
            lastFixTime = location.timestamp
            hasCourse = location.course >= 0 && speed != 0
            if hasCourse { reading.heading = location.course.rounded() }
            if let speed {
                groundSpeed = speed
                if hasCourse { courseRadians = location.course * .pi / 180 }
                updateSpeed(trueNorth: alignedToNorth)
            }
        case let .acceleration(acceleration, time, heading, trueNorth):
            alignedToNorth = trueNorth
            if !hasCourse, heading >= 0 { reading.heading = heading.rounded() }
            defer { motionTime = time }
            if let last = motionTime, time > last {
                let dt = time - last
                // A leaky integral isolates short handset movements and drops
                // residual velocity after a pause in sensor delivery.
                let retention = exp(-dt / decaySeconds)
                motionVelocity = motionVelocity * retention + acceleration * (dt * retention)
            }
            updateSpeed(trueNorth: trueNorth)
        }
    }

    private mutating func updateAltitude(_ location: CLLocation) {
        let height = location.altitude
        let uncertainty = location.verticalAccuracy
        guard height.isFinite, uncertainty.isFinite, uncertainty >= 0 else {
            reading.altitude = nil
            return
        }
        reading.altitude = height
        guard location.timestamp >= start else { return }
        guard let previousHeight = filteredAltitude else {
            // Start at the upper edge so an uncertain first fix cannot create ascent.
            filteredAltitude = height + uncertainty
            reading.ascent = 0
            return
        }
        // Count only a rise required by the new measurement's uncertainty interval.
        // Descents move the reference down, preserving the gain on the next climb.
        let nextHeight = min(height + uncertainty, max(height - uncertainty, previousHeight))
        filteredAltitude = nextHeight
        reading.ascent = (reading.ascent ?? 0) + max(0, nextHeight - previousHeight)
    }

    var alignedToNorth = false

    mutating func updateSpeed(trueNorth: Bool) {
        let fresh = lastFixTime.map { -$0.timeIntervalSinceNow < AppConfig.shared.currentLocationFreshnessThreshold } ?? false
        let baseline = fresh ? groundSpeed : 0
        let speed: Double
        if trueNorth && hasCourse {
            let ground = SIMD3(baseline * cos(courseRadians), baseline * sin(courseRadians), 0)
            speed = simd_length(ground + motionVelocity)
        } else {
            speed = hypot(baseline, simd_length(motionVelocity))
        }
        let kmh = speed * 3.6
        reading.speed = kmh
        reading.highest = max(reading.highest ?? kmh, kmh)
    }

}

struct FootprintDashboard: View {
    let locationManager: LocationManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("dashboardPortraitMapFraction") private var portraitFraction = 0.5
    @AppStorage("dashboardLandscapeMapFraction") private var landscapeFraction = 0.5
    @State private var dragExtent: CGFloat?
    @State private var confirmingExit = false
    @State private var start = Date()
    @State private var reading = DashboardReading()
    @State private var weatherLocation: CLLocation?
    @State private var weather: HourWeather?
    @State private var weatherPlaceholder = "—"
    @State private var attribution: WeatherAttribution?
    @State private var position: MapCameraPosition
    @State private var touching = false
    @State private var gestures = Set<RouteMapNativeGestureKind>()
    @State private var returning = false
    @State private var followPaused = false
    @State private var interactionID = UUID()
    @State private var resume: Task<Void, Never>?
    @State private var idleTimerBefore: Bool?
    @State private var samples = AsyncStream<DashboardSample>.makeStream()

    init(locationManager: LocationManager) {
        self.locationManager = locationManager
        _position = State(initialValue: locationManager.lastLocation.map { Self.streetCamera($0, heading: nil) } ?? .automatic)
    }

    private static func streetCamera(_ fix: CLLocation, heading: Double?) -> MapCameraPosition {
        .camera(MapCamera(centerCoordinate: fix.coordinate,
                          distance: AppConfig.shared.double(forKey: "DASHBOARD_CAMERA_DISTANCE_METERS"),
                          heading: heading ?? max(0, fix.course),
                          pitch: AppConfig.shared.double(forKey: "DASHBOARD_CAMERA_PITCH_DEGREES")))
    }

    var body: some View {
        GeometryReader { geometry in
            let horizontal = geometry.size.width > geometry.size.height
            let extent = max(1, horizontal ? geometry.size.width : geometry.size.height)
            let bounds = (extent * 0.35)...(extent * 0.60)
            let fraction = horizontal ? landscapeFraction : portraitFraction
            let mapExtent = min(bounds.upperBound, max(bounds.lowerBound, dragExtent ?? extent * fraction))
            let layout = horizontal ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            layout {
                Map(position: $position) {
                    UserAnnotation()
                    BrowseMapRoutes(routes: reading.routes)
                }
                .onMapCameraChange(frequency: .continuous) { _ in
                    // Keep extending idle time while the user's viewport is still coasting.
                    if !returning, !touching, gestures.isEmpty, position.positionedByUser {
                        updateInteraction()
                    }
                }
                .browseMapStyle(elevation: .realistic, colorSchemeOverride: .dark)
                .background {
                    RouteMapNativeGestureObserver(onInteractionChanged: { kind, active in
                        if active {
                            gestures.insert(kind)
                        } else if gestures.remove(kind) == nil {
                            return
                        }
                        updateInteraction()
                    }, onTouchChanged: { down in
                        touching = down
                        updateInteraction()
                    })
                }
                .frame(width: horizontal ? mapExtent : nil,
                       height: horizontal ? nil : mapExtent)
                .overlay(alignment: .topLeading) {
                    Button { confirmingExit = true } label: {
                        Image(systemName: "xmark")
                    }
                    .dfkCircleGlassButtonStyle()
                    .accessibilityLabel("退出仪表盘")
                    .padding(10)
                }
                MapPanelResizeHandle(horizontal: horizontal, extent: mapExtent, bounds: bounds,
                                     onChange: { dragExtent = $0 }, onEnd: { final in
                    if horizontal { landscapeFraction = final / extent }
                    else { portraitFraction = final / extent }
                    dragExtent = nil
                })
                .id(horizontal)
                .environment(\.colorScheme, .dark)
                .accessibilityLabel("调整仪表盘大小")
                instruments
            }
            .background {
                Color.black.overlay(Color.dfkAccent.opacity(0.14)).ignoresSafeArea()
            }
            .onChange(of: horizontal) { _, _ in dragExtent = nil }
        }
        .statusBarHidden()
        .interactiveDismissDisabled()
        .alert("退出仪表盘？", isPresented: $confirmingExit) {
            Button("继续使用", role: .cancel) { }
            Button("退出", role: .destructive) { dismiss() }
        } message: {
            Text("退出后将结束本次计时和速度统计。")
        }
        .onAppear { updateIdleTimer(phase == .active) }
        .onChange(of: phase) { _, phase in updateIdleTimer(phase == .active) }
        .onDisappear {
            updateIdleTimer(false)
            resume?.cancel()
            samples.continuation.finish()
        }
        .onChange(of: reading.heading) { _, _ in
            if !followPaused { updateFollowCamera() }
        }
        .onReceive(locationManager.acceptedLocationUpdates) { pair in
            guard let pair else { return }
            if !followPaused { updateFollowCamera(location: pair.mapped) }
            weatherLocation = pair.raw
            samples.continuation.yield(.fix(pair.raw, pair.mapped))
        }
        .task { await runMeter() }
        .task(id: weatherLocation != nil) {
            while let location = weatherLocation, !Task.isCancelled {
                do {
                    if let forecast = weather, forecast.date <= .now { weather = nil }
                    let next = try await Self.nextHourlyForecast(for: location)
                    guard !Task.isCancelled else { return }
                    weather = next
                    weatherPlaceholder = "暂不可用"
                    attribution = try? await WeatherService.shared.attribution
                } catch {
                    if !Task.isCancelled {
                        weather = nil
                        weatherPlaceholder = "暂不可用"
                    }
                }
                let refresh = AppConfig.shared.double(forKey: "DASHBOARD_WEATHER_REFRESH_SECONDS")
                let delay = min(refresh, weather?.date.timeIntervalSinceNow ?? refresh)
                try? await Task.sleep(for: .seconds(max(0, delay)))
            }
        }
    }

    private nonisolated static func nextHourlyForecast(for location: CLLocation) async throws -> HourWeather? {
        let forecast = try await WeatherService.shared.weather(for: location, including: .hourly)
        let now = Date()
        return forecast.first { $0.date > now }
    }

    private func updateIdleTimer(_ active: Bool) {
        if active, idleTimerBefore == nil {
            idleTimerBefore = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
        } else if !active, let idleTimerBefore {
            UIApplication.shared.isIdleTimerDisabled = idleTimerBefore
            self.idleTimerBefore = nil
        }
    }

    private func updateFollowCamera(location: CLLocation? = nil, completion: @escaping () -> Void = {}) {
        guard let fix = location ?? locationManager.lastLocation else {
            completion()
            return
        }
        withAnimation(.easeInOut(duration: reduceMotion ? 0.25 : 0.65), completionCriteria: .logicallyComplete) {
            position = Self.streetCamera(fix, heading: reading.heading)
        } completion: {
            completion()
        }
    }

    private func updateInteraction() {
        resume?.cancel()
        let token = UUID()
        interactionID = token
        followPaused = true
        returning = false
        guard !touching, gestures.isEmpty else { return }
        resume = Task { @MainActor in
            try? await Task.sleep(for: .seconds(AppConfig.shared.double(forKey: "DASHBOARD_RESUME_SECONDS")))
            guard !Task.isCancelled, interactionID == token, !touching, gestures.isEmpty else { return }
            returning = true
            updateFollowCamera {
                guard interactionID == token else { return }
                returning = false
                followPaused = false
            }
        }
    }

    private func runMeter() async {
        let motion = CMMotionManager()
        let sink = samples.continuation
        let trueNorth = CMMotionManager.availableAttitudeReferenceFrames().contains(.xTrueNorthZVertical)
        let frame: CMAttitudeReferenceFrame = trueNorth ? .xTrueNorthZVertical : .xArbitraryZVertical
        if motion.isDeviceMotionAvailable, CMMotionManager.availableAttitudeReferenceFrames().contains(frame) {
            motion.deviceMotionUpdateInterval = AppConfig.shared.double(forKey: "DASHBOARD_MOTION_INTERVAL_SECONDS")
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            motion.startDeviceMotionUpdates(using: frame, to: queue) { data, _ in
                guard let data else { return }
                // Transpose the reference-to-device matrix. Reference axes are north, west, up.
                let r = data.attitude.rotationMatrix
                let a = data.userAcceleration
                let north = (r.m11*a.x + r.m21*a.y + r.m31*a.z) * 9.80665
                let east = -(r.m12*a.x + r.m22*a.y + r.m32*a.z) * 9.80665
                let up = (r.m13*a.x + r.m23*a.y + r.m33*a.z) * 9.80665
                sink.yield(.acceleration(SIMD3(north, east, up), time: data.timestamp,
                                         heading: trueNorth ? data.heading : -1, trueNorth: trueNorth))
            }
        }
        defer { motion.stopDeviceMotionUpdates() }
        let worker = Task.detached { [stream = samples.stream, start] in
            var meter = DashboardMeter(start: start)
            for await sample in stream {
                guard !Task.isCancelled else { break }
                meter.accept(sample)
                let value = meter.reading
                await MainActor.run { reading = value }
            }
        }
        await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
    }

    private var instruments: some View {
        VStack(spacing: 6) {
            HStack(alignment: .top) {
                DashboardBattery()
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    if let weather {
                        let temperature = weather.temperature.converted(to: .celsius).value
                            .formatted(.number.precision(.fractionLength(0))) + "°C"
                        HStack(spacing: 4) {
                            Text(weather.date, style: .time)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Image(systemName: weather.symbolName)
                                .symbolRenderingMode(.multicolor)
                            Text(temperature)
                        }
                        .font(.headline.monospacedDigit())
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text("\(weather.date, style: .time) 预报，\(weather.condition.description)"))
                        .accessibilityValue(Text(temperature))
                    } else {
                        metric("天气", weatherPlaceholder)
                    }
                    if let attribution {
                        Link(destination: attribution.legalPageURL) {
                            AsyncImage(url: attribution.combinedMarkLightURL) { image in
                                image.resizable().scaledToFit()
                            } placeholder: { Text(" Weather").font(.caption2) }
                        }.frame(height: 12)
                    }
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 16) {
                Text("海拔 \(number(reading.altitude)) m")
                Text("↑ \(number(reading.ascent)) m")
                    .accessibilityLabel("累计爬升 \(number(reading.ascent)) 米")
            }
            .font(.subheadline.monospacedDigit())
            Spacer(minLength: 0)
            SegmentSpeed(speed: reading.speed)
                .frame(maxWidth: 340, maxHeight: 138)
                .accessibilityLabel("时速 \(number(reading.speed)) 公里")
            Text("km/h").font(.caption.bold()).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            SwiftUI.TimelineView(.periodic(from: start, by: 1)) { tick in
                Text(Duration.seconds(max(0, tick.date.timeIntervalSince(start)).rounded(.down))
                    .formatted(.time(pattern: .hourMinuteSecond)))
                    .font(.title.monospacedDigit().weight(.semibold))
            }
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline) {
                metric("平均速度", number(reading.average) + " km/h")
                metric("最高速度", number(reading.highest) + " km/h", font: .subheadline)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                metric("累计里程", number(reading.kilometers, places: 2) + " km")
            }
        }
        .padding()
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, .dark)
    }

    private func number(_ value: Double?, places: Int = 0) -> String {
        value?.formatted(.number.grouping(.never).precision(.fractionLength(places))) ?? "—"
    }

    private func metric(_ title: String, _ value: String, font: Font = .headline) -> some View {
        Text(value)
            .font(font.monospacedDigit())
            .accessibilityLabel(Text(title))
            .accessibilityValue(Text(value))
    }
}

private struct DashboardBattery: View {
    @Environment(\.scenePhase) private var phase
    @State private var previousMonitoring: Bool?
    @State private var level: Float = -1
    @State private var state: UIDevice.BatteryState = .unknown
    @State private var lowPower = false

    private func refresh() {
        level = UIDevice.current.batteryLevel
        state = UIDevice.current.batteryState
        lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    private var symbol: String {
        if state == .charging { return "battery.100percent.bolt" }
        guard level >= 0 else { return "battery.0percent" }
        let step = Int((level * 4).rounded()) * 25
        return "battery.\(step)percent"
    }

    private var tint: Color {
        if lowPower { return .yellow }
        if state == .charging || state == .full { return .green }
        if level >= 0 && Double(level) <= AppConfig.shared.double(forKey: "DASHBOARD_LOW_BATTERY_FRACTION") { return .red }
        return .primary
    }

    private var status: String {
        switch state {
        case .charging: return "充电中"
        case .full: return "已充满"
        case .unplugged: return lowPower ? "低电量模式" : "使用电池"
        default: return "电池状态未知"
        }
    }

    var body: some View {
        let percentage = level >= 0 ? level.formatted(.percent.precision(.fractionLength(0))) : "—"
        HStack(spacing: 4) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(percentage)
        }
        .font(.headline.monospacedDigit())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("电量")
        .accessibilityValue(Text("\(percentage)，\(status)"))
        .onAppear {
            let device = UIDevice.current
            previousMonitoring = device.isBatteryMonitoringEnabled
            device.isBatteryMonitoringEnabled = true
            refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryLevelDidChangeNotification)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryStateDidChangeNotification)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in refresh() }
        .onChange(of: phase) { _, phase in if phase == .active { refresh() } }
        .onDisappear {
            if let previousMonitoring { UIDevice.current.isBatteryMonitoringEnabled = previousMonitoring }
        }
    }
}

private struct SegmentSpeed: View {
    let speed: Double?
    private static let masks = [63, 6, 91, 79, 102, 109, 125, 7, 127, 111]
    private static let strokes: [(CGPoint, CGPoint)] = [
        (.init(x: 1,y: 0), .init(x: 8,y: 0)), (.init(x: 9,y: 1), .init(x: 9,y: 8)),
        (.init(x: 9,y: 10), .init(x: 9,y: 17)), (.init(x: 8,y: 18), .init(x: 1,y: 18)),
        (.init(x: 0,y: 17), .init(x: 0,y: 10)), (.init(x: 0,y: 8), .init(x: 0,y: 1)),
        (.init(x: 1,y: 9), .init(x: 8,y: 9))
    ]

    var body: some View {
        Canvas { context, size in
            let digits = speed.flatMap { $0.isFinite ? Int(min(999, max(0, $0.rounded()))) : nil }
            let width = CGFloat(3 * 13 - 4)
            let scale = min(size.height / 20, size.width / (width + 2))
            context.translateBy(x: (size.width - width * scale) / 2, y: (size.height - 18 * scale) / 2)
            context.scaleBy(x: scale, y: scale)
            for place in [100, 10, 1] {
                var mask = 0
                if let digits, place == 1 || digits >= place {
                    mask = Self.masks[(digits / place) % 10]
                }
                for (i, segment) in Self.strokes.enumerated() {
                    var path = Path()
                    path.move(to: segment.0)
                    path.addLine(to: segment.1)
                    context.stroke(path, with: .color(.white.opacity(mask & (1 << i) == 0 ? 0.18 : 1)), lineWidth: 1.5)
                }
                context.translateBy(x: 13, y: 0)
            }
        }
    }
}
