import MapKit
import os
import SwiftUI

struct BrowseMapPreferences: Equatable {
    enum Theme: String { case standard, muted, satellite, hybrid }
    enum Appearance: String { case system, light, dark }
    static let widthRange = 0.25...4.0
    static let transparencyRange = 0.0...1.0
    enum Places: String { case page, show, hide }

    var theme: Theme = .standard
    var appearance: Appearance = .system
    var places: Places = .page
    var width = 1.0
    var transparency = 0.5
    var colorHex = ""
    var outline = false
    var glow = false

    // Keep the existing on-disk and iCloud representation for older devices.
    var opacity: Double {
        get { 1 - transparency }
        set { transparency = 1 - newValue }
    }

    init() {}

    init(saved: [String: String]) {
        theme = Theme(rawValue: saved["theme"] ?? "") ?? .standard
        appearance = Appearance(rawValue: saved["appearance"] ?? "") ?? .system
        places = Places(rawValue: saved["places"] ?? "") ?? .page
        func readSlider(_ key: String, range: ClosedRange<Double>, low: Double, standard: Double, high: Double) -> Double {
            switch saved[key] {
            case "low": return low
            case "high": return high
            default:
                guard let raw = saved[key], let number = Double(raw), number.isFinite else { return standard }
                return min(range.upperBound, max(range.lowerBound, number))
            }
        }
        width = readSlider("width", range: Self.widthRange, low: 0.75, standard: width, high: 1.5)
        transparency = readSlider("opacity", range: Self.transparencyRange, low: 0.675, standard: transparency, high: 0.25)
        colorHex = saved["color"] ?? ""
        outline = saved["outline"] == "true"
        glow = saved["glow"] == "true"
    }

    var saved: [String: String] {
        ["theme": theme.rawValue, "appearance": appearance.rawValue, "places": places.rawValue,
         "width": String(width), "opacity": String(transparency), "color": colorHex, "outline": String(outline), "glow": String(glow)]
    }

    var cacheKey: String {
        "\(theme.rawValue)|\(appearance.rawValue)|\(places.rawValue)|\(width)|\(transparency)|\(colorHex)|\(outline)-\(glow)-stroke-v5"
    }

    var supportsAppearance: Bool { theme != .satellite && theme != .hybrid }

