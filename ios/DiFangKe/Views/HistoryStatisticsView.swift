import SwiftUI
import SwiftData
import MapKit
import UIKit

extension Notification.Name {
    static let dfkShareHistoryStatistics = Notification.Name("dfkShareHistoryStatistics")
}

enum StatisticsRange: Hashable {
    case last7Days
    case last30Days
    case last90Days
    case lastYear
    case customYear(Int)
    
    var rawValue: String {
        switch self {
        case .last7Days: return "7天"
        case .last30Days: return "30天"
        case .last90Days: return "90天"
        case .lastYear: return "1年"
        case .customYear(let y): return String(y)
        }
    }
    
    var days: Int? {
        switch self {
        case .last7Days: return 7
        case .last30Days: return 30
        case .last90Days: return 90
        case .lastYear: return 365
        default: return nil
        }
    }

    /// The review page's range wording, e.g. in titles.
    var reviewTitle: String {
        switch self {
        case .last7Days: return "最近7天"
        case .last30Days: return "最近30天"
        case .last90Days: return "最近90天"
        case .lastYear: return "过去一年"
        case .customYear(let year): return "\(year)年"
        }
    }
}

private enum FrequentPlaceRankScope: String, CaseIterable, Identifiable {
    case country = "国家"
    case city = "城市"
    case place = "地点"

    var id: Self { self }
}

private enum ActivityRankScope: String, CaseIterable, Identifiable {
    case footprints = "足迹"
    case transport = "交通"

    var id: Self { self }
}

private enum ReviewBentoDetail: String, Identifiable {
    case activity
    case rhythm
    case transport
    case regions

    var id: String { rawValue }
}

private func simplifiedChineseName(_ value: String) -> String {
    value.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? value
}

private struct StatisticsGeographyCandidate: Sendable {
    let footprintID: UUID
    let latitude: Double
    let longitude: Double
    let address: String?
}

private struct StatisticsGeographyResult: Sendable {
    let footprintID: UUID
    let countryCode: String
    let countryName: String
    let cityName: String
}

private struct ReviewMemoryCandidate: Identifiable {
    let id: String
    let date: Date
    let footprintID: UUID?
    /// The footprint's integrated place key, used to keep one memory per place.
    let placeKey: String?
    let title: String
    let evidence: String
    let reason: String
    let systemImage: String
    let photoAssetIDs: [String]
    let score: Double
}

private struct ReviewMemoryPhotoCarousel: View {
    let sourceAssetIDs: [String]
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedIndex = 0
    /// Oldest first, resolved through Photos off main.
    @State private var orderedAssetIDs: [String]?

    init(assetIDs: [String]) {
        self.sourceAssetIDs = assetIDs
    }

    private var assetIDs: [String] { orderedAssetIDs ?? [] }

    var body: some View {
        Group {
            if orderedAssetIDs == nil {
                // Until the order is known, show the same earliest photo the
                // carousel starts with.
                ContinuousTimelinePhotoThumbnail(
                    assetIDs: sourceAssetIDs,
                    targetSide: 420,
                    fillsAvailableSpace: true,
                    usesHighQualityThumbnail: true,
                    prefersEarliestPhoto: true
                )
            } else {
                carousel
            }
        }
        .task(id: sourceAssetIDs) {
            let ordered = await PhotoService.shared.assetIDsOldestFirstAsync(sourceAssetIDs)
            guard !Task.isCancelled else { return }
            orderedAssetIDs = ordered
        }
    }

    private var carousel: some View {
        TabView(selection: $selectedIndex) {
            ForEach(Array(assetIDs.enumerated()), id: \.element) { index, assetID in
                ContinuousTimelinePhotoThumbnail(
                    assetIDs: [assetID],
                    targetSide: 420,
                    fillsAvailableSpace: true,
                    usesHighQualityThumbnail: true,
                    prefersEarliestPhoto: true
                )
                .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .task(id: scenePhase) {
            guard scenePhase == .active, assetIDs.count > 1 else { return }
            let interval = max(1, AppConfig.shared.reviewMemoryCarouselInterval)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled, scenePhase == .active else { return }
                withAnimation(.easeInOut(duration: AppConfig.shared.reviewMemoryCarouselAnimationDuration)) {
                    selectedIndex = (selectedIndex + 1) % assetIDs.count
                }
            }
        }
    }
}

private struct ReviewPlaceSelection: Identifiable {
    let id: String
    let title: String
    let rangeText: String
    let visits: [Footprint]
    let photoAssetIDs: [String]
    /// Precomputed off main with the selection.
    let stats: ReviewPlaceStats

    /// Maps a background place group back to the caller's models.
    init?(group: ReviewPlaceGroup, rangeText: String, footprintsByID: [UUID: Footprint]) {
        let visits = group.visitIDs.compactMap { footprintsByID[$0] }
        guard !visits.isEmpty else { return nil }
        self.id = group.id
        self.title = group.title
        self.rangeText = rangeText
        self.visits = visits
        self.photoAssetIDs = group.photoAssetIDs
        self.stats = group.stats
    }
}

/// The places a review sheet shows, re-resolved whenever the sheet's own
/// range changes: by place key, or by a ranking item.
private struct ReviewPlaceQuery: Hashable {
    enum Source: Hashable {
        case placeKeys([String])
        case rankItem(FrequentPlaceRankScope, String)
    }

    let id: String
    let source: Source
    /// List title; a single place uses its own title.
    let title: String
    /// Full review map places use map titles, everything else place names.
    let usesMapTitle: Bool
    /// Shown as a list even when one place remains.
    let presentsList: Bool
}

/// Every sheet the review page opens. Each is hosted by its own
/// `HistoryStatisticsView` in sheet mode, so its range picker never changes
/// the page or any other sheet.
private enum ReviewSheetContent: Identifiable {
    case map
    case bento(ReviewBentoDetail)
    case favorites
    /// The query, and its places as resolved for the opening range.
    case places(ReviewPlaceQuery, [ReviewPlaceSelection])

    var id: String {
        switch self {
        case .map: return "map"
        case .bento(let detail): return "bento-\(detail.rawValue)"
        case .favorites: return "favorites"
        case .places(let query, _): return "places-\(query.id)"
        }
    }
}

/// The presenter's current review state, so a sheet opens with it at once
/// and only rebuilds when its own range changes.
private struct ReviewSheetSeed {
    let source: ReviewSourceSnapshot?
    let sourceFingerprint: Int?
    let range: StatisticsRange
    let activeYear: Int
    let derived: ReviewDerivedData
    let rangeFootprints: [Footprint]
    let rangeFootprintsByID: [UUID: Footprint]
    let tripActivityDays: [Date: String]
    let timelineItems: [TimelineItem]
    let mapRegion: MKCoordinateRegion?
    let mapPosition: MapCameraPosition
    let routesReady: Bool
    let frequentPlaceRankScope: FrequentPlaceRankScope
    /// Only sheets opened straight from the review page pick their own range;
    /// sheets opened from a sheet keep their presenter's range.
    let allowsRangeSelection: Bool
}

/// A sheet's own range selection, shown under its navigation title.
private struct ReviewRangeControl {
    let selection: Binding<StatisticsRange>
    let years: [Int]
    let activeYear: Int
}

/// The review page's segmented range picker; the last segment opens a year menu.
private struct ReviewRangePicker: View {
    @Binding var selection: StatisticsRange
    let years: [Int]
    let activeYear: Int

    private var isCustomYear: Bool {
        if case .customYear = selection { return true }
        return false
    }

    var body: some View {
        Picker("时间范围", selection: $selection) {
            Text("7天").tag(StatisticsRange.last7Days)
            Text("30天").tag(StatisticsRange.last30Days)
            Text("90天").tag(StatisticsRange.last90Days)
            Text("1年").tag(StatisticsRange.lastYear)
            Text(isCustomYear ? "\(String(activeYear)) ▾" : "年份 ▾")
                .tag(StatisticsRange.customYear(activeYear))
        }
        .pickerStyle(.segmented)
        .overlay {
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    Spacer()
                    if !years.isEmpty {
                        Menu {
                            ForEach(years, id: \.self) { year in
                                Button(String(year)) {
                                    selection = .customYear(year)
                                }
                            }
                        } label: {
                            Color.white.opacity(0.001)
                        }
                        .frame(width: geometry.size.width / 5)
                    }
                }
            }
        }
        .padding(.horizontal, 20)
    }
}

private extension View {
    /// Puts the sheet's range picker into its navigation bar, under the title.
    @ViewBuilder
    func reviewRangeBar(_ control: ReviewRangeControl?) -> some View {
        if let control {
            let picker = ReviewRangePicker(selection: control.selection, years: control.years, activeYear: control.activeYear)
                .padding(.bottom, 8)
            if #available(iOS 26.0, *) {
                // Joins the navigation bar's own edge effect, like system pages
                // with a segmented control under the title.
                safeAreaBar(edge: .top, spacing: 0) { picker }
            } else {
                safeAreaInset(edge: .top, spacing: 0) {
                    picker
                        .padding(.top, 8)
                        .background { ReviewNavigationBarBlur() }
                }
            }
        } else {
            self
        }
    }
}

private struct ReviewPlaceListSelection: Identifiable {
    let id: String
    let title: String
    let rangeText: String
    let places: [ReviewPlaceSelection]
}

private struct ReviewActivitySlice: Identifiable {
    let id: String
    let name: String
    let duration: TimeInterval
    let color: Color
    let icon: String
}

private struct ReviewActivityBarValue: Identifiable {
    let slice: ReviewActivitySlice
    let value: Double
    let valueText: String
    var id: String { slice.id }
}

/// Ranked horizontal bars per activity type (review activity details and place pages).
private struct ReviewActivityHorizontalBars: View {
    let title: String
    let icon: String
    let values: [ReviewActivityBarValue]

    var body: some View {
        let rankedValues = values.sorted {
            if $0.value != $1.value { return $0.value > $1.value }
            return $0.slice.name.localizedStandardCompare($1.slice.name) == .orderedAscending
        }
        let maximum = max(1, rankedValues.first?.value ?? 1)
        return VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: icon).font(.headline)
            ForEach(rankedValues.prefix(6)) { item in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label(item.slice.name, systemImage: item.slice.icon)
                            .lineLimit(1)
                        Spacer()
                        Text(item.valueText).fontWeight(.semibold).foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    GeometryReader { geometry in
                        Capsule().fill(item.slice.color.opacity(0.14))
                        Capsule()
                            .fill(item.slice.color)
                            .frame(width: max(5, geometry.size.width * item.value / maximum))
                    }
                    .frame(height: 8)
                }
            }
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

private struct ReviewActivityHeatmapRow: Identifiable {
    let slice: ReviewActivitySlice
    let counts: [Int]
    var id: String { slice.id }
}

private struct ReviewDailyFootprintHeatmap: View {
    let values: [Int]
    var preferredColumnCount: Int? = nil
    var accessibilityText = "每日足迹"

    var body: some View {
        Canvas { context, size in
            guard !values.isEmpty, size.width > 0, size.height > 0 else { return }

            let spacing: CGFloat = values.count > 100 ? 1.5 : 3
            let aspectRatio = Double(size.width / size.height)
            let automaticColumnCount = max(1, Int(ceil(sqrt(Double(values.count) * aspectRatio))))
            let columnCount = min(values.count, max(1, preferredColumnCount ?? automaticColumnCount))
            let rowCount = max(1, Int(ceil(Double(values.count) / Double(columnCount))))
            let cellSide = max(
                1,
                min(
                    (size.width - spacing * CGFloat(columnCount - 1)) / CGFloat(columnCount),
                    (size.height - spacing * CGFloat(rowCount - 1)) / CGFloat(rowCount)
                )
            )
            let gridWidth = cellSide * CGFloat(columnCount) + spacing * CGFloat(columnCount - 1)
            let horizontalOffset = max(0, (size.width - gridWidth) / 2)
            let maximum = max(1, values.max() ?? 1)

            for index in values.indices {
                let row = index / columnCount
                let column = index % columnCount
                let rect = CGRect(
                    x: horizontalOffset + CGFloat(column) * (cellSide + spacing),
                    y: CGFloat(row) * (cellSide + spacing),
                    width: cellSide,
                    height: cellSide
                )
                let color = values[index] == 0
                    ? Color(uiColor: .systemGray5)
                    : Color.dfkAccent.opacity(0.22 + 0.78 * Double(values[index]) / Double(maximum))
                context.fill(
                    Path(roundedRect: rect, cornerSize: CGSize(width: min(3, cellSide * 0.22), height: min(3, cellSide * 0.22))),
                    with: .color(color)
                )
            }
        }
        .accessibilityElement()
        .accessibilityLabel("\(accessibilityText)，共\(values.count)天")
    }
}

private final class ReviewNavigationBarBlurView: UIVisualEffectView {
    private let fadeMask = CAGradientLayer()
    private var blurAnimator: UIViewPropertyAnimator?

    init() {
        super.init(effect: nil)
        contentView.backgroundColor = UIColor.systemGroupedBackground.withAlphaComponent(0.72)
        let animator = UIViewPropertyAnimator(duration: 1, curve: .linear) { [weak self] in
            self?.effect = UIBlurEffect(style: .systemChromeMaterial)
        }
        animator.fractionComplete = 0.6
        blurAnimator = animator
        fadeMask.colors = [
            UIColor.black.cgColor,
            UIColor.black.cgColor,
            UIColor.clear.cgColor
        ]
        fadeMask.locations = [0, 0.68, 1]
        layer.mask = fadeMask
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        fadeMask.frame = bounds
    }

    deinit {
        blurAnimator?.stopAnimation(true)
    }
}

private struct ReviewNavigationBarBlur: UIViewRepresentable {
    func makeUIView(context: Context) -> ReviewNavigationBarBlurView {
        ReviewNavigationBarBlurView()
    }

    func updateUIView(_ uiView: ReviewNavigationBarBlurView, context: Context) {
        uiView.contentView.backgroundColor = UIColor.systemGroupedBackground.withAlphaComponent(0.72)
    }
}

private struct ReviewTransportSlice: Identifiable {
    let id: String
    let name: String
    let count: Int
    let distance: Double
    let color: Color
    let icon: String
}

private struct ReviewTransportBarValue: Identifiable {
    let slice: ReviewTransportSlice
    let value: Double
    let valueText: String
    var id: String { slice.id }
}

private struct ReviewTransportHeatmapRow: Identifiable {
    let slice: ReviewTransportSlice
    let counts: [Int]
    var id: String { slice.id }
}

private struct ReviewMileageMetrics {
    let dailyValues: [(date: Date, distance: Double)]
    let total: Double
    let dailyAverage: Double
    let peakDay: (date: Date, distance: Double)?
    let activeDayCount: Int
    let weekdayAverages: [Double]
}

private struct ReviewTransportBuildSnapshot: @unchecked Sendable {
    let id: UUID
    let startTime: Date
    let endTime: Date
    let startLocation: String
    let endLocation: String
    let typeRaw: String
    let distance: Double
    let averageSpeed: Double
    let pointsData: Data
    let manualTypeRaw: String?
    let stepCount: Int?
}

private struct ReviewDecodedTransport: @unchecked Sendable {
    let source: ReviewTransportBuildSnapshot
    let points: [CodableCoordinate]
}

private struct ReviewMapBounds: Sendable {
    let minimumLatitude: Double
    let maximumLatitude: Double
    let minimumLongitude: Double
    let maximumLongitude: Double
}

private struct ReviewMemoryCachePayload: Codable {
    let revision: Int
    let entries: [ReviewMemoryCacheEntry]
}

private struct ReviewMemoryCacheEntry: Codable {
    let id: String
    let date: Date
    let footprintID: UUID?
    let title: String
    let evidence: String
    let reason: String
    let systemImage: String
    let photoAssetIDs: [String]
    let score: Double
}

/// Keeps reverse-geocoding off the main actor. The statistics view only receives
/// completed value results in small batches, so MapKit/SwiftUI stays responsive.
private actor StatisticsGeographyResolver {
    private let geocoder = CLGeocoder()

    func resolve(_ candidate: StatisticsGeographyCandidate) async -> StatisticsGeographyResult? {
        let location = CLLocation(latitude: candidate.latitude, longitude: candidate.longitude)
        var countryCode: String?
        var countryName: String?
        var cityName: String?

        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(location)
            if let placemark = placemarks.first {
                countryCode = placemark.isoCountryCode
                countryName = countryCode.flatMap {
                    Locale(identifier: "zh_Hans_CN").localizedString(forRegionCode: $0)
                } ?? placemark.country
                cityName = placemark.locality ?? placemark.subAdministrativeArea ?? placemark.administrativeArea
            }
        } catch { }

        if countryCode == nil || countryName?.isEmpty != false || cityName?.isEmpty != false,
           let overseas = await OpenStreetMapGeocoder.shared.lookupInternationalHierarchy(coordinate: location.coordinate) {
            countryCode = overseas.countryCode ?? countryCode
            countryName = overseas.countryName ?? countryName
            cityName = overseas.cityName ?? cityName
        }

        if (countryCode == nil || countryName?.isEmpty != false || cityName?.isEmpty != false),
           let savedHierarchy = DFKGeographicHierarchy.fromPersistedForeignAddress(candidate.address) {
            countryCode = savedHierarchy.countryCode
            countryName = savedHierarchy.countryName
            cityName = savedHierarchy.cityName
        }

        guard let countryCode,
              let countryName, !countryName.isEmpty,
              let cityName, !cityName.isEmpty else {
            return nil
        }
        return StatisticsGeographyResult(
            footprintID: candidate.footprintID,
            countryCode: countryCode,
            countryName: simplifiedChineseName(countryName),
            cityName: simplifiedChineseName(cityName)
        )
    }

    func cancel() {
        geocoder.cancelGeocode()
    }
}

// MARK: - Background review data

/// Value copy of the footprint fields the review page reads. Taken in a
/// background context so grouping, ranking and scoring never walk models on
/// the main actor.
private struct ReviewFootprintSnapshot: @unchecked Sendable {
    let footprintID: UUID
    let startTime: Date
    let endTime: Date
    let latitude: Double
    let longitude: Double
    let photoAssetIDs: [String]
    let placeID: UUID?
    let address: String?
    let reason: String?
    let countryCode: String?
    let countryName: String?
    let cityName: String?
    let activityTypeValue: String?
    /// `activityTypeValue` resolved against the activity table with the snapshot.
    let activity: ReviewActivitySnapshot?
    let status: FootprintStatus
    let isHighlight: Bool?
    let isAddressEditedByHand: Bool
    /// The linked saved place's raw name and address; nil name when the
    /// footprint has no saved place.
    let savedPlaceName: String?
    let savedPlaceAddress: String?
    /// `reviewIntegratedPlaceKey(for:allPlaces:)`, resolved with the snapshot.
    let placeKey: String
    /// Saved place name, else the trimmed address (review titles).
    let placeName: String
    /// Saved place name, address or city (full review map titles).
    let mapTitle: String

    // Same rule as `Footprint.duration`.
    var duration: TimeInterval { max(0, endTime.timeIntervalSince(startTime)) }
}

private struct ReviewTransportSnapshot: Sendable {
    let id: UUID
    let startTime: Date
    let endTime: Date
    let typeRaw: String
    let manualTypeRaw: String?
    let distance: Double

    // Same rule as the former `reviewTransportType(for:)`.
    var type: TransportType {
        manualTypeRaw.flatMap(TransportType.init(rawValue:))
            ?? TransportType(rawValue: typeRaw)
            ?? .slow
    }
}

private struct ReviewActivitySnapshot: @unchecked Sendable {
    let id: UUID
    let name: String
    let icon: String
    let color: Color
}

/// Database-wide review source, fetched and fingerprinted off main.
private struct ReviewSourceSnapshot: @unchecked Sendable {
    let fingerprint: Int
    /// Non-ignored footprints, newest first (the former `allFootprints` order).
    let footprints: [ReviewFootprintSnapshot]
    let transports: [ReviewTransportSnapshot]
    let activities: [ReviewActivitySnapshot]
    let priorityPlaceIDs: Set<UUID>
}

/// AppConfig values the background builders read, captured on main.
private struct ReviewConfigSnapshot: Sendable {
    let longStayMinDuration: Double
    let photoMinCount: Int
    let firstVisitPhotoMinCount: Int
    let frequentVisitMinCount: Int
    let unusualDurationRatio: Double
    let minimumScore: Double
    let maximumCount: Int
    let longTimeNoSeeDays: Int
    let travelDistanceMin: Double
    let walkDistanceMin: Double
    let diverseTransportMinCount: Int

    static func current() -> ReviewConfigSnapshot {
        let config = AppConfig.shared
        return ReviewConfigSnapshot(
            longStayMinDuration: config.reviewMemoryLongStayMinDuration,
            photoMinCount: config.reviewMemoryPhotoMinCount,
            firstVisitPhotoMinCount: config.reviewMemoryFirstVisitPhotoMinCount,
            frequentVisitMinCount: config.reviewMemoryFrequentVisitMinCount,
            unusualDurationRatio: config.reviewMemoryUnusualDurationRatio,
            minimumScore: config.reviewMemoryMinimumScore,
            maximumCount: config.reviewMemoryMaximumCount,
            longTimeNoSeeDays: config.longTimeNoSeeDays,
            travelDistanceMin: config.reviewMemoryTravelDistanceMin,
            walkDistanceMin: config.reviewMemoryWalkDistanceMin,
            diverseTransportMinCount: config.reviewMemoryDiverseTransportMinCount
        )
    }
}

/// The applied range resolved once against a fixed `now`, so the background
/// filter and the main-context range fetch select the same records.
private struct ReviewRangeWindow: Sendable {
    let range: StatisticsRange
    let now: Date
    /// Inclusive lower bound of `startTime`.
    let lowerBound: Date
    /// Exclusive upper bound of `startTime` (custom years only).
    let upperBound: Date?
    /// The former `reviewRangeStart` / `reviewRangeEnd`.
    let rangeStart: Date
    let rangeEnd: Date

    init(range: StatisticsRange, now: Date = Date()) {
        let calendar = Calendar.current
        self.range = range
        self.now = now
        switch range {
        case .last7Days, .last30Days, .last90Days, .lastYear:
            let days = range.days ?? 0
            let cutoff = calendar.date(byAdding: .day, value: -days, to: now) ?? now
            lowerBound = cutoff
            upperBound = nil
            rangeStart = cutoff
            rangeEnd = now
        case .customYear(let year):
            let yearStart = calendar.date(from: DateComponents(year: year, month: 1, day: 1)) ?? now
            lowerBound = yearStart
            upperBound = calendar.date(from: DateComponents(year: year + 1, month: 1, day: 1))
            rangeStart = yearStart
            rangeEnd = calendar.date(from: DateComponents(year: year, month: 12, day: 31)) ?? now
        }
    }

    /// Same membership rule as the former `filteredFootprints` /
    /// `filteredTransportRecords`.
    func contains(_ date: Date) -> Bool {
        if case .customYear(let year) = range {
            return Calendar.current.component(.year, from: date) == year
        }
        return date >= lowerBound
    }
}

/// Declared outside the view so the background builder can create it
/// without touching the view's main-actor isolation.
private struct ReviewFrequentPlaceItem: Identifiable {
    let id: String
    let name: String
    let address: String
    let count: Int
    let duration: TimeInterval
    let footprintIDs: [UUID]
}

private struct ReviewGeographyMetric {
    let icon: String
    let value: String
    let label: String
}

private struct ReviewRhythmMetrics {
    let dailyCounts: [(date: Date, count: Int)]
    let activeDayCount: Int
    let activeDayRate: Int
    let weeklyAverageText: String
    let activeDayAverageText: String
    let peakCount: Int
    let longestStreak: Int
    let weekdayAverages: [CGFloat]
    let hourlyCounts: [Int]
}

private struct ReviewPlaceStats {
    let totalDuration: TimeInterval
    let geographyText: String?
    let weekdayCounts: [Int]
    let hourlyCounts: [Int]
    /// Visit durations in chronological order.
    let durationTrend: [Double]
    let averageDuration: TimeInterval
    let firstVisitDate: Date?
    let lastVisitDate: Date?
    /// Total stay per activity type, longest first.
    let activitySlices: [ReviewActivitySlice]
    let activityVisitCounts: [String: Int]
    let visitActivities: [UUID: ReviewActivitySnapshot]
}