    var scheme: ColorScheme? {
        guard supportsAppearance else { return nil }
        switch appearance {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    func mapStyle(elevation: MapStyle.Elevation,
                  pointsOfInterest: PointOfInterestCategories) -> MapStyle {
        let poi: PointOfInterestCategories = places == .page ? pointsOfInterest : (places == .show ? .all : .excludingAll)
        switch theme {
        case .satellite: return .imagery(elevation: elevation)
        case .hybrid: return .hybrid(elevation: elevation, pointsOfInterest: poi)
        default:
            return .standard(elevation: elevation, emphasis: theme == .muted ? .muted : .automatic,
                             pointsOfInterest: poi)
        }
    }

    func configuration(defaultFilter: MKPointOfInterestFilter?) -> MKMapConfiguration {
        let filter: MKPointOfInterestFilter? = places == .page ? defaultFilter : (places == .show ? .includingAll : .excludingAll)
        switch theme {
        case .satellite: return MKImageryMapConfiguration()
        case .hybrid:
            let config = MKHybridMapConfiguration()
            config.pointOfInterestFilter = filter
            return config
        default:
            let config = MKStandardMapConfiguration(emphasisStyle: theme == .muted ? .muted : .default)
            config.pointOfInterestFilter = filter
            return config
        }
    }

    func apply(to options: MKMapSnapshotter.Options, appearance: UIUserInterfaceStyle) -> UITraitCollection {
        let style = scheme.map { $0 == .dark ? UIUserInterfaceStyle.dark : .light } ?? appearance
        let traits = UITraitCollection(userInterfaceStyle: style)
        options.preferredConfiguration = configuration(defaultFilter: nil)
        options.traitCollection = traits
        return traits
    }

    func drawSnapshotLine(_ points: [CGPoint], appearance: UIUserInterfaceStyle, baseWidth: CGFloat,
                          dash: [CGFloat], baseAlpha: Double, baseColor: UIColor) {
        guard let first = points.first else { return }
        let path = UIBezierPath()
        path.move(to: first)
        for point in points.dropFirst() { path.addLine(to: point) }
        UITraitCollection(userInterfaceStyle: appearance).performAsCurrent {
            draw(path, baseWidth: baseWidth, dash: dash, baseAlpha: baseAlpha, baseColor: baseColor)
        }
    }

    func lineWidth(_ base: CGFloat) -> CGFloat {
        base * width
    }

    static func untraveledOpacity(dashed: Bool) -> Double { dashed ? 0.18 : 0.24 }

    func alpha(_ base: Double) -> Double {
        // The midpoint preserves each layer's original alpha, including playback highlights.
        if transparency == 0 { return 1 }
        if transparency < 0.5 { return pow(base, 2 * transparency) }
        return base * (2 * (1 - transparency))
    }

    func color(_ base: Color = .dfkAccent) -> Color {
        colorHex.isEmpty ? base : (Color(hex: colorHex) ?? base)
    }

    enum StrokeLayer: Hashable { case outerGlow, innerGlow, border, route }

    var strokeLayers: [StrokeLayer] {
        var layers: [StrokeLayer] = glow ? [.outerGlow, .innerGlow] : []
        if outline { layers.append(.border) }
        layers.append(.route)
        return layers
    }

    func routeStroke(_ base: StrokeStyle, ink: UIColor, baseAlpha: Double,
                     layer: StrokeLayer, playbackOpacity: Double = 1) -> (style: StrokeStyle, color: UIColor) {
        let width = lineWidth(base.lineWidth)
        let borderWidth: CGFloat = 4 // Two points outside each side of the route.
        var style = base
        let opacity = alpha(baseAlpha) * playbackOpacity
        let tint: UIColor
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, componentAlpha: CGFloat = 0
        ink.getRed(&red, green: &green, blue: &blue, alpha: &componentAlpha)
        switch layer {
        case .route:
            style.lineWidth = width
            tint = ink.withAlphaComponent(opacity)
        case .border:
            style.lineWidth = width + borderWidth
            tint = UIColor { $0.userInterfaceStyle == .dark ? .black : .white }.withAlphaComponent(opacity)
        case .outerGlow, .innerGlow:
            let outer = layer == .outerGlow
            style.lineWidth = width + (outline ? borderWidth : 0) + (outer ? 7 : 3.5)
            tint = UIColor(red: 0.3 + 0.7 * red, green: 0.3 + 0.7 * green,
                           blue: 0.3 + 0.7 * blue, alpha: opacity * (outer ? 0.15 : 0.32))
        }
        if !base.dash.isEmpty {
            let gapAllowance = (outline ? borderWidth : 0) + (glow ? 7 : 0)
            style.dash = base.dash.map { $0 * max(1, self.width) + gapAllowance }
        }
        return (style, tint)
    }

    func draw(_ path: UIBezierPath, baseWidth: CGFloat, dash: [CGFloat], baseAlpha: Double,
              baseColor: UIColor, scale: CGFloat = 1, playbackOpacity: Double = 1) {
        let ink = colorHex.isEmpty ? baseColor : UIColor(color())
        let base = StrokeStyle(lineWidth: baseWidth, dash: dash)
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        for layer in strokeLayers {
            let stroke = routeStroke(base, ink: ink, baseAlpha: baseAlpha, layer: layer, playbackOpacity: playbackOpacity)
            let lengths = stroke.style.dash.map { $0 * scale }
            path.setLineDash(lengths, count: lengths.count, phase: 0)
            path.lineWidth = stroke.style.lineWidth * scale
            stroke.color.setStroke()
            if layer == .border {
                // Keep the center transparent, including around each individual dash cap.
                let centerline = lengths.isEmpty ? path.cgPath : path.cgPath.copy(dashingWithPhase: 0, lengths: lengths)
                let ring = CGMutablePath()
                for width in [stroke.style.lineWidth, lineWidth(baseWidth)] {
                    ring.addPath(centerline.copy(strokingWithWidth: width * scale, lineCap: .round, lineJoin: .round, miterLimit: 10))
                }
                let border = UIBezierPath(cgPath: ring)
                border.usesEvenOddFillRule = true
                stroke.color.setFill()
                border.fill()
            } else {
                path.stroke()
            }
        }
    }

}

/// MapKit draws tiles concurrently. Each draw uses one coherent snapshot of the style.
final class BrowseRouteRenderer: MKPolylineRenderer {
    private struct Paint {
        var preferences = BrowseMapPreferences()
        var traits = UITraitCollection.current
        var width: CGFloat = 3
        var dash: [CGFloat] = []
        var playbackOpacity = 1.0
        var alpha = 1.0
    }

    private let paint = OSAllocatedUnfairLock(initialState: Paint())

    func configure(_ preferences: BrowseMapPreferences, traits: UITraitCollection, width: CGFloat,
                   dash: [CGFloat], alpha: Double, playbackOpacity: Double = 1) {
        paint.withLock { $0 = Paint(preferences: preferences, traits: traits, width: width, dash: dash, playbackOpacity: playbackOpacity, alpha: alpha) }
        shouldRasterize = true
        lineWidth = preferences.lineWidth(width) + (preferences.outline ? 4 : 0) + (preferences.glow ? 7 : 0)
        setNeedsDisplay()
    }

    func configureTransport(_ preferences: BrowseMapPreferences, traits: UITraitCollection, dashed: Bool,
                            playing: Bool = false, highlighted: Bool = false) {
        let alpha: Double = highlighted || playing ? 1 : (dashed ? 0.4 : 0.7)
        configure(preferences, traits: traits, width: dashed ? 1.5 : (highlighted ? 4 : 3),
                  dash: dashed ? [5, 5] : [], alpha: alpha,
                  playbackOpacity: playing && !highlighted ? BrowseMapPreferences.untraveledOpacity(dashed: dashed) : 1)
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard zoomScale > 0, let path else { return }
        let style = paint.withLock { $0 }
        style.traits.performAsCurrent {
            UIGraphicsPushContext(context)
            defer { UIGraphicsPopContext() }
            style.preferences.draw(UIBezierPath(cgPath: path), baseWidth: style.width, dash: style.dash,
                                   baseAlpha: style.alpha, baseColor: UIColor(Color.dfkAccent), scale: 1 / zoomScale, playbackOpacity: style.playbackOpacity)
        }
    }
}

/// Prepared with the route geometry, off the main thread. Identity stays stable
/// across camera updates and changes when a new set of routes is published.
final class BrowseRouteBatch: @unchecked Sendable {
    struct Line {
        let polyline: MKPolyline
        let dashed: Bool
    }
    let lines: [Line]
    static let empty = BrowseRouteBatch(lines: [])

    init(lines: [Line]) { self.lines = lines }

    convenience init<S>(_ segments: [S], coordinates: KeyPath<S, [CLLocationCoordinate2D]>, dashed: KeyPath<S, Bool>) {
        self.init(lines: segments.compactMap {
            let points = $0[keyPath: coordinates]
            guard points.count >= 2 else { return nil }
            return Line(polyline: MKPolyline(coordinates: points, count: points.count), dashed: $0[keyPath: dashed])
        })
    }
}

/// Let SwiftUI continue to own the camera, controls and annotations. Only
/// overlays installed by this view use the same renderer as the style preview.
struct BrowseMapRoutes: UIViewRepresentable {
    let routes: BrowseRouteBatch
    var highlighted: BrowseRouteBatch = .empty
    var playing = false
    var preferences = BrowseMapSettings.shared.value
    @Environment(\.colorScheme) private var systemScheme

    init(routes: BrowseRouteBatch, highlighted: BrowseRouteBatch = .empty, playing: Bool = false) {
        self.routes = routes
        self.highlighted = highlighted
        self.playing = playing
    }

    func makeUIView(context: Context) -> Probe {
        let view = Probe()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: Probe, context: Context) {
        view.style = self
        view.attach()
    }

    static func dismantleUIView(_ view: Probe, coordinator: ()) { view.detach() }

    final class Probe: UIView, MKMapViewDelegate {
        var style: BrowseMapRoutes?
        private weak var map: MKMapView?
        private weak var original: MKMapViewDelegate?
        private var base: BrowseRouteBatch?
        private var progress: BrowseRouteBatch?
        private var applied: BrowseMapPreferences?
        private var scheme: ColorScheme?
        private var playing = false
        private var strokes: [ObjectIdentifier: (dashed: Bool, highlighted: Bool)] = [:]

        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || original?.responds(to: selector) == true
        }

        override func forwardingTarget(for selector: Selector!) -> Any? {
            if original?.responds(to: selector) == true { return original }
            return super.forwardingTarget(for: selector)
        }

        override func layoutSubviews() { super.layoutSubviews(); attach() }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil {
                DispatchQueue.main.async { [weak self] in self?.attach() }
            } else { detach() }
        }

        func attach() {
            guard window != nil, let style else { return }
            // Remain within this map's immediate hosting hierarchy, even on
            // screens containing multiple maps.
            guard let target = map ?? RouteMapNativeGestureObserver.Coordinator.nearestMapView(to: self),
                  let delegate = target.delegate else { return }
            if delegate !== self {
                guard !(delegate is Probe) else { return }
                original = delegate
                map = target
                target.delegate = self
            }
            let effectiveScheme = style.preferences.scheme ?? style.systemScheme
            let restyle = applied != style.preferences || scheme != effectiveScheme || playing != style.playing
            applied = style.preferences
            scheme = effectiveScheme
            playing = style.playing
            let replaceBase = base !== style.routes
            let replaceProgress = replaceBase || progress !== style.highlighted
            if replaceProgress { remove(progress, from: target); progress = nil }
            if replaceBase {
                remove(base, from: target)
                base = style.routes
                add(style.routes, highlighted: false, to: target)
            }
            if replaceProgress {
                progress = style.highlighted
                add(style.highlighted, highlighted: true, to: target)
            }
            if restyle {
                for batch in [base, progress] {
                    for line in batch?.lines ?? [] {
                        if let renderer = target.renderer(for: line.polyline) as? BrowseRouteRenderer {
                            configure(renderer)
                        }
                    }
                }
            }
        }

        private func add(_ batch: BrowseRouteBatch, highlighted: Bool, to map: MKMapView) {
            for line in batch.lines {
                strokes[ObjectIdentifier(line.polyline)] = (line.dashed, highlighted)
                map.addOverlay(line.polyline, level: .aboveRoads)
            }
        }

        private func remove(_ batch: BrowseRouteBatch?, from map: MKMapView) {
            for line in batch?.lines ?? [] {
                map.removeOverlay(line.polyline)
                strokes.removeValue(forKey: ObjectIdentifier(line.polyline))
            }
        }

        func detach() {
            if let map {
                remove(progress, from: map)
                remove(base, from: map)
                if map.delegate === self { map.delegate = original }
            }
            progress = nil
            base = nil
            map = nil
            original = nil
            applied = nil
        }

        private func configure(_ renderer: BrowseRouteRenderer) {
            guard let line = strokes[ObjectIdentifier(renderer.polyline)], let applied else { return }
            renderer.configureTransport(applied, traits: UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light),
                                        dashed: line.dashed, playing: playing, highlighted: line.highlighted)
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let line = overlay as? MKPolyline, strokes[ObjectIdentifier(line)] != nil {
                let renderer = BrowseRouteRenderer(polyline: line)
                configure(renderer)
                return renderer
            }
            return original?.mapView?(mapView, rendererFor: overlay) ?? MKOverlayRenderer(overlay: overlay)
        }
    }
}

@Observable final class BrowseMapSettings {
    static let shared = BrowseMapSettings()
    static let storageKey = "browseMapPreferences"
    private var current: BrowseMapPreferences

    var value: BrowseMapPreferences {
        get { current }
        set {
            guard newValue != current else { return }
            current = newValue
            UserDefaults.standard.set(newValue.saved, forKey: Self.storageKey)
            CloudSettingsManager.shared.syncLocalToCloud(key: Self.storageKey)
        }
    }

    func applyCloudValue(_ saved: [String: String]) {
        let updated = BrowseMapPreferences(saved: saved)
        if current != updated { current = updated }
    }

    private init() {
        current = BrowseMapPreferences(saved: UserDefaults.standard.dictionary(forKey: Self.storageKey) as? [String: String] ?? [:])
    }
}

extension View {
    func browseMapStyle(elevation: MapStyle.Elevation = .automatic,
                        pointsOfInterest: PointOfInterestCategories = .all) -> some View {
        let prefs = BrowseMapSettings.shared.value
        return mapStyle(prefs.mapStyle(elevation: elevation, pointsOfInterest: pointsOfInterest))
            .transformEnvironment(\.colorScheme) { if let scheme = prefs.scheme { $0 = scheme } }
    }
}

extension MapPolyline {
    @MainActor @MapContentBuilder
    func browseStroke(_ base: Color = .dfkAccent, opacity: Double = 1, playbackOpacity: Double = 1, style: StrokeStyle, preferences: BrowseMapPreferences? = nil) -> some MapContent {
        let prefs = preferences ?? BrowseMapSettings.shared.value
        let ink = UIColor(prefs.color(base))
        ForEach(prefs.strokeLayers, id: \.self) { layer in
            let paint = prefs.routeStroke(style, ink: ink, baseAlpha: opacity, layer: layer, playbackOpacity: playbackOpacity)
            self.stroke(Color(uiColor: paint.color), style: paint.style)
        }
    }
}