/// A place's visits grouped and summarised in the background; the main actor
/// only maps `visitIDs` back to its own models.
private struct ReviewPlaceGroup: @unchecked Sendable {
    let id: String
    let title: String
    /// Newest first.
    let visitIDs: [UUID]
    let photoAssetIDs: [String]
    let stats: ReviewPlaceStats
}

/// Everything the review page derives from the source for one applied range.
/// Built in the background; `body` and its sections only read it.
private struct ReviewDerivedData: @unchecked Sendable {
    var range: StatisticsRange?
    /// Range footprints in source order (newest first).
    var rangeFootprints: [ReviewFootprintSnapshot] = []
    var rangeTransports: [ReviewTransportSnapshot] = []
    var rangeSnapshotsByID: [UUID: ReviewFootprintSnapshot] = [:]
    var footprintIDsByPlaceKey: [String: [UUID]] = [:]
    var favoriteFootprintIDs: Set<UUID> = []
    var availableYears: [Int] = []
    var transportCount = 0
    var totalDistance = 0.0
    var mapRevision = 0
    var geographyMetric = ReviewGeographyMetric(icon: "mappin.and.ellipse", value: "0", label: "个地点")
    var activitySlices: [ReviewActivitySlice] = []
    var activityRecognizedCount = 0
    var activityVisitCounts: [String: Int] = [:]
    var activityWeekdayCounts: [String: [Int]] = [:]
    var activityHourlyCounts: [String: [Int]] = [:]
    var transportSlices: [ReviewTransportSlice] = []
    var transportActiveDays: [String: Int] = [:]
    var transportWeekdayCounts: [String: [Int]] = [:]
    var transportHourlyCounts: [String: [Int]] = [:]
    var topRegions: [(name: String, duration: TimeInterval)] = []
    var pastMemoryCandidate: ReviewMemoryCandidate?
    var activityBuckets: [Int] = Array(repeating: 0, count: 24)
    var rhythm = ReviewRhythmMetrics(
        dailyCounts: [],
        activeDayCount: 0,
        activeDayRate: 0,
        weeklyAverageText: "0次",
        activeDayAverageText: "0次",
        peakCount: 0,
        longestStreak: 0,
        weekdayAverages: Array(repeating: 0, count: 7),
        hourlyCounts: Array(repeating: 0, count: 24)
    )
    var mileage = ReviewMileageMetrics(
        dailyValues: [],
        total: 0,
        dailyAverage: 0,
        peakDay: nil,
        activeDayCount: 0,
        weekdayAverages: Array(repeating: 0, count: 7)
    )
    var frequentPlaces: [FrequentPlaceRankScope: [ReviewFrequentPlaceItem]] = [:]
    var defaultFrequentPlaceRankScope: FrequentPlaceRankScope = .city
    var shareCoordinates: [CLLocationCoordinate2D] = []
    var photoCaptions: [String: String] = [:]

    func placeKey(for footprintID: UUID) -> String? {
        rangeSnapshotsByID[footprintID]?.placeKey
    }
}

private enum ReviewTimelineSlot: Sendable {
    case footprint(UUID)
    case transport(Int)
}

/// Routes, map bounds and timeline order for one applied range.
private struct ReviewDerivedResult: @unchecked Sendable {
    let derived: ReviewDerivedData
    let transports: [Transport]
    /// `(footprints + transports)` sorted by start time.
    let timelineSlots: [ReviewTimelineSlot]
    let bounds: ReviewMapBounds?
}

/// Runs `operation` detached and forwards cancellation of the awaiting task.
private func reviewDetached<T: Sendable>(
    priority: TaskPriority = .utility,
    _ operation: @escaping @Sendable () async -> T
) async -> T {
    let task = Task.detached(priority: priority, operation: operation)
    return await withTaskCancellationHandler {
        await task.value
    } onCancel: {
        task.cancel()
    }
}

/// Pure, nonisolated builders for the review page. Every function here runs
/// off the main actor and works only on snapshots or a private ModelContext.
private enum ReviewDataBuilder {
    static let weekdaySymbols = ["一", "二", "三", "四", "五", "六", "日"]

    // MARK: Formatting (shared with the view)

    static func formatRankDuration(_ duration: TimeInterval) -> String {
        let totalMinutes = Int(duration / 60)
        guard totalMinutes >= 60 else {
            return "\(totalMinutes)分钟"
        }

        let totalHours = totalMinutes / 60
        if totalHours >= 24 {
            let days = totalHours / 24
            if duration > 3 * 24 * 60 * 60 {
                return "\(days)天"
            }
            return "\(days)天\(totalHours % 24)小时"
        }

        let hours = Double(totalMinutes) / 60
        if hours < 10 {
            return String(format: "%.1f小时", hours)
        }
        return "\(Int(hours))小时"
    }

    static func formatRankMileage(_ distance: Double) -> String {
        if distance < 1_000 {
            return "\(Int(distance.rounded()))米"
        }
        return String(format: "%.1f公里", distance / 1_000)
    }

    static func compactNumber<T: BinaryFloatingPoint>(_ value: T) -> String {
        let number = Double(value)
        if abs(number.rounded() - number) < 0.05 {
            return String(Int(number.rounded()))
        }
        return String(format: "%.1f", number)
    }

    static func flagEmoji(for countryCode: String) -> String {
        let base: UInt32 = 127397
        return countryCode.uppercased().unicodeScalars.compactMap {
            UnicodeScalar(base + $0.value).map(String.init)
        }.joined()
    }

    static func rankName(
        for scope: FrequentPlaceRankScope,
        placeName: String,
        countryName: String?,
        countryCode: String?,
        cityName: String?
    ) -> String? {
        switch scope {
        case .place:
            return placeName
        case .country:
            guard let countryName, let countryCode else { return nil }
            return "\(flagEmoji(for: countryCode)) \(simplifiedChineseName(countryName))"
        case .city:
            return cityName.map(simplifiedChineseName)
        }
    }

    // MARK: Source

    /// Fetches the review source in its own context and fingerprints it.
    /// Returns nil when a fetch fails so the caller keeps its current source.
    static func fetchSource(in container: ModelContainer) -> ReviewSourceSnapshot? {
        let context = ModelContext(container)
        let footprintDescriptor = FetchDescriptor<Footprint>(
            predicate: #Predicate<Footprint> { $0.statusValue != "ignored" },
            sortBy: [SortDescriptor(\Footprint.startTime, order: .reverse)]
        )
        let transportRecordDescriptor = FetchDescriptor<TransportRecord>(
            predicate: #Predicate<TransportRecord> { $0.statusRaw == "active" }
        )
        let activityDescriptor = FetchDescriptor<ActivityType>(
            sortBy: [SortDescriptor(\ActivityType.sortOrder)]
        )
        guard let fetchedFootprints = try? context.fetch(footprintDescriptor),
              let fetchedTransports = try? context.fetch(transportRecordDescriptor),
              let fetchedActivities = try? context.fetch(activityDescriptor),
              let fetchedPlaces = try? context.fetch(FetchDescriptor<Place>()) else {
            return nil
        }

        var hasher = Hasher()
        for footprint in fetchedFootprints {
            hasher.combine(footprint.footprintID)
            hasher.combine(footprint.startTime)
            hasher.combine(footprint.endTime)
            hasher.combine(footprint.latitudeData.count)
            hasher.combine(footprint.longitudeData.count)
            hasher.combine(footprint.photoAssetIDsData)
            hasher.combine(footprint.placeID)
            hasher.combine(footprint.activityTypeValue)
            hasher.combine(footprint.countryCode)
            hasher.combine(footprint.cityName)
            hasher.combine(footprint.statusValue)
        }
        for transport in fetchedTransports {
            hasher.combine(transport.recordID)
            hasher.combine(transport.startTime)
            hasher.combine(transport.endTime)
            hasher.combine(transport.typeRaw)
            hasher.combine(transport.manualTypeRaw)
            hasher.combine(transport.distance)
            // Route payloads can be very large. Their identity, time range and
            // byte count are sufficient to detect normal edits without hashing
            // the entire JSON blob for every app-wide signal.
            hasher.combine(transport.pointsData.count)
        }
        for activity in fetchedActivities {
            hasher.combine(activity.id)
            hasher.combine(activity.name)
            hasher.combine(activity.icon)
            hasher.combine(activity.colorHex)
            hasher.combine(activity.sortOrder)
        }
        for place in fetchedPlaces {
            hasher.combine(place.placeID)
            hasher.combine(place.name)
            hasher.combine(place.latitude)
            hasher.combine(place.longitude)
            hasher.combine(place.address)
            hasher.combine(place.category)
        }

        // `allPlaces.first(where:)` semantics: the first place per ID wins.
        var placesByID: [UUID: Place] = [:]
        for place in fetchedPlaces where placesByID[place.placeID] == nil {
            placesByID[place.placeID] = place
        }

        let activities = fetchedActivities.map {
            ReviewActivitySnapshot(id: $0.id, name: $0.name, icon: $0.icon, color: $0.color)
        }
        let footprints = fetchedFootprints.map { footprint -> ReviewFootprintSnapshot in
            let place = footprint.placeID.flatMap { placesByID[$0] }
            let address = footprint.address?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let placeName: String
            if let place, !place.name.isEmpty {
                placeName = place.name
            } else {
                placeName = address.isEmpty ? "这个地方" : address
            }
            let mapTitle = [
                place?.name.trimmingCharacters(in: .whitespacesAndNewlines),
                footprint.address?.trimmingCharacters(in: .whitespacesAndNewlines),
                footprint.cityName?.trimmingCharacters(in: .whitespacesAndNewlines)
            ]
                .compactMap { $0 }
                .first { !$0.isEmpty } ?? "地点"
            return ReviewFootprintSnapshot(
                footprintID: footprint.footprintID,
                startTime: footprint.startTime,
                endTime: footprint.endTime,
                latitude: footprint.latitude,
                longitude: footprint.longitude,
                photoAssetIDs: footprint.photoAssetIDs,
                placeID: footprint.placeID,
                address: footprint.address,
                reason: footprint.reason,
                countryCode: footprint.countryCode,
                countryName: footprint.countryName,
                cityName: footprint.cityName,
                activityTypeValue: footprint.activityTypeValue,
                activity: activityType(value: footprint.activityTypeValue, in: activities),
                status: footprint.status,
                isHighlight: footprint.isHighlight,
                isAddressEditedByHand: footprint.isAddressEditedByHand,
                savedPlaceName: place?.name,
                savedPlaceAddress: place?.address,
                placeKey: reviewIntegratedPlaceKey(for: footprint, allPlaces: fetchedPlaces),
                placeName: placeName,
                mapTitle: mapTitle
            )
        }
        let transports = fetchedTransports.map {
            ReviewTransportSnapshot(
                id: $0.recordID,
                startTime: $0.startTime,
                endTime: $0.endTime,
                typeRaw: $0.typeRaw,
                manualTypeRaw: $0.manualTypeRaw,
                distance: $0.distance
            )
        }
        return ReviewSourceSnapshot(
            fingerprint: hasher.finalize(),
            footprints: footprints,
            transports: transports,
            activities: activities,
            priorityPlaceIDs: Set(fetchedPlaces.filter(\.isPriority).map(\.placeID))
        )
    }

    // MARK: Derived data

    /// Same rule as `Footprint.getActivityType(from:)`.
    static func activityType(value: String?, in activities: [ReviewActivitySnapshot]) -> ReviewActivitySnapshot? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return activities.first { $0.id.uuidString == value || $0.name == value }
    }

    static func derive(
        source: ReviewSourceSnapshot,
        window: ReviewRangeWindow,
        tripActivityDays: [Date: String],
        config: ReviewConfigSnapshot,
        container: ModelContainer
    ) -> ReviewDerivedResult {
        let calendar = Calendar.current
        let activities = source.activities
        let rangeFootprints = source.footprints.filter { window.contains($0.startTime) }
        let rangeTransports = source.transports.filter { window.contains($0.startTime) }

        var derived = ReviewDerivedData()
        derived.range = window.range
        derived.rangeFootprints = rangeFootprints
        derived.rangeTransports = rangeTransports
        derived.availableYears = Set(source.footprints.map { calendar.component(.year, from: $0.startTime) })
            .sorted(by: >)

        var snapshotsByID: [UUID: ReviewFootprintSnapshot] = [:]
        var idsByPlaceKey: [String: [UUID]] = [:]
        for footprint in rangeFootprints {
            snapshotsByID[footprint.footprintID] = footprint
            idsByPlaceKey[footprint.placeKey, default: []].append(footprint.footprintID)
        }
        derived.rangeSnapshotsByID = snapshotsByID
        derived.footprintIDsByPlaceKey = idsByPlaceKey
        derived.favoriteFootprintIDs = Set(rangeFootprints.lazy
            .filter { $0.isHighlight == true && $0.status != .ignored }
            .map(\.footprintID))

        // Hero metrics.
        derived.transportCount = rangeTransports.count
        derived.totalDistance = rangeTransports.reduce(0) { $0 + $1.distance }
        let latestFootprint = rangeFootprints.map(\.endTime).max()?.timeIntervalSince1970 ?? 0
        let latestTransport = rangeTransports.map(\.endTime).max()?.timeIntervalSince1970 ?? 0
        let rangeCode: Int
        switch window.range {
        case .last7Days: rangeCode = 7
        case .last30Days: rangeCode = 30
        case .last90Days: rangeCode = 90
        case .lastYear: rangeCode = 365
        case .customYear(let year): rangeCode = year
        }
        let dataRevision = rangeCode &* 1_000_003
            &+ rangeFootprints.count &* 10_007
            &+ rangeTransports.count &* 101
            &+ Int(max(latestFootprint, latestTransport))
        derived.mapRevision = dataRevision &* 31 &+ 6

        // Former `getTopLocations(delta: 0.01).count`: 3-decimal grid, top 200.
        let topLocationFactor = pow(10.0, 3.0)
        var topLocationKeys = Set<String>()
        for footprint in rangeFootprints {
            let lat = (footprint.latitude * topLocationFactor).rounded() / topLocationFactor
            let lon = (footprint.longitude * topLocationFactor).rounded() / topLocationFactor
            topLocationKeys.insert("\(lat),\(lon)")
        }
        let placeCount = min(200, topLocationKeys.count)

        let countryCodes = Set(rangeFootprints.compactMap { footprint -> String? in
            let value = footprint.countryCode?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? nil : value.uppercased()
        })
        let metricCities = Set(rangeFootprints.compactMap { footprint -> String? in
            let city = footprint.cityName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !city.isEmpty else { return nil }
            return "\(footprint.countryCode?.uppercased() ?? "")|\(city)"
        })
        if countryCodes.count > 1 {
            derived.geographyMetric = ReviewGeographyMetric(icon: "globe.asia.australia.fill", value: "\(countryCodes.count)", label: "个国家")
        } else if metricCities.count > 1 {
            derived.geographyMetric = ReviewGeographyMetric(icon: "building.2.fill", value: "\(metricCities.count)", label: "座城市")
        } else {
            derived.geographyMetric = ReviewGeographyMetric(icon: "mappin.and.ellipse", value: "\(placeCount)", label: "个地点")
        }

        // Activities.
        var activityTotals: [String: TimeInterval] = [:]
        var recognizedCount = 0
        var visitCounts: [String: Int] = [:]
        var activityWeekdays: [String: [Int]] = [:]
        var activityHours: [String: [Int]] = [:]
        for footprint in rangeFootprints {
            guard let activity = footprint.activity else { continue }
            recognizedCount += 1
            visitCounts[activity.name, default: 0] += 1
            let mondayFirstIndex = (calendar.component(.weekday, from: footprint.startTime) + 5) % 7
            activityWeekdays[activity.name, default: Array(repeating: 0, count: 7)][mondayFirstIndex] += 1
            activityHours[activity.name, default: Array(repeating: 0, count: 24)][calendar.component(.hour, from: footprint.startTime)] += 1
            // A trip day counts whole toward the trip's own type below, so
            // its individual stops are not counted a second time.
            guard tripActivityDays[calendar.startOfDay(for: footprint.startTime)] == nil else { continue }
            activityTotals[activity.name, default: 0] += footprint.duration
        }
        for value in tripActivityDays.values {
            guard let activity = activities.first(where: { $0.id.uuidString == value || $0.name == value }) else { continue }
            activityTotals[activity.name, default: 0] += 86_400
        }
        derived.activitySlices = activityTotals.compactMap { name, duration in
            guard let activity = activities.first(where: { $0.name == name }) else { return nil }
            return ReviewActivitySlice(id: name, name: name, duration: duration, color: activity.color, icon: activity.icon)
        }.sorted { $0.duration > $1.duration }
        derived.activityRecognizedCount = recognizedCount
        derived.activityVisitCounts = visitCounts
        derived.activityWeekdayCounts = activityWeekdays
        derived.activityHourlyCounts = activityHours

        // Transport.
        var transportCounts: [TransportType: Int] = [:]
        var transportDistances: [TransportType: Double] = [:]
        var transportDays: [String: Set<Date>] = [:]
        var transportWeekdays: [String: [Int]] = [:]
        var transportHours: [String: [Int]] = [:]
        for record in rangeTransports {
            let type = record.type
            transportCounts[type, default: 0] += 1
            transportDistances[type, default: 0] += record.distance
            transportDays[type.rawValue, default: []].insert(calendar.startOfDay(for: record.startTime))
            let mondayFirstIndex = (calendar.component(.weekday, from: record.startTime) + 5) % 7
            transportWeekdays[type.rawValue, default: Array(repeating: 0, count: 7)][mondayFirstIndex] += 1
            transportHours[type.rawValue, default: Array(repeating: 0, count: 24)][calendar.component(.hour, from: record.startTime)] += 1
        }
        let transportColors: [Color] = [.dfkAccent, .blue, .green, .orange, .purple]
        derived.transportSlices = transportCounts.map { type, count in
            let index = TransportType.allCases.firstIndex(of: type) ?? 0
            return ReviewTransportSlice(
                id: type.rawValue,
                name: type.localizedName,
                count: count,
                distance: transportDistances[type, default: 0],
                color: transportColors[index % transportColors.count],
                icon: type.sfSymbol
            )
        }.sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            return $0.distance > $1.distance
        }
        derived.transportActiveDays = transportDays.mapValues(\.count)
        derived.transportWeekdayCounts = transportWeekdays
        derived.transportHourlyCounts = transportHours

        // Regions.
        var regionTotals: [String: TimeInterval] = [:]
        for footprint in rangeFootprints {
            let city = footprint.cityName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let name = city.isEmpty ? footprint.placeName : city
            regionTotals[name, default: 0] += footprint.duration
        }
        derived.topRegions = regionTotals.map { (name: $0.key, duration: $0.value) }.sorted { $0.duration > $1.duration }

        derived.pastMemoryCandidate = pastMemoryCandidate(
            history: source.footprints,
            priorityPlaceIDs: source.priorityPlaceIDs,
            now: window.now
        )

        // Rhythm.
        let rangeDuration = max(1, window.rangeEnd.timeIntervalSince(window.rangeStart))
        var buckets = Array(repeating: 0, count: 24)
        var hourlyCounts = Array(repeating: 0, count: 24)
        for footprint in rangeFootprints {
            let progress = footprint.startTime.timeIntervalSince(window.rangeStart) / rangeDuration
            let index = min(23, max(0, Int(progress * 24)))
            buckets[index] += 1
            hourlyCounts[calendar.component(.hour, from: footprint.startTime)] += 1
        }
        derived.activityBuckets = buckets

        let endDate = calendar.startOfDay(for: min(window.rangeEnd, window.now))
        let dayCount: Int
        if let fixedDays = window.range.days {
            dayCount = fixedDays
        } else {
            let rangeStart = calendar.startOfDay(for: window.rangeStart)
            dayCount = max(1, (calendar.dateComponents([.day], from: rangeStart, to: endDate).day ?? 0) + 1)
        }
        let firstDate = calendar.date(byAdding: .day, value: -(dayCount - 1), to: endDate) ?? endDate
        let countsByDate = Dictionary(grouping: rangeFootprints) {
            calendar.startOfDay(for: $0.startTime)
        }.mapValues(\.count)
        let dailyCounts: [(date: Date, count: Int)] = (0..<dayCount).map { offset in
            let date = calendar.date(byAdding: .day, value: offset, to: firstDate) ?? firstDate
            return (date, countsByDate[date, default: 0])
        }
        let activeDayCount = dailyCounts.filter { $0.count > 0 }.count
        let totalCount = dailyCounts.reduce(0) { $0 + $1.count }
        let rhythmDays = max(1, dailyCounts.count)
        var longestStreak = 0
        var currentStreak = 0
        var weekdayTotals = Array(repeating: 0, count: 7)
        var weekdayOccurrences = Array(repeating: 0, count: 7)
        for item in dailyCounts {
            if item.count > 0 {
                currentStreak += 1
                longestStreak = max(longestStreak, currentStreak)
            } else {
                currentStreak = 0
            }
            let mondayFirstIndex = (calendar.component(.weekday, from: item.date) + 5) % 7
            weekdayTotals[mondayFirstIndex] += item.count
            weekdayOccurrences[mondayFirstIndex] += 1
        }
        derived.rhythm = ReviewRhythmMetrics(
            dailyCounts: dailyCounts,
            activeDayCount: activeDayCount,
            activeDayRate: Int((Double(activeDayCount) / Double(rhythmDays) * 100).rounded()),
            weeklyAverageText: "\(compactNumber(Double(totalCount) * 7 / Double(rhythmDays)))次",
            activeDayAverageText: "\(compactNumber(Double(totalCount) / Double(max(1, activeDayCount))))次",
            peakCount: dailyCounts.map(\.count).max() ?? 0,
            longestStreak: longestStreak,
            weekdayAverages: weekdayTotals.indices.map { index in
                CGFloat(weekdayTotals[index]) / CGFloat(max(1, weekdayOccurrences[index]))
            },
            hourlyCounts: hourlyCounts
        )

        // Mileage.
        let distanceByDate = Dictionary(grouping: rangeTransports) {
            calendar.startOfDay(for: $0.startTime)
        }.mapValues { records in
            records.reduce(0) { $0 + $1.distance }
        }
        let dailyValues = dailyCounts.map { item in
            (date: item.date, distance: distanceByDate[item.date, default: 0])
        }
        let mileageTotal = dailyValues.reduce(0) { $0 + $1.distance }
        var mileageTotals = Array(repeating: 0.0, count: 7)
        var mileageOccurrences = Array(repeating: 0, count: 7)
        for item in dailyValues {
            let mondayFirstIndex = (calendar.component(.weekday, from: item.date) + 5) % 7
            mileageTotals[mondayFirstIndex] += item.distance
            mileageOccurrences[mondayFirstIndex] += 1
        }
        derived.mileage = ReviewMileageMetrics(
            dailyValues: dailyValues,
            total: mileageTotal,
            dailyAverage: dailyValues.isEmpty ? 0 : mileageTotal / Double(dailyValues.count),
            peakDay: dailyValues.max { $0.distance < $1.distance },
            activeDayCount: dailyValues.filter { $0.distance > 0 }.count,
            weekdayAverages: mileageTotals.indices.map { index in
                mileageTotals[index] / Double(max(1, mileageOccurrences[index]))
            }
        )

        // Rankings.
        for scope in FrequentPlaceRankScope.allCases {
            derived.frequentPlaces[scope] = frequentPlaces(for: scope, footprints: rangeFootprints)
        }
        let rankCountries = Set(rangeFootprints.compactMap { footprint in
            footprint.countryCode?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty })
        if rankCountries.count > 1 {
            derived.defaultFrequentPlaceRankScope = .country
        } else {
            let rankCities = Set(rangeFootprints.compactMap { footprint -> String? in
                guard let city = footprint.cityName?.trimmingCharacters(in: .whitespacesAndNewlines), !city.isEmpty else {
                    return nil
                }
                return "\(footprint.countryCode ?? "")|\(city)"
            })
            derived.defaultFrequentPlaceRankScope = rankCities.count == 1 ? .place : .city
        }

        // Share inputs.
        derived.shareCoordinates = rangeFootprints.map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        }
        var photoCaptions: [String: String] = [:]
        for footprint in rangeFootprints {
            let place = footprint.address?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let caption = (place?.isEmpty == false ? place : footprint.cityName) else { continue }
            for assetID in footprint.photoAssetIDs where photoCaptions[assetID] == nil {
                photoCaptions[assetID] = caption
            }
        }
        derived.photoCaptions = photoCaptions

        // Routes: decode only this range's payloads from a private context.
        let routes = decodeRoutes(
            for: rangeTransports,
            window: window,
            footprints: rangeFootprints,
            config: config,
            container: container
        )

        var combined: [(startTime: Date, slot: ReviewTimelineSlot)] = rangeFootprints.map {
            (startTime: $0.startTime, slot: ReviewTimelineSlot.footprint($0.footprintID))
        }
        for (index, transport) in routes.transports.enumerated() {
            combined.append((startTime: transport.startTime, slot: ReviewTimelineSlot.transport(index)))
        }
        combined.sort { $0.startTime < $1.startTime }

        return ReviewDerivedResult(
            derived: derived,
            transports: routes.transports,
            timelineSlots: combined.map(\.slot),
            bounds: routes.bounds
        )
    }

    private static func frequentPlaces(
        for scope: FrequentPlaceRankScope,
        footprints: [ReviewFootprintSnapshot]
    ) -> [ReviewFrequentPlaceItem] {
        var groups: [String: (name: String, address: String, count: Int, duration: TimeInterval, footprintIDs: [UUID])] = [:]
        let hasMultipleCountries = Set(footprints.compactMap { footprint in
            footprint.countryCode?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }).count > 1

        for fp in footprints {
            var address = ""
            var placeName = ""
            if let savedPlaceName = fp.savedPlaceName {
                placeName = savedPlaceName
                address = fp.savedPlaceAddress ?? fp.address ?? ""
            } else if let addr = fp.address, !addr.isEmpty {
                let parts = addr.components(separatedBy: "市").last?.components(separatedBy: "区").last?.components(separatedBy: "县").last ?? addr
                placeName = parts.components(separatedBy: " ").first ?? addr
                address = addr
            }

            guard let name = rankName(
                for: scope,
                placeName: placeName,
                countryName: fp.countryName,
                countryCode: fp.countryCode,
                cityName: fp.cityName
            ) else {
                continue
            }

            // Only the place scope requires a place/address. Country and city
            // come from their own persisted hierarchy, including old overseas
            // footprints that were recorded before an address was available.
            if name.isEmpty || name.contains("未知") || (scope == .place && address.isEmpty) { continue }

            let subtitle: String
            let key: String
            switch scope {
            case .country:
                subtitle = ""
                key = fp.countryCode ?? name
            case .city:
                subtitle = hasMultipleCountries ? simplifiedChineseName(fp.countryName ?? "") : ""
                key = "\(fp.countryCode ?? "")|\(name)"
            case .place:
                subtitle = address
                key = fp.placeKey
            }
            if let existing = groups[key] {
                groups[key] = (existing.name, existing.address, existing.count + 1, existing.duration + fp.duration, existing.footprintIDs + [fp.footprintID])
            } else {
                groups[key] = (name, subtitle, 1, fp.duration, [fp.footprintID])
            }
        }

        return groups
            .filter { _, value in
                scope != .place || value.duration >= 3600
            }
            .map { key, value in
                ReviewFrequentPlaceItem(
                    id: key,
                    name: value.name,
                    address: value.address,
                    count: value.count,
                    duration: value.duration,
                    footprintIDs: value.footprintIDs
                )
            }
            .sorted { $0.duration > $1.duration }
    }

    private static func pastMemoryCandidate(
        history: [ReviewFootprintSnapshot],
        priorityPlaceIDs: Set<UUID>,
        now: Date
    ) -> ReviewMemoryCandidate? {
        let calendar = Calendar.current
        let today = calendar.dateComponents([.month, .day, .year], from: now)
        let match = history.filter { footprint in
            let components = calendar.dateComponents([.month, .day, .year], from: footprint.startTime)
            guard components.month == today.month,
                  components.day == today.day,
                  (components.year ?? today.year ?? 0) < (today.year ?? 0),
                  let placeID = footprint.placeID,
                  !priorityPlaceIDs.contains(placeID),
                  !(footprint.activityTypeValue ?? "").isEmpty else {
                return false
            }
            return true
        }
        .sorted { $0.startTime < $1.startTime }
        .first
        guard let footprint = match else { return nil }
        let years = max(1, calendar.dateComponents([.year], from: footprint.startTime, to: now).year ?? 1)
        return ReviewMemoryCandidate(
            id: "past-memory-\(footprint.footprintID.uuidString)",
            date: footprint.startTime,
            footprintID: footprint.footprintID,
            placeKey: footprint.placeKey,
            title: footprint.placeName,
            evidence: "\(years)年前",
            reason: "往年今日",
            systemImage: "clock.arrow.circlepath",
            photoAssetIDs: footprint.photoAssetIDs,
            score: 0
        )
    }

    private static func decodeRoutes(
        for records: [ReviewTransportSnapshot],
        window: ReviewRangeWindow,
        footprints: [ReviewFootprintSnapshot],
        config: ReviewConfigSnapshot,
        container: ModelContainer
    ) -> (transports: [Transport], bounds: ReviewMapBounds?) {
        // One range query; payloads are matched back by ID so the source
        // order and membership stay authoritative.
        let context = ModelContext(container)
        let lowerBound = window.lowerBound
        let descriptor: FetchDescriptor<TransportRecord>
        if let upperBound = window.upperBound {
            descriptor = FetchDescriptor<TransportRecord>(
                predicate: #Predicate<TransportRecord> {
                    $0.statusRaw == "active" && $0.startTime >= lowerBound && $0.startTime < upperBound
                }
            )
        } else {
            descriptor = FetchDescriptor<TransportRecord>(
                predicate: #Predicate<TransportRecord> {
                    $0.statusRaw == "active" && $0.startTime >= lowerBound
                }
            )
        }
        var recordsByID: [UUID: TransportRecord] = [:]
        for record in (try? context.fetch(descriptor)) ?? [] where recordsByID[record.recordID] == nil {
            recordsByID[record.recordID] = record
        }

        var transports: [Transport] = []
        transports.reserveCapacity(records.count)
        var decodedPoints: [[CodableCoordinate]] = []
        decodedPoints.reserveCapacity(records.count)
        for snapshot in records {
            let record = recordsByID[snapshot.id]
            let points = record.flatMap {
                try? JSONDecoder().decode([CodableCoordinate].self, from: $0.pointsData)
            } ?? []
            decodedPoints.append(points)
            let pathPoints = points.map {
                TransportPathPoint(
                    coordinate: CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon),
                    timestamp: $0.timestamp,
                    isSyntheticPadding: $0.isSyntheticPadding ?? false
                )
            }
            transports.append(Transport(
                id: snapshot.id,
                startTime: snapshot.startTime,
                endTime: snapshot.endTime,
                startLocation: record?.startLocation ?? "起点",
                endLocation: record?.endLocation ?? "终点",
                type: TransportType(rawValue: snapshot.typeRaw) ?? .slow,
                distance: snapshot.distance,
                averageSpeed: record?.averageSpeed ?? 0,
                points: pathPoints.map(\.coordinate),
                pathPoints: pathPoints,
                manualType: snapshot.manualTypeRaw.flatMap(TransportType.init(rawValue:)),
                stepCount: record?.stepCount
            ))
        }

        var minimumLatitude = Double.greatestFiniteMagnitude
        var maximumLatitude = -Double.greatestFiniteMagnitude
        var minimumLongitude = Double.greatestFiniteMagnitude
        var maximumLongitude = -Double.greatestFiniteMagnitude

        func include(latitude: Double, longitude: Double) {
            guard latitude.isFinite, longitude.isFinite,
                  (-90...90).contains(latitude), (-180...180).contains(longitude),
                  !(latitude == 0 && longitude == 0) else { return }
            minimumLatitude = min(minimumLatitude, latitude)
            maximumLatitude = max(maximumLatitude, latitude)
            minimumLongitude = min(minimumLongitude, longitude)
            maximumLongitude = max(maximumLongitude, longitude)
        }

        for footprint in footprints {
            include(latitude: footprint.latitude, longitude: footprint.longitude)
        }
        for points in decodedPoints {
            for point in points where point.isSyntheticPadding != true {
                guard point.lat.isFinite, point.lon.isFinite,
                      (-90...90).contains(point.lat), (-180...180).contains(point.lon),
                      !(point.lat == 0 && point.lon == 0) else { continue }
                include(latitude: point.lat, longitude: point.lon)
            }
        }

        let bounds: ReviewMapBounds? = minimumLatitude == Double.greatestFiniteMagnitude
            ? nil
            : ReviewMapBounds(
                minimumLatitude: minimumLatitude,
                maximumLatitude: maximumLatitude,
                minimumLongitude: minimumLongitude,
                maximumLongitude: maximumLongitude
            )
        return (transports, bounds)
    }

    // MARK: Place groups

    /// Groups `footprints` by place and summarises each group, newest visits
    /// first, sorted by total stay. Resolves photos through Photos off main.
    static func placeGroups(
        from footprints: [ReviewFootprintSnapshot],
        titleKeyPath: KeyPath<ReviewFootprintSnapshot, String>
    ) -> [ReviewPlaceGroup] {
        Dictionary(grouping: footprints, by: \.placeKey)
            .compactMap { key, visits in
                placeGroup(id: key, visits: visits, titleKeyPath: titleKeyPath, resolvedPhotoAssetIDs: nil)
            }
            .sorted { $0.stats.totalDuration > $1.stats.totalDuration }
    }

    static func placeGroup(
        id: String,
        visits: [ReviewFootprintSnapshot],
        titleKeyPath: KeyPath<ReviewFootprintSnapshot, String>,
        resolvedPhotoAssetIDs: [String]?
    ) -> ReviewPlaceGroup? {
        let orderedVisits = visits.sorted { $0.startTime > $1.startTime }
        guard let representative = orderedVisits.first else { return nil }

        var seenPhotoIDs: Set<String> = []
        let storedPhotoAssetIDs = orderedVisits
            .flatMap(\.photoAssetIDs)
            .filter { seenPhotoIDs.insert($0).inserted }
        let photoAssetIDs = resolvedPhotoAssetIDs ?? PhotoService.shared.displayableAssetIDs(storedPhotoAssetIDs)
        return ReviewPlaceGroup(
            id: id,
            title: representative[keyPath: titleKeyPath],
            visitIDs: orderedVisits.map(\.footprintID),
            photoAssetIDs: photoAssetIDs,
            stats: placeStats(for: orderedVisits)
        )
    }

    /// The former `ReviewPlaceView` computed statistics, for visits ordered
    /// newest first.
    private static func placeStats(for visits: [ReviewFootprintSnapshot]) -> ReviewPlaceStats {
        let calendar = Calendar.current
        let representative = visits.max {
            if $0.photoAssetIDs.count != $1.photoAssetIDs.count {
                return $0.photoAssetIDs.count < $1.photoAssetIDs.count
            }
            return $0.duration < $1.duration
        }
        let geographyText: String? = representative.flatMap { footprint in
            let values = [footprint.countryName, footprint.cityName]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return values.isEmpty ? nil : values.joined(separator: " · ")
        }
        var weekdayCounts = Array(repeating: 0, count: 7)
        var hourlyCounts = Array(repeating: 0, count: 24)
        for visit in visits {
            let mondayFirstIndex = (calendar.component(.weekday, from: visit.startTime) + 5) % 7
            weekdayCounts[mondayFirstIndex] += 1
            hourlyCounts[calendar.component(.hour, from: visit.startTime)] += 1
        }
        var activityTotals: [String: TimeInterval] = [:]
        var activityVisitCounts: [String: Int] = [:]
        var activitiesByName: [String: ReviewActivitySnapshot] = [:]
        var visitActivities: [UUID: ReviewActivitySnapshot] = [:]
        for visit in visits {
            guard let activity = visit.activity else { continue }
            activityTotals[activity.name, default: 0] += max(0, visit.duration)
            activityVisitCounts[activity.name, default: 0] += 1
            activitiesByName[activity.name] = activity
            visitActivities[visit.footprintID] = activity
        }
        let activitySlices = activityTotals.compactMap { name, duration -> ReviewActivitySlice? in
            guard let activity = activitiesByName[name] else { return nil }
            return ReviewActivitySlice(id: name, name: name, duration: duration, color: activity.color, icon: activity.icon)
        }.sorted { $0.duration > $1.duration }
        let chronological = visits.sorted { $0.startTime < $1.startTime }
        let trend = chronological.map { max(0, $0.duration) }
        return ReviewPlaceStats(
            totalDuration: visits.reduce(0) { $0 + $1.duration },
            geographyText: geographyText,
            weekdayCounts: weekdayCounts,
            hourlyCounts: hourlyCounts,
            durationTrend: trend,
            averageDuration: trend.isEmpty ? 0 : trend.reduce(0, +) / Double(trend.count),
            firstVisitDate: chronological.first?.startTime,
            lastVisitDate: chronological.last?.startTime,
            activitySlices: activitySlices,
            activityVisitCounts: activityVisitCounts,
            visitActivities: visitActivities
        )
    }

    // MARK: Memories

    static func memoryCacheKey(for range: StatisticsRange) -> String {
        "review.memory.v8.\(range.rawValue)"
    }

    static func loadCachedMemories(for range: StatisticsRange) -> [ReviewMemoryCandidate] {
        guard let data = UserDefaults.standard.data(forKey: memoryCacheKey(for: range)),
              let payload = try? JSONDecoder().decode(ReviewMemoryCachePayload.self, from: data) else { return [] }
        return payload.entries.filter {
            !$0.photoAssetIDs.isEmpty || $0.id.hasPrefix("favorite-")
        }.map { entry in
            ReviewMemoryCandidate(
                id: entry.id,
                date: entry.date,
                footprintID: entry.footprintID,
                placeKey: nil,
                title: entry.title,
                evidence: entry.evidence,
                reason: entry.reason,
                systemImage: entry.systemImage,
                photoAssetIDs: entry.photoAssetIDs,
                score: entry.score
            )
        }
    }

    static func saveCachedMemories(_ candidates: [ReviewMemoryCandidate], revision: Int, range: StatisticsRange) {
        let entries = candidates.filter {
            !$0.photoAssetIDs.isEmpty || $0.id.hasPrefix("favorite-")
        }.map {
            ReviewMemoryCacheEntry(
                id: $0.id,
                date: $0.date,
                footprintID: $0.footprintID,
                title: $0.title,
                evidence: $0.evidence,
                reason: $0.reason,
                systemImage: $0.systemImage,
                photoAssetIDs: $0.photoAssetIDs,
                score: $0.score
            )
        }
        let payload = ReviewMemoryCachePayload(revision: revision, entries: entries)
        if let data = try? JSONEncoder().encode(payload) {
            UserDefaults.standard.set(data, forKey: memoryCacheKey(for: range))
        }
    }

    private static func displayablePhotoAssetIDs(for footprint: ReviewFootprintSnapshot) async -> [String] {
        await PhotoService.shared.displayableAssetIDs(
            storedAssetIDs: footprint.photoAssetIDs,
            startTime: footprint.startTime,
            endTime: footprint.endTime,
            coordinate: CLLocationCoordinate2D(latitude: footprint.latitude, longitude: footprint.longitude)
        )
    }

    static func buildMemoryCandidates(
        history: [ReviewFootprintSnapshot],
        derived: ReviewDerivedData,
        config: ReviewConfigSnapshot
    ) async -> [ReviewMemoryCandidate] {
        var candidates: [ReviewMemoryCandidate] = []
        let calendar = Calendar.current
        let footprintsInRange = derived.rangeFootprints

        let historyByPlace = Dictionary(grouping: history, by: \.placeKey)
        let visitsByPlace = Dictionary(grouping: footprintsInRange, by: \.placeKey)
        var photosByPlace: [String: [String]] = [:]
        for (placeKey, visits) in visitsByPlace {
            var seenPhotoIDs = Set<String>()
            var photoAssetIDs: [String] = []
            for visit in visits {
                let visitPhotoAssetIDs = await displayablePhotoAssetIDs(for: visit)
                photoAssetIDs.append(contentsOf: visitPhotoAssetIDs.filter { seenPhotoIDs.insert($0).inserted })
            }
            photosByPlace[placeKey] = photoAssetIDs
            if Task.isCancelled { return [] }
        }
        let durationByPlace = visitsByPlace.mapValues { $0.reduce(0) { $0 + $1.duration } }
        let visitCountByPlace = visitsByPlace.mapValues(\.count)
        let representativeIDByPlace = visitsByPlace.compactMapValues { visits in
            visits.max {
                if $0.photoAssetIDs.count != $1.photoAssetIDs.count {
                    return $0.photoAssetIDs.count < $1.photoAssetIDs.count
                }
                return $0.duration < $1.duration
            }?.footprintID
        }
        let rankedDurationPlaces = durationByPlace
            .filter { $0.value >= config.longStayMinDuration }
            .sorted { $0.value > $1.value }
            .prefix(3)
        let longStayPlaceKeys = Set(rankedDurationPlaces.map(\.key))
        let longestPlaceKey = rankedDurationPlaces.first?.key
        let mostVisitedPlaceKey = visitCountByPlace.max {
            if $0.value != $1.value { return $0.value < $1.value }
            return (durationByPlace[$0.key] ?? 0) < (durationByPlace[$1.key] ?? 0)
        }?.key
        let mostPhotoPlaceKey = photosByPlace.max { $0.value.count < $1.value.count }?.key
        let frequentVisitMinCount = config.frequentVisitMinCount
        let longestFootprintID = footprintsInRange.max {
            if $0.duration != $1.duration { return $0.duration < $1.duration }
            return $0.startTime > $1.startTime
        }?.footprintID
        var previousVisitByID: [UUID: Date] = [:]
        var firstVisitIDByPlace: [String: UUID] = [:]
        var averageDurationByPlace: [String: TimeInterval] = [:]
        for (placeKey, placeHistory) in historyByPlace {
            let ordered = placeHistory.sorted {
                if $0.startTime != $1.startTime { return $0.startTime < $1.startTime }
                return $0.footprintID.uuidString < $1.footprintID.uuidString
            }
            firstVisitIDByPlace[placeKey] = ordered.first?.footprintID
            var previousDate: Date?
            for footprint in ordered {
                if let previousDate { previousVisitByID[footprint.footprintID] = previousDate }
                previousDate = footprint.startTime
            }
            averageDurationByPlace[placeKey] = placeHistory.reduce(0) { $0 + $1.duration } / Double(max(1, placeHistory.count))
        }
        if Task.isCancelled { return [] }

        var firstCountryDate: [String: Date] = [:]
        var firstCityDate: [String: Date] = [:]
        for footprint in history {
            let country = footprint.countryCode?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
            if !country.isEmpty {
                firstCountryDate[country] = min(firstCountryDate[country] ?? footprint.startTime, footprint.startTime)
            }
            let city = footprint.cityName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !city.isEmpty {
                let key = "\(country)|\(city)"
                firstCityDate[key] = min(firstCityDate[key] ?? footprint.startTime, footprint.startTime)
            }
        }

        for footprint in footprintsInRange {
            if Task.isCancelled { return [] }
            let placeKey = footprint.placeKey
            let placePhotoAssetIDs = photosByPlace[placeKey] ?? []
            let footprintPhotoAssetIDs = await displayablePhotoAssetIDs(for: footprint)
            let placeDuration = durationByPlace[placeKey] ?? 0
            let placeVisitCount = visitsByPlace[placeKey]?.count ?? 0
            let isPlaceRepresentative = representativeIDByPlace[placeKey] == footprint.footprintID
            let previousVisit = previousVisitByID[footprint.footprintID]
            let averageDuration = averageDurationByPlace[placeKey] ?? 0
            // “第一次来到这里”只属于该地点全部历史记录中的最早一次，
            // 不能因为当前统计周期或候选顺序改变而重新产生。
            let firstVisit = firstVisitIDByPlace[placeKey] == footprint.footprintID
            let daysSincePrevious = previousVisit.map {
                calendar.dateComponents([.day], from: $0, to: footprint.startTime).day ?? 0
            } ?? 0
            let countryCode = footprint.countryCode?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
            let cityName = footprint.cityName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let firstCountry = !countryCode.isEmpty && firstCountryDate[countryCode] == footprint.startTime
            let firstCity = !cityName.isEmpty && firstCityDate["\(countryCode)|\(cityName)"] == footprint.startTime

            var score = 0.0
            var reason = ""
            var evidence = ""
            var icon = "sparkles"

            if firstVisit && footprintPhotoAssetIDs.count >= config.firstVisitPhotoMinCount {
                score += 6
                reason = "第一次来到这里"
                evidence = "\(footprintPhotoAssetIDs.count)张照片 · \(formatRankDuration(footprint.duration))"
                icon = "flag.fill"
            }
            if firstCountry {
                score += 7
                reason = "第一次来到这个国家"
                evidence = footprint.countryName ?? countryCode
                icon = "globe.asia.australia.fill"
            } else if firstCity {
                score += 5
                if reason.isEmpty {
                    reason = "第一次来到这座城市"
                    evidence = cityName
                    icon = "building.2.fill"
                }
            }
            if footprint.footprintID == longestFootprintID,
               footprint.duration >= config.longStayMinDuration {
                score += 4
                if !firstCountry && !firstCity {
                    reason = "停留最久的一次"
                    evidence = "停留\(formatRankDuration(footprint.duration))"
                    icon = "hourglass.bottomhalf.filled"
                }
            }
            if isPlaceRepresentative,
               placeKey == mostVisitedPlaceKey,
               placeVisitCount > 1 {
                score += 3
                if !firstCountry && !firstCity && footprint.footprintID != longestFootprintID {
                    reason = "停留最多的地方"
                    evidence = "\(placeVisitCount)次到访 · 累计\(formatRankDuration(placeDuration))"
                    icon = "repeat.circle.fill"
                }
            }
            if isPlaceRepresentative && longStayPlaceKeys.contains(placeKey) {
                let durationScore = min(4, placeDuration / config.longStayMinDuration)
                score += durationScore
                if reason.isEmpty || (reason == "第一次来到这里" && placeVisitCount >= frequentVisitMinCount) {
                    reason = placeKey == longestPlaceKey
                        ? "这段时间最常停留"
                        : (placeVisitCount >= frequentVisitMinCount ? "常常回到这里" : "在这里度过了不少时间")
                    evidence = "累计\(formatRankDuration(placeDuration)) · \(placeVisitCount)次到访"
                    icon = "clock.fill"
                }
            }
            if averageDuration > 0 && footprint.duration >= averageDuration * config.unusualDurationRatio {
                score += 2
                if reason.isEmpty || reason == "第一次来到这里" {
                    reason = "这次停留得格外久"
                    evidence = "停留\(formatRankDuration(footprint.duration))"
                    icon = "hourglass"
                }
            }
            if isPlaceRepresentative && placePhotoAssetIDs.count >= config.photoMinCount {
                score += min(4, Double(placePhotoAssetIDs.count) / Double(max(1, config.photoMinCount)))
                if reason.isEmpty || (placeKey == mostPhotoPlaceKey && reason == "第一次来到这里") {
                    reason = placeKey == mostPhotoPlaceKey ? "照片最多的地方" : "用照片记下这里"
                    evidence = "累计拍了\(placePhotoAssetIDs.count)张照片"
                    icon = "photo.on.rectangle.angled"
                }
            }
            if daysSincePrevious >= config.longTimeNoSeeDays {
                score += 4
                if !firstCountry && !firstCity {
                    reason = "很久以后又回来"
                    evidence = "相隔\(daysSincePrevious)天"
                    icon = "arrow.uturn.backward.circle.fill"
                }
            }
            if footprint.status == .manual || footprint.status == .confirmed { score += 0.8 }
            if footprint.isAddressEditedByHand { score += 0.8 }
            let personalNote = footprint.reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !personalNote.isEmpty {
                score += 1.2
                if reason == "第一次来到这里" || reason == "用照片记下这里" {
                    reason = "你特别记下的一次停留"
                    evidence = personalNote
                    icon = "note.text"
                }
            }
            if footprint.isHighlight == true { score += 0.4 }

            guard score >= config.minimumScore,
                  !reason.isEmpty,
                  !placePhotoAssetIDs.isEmpty else { continue }
            candidates.append(ReviewMemoryCandidate(
                id: "footprint-\(footprint.footprintID.uuidString)",
                date: footprint.startTime,
                footprintID: footprint.footprintID,
                placeKey: placeKey,
                title: footprint.placeName,
                evidence: evidence,
                reason: reason,
                systemImage: icon,
                photoAssetIDs: placePhotoAssetIDs,
                score: score
            ))
        }

        let transportsByDay = Dictionary(grouping: derived.rangeTransports) { calendar.startOfDay(for: $0.startTime) }
        func photoIDs(on date: Date) -> [String] {
            footprintsInRange.filter { calendar.isDate($0.startTime, inSameDayAs: date) }.flatMap(\.photoAssetIDs)
        }

        // Farthest day.
        if let item = transportsByDay.map({ (date: $0.key, distance: $0.value.reduce(0) { $0 + $1.distance }) }).max(by: { $0.distance < $1.distance }),
           item.distance >= config.travelDistanceMin {
            let farthestPhotoIDs = photoIDs(on: item.date)
            if !farthestPhotoIDs.isEmpty {
                candidates.append(ReviewMemoryCandidate(
                    id: "distance-\(item.date.timeIntervalSince1970)",
                    date: item.date,
                    footprintID: nil,
                    placeKey: nil,
                    title: item.date.formatted(.dateTime.month().day()),
                    evidence: formatRankMileage(item.distance),
                    reason: "走得最远的一天",
                    systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                    photoAssetIDs: farthestPhotoIDs,
                    score: 5
                ))
            }
        }

        // Transport memories.
        var transportCandidates: [ReviewMemoryCandidate] = []
        if let walking = transportsByDay.map({ day, records -> (Date, Double) in
            let distance = records.filter {
                let type = $0.manualTypeRaw.flatMap(TransportType.init(rawValue:)) ?? TransportType(rawValue: $0.typeRaw) ?? .slow
                return type == .slow || type == .running
            }.reduce(0) { $0 + $1.distance }
            return (day, distance)
        }).max(by: { $0.1 < $1.1 }), walking.1 >= config.walkDistanceMin {
            transportCandidates.append(ReviewMemoryCandidate(
                id: "walking-\(walking.0.timeIntervalSince1970)", date: walking.0, footprintID: nil, placeKey: nil,
                title: walking.0.formatted(.dateTime.month().day()), evidence: formatRankMileage(walking.1),
                reason: "步行最多的一天", systemImage: "figure.walk", photoAssetIDs: photoIDs(on: walking.0), score: 4.8
            ))
        }
        if let diverse = transportsByDay.map({ day, records -> (Date, Int) in
            let types = Set(records.compactMap { $0.manualTypeRaw ?? $0.typeRaw }.filter { !$0.isEmpty })
            return (day, types.count)
        }).max(by: { $0.1 < $1.1 }), diverse.1 >= config.diverseTransportMinCount {
            transportCandidates.append(ReviewMemoryCandidate(
                id: "modes-\(diverse.0.timeIntervalSince1970)", date: diverse.0, footprintID: nil, placeKey: nil,
                title: diverse.0.formatted(.dateTime.month().day()), evidence: "用了\(diverse.1)种交通方式",
                reason: "出行方式最丰富的一天", systemImage: "arrow.triangle.branch", photoAssetIDs: photoIDs(on: diverse.0), score: 4.4
            ))
        }
        candidates.append(contentsOf: transportCandidates.filter { !$0.photoAssetIDs.isEmpty })

        // A favorite is an explicit user choice, so keep one visible as a
        // compact memory card even when its automatic score is not high enough.
        let favoriteFootprints = footprintsInRange.filter {
            $0.isHighlight == true && $0.status != .ignored
        }
        let orderedFavoriteFootprints = favoriteFootprints.sorted {
            if $0.startTime != $1.startTime { return $0.startTime < $1.startTime }
            return $0.footprintID.uuidString < $1.footprintID.uuidString
        }
        var favoriteCandidate: ReviewMemoryCandidate?
        for footprint in orderedFavoriteFootprints {
            if Task.isCancelled { return [] }
            let favoritePhotoAssetIDs = await displayablePhotoAssetIDs(for: footprint)
            guard !favoritePhotoAssetIDs.isEmpty else { continue }
            favoriteCandidate = ReviewMemoryCandidate(
                id: "favorite-\(footprint.footprintID.uuidString)",
                date: footprint.startTime,
                footprintID: nil,
                placeKey: nil,
                title: "\(favoriteFootprints.count)个重要片段",
                evidence: "点开查看全部收藏",
                reason: "收藏足迹",
                systemImage: "star.fill",
                photoAssetIDs: favoritePhotoAssetIDs,
                score: 0
            )
            break
        }
        if favoriteCandidate == nil, let footprint = orderedFavoriteFootprints.first {
            favoriteCandidate = ReviewMemoryCandidate(
                id: "favorite-\(footprint.footprintID.uuidString)",
                date: footprint.startTime,
                footprintID: nil,
                placeKey: nil,
                title: "\(favoriteFootprints.count)个重要片段",
                evidence: "点开查看全部收藏",
                reason: "收藏足迹",
                systemImage: "star.fill",
                photoAssetIDs: [],
                score: 0
            )
        }

        var usedDays: Set<Date> = []
        var usedPlaces: Set<String> = []
        var usedReasons: Set<String> = []
        var selected: [ReviewMemoryCandidate] = []
        let automaticLimit = max(0, config.maximumCount - (favoriteCandidate == nil ? 0 : 1))
        let rankedCandidates = candidates.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.date != $1.date { return $0.date < $1.date }
            return $0.id < $1.id
        }
        func appendCandidateIfAvailable(_ candidate: ReviewMemoryCandidate, requiresNewReason: Bool) {
            guard selected.count < automaticLimit else { return }
            let day = calendar.startOfDay(for: candidate.date)
            let placeKey = candidate.placeKey
            guard !usedDays.contains(day),
                  (placeKey.map({ !usedPlaces.contains($0) }) ?? true),
                  !requiresNewReason || !usedReasons.contains(candidate.reason) else { return }
            selected.append(candidate)
            usedDays.insert(day)
            usedReasons.insert(candidate.reason)
            if let placeKey { usedPlaces.insert(placeKey) }
        }
        for candidate in rankedCandidates {
            appendCandidateIfAvailable(candidate, requiresNewReason: true)
        }
        if selected.count < automaticLimit {
            for candidate in rankedCandidates {
                appendCandidateIfAvailable(candidate, requiresNewReason: false)
            }
        }
        if let favoriteCandidate { selected.append(favoriteCandidate) }
        return selected
    }
}