struct MapStyleSettingsView: View {
    @Bindable private var settings = BrowseMapSettings.shared
    @State private var confirmingReset = false
    @State private var preview: PreviewRoute?

    @State private var editingSlider: WritableKeyPath<BrowseMapPreferences, Double>?
    @State private var sliderValue: Double?

    private var previewPreferences: BrowseMapPreferences {
        var value = settings.value
        if let editingSlider, let sliderValue { value[keyPath: editingSlider] = sliderValue }
        return value
    }

    private func finishSliderEdit() {
        if let editingSlider, let sliderValue { settings.value[keyPath: editingSlider] = sliderValue }
        editingSlider = nil
        sliderValue = nil
    }

    private struct PreviewRoute {
        let walkingCoordinate: CLLocationCoordinate2D
        let solid: MKPolyline
        let dashed: MKPolyline
        let region: MKCoordinateRegion
    }

    // © OpenStreetMap contributors (ODbL). Donghua University (266150697) to Anshun Road (1005343158),
    // Yili Road (64376805) and the garden entrance paths (44480775, 44480774).
    private static let previewRoute = Task.detached(priority: .userInitiated) {
        let roadNodes: [(Double, Double)] = [
            (31.2036528, 121.4088808),
            (31.2036224, 121.4088837),
            (31.2034171, 121.4089168),
            (31.2034290, 121.4085308),
            (31.2031319, 121.4085790),
            (31.2030978, 121.4084626),
            (31.2029576, 121.4085147),
            (31.2025951, 121.4086756),
            (31.2018782, 121.4089799),
            (31.2018520, 121.4088951),
            (31.2017927, 121.4087231),
            (31.2017715, 121.4086193),
            (31.2017629, 121.4083615),
            (31.2017675, 121.4072233),
            (31.2018358, 121.4066580),
            (31.2018881, 121.4063487),
            (31.2020643, 121.4055043),
            (31.2022679, 121.4044407),
            (31.2024197, 121.4036725),
            (31.2025920, 121.4028090),
            (31.2026331, 121.4026639),
            (31.2024806, 121.4025490),
            (31.2025422, 121.4024355),
            (31.2026450, 121.4023754),
            (31.2027478, 121.4023840),
            (31.2028349, 121.4020825),
        ]
        let coordinates = roadNodes.map { CLLocation(latitude: $0.0, longitude: $0.1).gcj02.coordinate }
        let entranceTurn = 20 // 安顺路与伊犁路交叉口，共用节点使两段线连续。
        let bounds = MKPolyline(coordinates: coordinates, count: coordinates.count).boundingMapRect
        let region = MKCoordinateRegion(bounds.insetBy(dx: -bounds.width * 0.12, dy: -bounds.height * 0.25))
        let solid = Array(coordinates[...entranceTurn])
        let dashed = Array(coordinates[entranceTurn...])
        return PreviewRoute(walkingCoordinate: solid.distanceMidpoint ?? solid[0], solid: MKPolyline(coordinates: solid, count: solid.count),
                            dashed: MKPolyline(coordinates: dashed, count: dashed.count), region: region)
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 0) {
                Group {
                    if let preview {
                        RoutePreview(route: preview, preferences: previewPreferences, containerSize: geometry.size)
                        .accessibilityLabel("上海路线预览，从东华大学延安路校区经安顺路、伊犁路到新虹桥中心花园")
                    } else {
                        ProgressView()
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: min(200, geometry.size.height * 0.4))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .task { preview = await Self.previewRoute.value }
                .padding(.horizontal)
                settingsForm
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .onDisappear { finishSliderEdit() }
        .navigationTitle("地图样式")
        .navigationBarTitleDisplayMode(.inline)
    }

    private struct RoutePreview: UIViewRepresentable {
        let route: PreviewRoute
        let preferences: BrowseMapPreferences
        let containerSize: CGSize
        @Environment(\.colorScheme) private var systemScheme

        func makeCoordinator() -> Coordinator { Coordinator(self) }

        func makeUIView(context: Context) -> MKMapView {
            let map = MKMapView(frame: CGRect(origin: .zero, size: CGSize(width: max(1, containerSize.width),
                                                                         height: min(200, containerSize.height * 0.4))))
            map.isScrollEnabled = false
            map.isZoomEnabled = false
            map.isPitchEnabled = false
            map.isRotateEnabled = false
            map.delegate = context.coordinator
            map.setRegion(route.region, animated: false)
            map.addOverlays([route.solid, route.dashed])
            let walking = context.coordinator.walking
            walking.coordinate = route.walkingCoordinate
            walking.title = "步行"
            map.addAnnotation(walking)
            return map
        }

        func updateUIView(_ map: MKMapView, context: Context) {
            let coordinator = context.coordinator
            let previous = coordinator.parent
            coordinator.parent = self
            if !coordinator.configured || preferences.theme != previous.preferences.theme || preferences.places != previous.preferences.places {
                map.preferredConfiguration = preferences.configuration(defaultFilter: nil)
            }
            let wasConfigured = coordinator.configured
            coordinator.configured = true
            map.overrideUserInterfaceStyle = (preferences.scheme ?? systemScheme) == .dark ? .dark : .light
            if !wasConfigured || previous.preferences.colorHex != preferences.colorHex ||
                (previous.preferences.scheme ?? previous.systemScheme) != (preferences.scheme ?? systemScheme) {
                if let view = map.view(for: coordinator.walking) { coordinator.updateWalkingIcon(view, map: map) }
            }
            for line in [route.solid, route.dashed] {
                if let renderer = map.renderer(for: line) as? BrowseRouteRenderer {
                    coordinator.configure(renderer, line: line, map: map)
                }
            }
        }

        final class Coordinator: NSObject, MKMapViewDelegate {
            let walking = MKPointAnnotation()
            func updateWalkingIcon(_ view: MKAnnotationView, map: MKMapView) {
                view.image = RouteTransportMarker.image(icon: TransportType.slow.sfSymbol, travelsWest: true,
                                                       tint: parent.preferences.color(),
                                                       scheme: map.traitCollection.userInterfaceStyle == .dark ? .dark : .light)
            }

            func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
                guard annotation === walking else { return nil }
                let view = MKAnnotationView(annotation: annotation, reuseIdentifier: nil)
                view.displayPriority = .required
                updateWalkingIcon(view, map: mapView)
                return view
            }

            var parent: RoutePreview
            var configured = false
            init(_ parent: RoutePreview) { self.parent = parent }

            func configure(_ renderer: BrowseRouteRenderer, line: MKPolyline, map: MKMapView) {
                let dashed = line === parent.route.dashed
                renderer.configureTransport(parent.preferences, traits: map.traitCollection, dashed: dashed)
            }

            func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
                guard let line = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
                let renderer = BrowseRouteRenderer(polyline: line)
                configure(renderer, line: line, map: mapView)
                return renderer
            }
        }
    }

    private func sliderRow(_ title: String, key: WritableKeyPath<BrowseMapPreferences, Double>,
                           range: ClosedRange<Double>, step: Double, display: String) -> some View {
        VStack {
            HStack {
                Text(title)
                Spacer()
                Text(display).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: Binding(
                get: { previewPreferences[keyPath: key] },
                set: { value in
                    if editingSlider == key { sliderValue = value }
                    else { settings.value[keyPath: key] = value }
                }
            ), in: range, step: step, onEditingChanged: { editing in
                if editing { editingSlider = key }
                else { finishSliderEdit() }
            })
            .accessibilityLabel(title)
            .accessibilityValue(display)
        }
    }

    private var settingsForm: some View {
        Form {
            Section("地图主题") {
                Picker("类型", selection: $settings.value.theme) {
                    Text("标准").tag(BrowseMapPreferences.Theme.standard)
                    Text("淡化").tag(BrowseMapPreferences.Theme.muted)
                    Text("卫星").tag(BrowseMapPreferences.Theme.satellite)
                    Text("卫星带路名").tag(BrowseMapPreferences.Theme.hybrid)
                }
                if settings.value.supportsAppearance {
                    Picker("外观", selection: $settings.value.appearance) {
                        Text("跟随系统").tag(BrowseMapPreferences.Appearance.system)
                        Text("浅色").tag(BrowseMapPreferences.Appearance.light)
                        Text("深色").tag(BrowseMapPreferences.Appearance.dark)
                    }
                }
                if settings.value.theme != .satellite {
                    Picker("标签", selection: $settings.value.places) {
                        Text("页面默认").tag(BrowseMapPreferences.Places.page)
                        Text("显示").tag(BrowseMapPreferences.Places.show)
                        Text("隐藏").tag(BrowseMapPreferences.Places.hide)
                    }
                }
            }
            Section("交通线样式") {
                ColorPicker("颜色", selection: Binding(get: { settings.value.color() },
                                                      set: { settings.value.colorHex = $0.toHex() }), supportsOpacity: false)
                sliderRow("宽度", key: \.width, range: BrowseMapPreferences.widthRange, step: 0.05,
                          display: "\(previewPreferences.width.formatted(.number.precision(.fractionLength(0...2))))×")
                sliderRow("不透明度", key: \.opacity, range: BrowseMapPreferences.transparencyRange, step: 0.01,
                          display: previewPreferences.opacity.formatted(.percent))
                Toggle("边框", isOn: $settings.value.outline)
                Toggle("边缘荧光", isOn: $settings.value.glow)
            }
            Section {
                Button("恢复默认") { confirmingReset = true }
                    .disabled(settings.value == BrowseMapPreferences())
                    .confirmationDialog("恢复默认地图样式？", isPresented: $confirmingReset, titleVisibility: .visible) {
                        Button("恢复默认", role: .destructive) { settings.value = BrowseMapPreferences() }
                        Button("取消", role: .cancel) { }
                    } message: {
                        Text("地图主题、标签和交通线样式将恢复为默认设置。")
                    }
            }
        }
    }
}