struct HistoryStatisticsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    var onFootprintSelected: ((Footprint) -> Void)? = nil
    var onDateSelected: ((Date) -> Void)? = nil

    /// Database-wide value snapshot, fetched and fingerprinted off main.
    @State private var reviewSource: ReviewSourceSnapshot?
    /// Everything the sections show for the applied range, built off main.
    @State private var reviewDerived = ReviewDerivedData()
    /// Main-context models for the applied range (map items and selections).
    @State private var rangeFootprints: [Footprint] = []
    @State private var rangeFootprintsByID: [UUID: Footprint] = [:]

    @State private var selectedRange: StatisticsRange = .last30Days
    @State private var appliedRange: StatisticsRange = .last30Days
    /// Days spent on trips in the range, with each trip's activity type.
    @State private var reviewTripActivityDays: [Date: String] = [:]
    @State private var mapPosition: MapCameraPosition = .automatic
    @State private var reviewMapRegion: MKCoordinateRegion?
    @State private var reviewTimelineItemsCache: [TimelineItem] = []
    @State private var reviewMemoryCandidatesCache: [ReviewMemoryCandidate] = []
    /// The sheet this view presents; each hosts its own range.
    @State private var presentedSheet: ReviewSheetContent?
    @State private var pendingFavoriteFootprint: Footprint?
    /// Sheet mode: the content this instance hosts instead of the page, and
    /// its places as resolved for `sheetPlacesRange`.
    private let sheet: ReviewSheetContent?
    private let allowsRangeSelection: Bool
    @State private var sheetPlaces: [ReviewPlaceSelection] = []
    @State private var sheetPlacesRange: StatisticsRange?
    @State private var reviewRoutesReady = false
    @State private var reviewDerivedDataTask: Task<Void, Never>?
    @State private var reviewDerivedDataRequestID = UUID()
    @State private var scheduledReviewRefreshTask: Task<Void, Never>?
    @State private var reviewSourceFingerprint: Int?

    // AI Summary State
    @AppStorage("isAiAssistantEnabled") private var isAiAssistantEnabled = false
    @State private var aiSummary: String? = nil
    @State private var isGeneratingSummary = false
    @State private var aiSummaryTask: Task<Void, Never>?
    @State private var aiSummaryGeocoder: CLGeocoder?
    @State private var aiSummaryRequestID = UUID()
    // Cache structure: [RangeRawValue: (text: String, timestamp: Double)]
    @State private var summaryCache: [String: [String: Any]] = (UserDefaults.standard.dictionary(forKey: "statistics_ai_cache") as? [String: [String: Any]]) ?? [:]

    @State private var activeYearForSegment: Int = Calendar.current.component(.year, from: Date())
    @State private var sharePayload: DFKShareCardPayload?
    @State private var frequentPlaceRankScope: FrequentPlaceRankScope = .city
    @State private var hasManuallySelectedFrequentPlaceRankScope = false
    @State private var geographicBackfillAttempts: [UUID: Int] = [:]
    @State private var isResolvingGeographies = false
    @State private var geographyBackfillTask: Task<Void, Never>?
    @State private var geographyBackfillResolver: StatisticsGeographyResolver?
    @State private var geographyBackfillRequestID = UUID()

    init(onFootprintSelected: ((Footprint) -> Void)? = nil, onDateSelected: ((Date) -> Void)? = nil) {
        self.onFootprintSelected = onFootprintSelected
        self.onDateSelected = onDateSelected
        self.sheet = nil
        self.allowsRangeSelection = true
    }

    /// Sheet mode: starts from the presenter's state and rebuilds only for
    /// its own range changes.
    fileprivate init(sheet: ReviewSheetContent, seed: ReviewSheetSeed, onFootprintSelected: ((Footprint) -> Void)?) {
        self.onFootprintSelected = onFootprintSelected
        self.onDateSelected = nil
        self.sheet = sheet
        self.allowsRangeSelection = seed.allowsRangeSelection
        _reviewSource = State(initialValue: seed.source)
        _reviewSourceFingerprint = State(initialValue: seed.sourceFingerprint)
        _selectedRange = State(initialValue: seed.range)
        _appliedRange = State(initialValue: seed.range)
        _activeYearForSegment = State(initialValue: seed.activeYear)
        _reviewDerived = State(initialValue: seed.derived)
        _rangeFootprints = State(initialValue: seed.rangeFootprints)
        _rangeFootprintsByID = State(initialValue: seed.rangeFootprintsByID)
        _reviewTripActivityDays = State(initialValue: seed.tripActivityDays)
        _reviewTimelineItemsCache = State(initialValue: seed.timelineItems)
        _reviewMapRegion = State(initialValue: seed.mapRegion)
        _mapPosition = State(initialValue: seed.mapPosition)
        _reviewRoutesReady = State(initialValue: seed.routesReady)
        _frequentPlaceRankScope = State(initialValue: seed.frequentPlaceRankScope)
        if case .places(_, let places) = sheet {
            _sheetPlaces = State(initialValue: places)
            _sheetPlacesRange = State(initialValue: seed.range)
        }
    }

    // Footprints in the applied range, fetched once per derived refresh.
    private var filteredFootprints: [Footprint] {
        rangeFootprints
    }

    private var availableYears: [Int] {
        reviewDerived.availableYears
    }
    private var usesIPadLayout: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    var body: some View {
        Group {
            if let sheet {
                sheetBody(sheet)
            } else {
                reviewPage
            }
        }
        .onChange(of: selectedRange) { _, range in
            // Invalidate the previous range synchronously. Waiting for the
            // deferred refresh would leave a short window in which its result
            // could still update the map after the picker has already moved.
            if case .customYear(let year) = range {
                activeYearForSegment = year
            }
            reviewDerivedDataRequestID = UUID()
            reviewDerivedDataTask?.cancel()
            reviewRoutesReady = false
            reviewMapRegion = nil
            mapPosition = .automatic
            scheduleReviewRefresh(applying: range)
        }
        // Every level (page and each open sheet) drops its own working set;
        // a sheet's copy must not wait for its dismissal to be processed.
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                releaseReviewWorkingSet()
                if sheet != nil { dismiss() }
            } else if phase == .active, sheet == nil, reviewSourceFingerprint == nil {
                scheduleReviewRefresh(fetchesData: true)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            releaseReviewWorkingSet()
            if sheet != nil { dismiss() }
        }
        .sheet(item: $presentedSheet, onDismiss: {
            guard let footprint = pendingFavoriteFootprint else { return }
            pendingFavoriteFootprint = nil
            onFootprintSelected?(footprint)
        }) { content in
            HistoryStatisticsView(sheet: content, seed: sheetSeed) { footprint in
                // Open the footprint once this sheet has gone.
                pendingFavoriteFootprint = footprint
                presentedSheet = nil
            }
        }
    }

    private var reviewPage: some View {
        ScrollView {
            LazyVStack(spacing: 22, pinnedViews: [.sectionHeaders]) {
                Section {
                    if reviewRoutesReady {
                        if usesIPadLayout {
                            HStack(alignment: .top, spacing: 16) {
                                reviewHeroSection
                                    .frame(maxWidth: .infinity)
                                memorableSection
                                    .frame(maxWidth: .infinity)
                            }
                        } else {
                            reviewHeroSection
                        }

                        if !usesIPadLayout {
                            memorableSection
                        }
                        reviewBentoSection
                    } else {
                        ProgressView()
                            .controlSize(.large)
                            .frame(maxWidth: .infinity, minHeight: 420)
                    }

                    Spacer(minLength: 132)
                } header: {
                    rangePicker
                        .padding(.top, 8)
                        .padding(.bottom, 16)
                        .background {
                            ReviewNavigationBarBlur()
                        }
                }
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .onReceive(NotificationCenter.default.publisher(for: .dfkShareHistoryStatistics)) { _ in
            prepareStatsShare()
        }
        .onAppear {
            scheduleReviewRefresh(fetchesData: true)
        }
        .sheet(item: $sharePayload) { _ in
            DFKShareCardSheet(payload: $sharePayload)
        }
    }

    private func prepareStatsShare() {
        let footprints = filteredFootprints
        let coordinates = reviewDerived.shareCoordinates
        // The map snapshot loader takes models; these are one range query and
        // two small tables, fetched only when the user shares.
        let shareTransports = fetchRangeTransportRecords()
        let shareActivities = fetchMainActivityTypes()
        let sharePlaces = fetchMainPlaces()
        let rangeText = statisticsRangeText
        let rhythmValues = reviewActivityBuckets
        let rhythmStartText = reviewRhythmAxisStartText
        let rhythmEndText = reviewRhythmAxisEndText
        let loadingPayload = DFKShareCardFactory.loadingPayload(
            kind: .stats,
            rangeText: rangeText,
            coordinates: coordinates
        )
        sharePayload = loadingPayload
        let payloadID = loadingPayload.id

        let memories = Array(reviewMemoryCandidatesCache.prefix(4))
        let memory = memories.first
        let activityTotal = max(1, reviewActivitySlices.reduce(0) { $0 + $1.duration })
        let activityEntries = reviewActivitySlices.prefix(5).map {
            DFKShareRankingEntry(
                title: $0.name,
                detail: nil,
                value: formatRankDuration($0.duration),
                icon: $0.icon,
                color: $0.color,
                fraction: $0.duration / activityTotal
            )
        }
        let transportEntries = reviewTransportSlices.prefix(3).map {
            DFKShareRankingEntry(
                title: $0.name,
                detail: formatRankMileage($0.distance),
                value: "\($0.count)次",
                icon: $0.icon,
                color: $0.color
            )
        }
        let regionEntries = reviewTopRegions.prefix(3).map {
            DFKShareRankingEntry(
                title: $0.name,
                detail: nil,
                value: formatRankDuration($0.duration),
                icon: "mappin.and.ellipse",
                color: .dfkAccent
            )
        }
        let metric = reviewGeographyMetric
        let stats = [
            DFKShareStatEntry(label: metric.label, value: metric.value, detail: nil),
            DFKShareStatEntry(label: "路程", value: reviewDistanceText, detail: nil),
            DFKShareStatEntry(label: "段路程", value: "\(reviewDerived.transportCount)", detail: nil)
        ]

        let group = DispatchGroup()
        var loadedMapImages: (light: UIImage?, dark: UIImage?) = (nil, nil)
        var loadedTemplateMapImages: (tall: UIImage?, wide: UIImage?) = (nil, nil)
        var loadedMemories = memories.map {
            DFKShareReviewMemory(
                id: $0.id,
                reason: $0.reason,
                title: $0.title,
                detail: $0.evidence,
                image: nil,
                photoAssetIDs: $0.photoAssetIDs
            )
        }

        group.enter()
        DFKShareImageLoader.loadReviewMapImages(
            footprints: footprints,
            transports: shareTransports,
            activities: shareActivities,
            places: sharePlaces
        ) { images in
            loadedMapImages = images
            group.leave()
        }

        for (size, keepsWide) in [(DFKShareTemplateStyle.tallMapSize, false), (DFKShareTemplateStyle.wideMapSize, true)] {
            group.enter()
            DFKShareImageLoader.loadReviewMapImages(
                footprints: footprints,
                transports: shareTransports,
                activities: shareActivities,
                places: sharePlaces,
                size: size,
                markerScale: 1.5 * DFKShareTemplateStyle.portraitMapMarkerBoost
            ) { images in
                if keepsWide {
                    loadedTemplateMapImages.wide = images.dark
                } else {
                    loadedTemplateMapImages.tall = images.light
                }
                group.leave()
            }
        }

        for (index, candidate) in memories.enumerated() {
            group.enter()
            DFKShareImageLoader.loadSampledImages(assetIDs: candidate.photoAssetIDs) { media in
                loadedMemories[index].image = media.images.first
                loadedMemories[index].extraImages = Array(media.images.dropFirst())
                group.leave()
            }
        }

        // A random set from every photo of the period, each captioned with
        // the place it was taken (built with the derived data).
        let photoCaptions = reviewDerived.photoCaptions
        // Not resolved against the library up front: a year can hold thousands
        // of IDs, and a missing one simply fails to load from the sample.
        let photoPool = Array(photoCaptions.keys)
        var loadedPhotos = DFKShareMedia(images: [])
        group.enter()
        DFKShareImageLoader.loadSampledImages(assetIDs: photoPool, limit: 6) { media in
            loadedPhotos = media
            group.leave()
        }

        group.notify(queue: .main) {
            var payload = DFKShareCardFactory.statsPayload(
                rangeText: rangeText,
                coordinates: coordinates,
                stats: stats,
                memoryReason: memory?.reason,
                memoryTitle: memory?.title,
                memoryDetail: memory?.evidence,
                memoryImage: loadedMemories.first?.image,
                memories: loadedMemories,
                activityRankings: activityEntries,
                rhythmValues: rhythmValues,
                rhythmStartText: rhythmStartText,
                rhythmEndText: rhythmEndText,
                transportRankings: transportEntries,
                regionRankings: regionEntries
            )
            let mapImages = loadedMapImages
            payload.contentMapImage = mapImages.light ?? mapImages.dark
            payload.contentMapLightImage = mapImages.light
            payload.contentMapDarkImage = mapImages.dark
            payload.heroImages = loadedPhotos.images
            payload.heroImageAssetIDs = loadedPhotos.imageAssetIDs
            payload.photoAssetPool = photoPool
            payload.photoCaptionsByAssetID = photoCaptions
            payload.templateTallMapImage = loadedTemplateMapImages.tall
            payload.templateWideMapImage = loadedTemplateMapImages.wide
            guard sharePayload?.id == payloadID else { return }
            payload.id = payloadID
            sharePayload = payload
        }
    }

    private var statisticsRangeText: String {
        appliedRange.reviewTitle
    }

    // MARK: - Review Home

    private var reviewHeroSection: some View {
        ZStack(alignment: .bottom) {
            Color.clear
                .aspectRatio(1.618, contentMode: .fit)
                .padding(.bottom, 72)

            DFKMapView(
                cameraPosition: $mapPosition,
                isInteractive: false,
                allowsGeneratedSnapshot: reviewRoutesReady,
                showsUserLocation: false,
                timelineItems: reviewTimelineItemsCache,
                prefersActivityIcons: false,
                condensesTransportOverview: true,
                clustersPlacesByMapScale: true,
                placeClusterRegion: reviewMapRegion,
                showsUserDefinedPlaceRadii: false,
                topContentInset: 32,
                bottomContentInset: 76,
                timelineUpdateIdentifier: reviewMapRevision,
                showsMapControls: false
            )
            .allowsHitTesting(false)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 0) {
                reviewMetric(icon: reviewGeographyMetric.icon, value: reviewGeographyMetric.value, label: reviewGeographyMetric.label)
                Divider().frame(height: 36)
                reviewMetric(icon: "road.lanes", value: reviewDistanceText, label: "")
                Divider().frame(height: 36)
                reviewMetric(icon: "point.topleft.down.to.point.bottomright.curvepath", value: "\(reviewDerived.transportCount)", label: "段路程")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 15)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.white.opacity(0.42), lineWidth: 0.5)
            }
            .padding(12)
        }
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 0.5)
        }
        .overlay(alignment: .topTrailing) {
            Button { presentedSheet = .map } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.subheadline.bold())
                    .foregroundStyle(.primary)
                    .padding(11)
                    .background(.regularMaterial, in: Circle())
            }
            .padding(14)
            .accessibilityLabel("打开完整生活地图")
        }
        .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .onTapGesture { presentedSheet = .map }
        .padding(.horizontal, 16)
    }

    private func reviewMetric(icon: String, value: String, label: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.dfkAccent)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.headline.weight(.bold))
                if !label.isEmpty { Text(label).font(.caption.weight(.semibold)) }
            }
            .foregroundStyle(.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.62)
        }
        .frame(maxWidth: .infinity)
    }

    private var memorableSection: some View {
        let featuredCandidate = reviewMemoryCandidatesCache.first { !$0.id.hasPrefix("favorite-") }
        let compactCandidates = reviewMemoryCandidatesCache.filter { $0.id.hasPrefix("favorite-") }
            + [pastMemoryCandidate].compactMap { $0 }
            + reviewMemoryCandidatesCache.filter {
                $0.id != featuredCandidate?.id && !$0.id.hasPrefix("favorite-")
            }
        return VStack(alignment: .leading, spacing: 12) {
            if featuredCandidate == nil && compactCandidates.isEmpty {
                ContentUnavailableView("还没有特别突出的片段", systemImage: "sparkles", description: Text("停留、照片和新的经历积累后，会在这里自然出现"))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .padding(.horizontal, 16)
            } else {
                VStack(spacing: 12) {
                    if let first = featuredCandidate {
                        reviewMemoryCard(first, isLarge: true)
                            .padding(.horizontal, 16)
                    }

                    if !compactCandidates.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 12) {
                                ForEach(compactCandidates) { candidate in
                                    reviewMemoryCard(candidate, isLarge: false)
                                        .frame(width: 176)
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                        .scrollClipDisabled(!usesIPadLayout)
                    }
                }
            }
        }
    }

    private func reviewMemoryCard(_ candidate: ReviewMemoryCandidate, isLarge: Bool) -> some View {
        Button {
            if candidate.id.hasPrefix("favorite-") {
                presentedSheet = .favorites
                return
            }
            if candidate.id.hasPrefix("past-memory-") {
                onDateSelected?(candidate.date)
                return
            }
            openReviewPlace(for: candidate)
        } label: {
            Group {
                if isLarge {
                    ZStack(alignment: .bottomLeading) {
                        reviewMemoryArtwork(candidate, isLarge: true)
                            .scaledToFill()
                            .frame(maxWidth: .infinity)
                            .frame(height: 248)
                            .clipped()

                        LinearGradient(
                            colors: [.clear, .black.opacity(0.12), .black.opacity(0.78)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .allowsHitTesting(false)

                        VStack(alignment: .leading, spacing: 5) {
                            Text(candidate.reason)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.dfkAccent)
                                .lineLimit(1)
                            Text(candidate.title)
                                .font(.title2.weight(.bold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .minimumScaleFactor(0.68)
                                .allowsTightening(true)
                            Text(candidate.evidence)
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.82))
                                .lineLimit(1)
                        }
                        .shadow(color: .black.opacity(0.28), radius: 5, y: 2)
                        .padding(18)
                        .allowsHitTesting(false)
                    }
                    .frame(height: 248)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        reviewMemoryArtwork(candidate, isLarge: false)
                            .scaledToFill()
                            .frame(maxWidth: .infinity)
                            .frame(height: 116)
                            .clipped()
                        reviewMemoryText(candidate, isLarge: false)
                            .frame(height: 76, alignment: .topLeading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                    }
                    .frame(height: 212, alignment: .top)
                }
            }
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Opens the candidate's place; grouping, sorting and statistics run off
    /// main, and only the resulting selection is assigned here.
    private func openReviewPlace(for candidate: ReviewMemoryCandidate) {
        guard let footprintID = candidate.footprintID,
              let placeKey = reviewDerived.placeKey(for: footprintID) else {
            onDateSelected?(candidate.date)
            return
        }
        let derived = reviewDerived
        let rangeText = statisticsRangeText
        let resolvedPhotoAssetIDs = candidate.photoAssetIDs
        Task { @MainActor in
            let group = await reviewDetached(priority: .userInitiated) {
                ReviewDataBuilder.placeGroup(
                    id: placeKey,
                    visits: (derived.footprintIDsByPlaceKey[placeKey] ?? []).compactMap { derived.rangeSnapshotsByID[$0] },
                    titleKeyPath: \.placeName,
                    resolvedPhotoAssetIDs: resolvedPhotoAssetIDs
                )
            }
            if let group,
               let selection = ReviewPlaceSelection(group: group, rangeText: rangeText, footprintsByID: rangeFootprintsByID) {
                presentedSheet = .places(
                    ReviewPlaceQuery(id: placeKey, source: .placeKeys([placeKey]), title: selection.title, usesMapTitle: false, presentsList: false),
                    [selection]
                )
            } else {
                onDateSelected?(candidate.date)
            }
        }
    }

    private func openReviewRegionItem(_ item: FrequentPlaceItem, scope: FrequentPlaceRankScope) {
        let derived = reviewDerived
        let rangeText = statisticsRangeText
        let footprintIDs = item.footprintIDs
        Task { @MainActor in
            let groups = await reviewDetached(priority: .userInitiated) {
                ReviewDataBuilder.placeGroups(
                    from: footprintIDs.compactMap { derived.rangeSnapshotsByID[$0] },
                    titleKeyPath: \.placeName
                )
            }
            let places = groups.compactMap {
                ReviewPlaceSelection(group: $0, rangeText: rangeText, footprintsByID: rangeFootprintsByID)
            }
            guard !places.isEmpty else { return }

            presentedSheet = .places(
                ReviewPlaceQuery(
                    id: "\(scope.rawValue):\(item.id)",
                    source: .rankItem(scope, item.id),
                    title: item.name,
                    usesMapTitle: false,
                    presentsList: scope != .place
                ),
                places
            )
        }
    }

    @ViewBuilder
    private func reviewMemoryArtwork(_ candidate: ReviewMemoryCandidate, isLarge: Bool) -> some View {
        if !candidate.photoAssetIDs.isEmpty {
            if isLarge && candidate.photoAssetIDs.count > 1 {
                ReviewMemoryPhotoCarousel(assetIDs: candidate.photoAssetIDs)
            } else {
                ContinuousTimelinePhotoThumbnail(
                    assetIDs: candidate.photoAssetIDs,
                    targetSide: isLarge ? 420 : 176,
                    fillsAvailableSpace: true,
                    usesHighQualityThumbnail: true,
                    prefersEarliestPhoto: true
                )
            }
        } else {
            let isFavorite = candidate.id.hasPrefix("favorite-")
            let isPastMemory = candidate.id.hasPrefix("past-memory-")
            let primaryColor: Color = isFavorite ? .orange : (isPastMemory ? .indigo : .dfkAccent)
            let secondaryColor: Color = isFavorite ? .pink : (isPastMemory ? .purple : .blue)
            ZStack {
                LinearGradient(
                    colors: [primaryColor.opacity(0.34), secondaryColor.opacity(0.16)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Circle()
                    .fill(secondaryColor.opacity(0.1))
                    .frame(width: isLarge ? 180 : 92, height: isLarge ? 180 : 92)
                    .offset(x: isLarge ? 120 : 54, y: isLarge ? -74 : -34)
                Circle()
                    .fill(Color.white.opacity(0.24))
                    .frame(width: isLarge ? 82 : 56, height: isLarge ? 82 : 56)
                Image(systemName: candidate.systemImage)
                    .font(.system(size: isLarge ? 38 : 28, weight: .semibold))
                    .foregroundStyle(primaryColor)
            }
        }
    }

    private func reviewMemoryText(_ candidate: ReviewMemoryCandidate, isLarge: Bool) -> some View {
        VStack(alignment: .leading, spacing: isLarge ? 8 : 5) {
            Text(candidate.reason)
                .font(isLarge ? .subheadline.weight(.semibold) : .caption.weight(.semibold))
                .foregroundStyle(Color.dfkAccent)
                .lineLimit(isLarge ? 2 : 1)
            Text(candidate.title)
                .font(isLarge ? .title3.weight(.semibold) : .headline)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(isLarge ? 0.72 : 0.68)
                .allowsTightening(true)
            Text(candidate.evidence)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(isLarge ? 2 : 1)
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: isLarge ? .infinity : nil,
            alignment: .topLeading
        )
    }

    private var reviewBentoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: 12, alignment: .top),
                    count: usesIPadLayout ? 4 : 2
                ),
                spacing: 12
            ) {
                Button { presentedSheet = .bento(.activity) } label: { reviewActivityCompositionCard }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                Button { presentedSheet = .bento(.rhythm) } label: { reviewRhythmCard }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                Button { presentedSheet = .bento(.transport) } label: { reviewTransportCard }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                Button { presentedSheet = .bento(.regions) } label: { reviewRegionCard }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
            }
            .padding(.horizontal, 16)
        }
    }

    private var reviewActivityCompositionCard: some View {
        reviewBentoCard(title: "时间花在哪", icon: "clock.fill") {
            let slices = reviewActivitySlices
            let total = max(1, slices.reduce(0) { $0 + $1.duration })
            GeometryReader { geometry in
                let chartSide = min(116, max(56, geometry.size.width * 0.36))
                let lineWidth = min(14, max(8, chartSide * 0.14))
                HStack(spacing: 10) {
                    Canvas { context, size in
                        let radius = max(0, (min(size.width, size.height) - lineWidth) / 2)
                        var start = Angle.degrees(-90)
                        for slice in slices.prefix(5) {
                            let sweep = Angle.degrees(360 * slice.duration / total)
                            var path = Path()
                            path.addArc(
                                center: CGPoint(x: size.width / 2, y: size.height / 2),
                                radius: radius,
                                startAngle: start,
                                endAngle: start + sweep,
                                clockwise: false
                            )
                            context.stroke(
                                path,
                                with: .color(slice.color),
                                style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt)
                            )
                            start += sweep
                        }
                    }
                    .frame(width: chartSide, height: chartSide)

                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(slices.prefix(3)) { slice in
                            HStack(alignment: .top, spacing: 5) {
                                Circle()
                                    .fill(slice.color)
                                    .frame(width: 7, height: 7)
                                    .padding(.top, 3)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(slice.name)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Text(formatRankDuration(slice.duration))
                                        .fontWeight(.semibold)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.65)
                                        .allowsTightening(true)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
            .frame(height: 116)
        }
    }

    private var reviewRhythmCard: some View {
        reviewBentoCard(title: "出行节奏", icon: "chart.bar.xaxis") {
            let mileage = reviewMileageMetrics
            VStack(alignment: .leading, spacing: 10) {
                let values = mileage.dailyValues.map { Int($0.distance.rounded()) }
                ReviewDailyFootprintHeatmap(values: values, accessibilityText: "每日里程热度")
                    .frame(height: reviewRhythmCardHeatmapHeight(itemCount: values.count))
                Text("日均 \(formatRankMileage(mileage.dailyAverage))")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
    }

    private func reviewRhythmCardHeatmapHeight(itemCount: Int) -> CGFloat {
        min(164, max(92, CGFloat(sqrt(Double(max(1, itemCount)))) * 8.5))
    }

    private func reviewRhythmBar(value: Int, maximum: Int, width: CGFloat) -> some View {
        let opacity = value == 0 ? 0.12 : 0.34
        let color = value == maximum ? Color.dfkAccent : Color.dfkAccent.opacity(opacity)
        let height = max(6, 68 * CGFloat(value) / CGFloat(maximum))
        return Capsule().fill(color).frame(width: width, height: height)
    }

    private func reviewRhythmBarWidth(totalWidth: CGFloat, count: Int) -> CGFloat {
        let spacing = CGFloat(max(0, count - 1)) * 3
        return max(2, (totalWidth - spacing) / CGFloat(max(1, count)))
    }

    private var reviewRhythmAxisStartText: String {
        reviewRangeStart.formatted(.dateTime.month().day())
    }

    private var reviewRhythmAxisEndText: String {
        reviewRangeEnd.formatted(.dateTime.month().day())
    }

    private func reviewRhythmBucketText(at index: Int) -> String {
        let count = max(1, reviewActivityBuckets.count)
        let interval = reviewRangeEnd.timeIntervalSince(reviewRangeStart) / Double(count)
        let start = reviewRangeStart.addingTimeInterval(interval * Double(index))
        let end = reviewRangeStart.addingTimeInterval(interval * Double(index + 1))
        return "\(start.formatted(.dateTime.month().day()))–\(end.formatted(.dateTime.month().day()))"
    }

    private var reviewTransportCard: some View {
        reviewBentoCard(title: "最常用交通", icon: "car.fill") {
            let slices = reviewTransportSlices
            VStack(alignment: .leading, spacing: 10) {
                ForEach(slices.prefix(3)) { slice in
                    HStack(spacing: 8) {
                        Image(systemName: slice.icon).foregroundStyle(slice.color).frame(width: 18)
                        Text(slice.name).font(.caption).lineLimit(1)
                        Spacer()
                        Text("\(slice.count)次")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .allowsTightening(true)
                    }
                }
            }
        }
    }

    private var reviewRegionCard: some View {
        reviewBentoCard(title: "最常停留的区域", icon: "map.fill") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(reviewTopRegions.prefix(3), id: \.name) { item in
                    HStack {
                        Text(item.name).font(.caption).lineLimit(1)
                        Spacer()
                        Text(formatRankDuration(item.duration))
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.65)
                            .allowsTightening(true)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func reviewBentoDetailView(_ detail: ReviewBentoDetail) -> some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    Text(statisticsRangeText)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.dfkAccent)

                    if !reviewRoutesReady {
                        ProgressView()
                            .controlSize(.large)
                            .frame(maxWidth: .infinity, minHeight: 320)
                    } else {
                    switch detail {
                    case .activity:
                        reviewActivityDetail
                    case .rhythm:
                        reviewRhythmDetail
                    case .transport:
                        reviewTransportDetail
                    case .regions:
                        reviewRegionsDetail
                    }
                    }
                }
                .padding(20)
            }
            .background(Color.dfkBackground)
            .navigationTitle("\(statisticsRangeText) · \(reviewBentoDetailTitle(detail))")
            .navigationBarTitleDisplayMode(.inline)
            .reviewRangeBar(rangeControl)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").dfkToolbarDismissIcon()
                    }
                }
            }
        }
    }

    // MARK: - Review Sheets

    private var sheetSeed: ReviewSheetSeed {
        ReviewSheetSeed(
            source: reviewSource,
            sourceFingerprint: reviewSourceFingerprint,
            range: appliedRange,
            activeYear: activeYearForSegment,
            derived: reviewDerived,
            rangeFootprints: rangeFootprints,
            rangeFootprintsByID: rangeFootprintsByID,
            tripActivityDays: reviewTripActivityDays,
            timelineItems: reviewTimelineItemsCache,
            mapRegion: reviewMapRegion,
            mapPosition: mapPosition,
            routesReady: reviewRoutesReady,
            frequentPlaceRankScope: frequentPlaceRankScope,
            allowsRangeSelection: sheet == nil
        )
    }

    private var rangeControl: ReviewRangeControl? {
        guard allowsRangeSelection else { return nil }
        return ReviewRangeControl(selection: $selectedRange, years: availableYears, activeYear: activeYearForSegment)
    }

    @ViewBuilder
    private func sheetBody(_ content: ReviewSheetContent) -> some View {
        switch content {
        case .map:
            if reviewRoutesReady {
                FullReviewMapView(
                    title: "\(statisticsRangeText) · \(reviewGeographyMetric.value)\(reviewGeographyMetric.label)",
                    rangeText: statisticsRangeText,
                    timelineItems: reviewTimelineItemsCache,
                    footprintSnapshots: reviewDerived.rangeSnapshotsByID,
                    initialRegion: reviewMapRegion,
                    initialPosition: mapPosition,
                    rangeControl: rangeControl,
                    onOpenPlaces: { query, places in
                        presentedSheet = .places(query, places)
                    }
                )
            } else {
                reviewSheetLoading(title: statisticsRangeText)
            }
        case .bento(let detail):
            reviewBentoDetailView(detail)
        case .favorites:
            NavigationStack {
                Group {
                    if reviewRoutesReady {
                        HistoryFavoritesView(
                            includedFootprintIDs: reviewDerived.favoriteFootprintIDs
                        ) { footprint in
                            onFootprintSelected?(footprint)
                        }
                    } else {
                        ProgressView()
                            .controlSize(.large)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .navigationTitle("\(statisticsRangeText) · 收藏足迹")
                .navigationBarTitleDisplayMode(.inline)
                .reviewRangeBar(rangeControl)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark").dfkToolbarDismissIcon()
                        }
                    }
                }
            }
            .presentationDetents([.large])
        case .places(let query, _):
            Group {
                if !reviewRoutesReady || sheetPlacesRange != appliedRange {
                    reviewSheetLoading(title: "\(statisticsRangeText) · \(query.title)")
                } else if query.presentsList {
                    ReviewPlaceListSheet(
                        selection: ReviewPlaceListSelection(id: query.id, title: query.title, rangeText: statisticsRangeText, places: sheetPlaces),
                        rangeControl: rangeControl,
                        onSelectPlace: { place in
                            presentedSheet = .places(
                                ReviewPlaceQuery(id: place.id, source: .placeKeys([place.id]), title: place.title, usesMapTitle: query.usesMapTitle, presentsList: false),
                                [place]
                            )
                        }
                    )
                } else if let place = sheetPlaces.first {
                    ReviewPlaceView(selection: place, rangeControl: rangeControl)
                } else {
                    reviewSheetChrome(title: "\(statisticsRangeText) · \(query.title)") {
                        ContentUnavailableView("这段时间没有到访", systemImage: "mappin.slash", description: Text("换一个时间范围看看"))
                    }
                }
            }
            .presentationDetents(query.presentsList ? Set<PresentationDetent>([.medium, .large]) : [.large])
            .task(id: "\(appliedRange.rawValue)|\(reviewRoutesReady)") {
                await resolveSheetPlaces(query)
            }
        }
    }

    private func reviewSheetLoading(title: String) -> some View {
        reviewSheetChrome(title: title) {
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func reviewSheetChrome<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        NavigationStack {
            content()
                .background(Color.dfkBackground)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .reviewRangeBar(rangeControl)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark").dfkToolbarDismissIcon()
                        }
                    }
                }
        }
    }

    /// Re-resolves a place sheet for the sheet's range, off main, once that
    /// range's data is ready.
    private func resolveSheetPlaces(_ query: ReviewPlaceQuery) async {
        let range = appliedRange
        guard reviewRoutesReady, sheetPlacesRange != range else { return }
        let derived = reviewDerived
        let rangeText = statisticsRangeText
        let groups = await reviewDetached(priority: .userInitiated) {
            let footprintIDs: [UUID]
            switch query.source {
            case .placeKeys(let keys):
                footprintIDs = keys.flatMap { derived.footprintIDsByPlaceKey[$0] ?? [] }
            case .rankItem(let scope, let itemID):
                footprintIDs = derived.frequentPlaces[scope]?.first(where: { $0.id == itemID })?.footprintIDs ?? []
            }
            let titleKeyPath: KeyPath<ReviewFootprintSnapshot, String> = query.usesMapTitle ? \.mapTitle : \.placeName
            return ReviewDataBuilder.placeGroups(
                from: footprintIDs.compactMap { derived.rangeSnapshotsByID[$0] },
                titleKeyPath: titleKeyPath
            )
        }
        guard !Task.isCancelled, range == appliedRange, reviewRoutesReady else { return }
        sheetPlaces = groups.compactMap {
            ReviewPlaceSelection(group: $0, rangeText: rangeText, footprintsByID: rangeFootprintsByID)
        }
        sheetPlacesRange = range
    }

    private func reviewBentoDetailTitle(_ detail: ReviewBentoDetail) -> String {
        switch detail {
        case .activity: return "时间花在哪"
        case .rhythm: return "出行节奏"
        case .transport: return "最常用交通"
        case .regions: return "最常停留的区域"
        }
    }

    private var reviewActivityDetail: some View {
        let slices = reviewActivitySlices
        let total = max(1, slices.reduce(0) { $0 + $1.duration })
        return VStack(spacing: 16) {
            Canvas { context, size in
                let lineWidth: CGFloat = 24
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let radius = max(0, min(size.width * 0.23, size.height * 0.30))
                var start = Angle.degrees(-90)
                var leftLabels: [(slice: ReviewActivitySlice, angle: Angle, y: CGFloat)] = []
                var rightLabels: [(slice: ReviewActivitySlice, angle: Angle, y: CGFloat)] = []

                for slice in slices {
                    let sweep = Angle.degrees(360 * slice.duration / total)
                    let middle = start + Angle.degrees(sweep.degrees / 2)
                    var path = Path()
                    path.addArc(
                        center: center,
                        radius: radius,
                        startAngle: start,
                        endAngle: start + sweep,
                        clockwise: false
                    )
                    context.stroke(
                        path,
                        with: .color(slice.color),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt)
                    )
                    let targetY = center.y + CGFloat(sin(middle.radians)) * (radius + 34)
                    if cos(middle.radians) < 0 {
                        leftLabels.append((slice, middle, targetY))
                    } else {
                        rightLabels.append((slice, middle, targetY))
                    }
                    start += sweep
                }

                func arranged(_ labels: [(slice: ReviewActivitySlice, angle: Angle, y: CGFloat)]) -> [(slice: ReviewActivitySlice, angle: Angle, y: CGFloat)] {
                    guard !labels.isEmpty else { return [] }
                    var result = labels.sorted { $0.y < $1.y }
                    let minimumY: CGFloat = 18
                    let maximumY = size.height - 18
                    let gap = min(28, (maximumY - minimumY) / CGFloat(max(1, result.count - 1)))
                    result[0].y = max(minimumY, result[0].y)
                    for index in result.indices.dropFirst() {
                        result[index].y = max(result[index].y, result[index - 1].y + gap)
                    }
                    if let overflow = result.last.map({ $0.y - maximumY }), overflow > 0 {
                        for index in result.indices { result[index].y -= overflow }
                    }
                    return result
                }

                for (isLeft, labels) in [(true, arranged(leftLabels)), (false, arranged(rightLabels))] {
                    for label in labels {
                        let direction: CGFloat = isLeft ? -1 : 1
                        let radians = label.angle.radians
                        let lineStart = CGPoint(
                            x: center.x + CGFloat(cos(radians)) * (radius + lineWidth / 2),
                            y: center.y + CGFloat(sin(radians)) * (radius + lineWidth / 2)
                        )
                        let elbow = CGPoint(x: center.x + direction * (radius + 32), y: label.y)
                        let percent = Int((label.slice.duration / total * 100).rounded())
                        let text = context.resolve(
                            Text("\(label.slice.name) \(percent)%")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(label.slice.color)
                        )
                        let textSize = text.measure(
                            in: CGSize(width: size.width * 0.34, height: 30)
                        )
                        let lineEnd = CGPoint(
                            x: isLeft ? 14 + textSize.width : size.width - 14 - textSize.width,
                            y: label.y
                        )
                        var leader = Path()
                        leader.move(to: lineStart)
                        leader.addLine(to: elbow)
                        leader.addLine(to: lineEnd)
                        context.stroke(leader, with: .color(label.slice.color.opacity(0.8)), lineWidth: 1)

                        context.draw(
                            text,
                            at: CGPoint(x: isLeft ? 8 : size.width - 8, y: label.y - 3),
                            anchor: isLeft ? .leading : .trailing
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 290)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))

            VStack(spacing: 0) {
                ForEach(slices) { slice in
                    reviewDetailRow(
                        icon: slice.icon,
                        color: slice.color,
                        title: slice.name,
                        value: formatRankDuration(slice.duration),
                        subtitle: "占停留时间 \(Int((slice.duration / total * 100).rounded()))%"
                    )
                }
            }
            .reviewDetailListStyle()

            reviewActivitySummaryGrid
            reviewActivityVisitCountChart
            reviewActivityAverageDurationChart
            reviewActivityWeekdayHeatmap
            reviewActivityHourlyRhythms
        }
    }

    private var reviewActivitySummaryGrid: some View {
        let slices = reviewActivitySlices
        let visitCount = reviewDerived.activityRecognizedCount
        let totalDuration = slices.reduce(0) { $0 + $1.duration }
        let dominantShare = totalDuration > 0 ? Int(((slices.first?.duration ?? 0) / totalDuration * 100).rounded()) : 0
        let averageDuration = visitCount == 0 ? 0 : totalDuration / Double(visitCount)
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2), spacing: 10) {
            reviewActivityMetricCard(title: "活动类型", value: "\(slices.count)种", icon: "square.grid.2x2.fill")
            reviewActivityMetricCard(title: "活动记录", value: "\(visitCount)次", icon: "list.number")
            reviewActivityMetricCard(title: "单次平均", value: formatRankDuration(averageDuration), icon: "timer")
            reviewActivityMetricCard(title: "头部活动占比", value: "\(dominantShare)%", icon: "chart.pie.fill")
        }
    }

    private func reviewActivityMetricCard(title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon).foregroundStyle(Color.dfkAccent)
            Text(value)
                .font(.title2.bold())
                .lineLimit(1)
                .minimumScaleFactor(0.68)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var reviewActivityVisitCountChart: some View {
        let values = reviewActivitySlices.map { slice in
            ReviewActivityBarValue(
                slice: slice,
                value: Double(reviewActivityVisitCount(for: slice.name)),
                valueText: "\(reviewActivityVisitCount(for: slice.name))次"
            )
        }
        return reviewActivityHorizontalBars(title: "各类型发生次数", icon: "chart.bar.xaxis", values: values)
    }

    private var reviewActivityAverageDurationChart: some View {
        let values = reviewActivitySlices.map { slice in
            let count = max(1, reviewActivityVisitCount(for: slice.name))
            let average = slice.duration / Double(count)
            return ReviewActivityBarValue(
                slice: slice,
                value: average,
                valueText: formatRankDuration(average)
            )
        }
        return reviewActivityHorizontalBars(title: "单次平均停留", icon: "hourglass", values: values)
    }

    private func reviewActivityHorizontalBars(
        title: String,
        icon: String,
        values: [ReviewActivityBarValue]
    ) -> some View {
        ReviewActivityHorizontalBars(title: title, icon: icon, values: values)
    }

    private var reviewActivityWeekdayHeatmap: some View {
        let slices = Array(reviewActivitySlices.prefix(5))
        let rows = slices.map {
            ReviewActivityHeatmapRow(slice: $0, counts: reviewActivityWeekdayCounts(for: $0.name))
        }
        let maximum = max(1, rows.flatMap(\.counts).max() ?? 1)
        return VStack(alignment: .leading, spacing: 14) {
            Label("星期 × 活动", systemImage: "calendar").font(.headline)
            HStack(spacing: 5) {
                Color.clear.frame(width: 72, height: 1)
                ForEach(reviewRhythmWeekdaySymbols, id: \.self) { symbol in
                    Text(symbol).font(.caption2).frame(maxWidth: .infinity)
                }
            }
            ForEach(rows) { row in
                HStack(spacing: 5) {
                    Text(row.slice.name)
                        .font(.caption)
                        .lineLimit(1)
                        .frame(width: 72, alignment: .leading)
                    ForEach(row.counts.indices, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(row.slice.color.opacity(row.counts[index] == 0 ? 0.08 : 0.20 + 0.80 * Double(row.counts[index]) / Double(maximum)))
                            .aspectRatio(1, contentMode: .fit)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var reviewActivityHourlyRhythms: some View {
        let slices = Array(reviewActivitySlices.prefix(4))
        return VStack(alignment: .leading, spacing: 16) {
            Label("活动发生时刻", systemImage: "clock").font(.headline)
            ForEach(slices) { slice in
                let values = reviewActivityHourlyCounts(for: slice.name)
                let maximum = max(1, values.max() ?? 1)
                VStack(alignment: .leading, spacing: 6) {
                    Text(slice.name).font(.caption.weight(.semibold))
                    HStack(alignment: .bottom, spacing: 2) {
                        ForEach(values.indices, id: \.self) { index in
                            Capsule()
                                .fill(slice.color.opacity(values[index] == 0 ? 0.08 : 0.30 + 0.70 * Double(values[index]) / Double(maximum)))
                                .frame(maxWidth: .infinity)
                                .frame(height: max(3, 34 * CGFloat(values[index]) / CGFloat(maximum)))
                        }
                    }
                    .frame(height: 34, alignment: .bottom)
                }
            }
            HStack {
                Text("0时"); Spacer(); Text("6时"); Spacer(); Text("12时"); Spacer(); Text("18时"); Spacer(); Text("24时")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var reviewTransportDetail: some View {
        let slices = reviewTransportSlices
        let total = max(1, slices.reduce(0) { $0 + $1.count })
        return VStack(alignment: .leading, spacing: 18) {
            VStack(spacing: 0) {
                ForEach(slices) { slice in
                    reviewDetailRow(
                        icon: slice.icon,
                        color: slice.color,
                        title: slice.name,
                        value: "\(slice.count)次",
                        subtitle: "占出行次数 \(Int((Double(slice.count) / Double(total) * 100).rounded()))% · \(formatRankMileage(slice.distance))"
                    )
                }
            }
            .reviewDetailListStyle()

            reviewTransportSummaryGrid
            reviewTransportActiveDaysChart
            reviewTransportDistanceChart
            reviewTransportAverageDistanceChart
            reviewTransportWeekdayHeatmap
            reviewTransportHourlyRhythms
        }
    }

    private var reviewTransportSummaryGrid: some View {
        let slices = reviewTransportSlices
        let totalCount = slices.reduce(0) { $0 + $1.count }
        let totalDistance = slices.reduce(0) { $0 + $1.distance }
        let averageDistance = totalCount == 0 ? 0 : totalDistance / Double(totalCount)
        let dominantShare = totalCount == 0 ? 0 : Int((Double(slices.first?.count ?? 0) / Double(totalCount) * 100).rounded())
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2), spacing: 10) {
            reviewTransportMetricCard(title: "交通方式", value: "\(slices.count)种", icon: "square.grid.2x2.fill")
            reviewTransportMetricCard(title: "路程总数", value: "\(totalCount)段", icon: "point.bottomleft.forward.to.point.topright.scurvepath")
            reviewTransportMetricCard(title: "单程平均", value: formatRankMileage(averageDistance), icon: "ruler")
            reviewTransportMetricCard(title: "常用方式占比", value: "\(dominantShare)%", icon: "chart.pie.fill")
        }
    }

    private func reviewTransportMetricCard(title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon).foregroundStyle(Color.dfkAccent)
            Text(value)
                .font(.title2.bold())
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var reviewTransportActiveDaysChart: some View {
        let values = reviewTransportSlices.map { slice in
            let activeDays = reviewDerived.transportActiveDays[slice.id] ?? 0
            return ReviewTransportBarValue(slice: slice, value: Double(activeDays), valueText: "\(activeDays)天")
        }
        return reviewTransportHorizontalBars(title: "使用天数", icon: "calendar", values: values)
    }

    private var reviewTransportDistanceChart: some View {
        let values = reviewTransportSlices.map {
            ReviewTransportBarValue(slice: $0, value: $0.distance, valueText: formatRankMileage($0.distance))
        }
        return reviewTransportHorizontalBars(title: "累计里程", icon: "road.lanes", values: values)
    }

    private var reviewTransportAverageDistanceChart: some View {
        let values = reviewTransportSlices.map {
            let average = $0.count == 0 ? 0 : $0.distance / Double($0.count)
            return ReviewTransportBarValue(slice: $0, value: average, valueText: formatRankMileage(average))
        }
        return reviewTransportHorizontalBars(title: "平均单程距离", icon: "ruler", values: values)
    }

    private func reviewTransportHorizontalBars(
        title: String,
        icon: String,
        values: [ReviewTransportBarValue]
    ) -> some View {
        let rankedValues = values.sorted {
            if $0.value != $1.value { return $0.value > $1.value }
            return $0.slice.name.localizedStandardCompare($1.slice.name) == .orderedAscending
        }
        let maximum = max(1, rankedValues.first?.value ?? 1)
        return VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: icon).font(.headline)
            ForEach(rankedValues.prefix(6)) { item in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label(item.slice.name, systemImage: item.slice.icon).lineLimit(1)
                        Spacer()
                        Text(item.valueText).fontWeight(.semibold).foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    GeometryReader { geometry in
                        Capsule().fill(item.slice.color.opacity(0.14))
                        Capsule()
                            .fill(item.slice.color)
                            .frame(width: max(5, geometry.size.width * item.value / maximum))
                    }
                    .frame(height: 8)
                }
            }
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var reviewTransportWeekdayHeatmap: some View {
        let slices = Array(reviewTransportSlices.prefix(5))
        let rows = slices.map {
            ReviewTransportHeatmapRow(slice: $0, counts: reviewTransportWeekdayCounts(for: $0.id))
        }
        let maximum = max(1, rows.flatMap(\.counts).max() ?? 1)
        return VStack(alignment: .leading, spacing: 14) {
            Label("星期 × 交通方式", systemImage: "calendar").font(.headline)
            HStack(spacing: 5) {
                Color.clear.frame(width: 72, height: 1)
                ForEach(reviewRhythmWeekdaySymbols, id: \.self) { symbol in
                    Text(symbol).font(.caption2).frame(maxWidth: .infinity)
                }
            }
            ForEach(rows) { row in
                HStack(spacing: 5) {
                    Text(row.slice.name).font(.caption).lineLimit(1).frame(width: 72, alignment: .leading)
                    ForEach(row.counts.indices, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(row.slice.color.opacity(row.counts[index] == 0 ? 0.08 : 0.20 + 0.80 * Double(row.counts[index]) / Double(maximum)))
                            .aspectRatio(1, contentMode: .fit)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var reviewTransportHourlyRhythms: some View {
        let slices = Array(reviewTransportSlices.prefix(4))
        return VStack(alignment: .leading, spacing: 16) {
            Label("交通发生时刻", systemImage: "clock").font(.headline)
            ForEach(slices) { slice in
                let values = reviewTransportHourlyCounts(for: slice.id)
                let maximum = max(1, values.max() ?? 1)
                VStack(alignment: .leading, spacing: 6) {
                    Text(slice.name).font(.caption.weight(.semibold))
                    HStack(alignment: .bottom, spacing: 2) {
                        ForEach(values.indices, id: \.self) { index in
                            Capsule()
                                .fill(slice.color.opacity(values[index] == 0 ? 0.08 : 0.30 + 0.70 * Double(values[index]) / Double(maximum)))
                                .frame(maxWidth: .infinity)
                                .frame(height: max(3, 34 * CGFloat(values[index]) / CGFloat(maximum)))
                        }
                    }
                    .frame(height: 34, alignment: .bottom)
                }
            }
            HStack {
                Text("0时"); Spacer(); Text("6时"); Spacer(); Text("12时"); Spacer(); Text("18时"); Spacer(); Text("24时")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var reviewRhythmDetail: some View {
        let mileage = reviewMileageMetrics
        return VStack(alignment: .leading, spacing: 16) {
            Text("从每日里程、星期、时刻、趋势和连续性观察这段时间的出行节奏。")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            reviewMileageDailyHeatmap(mileage)
            reviewMileageSummaryGrid(mileage)
            reviewMileageDailyChart(mileage)
            reviewMileageWeekdayChart(mileage)

            VStack(alignment: .leading, spacing: 4) {
                Text("足迹活跃分析")
                    .font(.title3.bold())
                Text("以下按足迹次数与活跃天数统计，不代表里程。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 8)

            reviewRhythmSummaryGrid

            VStack(alignment: .leading, spacing: 6) {
                Label("周期走势", systemImage: "chart.xyaxis.line")
                    .font(.headline)
                GeometryReader { geometry in
                    let values = reviewActivityBuckets
                    let maximum = max(1, values.max() ?? 1)
                    HStack(alignment: .bottom, spacing: 3) {
                        ForEach(values.indices, id: \.self) { index in
                            reviewRhythmBar(
                                value: values[index],
                                maximum: maximum,
                                width: reviewRhythmBarWidth(totalWidth: geometry.size.width, count: values.count)
                            )
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: .bottom)
                }
                .frame(height: 150)
                HStack {
                    Text(reviewRhythmAxisStartText)
                    Spacer()
                    Text(reviewRhythmAxisEndText)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(16)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))

            reviewRhythmWeekdayChart
            reviewRhythmHourlyChart

            HStack(spacing: 12) {
                reviewRhythmInsightCard(
                    title: "最长连续活跃",
                    value: "\(reviewRhythmLongestStreak)天",
                    icon: "flame.fill"
                )
                reviewRhythmInsightCard(
                    title: "最高单日",
                    value: "\(reviewRhythmPeakCount)次",
                    icon: "arrow.up.right"
                )
            }
        }
    }

    private var reviewRhythmSummaryGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2), spacing: 10) {
            reviewRhythmMetricCard(title: "每周平均", value: reviewRhythmWeeklyAverageText, icon: "calendar")
            reviewRhythmMetricCard(title: "活跃天", value: "\(reviewRhythmActiveDayCount)天", icon: "checkmark.circle.fill")
            reviewRhythmMetricCard(title: "活跃天比例", value: "\(reviewRhythmActiveDayRate)%", icon: "circle.grid.3x3.fill")
            reviewRhythmMetricCard(title: "活跃日平均", value: reviewRhythmActiveDayAverageText, icon: "figure.walk")
        }
    }

    private func reviewMileageSummaryGrid(_ mileage: ReviewMileageMetrics) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2), spacing: 10) {
            reviewRhythmMetricCard(title: "总里程", value: formatRankMileage(mileage.total), icon: "road.lanes")
            reviewRhythmMetricCard(title: "日均里程", value: formatRankMileage(mileage.dailyAverage), icon: "divide")
            reviewRhythmMetricCard(title: "单日最高", value: formatRankMileage(mileage.peakDay?.distance ?? 0), icon: "arrow.up.right")
            reviewRhythmMetricCard(title: "有里程记录", value: "\(mileage.activeDayCount)天", icon: "calendar.badge.checkmark")
        }
    }

    private func reviewMileageDailyChart(_ mileage: ReviewMileageMetrics) -> some View {
        let values = mileage.dailyValues
        let maximum = max(1, values.map(\.distance).max() ?? 1)
        return VStack(alignment: .leading, spacing: 14) {
            Label("每日里程", systemImage: "chart.bar.xaxis")
                .font(.headline)
            Canvas { context, size in
                guard !values.isEmpty else { return }
                let spacing: CGFloat = values.count > 100 ? 0.5 : 3
                let barWidth = max(0.5, (size.width - spacing * CGFloat(values.count - 1)) / CGFloat(values.count))
                for index in values.indices {
                    let distance = values[index].distance
                    let barHeight = distance == 0 ? 5 : max(5, size.height * CGFloat(distance / maximum))
                    let rect = CGRect(
                        x: CGFloat(index) * (barWidth + spacing),
                        y: size.height - barHeight,
                        width: barWidth,
                        height: barHeight
                    )
                    let color = distance == 0
                        ? Color(uiColor: .systemGray5)
                        : (distance == maximum ? Color.dfkAccent : Color.dfkAccent.opacity(0.42))
                    context.fill(
                        Path(
                            roundedRect: rect,
                            cornerSize: CGSize(width: min(barWidth / 2, 4), height: min(barWidth / 2, 4))
                        ),
                        with: .color(color)
                    )
                }
            }
            .frame(height: 110)
            .accessibilityElement()
            .accessibilityLabel("每日里程柱状图")
            HStack {
                Text(values.first?.date.formatted(.dateTime.month().day()) ?? "")
                Spacer()
                if let peak = mileage.peakDay {
                    Text("最高：\(peak.date.formatted(.dateTime.month().day())) · \(formatRankMileage(peak.distance))")
                }
                Spacer()
                Text(values.last?.date.formatted(.dateTime.month().day()) ?? "")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func reviewMileageWeekdayChart(_ mileage: ReviewMileageMetrics) -> some View {
        let values = mileage.weekdayAverages
        let maximum = max(1, values.max() ?? 1)
        let peakIndex = values.indices.max { values[$0] < values[$1] }
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("星期平均里程", systemImage: "calendar")
                    .font(.headline)
                Spacer()
                if let peakIndex, values[peakIndex] > 0 {
                    Text("周\(reviewRhythmWeekdaySymbols[peakIndex])最多")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.dfkAccent)
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(values.indices, id: \.self) { index in
                    VStack(spacing: 6) {
                        Text(formatRankMileage(values[index]))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.55)
                        Capsule()
                            .fill(values[index] == maximum ? Color.dfkAccent : Color.dfkAccent.opacity(0.38))
                            .frame(height: max(8, 92 * CGFloat(values[index] / maximum)))
                        Text(reviewRhythmWeekdaySymbols[index])
                            .font(.caption.weight(.medium))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func reviewRhythmMetricCard(title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(Color.dfkAccent)
            Text(value)
                .font(.title2.bold())
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var reviewRhythmWeekdayChart: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("星期节奏", systemImage: "calendar")
                .font(.headline)
            let averages = reviewRhythmWeekdayAverages
            let maximum = max(0.1, averages.max() ?? 0.1)
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(averages.indices, id: \.self) { index in
                    VStack(spacing: 6) {
                        Text(reviewRhythmCompactNumber(averages[index]))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Capsule()
                            .fill(averages[index] == maximum ? Color.dfkAccent : Color.dfkAccent.opacity(0.38))
                            .frame(height: max(8, 92 * averages[index] / maximum))
                        Text(reviewRhythmWeekdaySymbols[index])
                            .font(.caption.weight(.medium))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var reviewRhythmHourlyChart: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("一天中的节奏", systemImage: "clock")
                .font(.headline)
            GeometryReader { geometry in
                let values = reviewRhythmHourlyCounts
                let maximum = max(1, values.max() ?? 1)
                let spacing: CGFloat = 3
                let width = max(3, (geometry.size.width - spacing * 23) / 24)
                HStack(alignment: .bottom, spacing: spacing) {
                    ForEach(values.indices, id: \.self) { index in
                        Capsule()
                            .fill(values[index] == maximum ? Color.dfkAccent : Color.dfkAccent.opacity(values[index] == 0 ? 0.10 : 0.38))
                            .frame(width: width, height: max(5, 110 * CGFloat(values[index]) / CGFloat(maximum)))
                    }
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .frame(height: 110)
            HStack {
                Text("0时")
                Spacer()
                Text("6时")
                Spacer()
                Text("12时")
                Spacer()
                Text("18时")
                Spacer()
                Text("24时")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func reviewMileageDailyHeatmap(_ mileage: ReviewMileageMetrics) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("每日里程热度", systemImage: "square.grid.3x3.fill")
                .font(.headline)
            let values = mileage.dailyValues.map { Int($0.distance.rounded()) }
            let columnCount = reviewRhythmDetailHeatmapColumnCount(for: values.count)
            ReviewDailyFootprintHeatmap(
                values: values,
                preferredColumnCount: columnCount,
                accessibilityText: "每日里程热度"
            )
                .frame(height: reviewRhythmDetailHeatmapHeight(itemCount: values.count, columnCount: columnCount))
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func reviewRhythmDetailHeatmapColumnCount(for itemCount: Int) -> Int {
        guard itemCount > 0 else { return 1 }
        // Keep long ranges visually balanced instead of compressing a year
        // into a very wide, tiny-cell strip.
        return min(itemCount, max(7, Int(ceil(sqrt(Double(itemCount) * 1.15)))))
    }

    private func reviewRhythmDetailHeatmapHeight(itemCount: Int, columnCount: Int) -> CGFloat {
        guard itemCount > 0 else { return 0 }
        let spacing: CGFloat = itemCount > 100 ? 1.5 : 3
        let safeColumnCount = max(1, columnCount)
        let rowCount = Int(ceil(Double(itemCount) / Double(safeColumnCount)))
        // Match the same width constraint used by the rendered grid. Limiting
        // the cell side keeps short ranges compact and prevents iPad cells from
        // becoming oversized while still allowing a year to use the card well.
        let availableWidth = max(1, min(UIScreen.main.bounds.width - 72, 700))
        let cellSide = min(
            18,
            max(1, (availableWidth - spacing * CGFloat(safeColumnCount - 1)) / CGFloat(safeColumnCount))
        )
        return CGFloat(rowCount) * cellSide + CGFloat(max(0, rowCount - 1)) * spacing
    }

    private func reviewRhythmInsightCard(title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon).foregroundStyle(Color.dfkAccent)
            Text(value).font(.title2.bold())
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var reviewRegionsDetail: some View {
        VStack(alignment: .leading, spacing: 22) {
            reviewRegionDetailSection(title: "国家", scope: .country, items: getFrequentPlacesData(for: .country))
            reviewRegionDetailSection(title: "城市", scope: .city, items: getFrequentPlacesData(for: .city))
            reviewRegionDetailSection(title: "地点", scope: .place, items: getFrequentPlacesData(for: .place))
        }
    }

    private func reviewRegionDetailSection(title: String, scope: FrequentPlaceRankScope, items: [FrequentPlaceItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title2.bold())
            if items.isEmpty {
                Text("暂无数据")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        Button {
                            openReviewRegionItem(item, scope: scope)
                        } label: {
                            HStack(spacing: 12) {
                                Text("\(index + 1)")
                                    .font(.subheadline.bold())
                                    .foregroundStyle(index < 3 ? Color.dfkAccent : .secondary)
                                    .frame(width: 24, alignment: .leading)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.name).fontWeight(.semibold)
                                    if !item.address.isEmpty, item.address != item.name {
                                        Text(item.address).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 3) {
                                    Text(formatRankDuration(item.duration)).fontWeight(.semibold)
                                    Text("\(item.count)次").font(.caption).foregroundStyle(.secondary)
                                }
                                Image(systemName: "chevron.right")
                                    .font(.caption.bold())
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 12)
                        if index < items.count - 1 { Divider() }
                    }
                }
                .reviewDetailListStyle()
            }
        }
    }

    private func reviewDetailRow(icon: String, color: Color, title: String, value: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).fontWeight(.semibold)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(value).fontWeight(.semibold)
        }
        .padding(.vertical, 12)
    }

    private func reviewBentoCard<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .symbolRenderingMode(.hierarchical)
                    .fixedSize()
                Text(title)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .allowsTightening(true)
                    .layoutPriority(1)
            }
            .font(.subheadline.bold())
            .foregroundStyle(.primary)
            content()
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 154, alignment: .topLeading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func reviewSectionHeader(_ title: String, trailingTitle: String?, action: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
                .font(.title2.bold())
            Spacer()
            if let trailingTitle {
                Button(action: action) {
                    HStack(spacing: 4) {
                        Text(trailingTitle)
                        Image(systemName: "chevron.right")
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 20)
    }

    // MARK: Derived values (built off main in `ReviewDataBuilder.derive`)

    private var reviewDistanceText: String {
        formatRankMileage(reviewDerived.totalDistance)
    }

    private var reviewMapRevision: Int {
        reviewDerived.mapRevision
    }

    private var reviewGeographyMetric: (icon: String, value: String, label: String) {
        let metric = reviewDerived.geographyMetric
        return (metric.icon, metric.value, metric.label)
    }

    private var reviewActivitySlices: [ReviewActivitySlice] {
        reviewDerived.activitySlices
    }

    private func reviewActivityVisitCount(for name: String) -> Int {
        reviewDerived.activityVisitCounts[name] ?? 0
    }

    private func reviewActivityWeekdayCounts(for name: String) -> [Int] {
        reviewDerived.activityWeekdayCounts[name] ?? Array(repeating: 0, count: 7)
    }

    private func reviewActivityHourlyCounts(for name: String) -> [Int] {
        reviewDerived.activityHourlyCounts[name] ?? Array(repeating: 0, count: 24)
    }

    private var reviewTransportSlices: [ReviewTransportSlice] {
        reviewDerived.transportSlices
    }

    private func reviewTransportWeekdayCounts(for typeID: String) -> [Int] {
        reviewDerived.transportWeekdayCounts[typeID] ?? Array(repeating: 0, count: 7)
    }

    private func reviewTransportHourlyCounts(for typeID: String) -> [Int] {
        reviewDerived.transportHourlyCounts[typeID] ?? Array(repeating: 0, count: 24)
    }

    private var reviewTopRegions: [(name: String, duration: TimeInterval)] {
        reviewDerived.topRegions
    }

    private var pastMemoryCandidate: ReviewMemoryCandidate? {
        reviewDerived.pastMemoryCandidate
    }

    private var reviewRangeWindow: ReviewRangeWindow {
        ReviewRangeWindow(range: appliedRange)
    }

    private var reviewRangeStart: Date {
        reviewRangeWindow.rangeStart
    }

    private var reviewRangeEnd: Date {
        reviewRangeWindow.rangeEnd
    }

    private var reviewActivityBuckets: [Int] {
        reviewDerived.activityBuckets
    }

    private var reviewMileageMetrics: ReviewMileageMetrics {
        reviewDerived.mileage
    }

    private var reviewRhythmActiveDayCount: Int {
        reviewDerived.rhythm.activeDayCount
    }

    private var reviewRhythmActiveDayRate: Int {
        reviewDerived.rhythm.activeDayRate
    }

    private var reviewRhythmWeeklyAverageText: String {
        reviewDerived.rhythm.weeklyAverageText
    }

    private var reviewRhythmActiveDayAverageText: String {
        reviewDerived.rhythm.activeDayAverageText
    }

    private var reviewRhythmPeakCount: Int {
        reviewDerived.rhythm.peakCount
    }

    private var reviewRhythmLongestStreak: Int {
        reviewDerived.rhythm.longestStreak
    }

    private var reviewRhythmWeekdaySymbols: [String] {
        ReviewDataBuilder.weekdaySymbols
    }

    private var reviewRhythmWeekdayAverages: [CGFloat] {
        reviewDerived.rhythm.weekdayAverages
    }

    private var reviewRhythmHourlyCounts: [Int] {
        reviewDerived.rhythm.hourlyCounts
    }

    private func reviewRhythmCompactNumber<T: BinaryFloatingPoint>(_ value: T) -> String {
        ReviewDataBuilder.compactNumber(value)
    }
    
    private func updateAiSummary() {
        guard isAiAssistantEnabled else { return }
        
        let key = appliedRange.rawValue
        if let cachedData = summaryCache[key],
           let text = cachedData["text"] as? String,
           let timestamp = cachedData["timestamp"] as? Double {
            
            let date = Date(timeIntervalSince1970: timestamp)
            let expiration = getExpirationFor(appliedRange)
            
            if Date().timeIntervalSince(date) < expiration {
                withAnimation {
                    self.aiSummary = text
                }
                return
            }
        }
        
        generateAiSummary()
    }
    
    private func getExpirationFor(_ range: StatisticsRange) -> TimeInterval {
        let hour: TimeInterval = 3600
        let day: TimeInterval = 24 * hour
        
        switch range {
        case .last7Days: return 1 * day
        case .last30Days: return 3 * day
        case .last90Days: return 7 * day
        case .lastYear, .customYear: return 30 * day
        }
    }
    
    private func generateAiSummary() {
        stopAiSummaryWork()
        let requestID = UUID()
        aiSummaryRequestID = requestID
        let rangeAtStart = appliedRange
        let footprintsInScope = filteredFootprints
        guard !footprintsInScope.isEmpty else {
            self.aiSummary = nil
            return
        }
        
        isGeneratingSummary = true
        self.aiSummary = nil
        
        // Prepare data for AI
        let rankData = getActivityRankData(for: .footprints).prefix(3).map { "\($0.name)(\($0.count)次)" }.joined(separator: ", ")
        let topPlacesCount = getTopLocations(delta: 0.01).prefix(3).count
        
        // 寻找主要地点分组
        let validPlaces = Dictionary(grouping: footprintsInScope) { fp -> String in
            let addr = fp.address ?? ""
            if addr.isEmpty { return "" }
            return addr.components(separatedBy: "市").last?.components(separatedBy: "区").last?.components(separatedBy: "县").last ?? addr
        }
        .filter { $0.key.count > 1 && !$0.key.contains("未知") }
        .sorted { $0.value.count > $1.value.count }
        .prefix(5)
        
        // 提取时间跨度描述
        let timeSpanText: String
        switch rangeAtStart {
        case .last7Days: timeSpanText = "最近7天"
        case .last30Days: timeSpanText = "最近1个月"
        case .last90Days: timeSpanText = "最近3个月"
        case .lastYear: timeSpanText = "过去一年"
        case .customYear(let year): timeSpanText = "\(year)年"
        }
        
        // 提前在主线程筛选出有自定义标签的重要地点足迹
        var userPlaceCounts: [String: Int] = [:]
        let summaryPlaces = fetchMainPlaces()
        for fp in footprintsInScope {
            if let pID = fp.placeID, let place = summaryPlaces.first(where: { $0.placeID == pID }), place.isUserDefined, !place.name.isEmpty {
                userPlaceCounts[place.name, default: 0] += 1
            }
        }
        
        aiSummaryTask = Task { @MainActor in
            // 构建需要反查的代表性足迹列表
            var repsToGeocode: [Footprint] = []
            
            // 1. 全局 55km 网格抽样 (保障广度)
            var uniqueGrids: [String: Footprint] = [:]
            for fp in footprintsInScope {
                let key = "\(Int(fp.latitude * 2))_\(Int(fp.longitude * 2))"
                if uniqueGrids[key] == nil {
                    uniqueGrids[key] = fp
                    repsToGeocode.append(fp)
                }
            }
            repsToGeocode = Array(repsToGeocode.prefix(8))
            
            // 2. Top 5 地点的代表足迹 (保障精度)
            for placeGroup in validPlaces {
                if let firstFp = placeGroup.value.first {
                    if !repsToGeocode.contains(where: { $0.footprintID == firstFp.footprintID }) {
                        repsToGeocode.append(firstFp)
                    }
                }
            }
            
            let geocoder = CLGeocoder()
            aiSummaryGeocoder = geocoder
            defer {
                if aiSummaryGeocoder === geocoder {
                    aiSummaryGeocoder = nil
                }
                if requestID == aiSummaryRequestID {
                    aiSummaryTask = nil
                }
            }
            var fpToCity: [UUID: String] = [:]
            var fpToCountry: [UUID: String] = [:]
            
            for fp in repsToGeocode {
                guard !Task.isCancelled else { return }
                let location = CLLocation(latitude: fp.latitude, longitude: fp.longitude)
                if let placemarks = try? await geocoder.reverseGeocodeLocation(location),
                   let placemark = placemarks.first {
                    var bestCityName: String? = nil
                    
                    // 1. 优先提取区县级 (如果是县级市、县等具备独立城市属性的区域)
                    if let subLocality = placemark.subLocality, 
                       (subLocality.hasSuffix("市") || subLocality.hasSuffix("县") || subLocality.hasSuffix("州") || subLocality.hasSuffix("旗") || subLocality.hasSuffix("盟")) {
                        bestCityName = subLocality
                    } 
                    // 2. 否则使用地级市
                    else if let locality = placemark.locality {
                        bestCityName = locality
                    } 
                    // 3. 直辖市兜底
                    else if let adminArea = placemark.administrativeArea {
                        bestCityName = adminArea
                    }
                    
                    if let city = bestCityName {
                        fpToCity[fp.footprintID] = city
                    }
                    if let country = placemark.country {
                        fpToCountry[fp.footprintID] = country
                    }
                }
            }
            
            // 提取所有涉及的城市和国家
            let citiesArray = Array(Set(fpToCity.values)).sorted()
            let countriesArray = Array(Set(fpToCountry.values)).sorted()
            
            let citiesStr = citiesArray.prefix(3).joined(separator: "、")
            let countriesStr = countriesArray.prefix(3).joined(separator: "、")
            let hasMultipleCities = citiesArray.count > 1
            let hasMultipleCountries = countriesArray.count > 1
            let isCrossRegion = hasMultipleCities || hasMultipleCountries
            
            var scopeContexts: [String] = []
            if hasMultipleCountries { scopeContexts.append("\(countriesStr)等多个国家") }
            else if !countriesArray.isEmpty && countriesArray.first != "中国" { scopeContexts.append("\(countriesStr)") }
            
            if hasMultipleCities { scopeContexts.append("\(citiesStr)等多个城市") }
            
            let scopeContext = scopeContexts.isEmpty ? "" : "- 范围：跨越了\(scopeContexts.joined(separator: "，"))\n"
            
            // 将地点按所属城市分组
            var cityToPlaces: [String: [String]] = [:]
            for placeGroup in validPlaces {
                let placeName = placeGroup.key
                let count = placeGroup.value.count
                let firstFp = placeGroup.value.first!
                
                let city = fpToCity[firstFp.footprintID] ?? "未知区域"
                cityToPlaces[city, default: []].append("\(placeName)(\(count)次)")
            }
            let topNamesGrouped = cityToPlaces.map { "\($0.key)的\($0.value.joined(separator: "、"))" }.joined(separator: "；")
            
            // 提取重要节点 (所有用户自定义标签)
            let topUserPlaces = userPlaceCounts
                .sorted { $0.value > $1.value }
                .prefix(5)
                .map { "\($0.key)(\($0.value)次)" }
            
            let importantContext = topUserPlaces.isEmpty ? "" : "- 核心节点：\(topUserPlaces.joined(separator: "，"))\n"
            
            // 增补更丰富的信息维度
            let totalDuration = footprintsInScope.reduce(0) { $0 + $1.duration }
            let durationHours = Int(totalDuration / 3600)
            let totalPhotos = footprintsInScope.reduce(0) { $0 + $1.photoAssetIDs.count }
            
            let timeRequirement = "3. **贴合时间跨度**：当前总结的时间跨度是“\(timeSpanText)”。绝不要笼统地说“最近”，请在文中自然地体现出这个时间范围（如“这\(timeSpanText)里”、“在整个\(timeSpanText)中”）。"
            
            let locationRequirement = isCrossRegion 
                ? "4. **提及跨地域与地标**：你的足迹跨越了不同的城市或国家，请在总结中自然地提及你的跨城/跨国节奏（如：\(citiesArray.first ?? "")），并带出一两个具体地点（如：\(validPlaces.first?.key ?? "某地")）。"
                : "4. **必须提及地名**：在总结中必须自然地提及一到两个你最常去的具体地点名称（如：\(validPlaces.first?.key ?? "某地")），增加专属感。"
                
            let visionRequirement = isCrossRegion
                ? "5. **视角与格局**：因为活动跨越了不同地域，请用相对广阔的视角，体现出你穿梭于不同城市间的活力、充实或奔波。"
                : "5. **视角与格局**：因为活动集中在一地，请用贴近生活的微观视角，体现出你在熟悉街区里深耕日常的规律与踏实。"
            
            let prompt = """
            请作为读者的老朋友，直接对着读者本人说话，帮他回顾这段时间的生活。
            
            数据事实：
            - 时间跨度：\(timeSpanText)
            \(scopeContext)\(importantContext)        - 密度：\(footprintsInScope.count)次记录，约\(durationHours)小时的停留
            - 偏好：主要活动包含\(rankData)
            - 广度：在\(topPlacesCount)个区域活动频繁（常去：\(topNamesGrouped)）
            - 影像：拍了\(totalPhotos)张照片
            
            撰写要求：
            1. **严格第二人称**：必须全程使用“你”、“你的”来称呼读者。绝对禁止在文中出现“我”、“我的”、“他”、“她”，不要写成日记口吻，必须是你在对朋友说话的口吻。
            2. **禁止堆砌数字**：严禁直接输出干巴巴的统计数字（如“50次”、“80小时”），要把数字转化为日常的描述（如“经常去”、“待了很久”、“拍了不少照片”）。不要用太文艺肉麻的词汇。
            \(timeRequirement)
            \(locationRequirement)
            \(visionRequirement)
            6. **多维推理**：如果照片多，可以说你喜欢记录；如果地点分散，说明你经常到处跑；如果集中，说明生活比较规律安稳。
            7. **语言与篇幅**：80字左右。语气必须平实、正常、干练，绝对不要过度抒情，绝对不要写得太文绉绉、不要肉麻。
            """
            guard !Task.isCancelled else { return }
            
            OpenAIService.shared.getCustomSummary(prompt: prompt) { summary in
                // 竞态过滤
                guard rangeAtStart == self.appliedRange,
                      requestID == self.aiSummaryRequestID else { return }
                
                withAnimation {
                    let finalized = summary ?? ""
                    self.aiSummary = finalized
                    
                    // Save to persistent cache
                    let cacheItem: [String: Any] = [
                        "text": finalized,
                        "timestamp": Date().timeIntervalSince1970
                    ]
                    self.summaryCache[rangeAtStart.rawValue] = cacheItem
                    UserDefaults.standard.set(self.summaryCache, forKey: "statistics_ai_cache")
                    
                    self.isGeneratingSummary = false
                }
            }
        }
    }

    private func stopAiSummaryWork() {
        aiSummaryRequestID = UUID()
        aiSummaryTask?.cancel()
        aiSummaryTask = nil
        aiSummaryGeocoder?.cancelGeocode()
        aiSummaryGeocoder = nil
        isGeneratingSummary = false
    }

    private func releaseReviewWorkingSet() {
        stopAiSummaryWork()
        stopGeographyBackfill()
        scheduledReviewRefreshTask?.cancel()
        scheduledReviewRefreshTask = nil
        reviewDerivedDataRequestID = UUID()
        reviewDerivedDataTask?.cancel()
        reviewDerivedDataTask = nil

        // HistoryStatisticsView is deliberately kept alive after its first tab
        // selection. Consequently, neither switching tabs nor backgrounding the
        // app destroys this state. Release the database-wide source arrays and
        // the second, decoded copy of every transport route while the UI cannot
        // be used; the existing refresh path restores them when needed.
        reviewSource = nil
        reviewDerived = ReviewDerivedData()
        rangeFootprints.removeAll(keepingCapacity: false)
        rangeFootprintsByID.removeAll(keepingCapacity: false)
        reviewTimelineItemsCache.removeAll(keepingCapacity: false)
        reviewMemoryCandidatesCache.removeAll(keepingCapacity: false)
        reviewSourceFingerprint = nil
        reviewRoutesReady = false
        reviewMapRegion = nil
        mapPosition = .automatic
        presentedSheet = nil
        pendingFavoriteFootprint = nil
        sharePayload = nil
        DFKMapSnapshotCache.shared.removeAllMemoryImages()
    }

    private func scheduleReviewRefresh(
        applying range: StatisticsRange? = nil,
        fetchesData: Bool = false
    ) {
        scheduledReviewRefreshTask?.cancel()
        scheduledReviewRefreshTask = Task { @MainActor in
            // Commit the tab or picker selection first. The data work starts on
            // a later main-actor turn so the interaction never waits for it.
            await Task.yield()
            try? await Task.sleep(nanoseconds: 16_000_000)
            guard !Task.isCancelled else { return }

            var sourceChanged = false
            if fetchesData || reviewSource == nil {
                // Fetch and fingerprint the whole source in a private context;
                // the main actor only compares the resulting fingerprint.
                let container = modelContext.container
                let source = await reviewDetached(priority: .userInitiated) {
                    ReviewDataBuilder.fetchSource(in: container)
                }
                guard !Task.isCancelled else { return }
                if let source, source.fingerprint != reviewSourceFingerprint {
                    reviewSourceFingerprint = source.fingerprint
                    reviewSource = source
                    sourceChanged = true
                }
            }
            if let range {
                appliedRange = range
            }
            // Re-entering the page must preserve the current result when the
            // source fingerprint is unchanged; only an explicit range change
            // or newly fetched source data may rebuild the review content.
            guard range != nil || sourceChanged else { return }

            // Let the freshly selected UI render before rebuilding maps,
            // memories and rankings for the applied range.
            await Task.yield()
            guard !Task.isCancelled else { return }

            stopGeographyBackfill()
            hasManuallySelectedFrequentPlaceRankScope = false
            startReviewDerivedDataRefresh()
        }
    }

    private func startReviewDerivedDataRefresh() {
        reviewDerivedDataTask?.cancel()
        let requestID = UUID()
        reviewDerivedDataRequestID = requestID
        let rangeAtStart = appliedRange
        guard let source = reviewSource else { return }

        let window = ReviewRangeWindow(range: rangeAtStart)
        let config = ReviewConfigSnapshot.current()
        let container = modelContext.container
        let tripRangeStart = window.rangeStart
        let tripRangeEnd = min(window.rangeEnd, window.now)

        // Never leave a previous range visible while its replacement is being
        // built. Rankings, rhythm, routes and memories are all derived off
        // main and published together once the request is proven current.
        reviewTimelineItemsCache = []
        reviewRoutesReady = false

        reviewDerivedDataTask = Task { @MainActor in
            let cachedMemories = await reviewDetached(priority: .userInitiated) {
                ReviewDataBuilder.loadCachedMemories(for: rangeAtStart)
            }
            guard !Task.isCancelled,
                  requestID == reviewDerivedDataRequestID,
                  rangeAtStart == appliedRange else { return }
            reviewMemoryCandidatesCache = cachedMemories

            let tripDays = await TripScanManager.shared.tripActivityDays(from: tripRangeStart, through: tripRangeEnd)
            guard !Task.isCancelled,
                  requestID == reviewDerivedDataRequestID,
                  rangeAtStart == appliedRange else { return }
            reviewTripActivityDays = tripDays

            let result = await reviewDetached(priority: .userInitiated) {
                ReviewDataBuilder.derive(
                    source: source,
                    window: window,
                    tripActivityDays: tripDays,
                    config: config,
                    container: container
                )
            }
            guard !Task.isCancelled,
                  requestID == reviewDerivedDataRequestID,
                  rangeAtStart == appliedRange else { return }

            // Map items, selections and sharing need this context's models:
            // one range query, matched to the derived data by ID.
            let models = fetchRangeFootprintModels(in: window)
            let modelsByID = Dictionary(models.map { ($0.footprintID, $0) }, uniquingKeysWith: { first, _ in first })
            reviewDerived = result.derived
            rangeFootprints = models
            rangeFootprintsByID = modelsByID
            updateDefaultFrequentPlaceRankScope()
            if let bounds = result.bounds {
                let region = mapRegion(for: bounds)
                reviewMapRegion = region
                mapPosition = .region(region)
            }

            // Memories only appear on the page; sheets skip building them.
            if sheet == nil {
                let history = source.footprints
                let derived = result.derived
                let candidates = await reviewDetached(priority: .utility) {
                    await ReviewDataBuilder.buildMemoryCandidates(history: history, derived: derived, config: config)
                }
                guard !Task.isCancelled,
                      requestID == reviewDerivedDataRequestID,
                      rangeAtStart == appliedRange else { return }
                reviewMemoryCandidatesCache = candidates
                let revision = derived.mapRevision
                Task.detached(priority: .utility) {
                    ReviewDataBuilder.saveCachedMemories(candidates, revision: revision, range: rangeAtStart)
                }
            }
            reviewTimelineItemsCache = result.timelineSlots.compactMap { slot -> TimelineItem? in
                switch slot {
                case .footprint(let id):
                    return modelsByID[id].map(TimelineItem.footprint)
                case .transport(let index):
                    return .transport(result.transports[index])
                }
            }
            reviewRoutesReady = true
        }
    }

    private func fetchRangeFootprintModels(in window: ReviewRangeWindow) -> [Footprint] {
        let lowerBound = window.lowerBound
        let descriptor: FetchDescriptor<Footprint>
        if let upperBound = window.upperBound {
            descriptor = FetchDescriptor<Footprint>(
                predicate: #Predicate<Footprint> {
                    $0.statusValue != "ignored" && $0.startTime >= lowerBound && $0.startTime < upperBound
                },
                sortBy: [SortDescriptor(\Footprint.startTime, order: .reverse)]
            )
        } else {
            descriptor = FetchDescriptor<Footprint>(
                predicate: #Predicate<Footprint> {
                    $0.statusValue != "ignored" && $0.startTime >= lowerBound
                },
                sortBy: [SortDescriptor(\Footprint.startTime, order: .reverse)]
            )
        }
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    /// Range transport models, fetched only for sharing (the map snapshot
    /// loader takes models).
    private func fetchRangeTransportRecords() -> [TransportRecord] {
        let window = reviewRangeWindow
        let lowerBound = window.lowerBound
        let descriptor: FetchDescriptor<TransportRecord>
        if let upperBound = window.upperBound {
            descriptor = FetchDescriptor<TransportRecord>(
                predicate: #Predicate<TransportRecord> {
                    $0.statusRaw == "active" && $0.startTime >= lowerBound && $0.startTime < upperBound
                }
            )
        } else {
            descriptor = FetchDescriptor<TransportRecord>(
                predicate: #Predicate<TransportRecord> {
                    $0.statusRaw == "active" && $0.startTime >= lowerBound
                }
            )
        }
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    private func fetchMainActivityTypes() -> [ActivityType] {
        let descriptor = FetchDescriptor<ActivityType>(
            sortBy: [SortDescriptor(\ActivityType.sortOrder)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    private func fetchMainPlaces() -> [Place] {
        (try? modelContext.fetch(FetchDescriptor<Place>())) ?? []
    }

    private func mapRegion(for bounds: ReviewMapBounds) -> MKCoordinateRegion {
        let center = CLLocationCoordinate2D(
            latitude: (bounds.minimumLatitude + bounds.maximumLatitude) / 2,
            longitude: (bounds.minimumLongitude + bounds.maximumLongitude) / 2
        )
        let latitudeDelta = max(0.015, (bounds.maximumLatitude - bounds.minimumLatitude) * 1.6)
        let longitudeDelta = max(0.015, (bounds.maximumLongitude - bounds.minimumLongitude) * 1.6)
        return MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: latitudeDelta, longitudeDelta: longitudeDelta)
        )
    }

    private var rangePicker: some View {
        ReviewRangePicker(selection: $selectedRange, years: availableYears, activeYear: activeYearForSegment)
    }

    // MARK: - Frequent Places Section
    private var frequentPlacesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                sectionHeader("常去地点", icon: "mappin.and.ellipse", horizontalPadding: 0)
                if isResolvingGeographies {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("正在补齐国家和城市")
                }

                Picker("地点排行维度", selection: Binding(
                    get: { frequentPlaceRankScope },
                    set: { scope in
                        frequentPlaceRankScope = scope
                        hasManuallySelectedFrequentPlaceRankScope = true
                    }
                )) {
                    ForEach(FrequentPlaceRankScope.allCases) { scope in
                        Text(scope.rawValue).tag(scope)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .frame(width: 172)
            }
            .padding(.horizontal, 20)
            
            let data = getFrequentPlacesData()
            
            if data.isEmpty {
                placeholderView("暂无常去地点数据")
            } else {
                VStack(spacing: 0) {
                    ForEach(data.indices, id: \.self) { index in
                        let item = data[index]
                        Button {
                            openReviewRegionItem(item, scope: frequentPlaceRankScope)
                        } label: {
                            HStack(spacing: 12) {
                                Text("\(index + 1)")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(index < 3 ? .dfkAccent : .secondary.opacity(0.5))
                                    .frame(width: 24, alignment: .leading)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.name)
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundColor(.primary)
                                        .lineLimit(1)

                                    if !item.address.isEmpty && item.address != item.name {
                                        Text(item.address)
                                            .font(.system(size: 12))
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    }
                                }

                                Spacer()

                                VStack(alignment: .trailing, spacing: 4) {
                                    Text(formatRankDuration(item.duration))
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundColor(.dfkAccent)

                                    Text("\(item.count)个足迹")
                                        .font(.system(size: 12))
                                        .foregroundColor(.secondary)
                                }

                                Image(systemName: "chevron.right")
                                    .font(.caption.bold())
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 12)
                        
                        if index < data.count - 1 {
                            Divider()
                                .padding(.leading, 36)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.05))
                .cornerRadius(24)
                .padding(.horizontal, 16)
            }
        }
    }
    
    // MARK: - Activity Rank Section
    private var activityRankSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader("活动偏好", icon: "medal.fill")
            
            let data = getActivityRankData(for: .footprints)
            
            if data.isEmpty {
                placeholderView("暂无活动数据")
            } else {
                preferenceRankList(
                    items: data,
                    barValue: { $0.totalDuration },
                    compressesLongTail: true,
                    valueText: { formatRankDuration($0.totalDuration) }
                )
            }
        }
    }

    private var transportRankSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader("交通偏好", icon: "car.fill")

            let data = getActivityRankData(for: .transport)

            if data.isEmpty {
                placeholderView("暂无交通数据")
            } else {
                preferenceRankList(
                    items: data,
                    barValue: { Double($0.count) },
                    compressesLongTail: false,
                    valueText: { formatRankMileage($0.totalDistance) }
                )
            }
        }
    }

    private func preferenceRankList(
        items: [RankItem],
        barValue: @escaping (RankItem) -> Double,
        compressesLongTail: Bool,
        valueText: @escaping (RankItem) -> String
    ) -> some View {
        let maxBarValue = max(1, items.map(barValue).max() ?? 1)
        return VStack(spacing: 16) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: item.icon)
                            .font(.system(size: 16))
                            .foregroundColor(item.color)
                            .frame(width: 22)
                        Text(item.name)
                            .font(.system(size: 15, weight: .medium))
                    }
                    .frame(width: 80, alignment: .leading)

                    GeometryReader { geo in
                        let value = max(0, barValue(item))
                        let fraction = preferenceBarFraction(
                            value: value,
                            maxValue: maxBarValue,
                            compressesLongTail: compressesLongTail
                        )
                        let width = geo.size.width * CGFloat(fraction)
                        RoundedRectangle(cornerRadius: 10)
                            .fill(item.color.gradient)
                            .frame(width: fraction > 0 ? max(12, width) : 0)
                    }
                    .frame(height: 12)

                    Text(valueText(item))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 62, alignment: .trailing)
                }
                .padding(.horizontal, 20)
            }
        }
        .padding(.vertical, 24)
        .background(Color.white.opacity(0.05))
        .cornerRadius(24)
        .padding(.horizontal, 16)
    }

    private func preferenceBarFraction(value: Double, maxValue: Double, compressesLongTail: Bool) -> Double {
        guard value > 0, maxValue > 0 else { return 0 }
        guard compressesLongTail else { return value / maxValue }

        // Use one hour as the reference interval so a long "在家" record does
        // not visually erase shorter, meaningful activities.
        let referenceDuration: Double = 3_600
        return log1p(value / referenceDuration) / log1p(maxValue / referenceDuration)
    }
    
    private func sectionHeader(_ title: String, icon: String, horizontalPadding: CGFloat = 20) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(.dfkAccent)
                .font(.system(size: 14, weight: .bold))
            Text(title)
                .font(.system(size: 16, weight: .bold))
            Spacer()
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.top, 8)
    }
    
    private func placeholderView(_ text: String) -> some View {
        HStack {
            Spacer()
            VStack(spacing: 12) {
                Image(systemName: "chart.pie")
                    .font(.system(size: 30))
                    .foregroundColor(.gray.opacity(0.3))
                Text(text)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary.opacity(0.5))
            }
            .padding(.vertical, 40)
            Spacer()
        }
    }
    
    // MARK: - Data Helpers
    
    fileprivate typealias FrequentPlaceItem = ReviewFrequentPlaceItem
    
    private func getFrequentPlacesData() -> [FrequentPlaceItem] {
        getFrequentPlacesData(for: frequentPlaceRankScope)
    }

    private func getFrequentPlacesData(for scope: FrequentPlaceRankScope) -> [FrequentPlaceItem] {
        reviewDerived.frequentPlaces[scope] ?? []
    }

    private func updateDefaultFrequentPlaceRankScope() {
        guard !hasManuallySelectedFrequentPlaceRankScope else { return }
        frequentPlaceRankScope = reviewDerived.defaultFrequentPlaceRankScope
    }

    struct LocationPoint {
        let hash: String
        let coord: CLLocationCoordinate2D
        let count: Int
    }
    
    private func getTopLocations(delta: Double) -> [LocationPoint] {
        var groups: [String: (Double, Double, Int)] = [:]
        
        // 根据地图缩放程度（delta）动态调整聚合精度
        // 越缩小（delta 越大），聚合范围越广
        let precision: Int
        if delta < 0.05 { precision = 3 }      // 约 110m 精度
        else if delta < 0.5 { precision = 2 }   // 约 1.1km 精度
        else if delta < 5.0 { precision = 1 }   // 约 11km 精度
        else { precision = 0 }                  // 约 110km 精度
        
        let factor = pow(10.0, Double(precision))
        
        for fp in filteredFootprints {
            // 使用舍入计算网格点，而非字符串格式化，性能更优
            let lat = (fp.latitude * factor).rounded() / factor
            let lon = (fp.longitude * factor).rounded() / factor
            let key = "\(lat),\(lon)"
            
            if let existing = groups[key] {
                groups[key] = (lat, lon, existing.2 + 1)
            } else {
                groups[key] = (lat, lon, 1)
            }
        }
        
        return groups.map { LocationPoint(hash: $0.key, coord: CLLocationCoordinate2D(latitude: $0.value.0, longitude: $0.value.1), count: $0.value.2) }
            .sorted { 
                if $0.count == $1.count {
                    return $0.hash < $1.hash
                }
                return $0.count > $1.count 
            }
            .prefix(200) // 聚合后点数减少，可以适当放宽显示上限
            .map { $0 }
    }
    
    
    struct RankItem: Identifiable {
        let id = UUID()
        let name: String
        let count: Int
        let totalDuration: TimeInterval
        let totalDistance: Double
        let color: Color
        let icon: String
    }
    
    private func getActivityRankData(for scope: ActivityRankScope) -> [RankItem] {
        var totals: [String: (count: Int, duration: TimeInterval, distance: Double)] = [:]
        let activityTypes = fetchMainActivityTypes()
        
        if scope == .footprints {
            for fp in filteredFootprints {
                if let type = fp.getActivityType(from: activityTypes)?.name {
                    var total = totals[type, default: (0, 0, 0)]
                    total.count += 1
                    total.duration += fp.duration
                    totals[type] = total
                }
            }
        } else {
            for transport in reviewDerived.rangeTransports {
                if let type = TransportType(rawValue: transport.manualTypeRaw ?? transport.typeRaw) {
                    var total = totals[type.localizedName, default: (0, 0, 0)]
                    total.count += 1
                    total.distance += transport.distance
                    totals[type.localizedName] = total
                }
            }
        }
        
        return totals.map { name, total in
            // 优先匹配预定义活动
            if let activity = activityTypes.first(where: { $0.name == name }) {
                return RankItem(name: name, count: total.count, totalDuration: total.duration, totalDistance: total.distance, color: activity.color, icon: activity.icon)
            }
            
            // 匹配交通工具类型
            if let transportType = TransportType.allCases.first(where: { $0.localizedName == name }) {
                return RankItem(name: name, count: total.count, totalDuration: total.duration, totalDistance: total.distance, color: .dfkAccent, icon: transportType.sfSymbol)
            }
            
            return RankItem(name: name, count: total.count, totalDuration: total.duration, totalDistance: total.distance, color: .gray, icon: "mappin.and.ellipse")
        }.sorted {
            if scope == .footprints, $0.totalDuration != $1.totalDuration {
                return $0.totalDuration > $1.totalDuration
            }
            if $0.count == $1.count {
                return $0.name < $1.name
            }
            return $0.count > $1.count 
        }
    }

    private func formatRankDuration(_ duration: TimeInterval) -> String {
        ReviewDataBuilder.formatRankDuration(duration)
    }

    private func formatRankMileage(_ distance: Double) -> String {
        ReviewDataBuilder.formatRankMileage(distance)
    }
    
    private func resolveRankingGeographies() {
        let pending = filteredFootprints.filter {
            ($0.countryCode == nil || $0.countryName == nil || $0.cityName == nil)
                && geographicBackfillAttempts[$0.footprintID, default: 0] < 3
        }
        guard !pending.isEmpty, !isResolvingGeographies else { return }
        isResolvingGeographies = true
        let requestID = UUID()
        geographyBackfillRequestID = requestID
        let candidates = pending.map {
            StatisticsGeographyCandidate(
                footprintID: $0.footprintID,
                latitude: $0.latitude,
                longitude: $0.longitude,
                address: $0.address
            )
        }
        for candidate in candidates {
            geographicBackfillAttempts[candidate.footprintID, default: 0] += 1
        }

        let resolver = StatisticsGeographyResolver()
        geographyBackfillResolver = resolver
        geographyBackfillTask = Task.detached(priority: .utility) {
            var pendingResults: [StatisticsGeographyResult] = []
            for candidate in candidates {
                guard !Task.isCancelled else { break }
                if let result = await resolver.resolve(candidate) {
                    pendingResults.append(result)
                }
                if pendingResults.count >= 12 {
                    await applyRankingGeographies(pendingResults, requestID: requestID)
                    pendingResults.removeAll(keepingCapacity: true)
                }
                // Keep public reverse-geocoding requests serial and paced.
                try? await Task.sleep(for: .milliseconds(350))
            }
            if !pendingResults.isEmpty, !Task.isCancelled {
                await applyRankingGeographies(pendingResults, requestID: requestID)
            }
            await finishRankingGeographyBackfill(requestID: requestID)
        }
    }

    @MainActor
    private func applyRankingGeographies(_ results: [StatisticsGeographyResult], requestID: UUID) {
        guard requestID == geographyBackfillRequestID else { return }
        let resultsByID = Dictionary(uniqueKeysWithValues: results.map { ($0.footprintID, $0) })
        var changed = false
        for footprint in rangeFootprints {
            guard let result = resultsByID[footprint.footprintID] else { continue }
            footprint.countryCode = result.countryCode
            footprint.countryName = result.countryName
            footprint.cityName = result.cityName
            changed = true
        }
        guard changed else { return }
        try? modelContext.save()
        // Rankings are derived off main from the stored source; the next
        // source refresh picks these saved values up.
        rangeFootprints = Array(rangeFootprints)
        updateDefaultFrequentPlaceRankScope()
    }

    @MainActor
    private func finishRankingGeographyBackfill(requestID: UUID) {
        guard requestID == geographyBackfillRequestID else { return }
        geographyBackfillResolver = nil
        isResolvingGeographies = false
        geographyBackfillTask = nil
    }

    private func stopGeographyBackfill() {
        geographyBackfillRequestID = UUID()
        geographyBackfillTask?.cancel()
        geographyBackfillTask = nil
        if let resolver = geographyBackfillResolver {
            Task { await resolver.cancel() }
        }
        geographyBackfillResolver = nil
        isResolvingGeographies = false
    }

    private func requestMissingRankingGeographies() {
        guard filteredFootprints.contains(where: {
            ($0.countryCode == nil || $0.countryName == nil || $0.cityName == nil)
                && geographicBackfillAttempts[$0.footprintID, default: 0] < 3
        }) else {
            return
        }
        DispatchQueue.main.async {
            self.resolveRankingGeographies()
        }
    }
    
}

private extension View {
    func reviewDetailListStyle() -> some View {
        padding(.horizontal, 16)
            .background(
                Color(uiColor: .secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: 22, style: .continuous)
            )
    }
}

private struct ReviewPlaceView: View {
    @Environment(\.dismiss) private var dismiss
    let selection: ReviewPlaceSelection
    let rangeControl: ReviewRangeControl?
    @State private var mapPosition: MapCameraPosition
    @State private var selectedPhotoID: IdentifiableString?
    @State private var showsAllPhotos = false
    private let photoPreviewCount = AppConfig.shared.reviewPlacePhotoPreviewCount

    init(selection: ReviewPlaceSelection, rangeControl: ReviewRangeControl? = nil) {
        self.selection = selection
        self.rangeControl = rangeControl
        if let coordinate = Self.representativeCoordinate(in: selection.visits) {
            _mapPosition = State(initialValue: .region(MKCoordinateRegion(
                center: coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.012, longitudeDelta: 0.012)
            )))
        } else {
            _mapPosition = State(initialValue: .automatic)
        }
    }

    // Computed off main with the selection (`ReviewDataBuilder.placeGroup`).
    private var totalDuration: TimeInterval {
        selection.stats.totalDuration
    }

    private var geographyText: String? {
        selection.stats.geographyText
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                // Keep the title geometry alive after it scrolls offscreen;
                // LazyVStack recycles it and resets the compact-title state.
                VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(selection.title)
                        .font(.largeTitle.bold())
                    if let geographyText {
                        Text(geographyText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Text(selection.rangeText)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.dfkAccent)
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)

                HStack(spacing: 10) {
                    placeMetric(value: "\(selection.visits.count)", label: "次到访")
                    placeMetric(value: placeDurationText(totalDuration), label: "累计停留")
                    placeMetric(value: "\(selection.photoAssetIDs.count)", label: "张照片")
                }
                .padding(.horizontal, 18)

                if let coordinate = Self.representativeCoordinate(in: selection.visits) {
                    Map(position: $mapPosition, interactionModes: []) {
                        Marker(selection.title, coordinate: coordinate)
                            .tint(Color.dfkAccent)
                    }
                    .mapStyle(.standard)
                    .frame(height: 170)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .padding(.horizontal, 18)
                }

                if !selection.photoAssetIDs.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("这里的照片")
                            .font(.title2.bold())
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3),
                            spacing: 8
                        ) {
                            ForEach(showsAllPhotos ? selection.photoAssetIDs : Array(selection.photoAssetIDs.prefix(photoPreviewCount)), id: \.self) { assetID in
                                AssetThumbnailView(
                                    assetID: assetID,
                                    showsTime: false,
                                    showsDate: true,
                                    targetSize: CGSize(width: 300, height: 300)
                                )
                                .aspectRatio(1, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selectedPhotoID = IdentifiableString(value: assetID)
                                }
                            }
                        }
                        if !showsAllPhotos, selection.photoAssetIDs.count > photoPreviewCount {
                            Button {
                                withAnimation { showsAllPhotos = true }
                            } label: {
                                Text("查看更多（共\(selection.photoAssetIDs.count)张）")
                                    .font(.subheadline.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .tint(Color.dfkAccent)
                        }
                    }
                    .padding(.horizontal, 18)
                }

                placeVisualStatistics
                    .padding(.horizontal, 18)

                VStack(alignment: .leading, spacing: 12) {
                    Text("到访记录")
                        .font(.title2.bold())
                    ForEach(selection.visits, id: \.footprintID) { footprint in
                        visitRow(footprint)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 28)
                }
            }
            .background(Color.dfkBackground)
            .navigationTitle("\(selection.rangeText) · \(selection.title)")
            .navigationBarTitleDisplayMode(.inline)
            .reviewRangeBar(rangeControl)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").dfkToolbarDismissIcon()
                    }
                }
            }
        }
        .fullScreenCover(item: $selectedPhotoID) { selectedPhoto in
            let index = selection.photoAssetIDs.firstIndex(of: selectedPhoto.value) ?? 0
            PhotoFullscreenView(assetIDs: selection.photoAssetIDs, currentIndex: index)
        }
    }

    private func placeMetric(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.title3.bold())
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var placeVisualStatistics: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("到访规律")
                .font(.title2.bold())

            if !selection.stats.activitySlices.isEmpty {
                placeActivityChart
            }
            placeWeekdayChart
            placeHourlyChart
            placeDurationTrendChart
        }
    }

    private var placeWeekdayChart: some View {
        let values = placeWeekdayVisitCounts
        let maximum = max(1, values.max() ?? 1)
        return VStack(alignment: .leading, spacing: 14) {
            Label("星期偏好", systemImage: "calendar")
                .font(.headline)

            HStack(alignment: .bottom, spacing: 8) {
                ForEach(values.indices, id: \.self) { index in
                    VStack(spacing: 6) {
                        Text("\(values[index])")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Capsule()
                            .fill(values[index] == maximum ? Color.dfkAccent : Color.dfkAccent.opacity(values[index] == 0 ? 0.10 : 0.38))
                            .frame(height: max(7, 72 * CGFloat(values[index]) / CGFloat(maximum)))
                        Text(placeWeekdaySymbols[index])
                            .font(.caption.weight(.medium))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 112, alignment: .bottom)
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var placeActivityChart: some View {
        let counts = selection.stats.activityVisitCounts
        let values = selection.stats.activitySlices.map { slice in
            ReviewActivityBarValue(
                slice: slice,
                value: slice.duration,
                valueText: "\(counts[slice.name] ?? 0)次 · \(placeDurationText(slice.duration))"
            )
        }
        return ReviewActivityHorizontalBars(title: "活动类型", icon: "square.grid.2x2", values: values)
    }

    private var placeHourlyChart: some View {
        let values = placeHourlyVisitCounts
        return VStack(alignment: .leading, spacing: 14) {
            Label("到访时刻", systemImage: "clock")
                .font(.headline)

            placeBarCanvas(values: values.map { Double($0) })
                .frame(height: 92)

            HStack {
                Text("0时")
                Spacer()
                Text("6时")
                Spacer()
                Text("12时")
                Spacer()
                Text("18时")
                Spacer()
                Text("24时")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var placeDurationTrendChart: some View {
        let values = selection.stats.durationTrend
        let average = selection.stats.averageDuration
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Label("停留时长变化", systemImage: "chart.bar.fill")
                    .font(.headline)
                Spacer()
                Text("平均 \(placeDurationText(average))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            placeBarCanvas(values: values)
                .frame(height: 104)

            if let first = selection.stats.firstVisitDate, let last = selection.stats.lastVisitDate {
                HStack {
                    Text(first.formatted(.dateTime.year().month().day()))
                    Spacer()
                    Text(last.formatted(.dateTime.year().month().day()))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func placeBarCanvas(values: [Double]) -> some View {
        Canvas { context, size in
            guard !values.isEmpty, size.width > 0, size.height > 0 else { return }
            let maximum = max(1, values.max() ?? 1)
            let spacing: CGFloat = values.count > 60 ? 1 : 2.5
            let barWidth = max(1, (size.width - spacing * CGFloat(values.count - 1)) / CGFloat(values.count))

            for index in values.indices {
                let height = values[index] == 0 ? 4 : max(6, size.height * CGFloat(values[index] / maximum))
                let rect = CGRect(
                    x: CGFloat(index) * (barWidth + spacing),
                    y: size.height - height,
                    width: barWidth,
                    height: height
                )
                context.fill(
                    Path(roundedRect: rect, cornerRadius: min(barWidth / 2, 4)),
                    with: .color(Color.dfkAccent.opacity(values[index] == maximum ? 1 : (values[index] == 0 ? 0.10 : 0.38)))
                )
            }
        }
    }

    private var placeWeekdaySymbols: [String] {
        ReviewDataBuilder.weekdaySymbols
    }

    private var placeWeekdayVisitCounts: [Int] {
        selection.stats.weekdayCounts
    }

    private var placeHourlyVisitCounts: [Int] {
        selection.stats.hourlyCounts
    }

    private func visitRow(_ footprint: Footprint) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(footprint.startTime.formatted(.dateTime.month().day()))
                    .font(.headline.bold())
                    .lineLimit(1)
                Spacer(minLength: 12)
                Text("\(footprint.startTime.formatted(.dateTime.hour().minute()))–\(footprint.endTime.formatted(.dateTime.hour().minute()))")
                    .font(.headline)
                    .monospacedDigit()
                    .lineLimit(1)
            }

            HStack(spacing: 12) {
                if let activity = selection.stats.visitActivities[footprint.footprintID] {
                    Label(activity.name, systemImage: activity.icon)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(activity.color)
                        .lineLimit(1)
                }
                Text("停留 \(placeDurationText(footprint.duration))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                if !footprint.photoAssetIDs.isEmpty {
                    Label("\(footprint.photoAssetIDs.count)张照片", systemImage: "photo")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            if let reason = footprint.reason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty {
                Text(reason)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func placeDurationText(_ duration: TimeInterval) -> String {
        let minutes = max(1, Int(duration / 60))
        if minutes < 60 { return "\(minutes)分钟" }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        if hours < 24 {
            return remainingMinutes == 0 ? "\(hours)小时" : "\(hours)小时\(remainingMinutes)分"
        }
        let days = hours / 24
        let remainingHours = hours % 24
        return remainingHours == 0 ? "\(days)天" : "\(days)天\(remainingHours)小时"
    }

    private static func representativeCoordinate(in visits: [Footprint]) -> CLLocationCoordinate2D? {
        visits.lazy
            .map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
            .first { CLLocationCoordinate2DIsValid($0) && !($0.latitude == 0 && $0.longitude == 0) }
    }
}

struct FullReviewMapView: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let rangeText: String
    let timelineItems: [TimelineItem]
    /// Background snapshots of the range footprints, keyed by ID, so place
    /// grouping on taps runs off main.
    private let footprintSnapshots: [UUID: ReviewFootprintSnapshot]
    let initialRegion: MKCoordinateRegion?
    let initialPosition: MapCameraPosition
    private let rangeControl: ReviewRangeControl?
    /// The host presents tapped places, each sheet with its own range.
    private let onOpenPlaces: (ReviewPlaceQuery, [ReviewPlaceSelection]) -> Void
    
    @State private var position: MapCameraPosition
    
    fileprivate init(
        title: String,
        rangeText: String,
        timelineItems: [TimelineItem],
        footprintSnapshots: [UUID: ReviewFootprintSnapshot],
        initialRegion: MKCoordinateRegion?,
        initialPosition: MapCameraPosition,
        rangeControl: ReviewRangeControl?,
        onOpenPlaces: @escaping (ReviewPlaceQuery, [ReviewPlaceSelection]) -> Void
    ) {
        self.title = title
        self.rangeText = rangeText
        self.timelineItems = timelineItems
        self.footprintSnapshots = footprintSnapshots
        self.initialRegion = initialRegion
        self.initialPosition = initialPosition
        self.rangeControl = rangeControl
        self.onOpenPlaces = onOpenPlaces
        self._position = State(initialValue: initialPosition)
    }
    
    var body: some View {
        NavigationStack {
            DFKMapView(
                cameraPosition: $position,
                isInteractive: true,
                showsUserLocation: true,
                timelineItems: timelineItems,
                prefersActivityIcons: false,
                condensesTransportOverview: true,
                clustersPlacesByMapScale: true,
                placeClusterRegion: initialRegion,
                showsUserDefinedPlaceRadii: false,
                onTimelineItemTap: { item in
                    guard case .footprint(let footprint) = item else { return }
                    presentPlace(footprint: footprint)
                },
                onAggregatedFootprintTap: { aggregated in
                    presentPlaces(from: aggregated.footprints, clusterID: aggregated.id)
                },
                onResetCamera: {
                    withAnimation { position = initialPosition }
                }
            )
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .reviewRangeBar(rangeControl)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark").dfkToolbarDismissIcon()
                    }
                }
            }
        }
    }

    /// Groups the tapped footprints by place off main, then presents them.
    private func presentPlaces(from footprints: [Footprint], clusterID: String) {
        let snapshots = footprints.compactMap { footprintSnapshots[$0.footprintID] }
        let footprintsByID = Dictionary(footprints.map { ($0.footprintID, $0) }, uniquingKeysWith: { first, _ in first })
        let rangeText = self.rangeText
        Task { @MainActor in
            let groups = await reviewDetached(priority: .userInitiated) {
                ReviewDataBuilder.placeGroups(from: snapshots, titleKeyPath: \.mapTitle)
            }
            let places = groups.compactMap {
                ReviewPlaceSelection(group: $0, rangeText: rangeText, footprintsByID: footprintsByID)
            }
            guard let first = places.first else { return }
            onOpenPlaces(
                ReviewPlaceQuery(
                    id: clusterID,
                    source: .placeKeys(places.map(\.id)),
                    title: places.count > 1 ? "附近地点" : first.title,
                    usesMapTitle: true,
                    presentsList: places.count > 1
                ),
                places
            )
        }
    }

    private func presentPlace(footprint: Footprint) {
        guard let snapshot = footprintSnapshots[footprint.footprintID] else { return }
        let footprintsByID = [footprint.footprintID: footprint]
        let rangeText = self.rangeText
        let placeKey = snapshot.placeKey
        Task { @MainActor in
            let group = await reviewDetached(priority: .userInitiated) {
                ReviewDataBuilder.placeGroup(id: placeKey, visits: [snapshot], titleKeyPath: \.mapTitle, resolvedPhotoAssetIDs: nil)
            }
            guard let place = group.flatMap({
                ReviewPlaceSelection(group: $0, rangeText: rangeText, footprintsByID: footprintsByID)
            }) else { return }
            onOpenPlaces(
                ReviewPlaceQuery(id: placeKey, source: .placeKeys([placeKey]), title: place.title, usesMapTitle: true, presentsList: false),
                [place]
            )
        }
    }
}

private struct ReviewPlaceListSheet: View {
    @Environment(\.dismiss) private var dismiss
    let selection: ReviewPlaceListSelection
    let rangeControl: ReviewRangeControl?
    /// The host presents the place, with its own range.
    let onSelectPlace: (ReviewPlaceSelection) -> Void

    var body: some View {
        NavigationStack {
            List(selection.places) { place in
                Button {
                    onSelectPlace(place)
                } label: {
                    ReviewPlaceListRow(place: place)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("\(selection.rangeText) · \(selection.title)")
            .navigationBarTitleDisplayMode(.inline)
            .reviewRangeBar(rangeControl)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").dfkToolbarDismissIcon()
                    }
                }
            }
        }
    }

}

private struct ReviewPlaceListRow: View {
    let place: ReviewPlaceSelection

    var body: some View {
        HStack(spacing: 12) {
            if let photoAssetID = place.photoAssetIDs.first {
                ContinuousTimelinePhotoThumbnail(
                    assetIDs: [photoAssetID],
                    targetSide: 120,
                    fillsAvailableSpace: true,
                    usesHighQualityThumbnail: true
                )
                .scaledToFill()
                .frame(width: 54, height: 54)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                Image(systemName: "mappin.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Color.dfkAccent)
                    .frame(width: 54, height: 54)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(place.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                HStack(spacing: 10) {
                    Text("\(place.visits.count)次到访")
                    if !place.photoAssetIDs.isEmpty {
                        Text("\(place.photoAssetIDs.count)张照片")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.bold())
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

struct HistoryStatisticsView_Previews: PreviewProvider {
    static var previews: some View {
        HistoryStatisticsView()
    }
}
