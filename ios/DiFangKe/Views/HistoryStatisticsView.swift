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
    let footprint: Footprint?
    let title: String
    let evidence: String
    let reason: String
    let systemImage: String
    let photoAssetIDs: [String]
    let score: Double
}

private struct ReviewMemoryPhotoCarousel: View {
    let assetIDs: [String]
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedIndex = 0

    init(assetIDs: [String]) {
        self.assetIDs = PhotoService.shared.assetIDsOldestFirst(assetIDs)
    }

    var body: some View {
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
}

private struct ReviewMapPlaceCluster: Identifiable {
    let id: String
    let places: [ReviewPlaceSelection]
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

struct HistoryStatisticsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    var onFootprintSelected: ((Footprint) -> Void)? = nil
    var onDateSelected: ((Date) -> Void)? = nil
    
    @State private var allFootprints: [Footprint] = []
    @State private var transportRecords: [TransportRecord] = []
    @State private var activityTypes: [ActivityType] = []
    @State private var allPlaces: [Place] = []
    
    @State private var selectedRange: StatisticsRange = .last30Days
    @State private var appliedRange: StatisticsRange = .last30Days
    /// Days spent on trips in the range, with each trip's activity type.
    @State private var reviewTripActivityDays: [Date: String] = [:]
    @State private var mapPosition: MapCameraPosition = .automatic
    @State private var reviewMapRegion: MKCoordinateRegion?
    @State private var reviewTimelineItemsCache: [TimelineItem] = []
    @State private var reviewTransportOverviewPoints: [DFKTransportOverviewPoint] = []
    @State private var reviewMemoryCandidatesCache: [ReviewMemoryCandidate] = []
    @State private var selectedReviewPlace: ReviewPlaceSelection?
    @State private var selectedBentoDetail: ReviewBentoDetail?
    @State private var selectedReviewPlaceList: ReviewPlaceListSelection?
    @State private var selectedBentoReviewPlace: ReviewPlaceSelection?
    @State private var selectedBentoReviewPlaceList: ReviewPlaceListSelection?
    @State private var showingAllFavorites = false
    @State private var pendingFavoriteFootprint: Footprint?
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
    
    @State private var showingFullMap = false
    @State private var activeYearForSegment: Int = Calendar.current.component(.year, from: Date())
    @State private var sharePayload: DFKShareCardPayload?
    @State private var frequentPlaceRankScope: FrequentPlaceRankScope = .city
    @State private var hasManuallySelectedFrequentPlaceRankScope = false
    @State private var geographicBackfillAttempts: [UUID: Int] = [:]
    @State private var isResolvingGeographies = false
    @State private var geographyBackfillTask: Task<Void, Never>?
    @State private var geographyBackfillResolver: StatisticsGeographyResolver?
    @State private var geographyBackfillRequestID = UUID()
    
    // Filtered footprints based on range
    private var filteredFootprints: [Footprint] {
        let calendar = Calendar.current
        switch appliedRange {
        case .last7Days:
            let cutoff = calendar.date(byAdding: .day, value: -7, to: Date())!
            return allFootprints.filter { $0.startTime >= cutoff }
        case .last30Days:
            let cutoff = calendar.date(byAdding: .day, value: -30, to: Date())!
            return allFootprints.filter { $0.startTime >= cutoff }
        case .last90Days:
            let cutoff = calendar.date(byAdding: .day, value: -90, to: Date())!
            return allFootprints.filter { $0.startTime >= cutoff }
        case .lastYear:
            let cutoff = calendar.date(byAdding: .day, value: -365, to: Date())!
            return allFootprints.filter { $0.startTime >= cutoff }
        case .customYear(let year):
            return allFootprints.filter { calendar.component(.year, from: $0.startTime) == year }
        }
    }
    
    private var availableYears: [Int] {
        let years = Set(allFootprints.map { Calendar.current.component(.year, from: $0.startTime) })
        return years.sorted(by: >)
    }
    private var usesIPadLayout: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }
    
    var body: some View {
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
        .onChange(of: selectedRange) { _, range in
            // Invalidate the previous range synchronously. Waiting for the
            // deferred refresh would leave a short window in which its result
            // could still update the map after the picker has already moved.
            reviewDerivedDataRequestID = UUID()
            reviewDerivedDataTask?.cancel()
            reviewRoutesReady = false
            reviewMapRegion = nil
            mapPosition = .automatic
            scheduleReviewRefresh(applying: range)
        }
        .onReceive(NotificationCenter.default.publisher(for: .dfkShareHistoryStatistics)) { _ in
            prepareStatsShare()
        }
        .onAppear {
            scheduleReviewRefresh(fetchesData: true)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                releaseReviewWorkingSet()
            } else if phase == .active, reviewSourceFingerprint == nil {
                scheduleReviewRefresh(fetchesData: true)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            releaseReviewWorkingSet()
        }
        .sheet(isPresented: $showingFullMap) {
            FullReviewMapView(
                title: "\(statisticsRangeText) · \(reviewGeographyMetric.value)\(reviewGeographyMetric.label)",
                rangeText: statisticsRangeText,
                timelineItems: reviewTimelineItemsCache,
                transportOverviewPoints: reviewTransportOverviewPoints,
                initialRegion: reviewMapRegion,
                initialPosition: mapPosition
            )
        }
        .sheet(item: $selectedReviewPlace) { selection in
            ReviewPlaceView(selection: selection)
        }
        .sheet(item: $selectedBentoDetail) { detail in
            reviewBentoDetailView(detail)
        }
        .sheet(item: $selectedReviewPlaceList) { selection in
            ReviewPlaceListSheet(selection: selection)
        }
        .sheet(isPresented: $showingAllFavorites, onDismiss: {
            guard let footprint = pendingFavoriteFootprint else { return }
            pendingFavoriteFootprint = nil
            onFootprintSelected?(footprint)
        }) {
            NavigationStack {
                HistoryFavoritesView(
                    includedFootprintIDs: Set(filteredFootprints.lazy
                        .filter { $0.isHighlight == true && $0.status != .ignored }
                        .map(\.footprintID))
                ) { footprint in
                    pendingFavoriteFootprint = footprint
                    showingAllFavorites = false
                }
                .navigationTitle("\(statisticsRangeText) · 收藏足迹")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showingAllFavorites = false } label: {
                            Image(systemName: "xmark").dfkToolbarDismissIcon()
                        }
                    }
                }
            }
            .presentationDetents([.large])
        }
        .sheet(item: $sharePayload) { _ in
            DFKShareCardSheet(payload: $sharePayload)
        }
    }

    private func prepareStatsShare() {
        let footprints = filteredFootprints
        let coordinates = footprints.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
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
            DFKShareStatEntry(label: "段路程", value: "\(filteredTransportRecords.count)", detail: nil)
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
            transports: filteredTransportRecords,
            activities: activityTypes,
            places: allPlaces
        ) { images in
            loadedMapImages = images
            group.leave()
        }

        for (size, keepsWide) in [(DFKShareTemplateStyle.tallMapSize, false), (DFKShareTemplateStyle.wideMapSize, true)] {
            group.enter()
            DFKShareImageLoader.loadReviewMapImages(
                footprints: footprints,
                transports: filteredTransportRecords,
                activities: activityTypes,
                places: allPlaces,
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
        // the place it was taken.
        var photoCaptions: [String: String] = [:]
        for footprint in footprints {
            let place = footprint.address?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let caption = (place?.isEmpty == false ? place : footprint.cityName) else { continue }
            for assetID in footprint.photoAssetIDs where photoCaptions[assetID] == nil {
                photoCaptions[assetID] = caption
            }
        }
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
        switch appliedRange {
        case .last7Days: return "最近7天"
        case .last30Days: return "最近30天"
        case .last90Days: return "最近90天"
        case .lastYear: return "过去一年"
        case .customYear(let year): return "\(year)年"
        }
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
                transportOverviewPoints: reviewTransportOverviewPoints,
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
                reviewMetric(icon: "point.topleft.down.to.point.bottomright.curvepath", value: "\(filteredTransportRecords.count)", label: "段路程")
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
            Button { showingFullMap = true } label: {
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
        .onTapGesture { showingFullMap = true }
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
                showingAllFavorites = true
                return
            }
            if candidate.id.hasPrefix("past-memory-") {
                onDateSelected?(candidate.date)
                return
            }
            if let selection = reviewPlaceSelection(for: candidate) {
                selectedReviewPlace = selection
            } else {
                onDateSelected?(candidate.date)
            }
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

    private func reviewPlaceSelection(for candidate: ReviewMemoryCandidate) -> ReviewPlaceSelection? {
        guard let footprint = candidate.footprint else { return nil }
        let placeKey = reviewPlaceKey(for: footprint)
        let visits = filteredFootprints
            .filter { reviewPlaceKey(for: $0) == placeKey }
        return reviewPlaceSelection(id: placeKey, visits: visits, photoAssetIDs: candidate.photoAssetIDs)
    }

    private func reviewPlaceSelection(id: String, visits: [Footprint], photoAssetIDs resolvedPhotoAssetIDs: [String]? = nil) -> ReviewPlaceSelection? {
        let orderedVisits = visits.sorted { $0.startTime > $1.startTime }
        guard let representative = orderedVisits.first else { return nil }

        var seenPhotoIDs: Set<String> = []
        let storedPhotoAssetIDs = orderedVisits
            .flatMap(\.photoAssetIDs)
            .filter { seenPhotoIDs.insert($0).inserted }
        let photoAssetIDs = resolvedPhotoAssetIDs ?? PhotoService.shared.displayableAssetIDs(storedPhotoAssetIDs)
        return ReviewPlaceSelection(
            id: id,
            title: reviewPlaceName(for: representative),
            rangeText: statisticsRangeText,
            visits: orderedVisits,
            photoAssetIDs: photoAssetIDs
        )
    }

    private func openReviewRegionItem(_ item: FrequentPlaceItem, scope: FrequentPlaceRankScope) {
        let footprintIDs = Set(item.footprintIDs)
        let grouped = Dictionary(grouping: filteredFootprints.filter { footprintIDs.contains($0.footprintID) }, by: reviewPlaceKey)
        let places = grouped.compactMap { key, visits in
            reviewPlaceSelection(id: key, visits: visits)
        }.sorted { left, right in
            let leftDuration = left.visits.reduce(0) { $0 + $1.duration }
            let rightDuration = right.visits.reduce(0) { $0 + $1.duration }
            return leftDuration > rightDuration
        }
        guard !places.isEmpty else { return }

        if scope == .place, let place = places.first {
            if selectedBentoDetail == .regions {
                selectedBentoReviewPlace = place
            } else {
                selectedReviewPlace = place
            }
        } else {
            let selection = ReviewPlaceListSelection(
                id: "\(scope.rawValue):\(item.id)",
                title: item.name,
                rangeText: statisticsRangeText,
                places: places
            )
            if selectedBentoDetail == .regions {
                selectedBentoReviewPlaceList = selection
            } else {
                selectedReviewPlaceList = selection
            }
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
                Button { selectedBentoDetail = .activity } label: { reviewActivityCompositionCard }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                Button { selectedBentoDetail = .rhythm } label: { reviewRhythmCard }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                Button { selectedBentoDetail = .transport } label: { reviewTransportCard }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                Button { selectedBentoDetail = .regions } label: { reviewRegionCard }
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
                .padding(20)
            }
            .background(Color.dfkBackground)
            .navigationTitle("\(statisticsRangeText) · \(reviewBentoDetailTitle(detail))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { selectedBentoDetail = nil } label: {
                        Image(systemName: "xmark").dfkToolbarDismissIcon()
                    }
                }
            }
        }
        .sheet(item: $selectedBentoReviewPlace) { selection in
            ReviewPlaceView(selection: selection)
        }
        .sheet(item: $selectedBentoReviewPlaceList) { selection in
            ReviewPlaceListSheet(selection: selection)
        }
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
        let visits = reviewActivityRecognizedFootprints
        let totalDuration = slices.reduce(0) { $0 + $1.duration }
        let dominantShare = totalDuration > 0 ? Int(((slices.first?.duration ?? 0) / totalDuration * 100).rounded()) : 0
        let averageDuration = visits.isEmpty ? 0 : totalDuration / Double(visits.count)
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2), spacing: 10) {
            reviewActivityMetricCard(title: "活动类型", value: "\(slices.count)种", icon: "square.grid.2x2.fill")
            reviewActivityMetricCard(title: "活动记录", value: "\(visits.count)次", icon: "list.number")
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
        let calendar = Calendar.current
        let values = reviewTransportSlices.map { slice in
            let activeDays = Set(
                filteredTransportRecords.lazy
                    .filter { reviewTransportType(for: $0).rawValue == slice.id }
                    .map { calendar.startOfDay(for: $0.startTime) }
            ).count
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

    private var reviewPlaceCount: Int {
        getTopLocations(delta: 0.01).count
    }

    private var reviewDistanceText: String {
        formatRankMileage(filteredTransportRecords.reduce(0) { $0 + $1.distance })
    }

    private var reviewMapRevision: Int {
        let latestFootprint = filteredFootprints.map(\.endTime).max()?.timeIntervalSince1970 ?? 0
        let latestTransport = filteredTransportRecords.map(\.endTime).max()?.timeIntervalSince1970 ?? 0
        let rangeCode: Int
        switch appliedRange {
        case .last7Days: rangeCode = 7
        case .last30Days: rangeCode = 30
        case .last90Days: rangeCode = 90
        case .lastYear: rangeCode = 365
        case .customYear(let year): rangeCode = year
        }
        let dataRevision = rangeCode &* 1_000_003
            &+ filteredFootprints.count &* 10_007
            &+ filteredTransportRecords.count &* 101
            &+ Int(max(latestFootprint, latestTransport))
        return dataRevision &* 31 &+ 6
    }

    private var reviewGeographyMetric: (icon: String, value: String, label: String) {
        let countries = Set(filteredFootprints.compactMap { footprint -> String? in
            let value = footprint.countryCode?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? nil : value.uppercased()
        })
        if countries.count > 1 { return ("globe.asia.australia.fill", "\(countries.count)", "个国家") }

        let cities = Set(filteredFootprints.compactMap { footprint -> String? in
            let city = footprint.cityName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !city.isEmpty else { return nil }
            return "\(footprint.countryCode?.uppercased() ?? "")|\(city)"
        })
        if cities.count > 1 { return ("building.2.fill", "\(cities.count)", "座城市") }
        return ("mappin.and.ellipse", "\(reviewPlaceCount)", "个地点")
    }

    private func buildReviewMemoryCandidatesCooperatively() async -> [ReviewMemoryCandidate] {
        var candidates: [ReviewMemoryCandidate] = []
        let calendar = Calendar.current
        let footprintsInRange = filteredFootprints

        let historyByPlace = Dictionary(grouping: allFootprints, by: reviewPlaceKey)
        let visitsByPlace = Dictionary(grouping: footprintsInRange, by: reviewPlaceKey)
        var photosByPlace: [String: [String]] = [:]
        for (placeKey, visits) in visitsByPlace {
            var seenPhotoIDs = Set<String>()
            var photoAssetIDs: [String] = []
            for visit in visits {
                let visitPhotoAssetIDs = await PhotoService.shared.displayableAssetIDs(for: visit)
                photoAssetIDs.append(contentsOf: visitPhotoAssetIDs.filter { seenPhotoIDs.insert($0).inserted })
            }
            photosByPlace[placeKey] = photoAssetIDs
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
            .filter { $0.value >= AppConfig.shared.reviewMemoryLongStayMinDuration }
            .sorted { $0.value > $1.value }
            .prefix(3)
        let longStayPlaceKeys = Set(rankedDurationPlaces.map(\.key))
        let longestPlaceKey = rankedDurationPlaces.first?.key
        let mostVisitedPlaceKey = visitCountByPlace.max {
            if $0.value != $1.value { return $0.value < $1.value }
            return (durationByPlace[$0.key] ?? 0) < (durationByPlace[$1.key] ?? 0)
        }?.key
        let mostPhotoPlaceKey = photosByPlace.max { $0.value.count < $1.value.count }?.key
        let frequentVisitMinCount = AppConfig.shared.reviewMemoryFrequentVisitMinCount
        let longestFootprintID = footprintsInRange.max {
            if $0.duration != $1.duration { return $0.duration < $1.duration }
            return $0.startTime > $1.startTime
        }?.footprintID
        var previousVisitByID: [UUID: Date] = [:]
        var firstVisitIDByPlace: [String: UUID] = [:]
        var averageDurationByPlace: [String: TimeInterval] = [:]
        for (index, entry) in historyByPlace.enumerated() {
            if index.isMultiple(of: 40) {
                await Task.yield()
                if Task.isCancelled { return [] }
            }
            let (placeKey, history) = entry
            let ordered = history.sorted {
                if $0.startTime != $1.startTime { return $0.startTime < $1.startTime }
                return $0.footprintID.uuidString < $1.footprintID.uuidString
            }
            firstVisitIDByPlace[placeKey] = ordered.first?.footprintID
            var previousDate: Date?
            for footprint in ordered {
                if let previousDate { previousVisitByID[footprint.footprintID] = previousDate }
                previousDate = footprint.startTime
            }
            averageDurationByPlace[placeKey] = history.reduce(0) { $0 + $1.duration } / Double(max(1, history.count))
        }

        var firstCountryDate: [String: Date] = [:]
        var firstCityDate: [String: Date] = [:]
        for (index, footprint) in allFootprints.enumerated() {
            if index.isMultiple(of: 100) {
                await Task.yield()
                if Task.isCancelled { return [] }
            }
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

        for (index, footprint) in footprintsInRange.enumerated() {
            if index.isMultiple(of: 40) {
                await Task.yield()
                if Task.isCancelled { return [] }
            }
            let placeKey = reviewPlaceKey(for: footprint)
            let placePhotoAssetIDs = photosByPlace[placeKey] ?? []
            let footprintPhotoAssetIDs = await PhotoService.shared.displayableAssetIDs(for: footprint)
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

            if firstVisit && footprintPhotoAssetIDs.count >= AppConfig.shared.reviewMemoryFirstVisitPhotoMinCount {
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
               footprint.duration >= AppConfig.shared.reviewMemoryLongStayMinDuration {
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
                let durationScore = min(4, placeDuration / AppConfig.shared.reviewMemoryLongStayMinDuration)
                score += durationScore
                if reason.isEmpty || (reason == "第一次来到这里" && placeVisitCount >= frequentVisitMinCount) {
                    reason = placeKey == longestPlaceKey
                        ? "这段时间最常停留"
                        : (placeVisitCount >= frequentVisitMinCount ? "常常回到这里" : "在这里度过了不少时间")
                    evidence = "累计\(formatRankDuration(placeDuration)) · \(placeVisitCount)次到访"
                    icon = "clock.fill"
                }
            }
            if averageDuration > 0 && footprint.duration >= averageDuration * AppConfig.shared.reviewMemoryUnusualDurationRatio {
                score += 2
                if reason.isEmpty || reason == "第一次来到这里" {
                    reason = "这次停留得格外久"
                    evidence = "停留\(formatRankDuration(footprint.duration))"
                    icon = "hourglass"
                }
            }
            if isPlaceRepresentative && placePhotoAssetIDs.count >= AppConfig.shared.reviewMemoryPhotoMinCount {
                score += min(4, Double(placePhotoAssetIDs.count) / Double(max(1, AppConfig.shared.reviewMemoryPhotoMinCount)))
                if reason.isEmpty || (placeKey == mostPhotoPlaceKey && reason == "第一次来到这里") {
                    reason = placeKey == mostPhotoPlaceKey ? "照片最多的地方" : "用照片记下这里"
                    evidence = "累计拍了\(placePhotoAssetIDs.count)张照片"
                    icon = "photo.on.rectangle.angled"
                }
            }
            if daysSincePrevious >= AppConfig.shared.longTimeNoSeeDays {
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

            guard score >= AppConfig.shared.reviewMemoryMinimumScore,
                  !reason.isEmpty,
                  !placePhotoAssetIDs.isEmpty else { continue }
            candidates.append(ReviewMemoryCandidate(
                id: "footprint-\(footprint.footprintID.uuidString)",
                date: footprint.startTime,
                footprint: footprint,
                title: reviewPlaceName(for: footprint),
                evidence: evidence,
                reason: reason,
                systemImage: icon,
                photoAssetIDs: placePhotoAssetIDs,
                score: score
            ))
        }

        if let farthest = reviewFarthestDay, !farthest.photoIDs.isEmpty {
            candidates.append(ReviewMemoryCandidate(
                id: "distance-\(farthest.date.timeIntervalSince1970)",
                date: farthest.date,
                footprint: nil,
                title: farthest.date.formatted(.dateTime.month().day()),
                evidence: formatRankMileage(farthest.distance),
                reason: "走得最远的一天",
                systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                photoAssetIDs: farthest.photoIDs,
                score: 5
            ))
        }
        candidates.append(contentsOf: reviewTransportMemoryCandidates.filter { !$0.photoAssetIDs.isEmpty })

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
            let photoAssetIDs = await PhotoService.shared.displayableAssetIDs(for: footprint)
            guard !photoAssetIDs.isEmpty else { continue }
            favoriteCandidate = ReviewMemoryCandidate(
                id: "favorite-\(footprint.footprintID.uuidString)",
                date: footprint.startTime,
                footprint: nil,
                title: "\(favoriteFootprints.count)个重要片段",
                evidence: "点开查看全部收藏",
                reason: "收藏足迹",
                systemImage: "star.fill",
                photoAssetIDs: photoAssetIDs,
                score: 0
            )
            break
        }
        if favoriteCandidate == nil, let footprint = orderedFavoriteFootprints.first {
            favoriteCandidate = ReviewMemoryCandidate(
                id: "favorite-\(footprint.footprintID.uuidString)",
                date: footprint.startTime,
                footprint: nil,
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
        let automaticLimit = max(0, AppConfig.shared.reviewMemoryMaximumCount - (favoriteCandidate == nil ? 0 : 1))
        let rankedCandidates = candidates.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.date != $1.date { return $0.date < $1.date }
            return $0.id < $1.id
        }
        func appendCandidateIfAvailable(_ candidate: ReviewMemoryCandidate, requiresNewReason: Bool) {
            guard selected.count < automaticLimit else { return }
            let day = calendar.startOfDay(for: candidate.date)
            let placeKey = candidate.footprint.map(reviewPlaceKey)
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

    private var reviewFarthestDay: (date: Date, distance: Double, photoIDs: [String])? {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: filteredTransportRecords) { calendar.startOfDay(for: $0.startTime) }
        guard let item = grouped.map({ (date: $0.key, distance: $0.value.reduce(0) { $0 + $1.distance }) }).max(by: { $0.distance < $1.distance }),
              item.distance >= AppConfig.shared.reviewMemoryTravelDistanceMin else { return nil }
        let photoIDs = filteredFootprints.filter { calendar.isDate($0.startTime, inSameDayAs: item.date) }.flatMap(\.photoAssetIDs)
        return (item.date, item.distance, photoIDs)
    }

    private var reviewTransportMemoryCandidates: [ReviewMemoryCandidate] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: filteredTransportRecords) { calendar.startOfDay(for: $0.startTime) }
        var candidates: [ReviewMemoryCandidate] = []

        if let walking = grouped.map({ day, records -> (Date, Double) in
            let distance = records.filter {
                let type = $0.manualTypeRaw.flatMap(TransportType.init(rawValue:)) ?? TransportType(rawValue: $0.typeRaw) ?? .slow
                return type == .slow || type == .running
            }.reduce(0) { $0 + $1.distance }
            return (day, distance)
        }).max(by: { $0.1 < $1.1 }), walking.1 >= AppConfig.shared.reviewMemoryWalkDistanceMin {
            candidates.append(ReviewMemoryCandidate(
                id: "walking-\(walking.0.timeIntervalSince1970)", date: walking.0, footprint: nil,
                title: walking.0.formatted(.dateTime.month().day()), evidence: formatRankMileage(walking.1),
                reason: "步行最多的一天", systemImage: "figure.walk", photoAssetIDs: reviewPhotoIDs(on: walking.0), score: 4.8
            ))
        }

        if let diverse = grouped.map({ day, records -> (Date, Int) in
            let types = Set(records.compactMap { $0.manualTypeRaw ?? $0.typeRaw }.filter { !$0.isEmpty })
            return (day, types.count)
        }).max(by: { $0.1 < $1.1 }), diverse.1 >= AppConfig.shared.reviewMemoryDiverseTransportMinCount {
            candidates.append(ReviewMemoryCandidate(
                id: "modes-\(diverse.0.timeIntervalSince1970)", date: diverse.0, footprint: nil,
                title: diverse.0.formatted(.dateTime.month().day()), evidence: "用了\(diverse.1)种交通方式",
                reason: "出行方式最丰富的一天", systemImage: "arrow.triangle.branch", photoAssetIDs: reviewPhotoIDs(on: diverse.0), score: 4.4
            ))
        }
        return candidates
    }

    private func reviewPhotoIDs(on date: Date) -> [String] {
        filteredFootprints.filter { Calendar.current.isDate($0.startTime, inSameDayAs: date) }.flatMap(\.photoAssetIDs)
    }

    private func reviewPlaceKey(for footprint: Footprint) -> String {
        reviewIntegratedPlaceKey(for: footprint, allPlaces: allPlaces)
    }

    private var reviewActivitySlices: [ReviewActivitySlice] {
        let calendar = Calendar.current
        var totals: [String: TimeInterval] = [:]
        for footprint in filteredFootprints {
            // A trip day counts whole toward the trip's own type below, so
            // its individual stops are not counted a second time.
            guard reviewTripActivityDays[calendar.startOfDay(for: footprint.startTime)] == nil,
                  let activity = footprint.getActivityType(from: activityTypes) else { continue }
            totals[activity.name, default: 0] += footprint.duration
        }
        for value in reviewTripActivityDays.values {
            guard let activity = activityTypes.first(where: { $0.id.uuidString == value || $0.name == value }) else { continue }
            totals[activity.name, default: 0] += 86_400
        }
        return totals.compactMap { name, duration in
            guard let activity = activityTypes.first(where: { $0.name == name }) else { return nil }
            return ReviewActivitySlice(id: name, name: name, duration: duration, color: activity.color, icon: activity.icon)
        }.sorted { $0.duration > $1.duration }
    }

    private var reviewActivityRecognizedFootprints: [Footprint] {
        filteredFootprints.filter { $0.getActivityType(from: activityTypes) != nil }
    }

    private func reviewActivityVisitCount(for name: String) -> Int {
        reviewActivityRecognizedFootprints.filter {
            $0.getActivityType(from: activityTypes)?.name == name
        }.count
    }

    private func reviewActivityWeekdayCounts(for name: String) -> [Int] {
        let calendar = Calendar.current
        var values = Array(repeating: 0, count: 7)
        for footprint in reviewActivityRecognizedFootprints where footprint.getActivityType(from: activityTypes)?.name == name {
            let mondayFirstIndex = (calendar.component(.weekday, from: footprint.startTime) + 5) % 7
            values[mondayFirstIndex] += 1
        }
        return values
    }

    private func reviewActivityHourlyCounts(for name: String) -> [Int] {
        let calendar = Calendar.current
        var values = Array(repeating: 0, count: 24)
        for footprint in reviewActivityRecognizedFootprints where footprint.getActivityType(from: activityTypes)?.name == name {
            values[calendar.component(.hour, from: footprint.startTime)] += 1
        }
        return values
    }

    private var reviewTransportSlices: [ReviewTransportSlice] {
        var counts: [TransportType: Int] = [:]
        var distances: [TransportType: Double] = [:]
        for record in filteredTransportRecords {
            let type = reviewTransportType(for: record)
            counts[type, default: 0] += 1
            distances[type, default: 0] += record.distance
        }
        let colors: [Color] = [.dfkAccent, .blue, .green, .orange, .purple]
        return counts.map { type, count in
            let index = TransportType.allCases.firstIndex(of: type) ?? 0
            return ReviewTransportSlice(
                id: type.rawValue,
                name: type.localizedName,
                count: count,
                distance: distances[type, default: 0],
                color: colors[index % colors.count],
                icon: type.sfSymbol
            )
        }.sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            return $0.distance > $1.distance
        }
    }

    private func reviewTransportType(for record: TransportRecord) -> TransportType {
        record.manualTypeRaw.flatMap(TransportType.init(rawValue:))
            ?? TransportType(rawValue: record.typeRaw)
            ?? .slow
    }

    private func reviewTransportWeekdayCounts(for typeID: String) -> [Int] {
        let calendar = Calendar.current
        var values = Array(repeating: 0, count: 7)
        for record in filteredTransportRecords where reviewTransportType(for: record).rawValue == typeID {
            let mondayFirstIndex = (calendar.component(.weekday, from: record.startTime) + 5) % 7
            values[mondayFirstIndex] += 1
        }
        return values
    }

    private func reviewTransportHourlyCounts(for typeID: String) -> [Int] {
        let calendar = Calendar.current
        var values = Array(repeating: 0, count: 24)
        for record in filteredTransportRecords where reviewTransportType(for: record).rawValue == typeID {
            values[calendar.component(.hour, from: record.startTime)] += 1
        }
        return values
    }

    private var reviewTopRegions: [(name: String, duration: TimeInterval)] {
        var totals: [String: TimeInterval] = [:]
        for footprint in filteredFootprints {
            let city = footprint.cityName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let name = city.isEmpty ? reviewPlaceName(for: footprint) : city
            totals[name, default: 0] += footprint.duration
        }
        return totals.map { ($0.key, $0.value) }.sorted { $0.duration > $1.duration }
    }

    private var pastMemoryFootprint: Footprint? {
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.dateComponents([.month, .day, .year], from: now)
        let importantPlaceIDs = Set(allPlaces.filter(\.isPriority).map(\.placeID))
        return allFootprints.filter { footprint in
            let components = calendar.dateComponents([.month, .day, .year], from: footprint.startTime)
            guard components.month == today.month,
                  components.day == today.day,
                  (components.year ?? today.year ?? 0) < (today.year ?? 0),
                  let placeID = footprint.placeID,
                  !importantPlaceIDs.contains(placeID),
                  !(footprint.activityTypeValue ?? "").isEmpty else {
                return false
            }
            return true
        }
        .sorted { $0.startTime < $1.startTime }
        .first
    }

    private var pastMemoryCandidate: ReviewMemoryCandidate? {
        guard let footprint = pastMemoryFootprint else { return nil }
        let years = max(1, Calendar.current.dateComponents([.year], from: footprint.startTime, to: Date()).year ?? 1)
        return ReviewMemoryCandidate(
            id: "past-memory-\(footprint.footprintID.uuidString)",
            date: footprint.startTime,
            footprint: footprint,
            title: reviewPlaceName(for: footprint),
            evidence: "\(years)年前",
            reason: "往年今日",
            systemImage: "clock.arrow.circlepath",
            photoAssetIDs: footprint.photoAssetIDs,
            score: 0
        )
    }

    private func reviewPlaceName(for footprint: Footprint) -> String {
        if let placeID = footprint.placeID,
           let place = allPlaces.first(where: { $0.placeID == placeID }),
           !place.name.isEmpty {
            return place.name
        }
        let address = footprint.address?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return address.isEmpty ? "这个地方" : address
    }

    private var reviewRangeStart: Date {
        let calendar = Calendar.current
        switch appliedRange {
        case .last7Days: return calendar.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        case .last30Days: return calendar.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        case .last90Days: return calendar.date(byAdding: .day, value: -90, to: Date()) ?? Date()
        case .lastYear: return calendar.date(byAdding: .day, value: -365, to: Date()) ?? Date()
        case .customYear(let year): return calendar.date(from: DateComponents(year: year, month: 1, day: 1)) ?? Date()
        }
    }

    private var reviewRangeEnd: Date {
        if case .customYear(let year) = appliedRange {
            return Calendar.current.date(from: DateComponents(year: year, month: 12, day: 31)) ?? Date()
        }
        return Date()
    }

    private var reviewActivityBuckets: [Int] {
        let bucketCount = 24
        let duration = max(1, reviewRangeEnd.timeIntervalSince(reviewRangeStart))
        var buckets = Array(repeating: 0, count: bucketCount)
        for footprint in filteredFootprints {
            let progress = footprint.startTime.timeIntervalSince(reviewRangeStart) / duration
            let index = min(bucketCount - 1, max(0, Int(progress * Double(bucketCount))))
            buckets[index] += 1
        }
        return buckets
    }

    private var reviewRhythmDailyCounts: [(date: Date, count: Int)] {
        let calendar = Calendar.current
        let endDate = calendar.startOfDay(for: min(reviewRangeEnd, Date()))
        let dayCount: Int
        if let fixedDays = appliedRange.days {
            dayCount = fixedDays
        } else {
            let rangeStart = calendar.startOfDay(for: reviewRangeStart)
            dayCount = max(1, (calendar.dateComponents([.day], from: rangeStart, to: endDate).day ?? 0) + 1)
        }
        let firstDate = calendar.date(byAdding: .day, value: -(dayCount - 1), to: endDate) ?? endDate
        let countsByDate = Dictionary(grouping: filteredFootprints) {
            calendar.startOfDay(for: $0.startTime)
        }.mapValues(\.count)
        return (0..<dayCount).map { offset in
            let date = calendar.date(byAdding: .day, value: offset, to: firstDate) ?? firstDate
            return (date, countsByDate[date, default: 0])
        }
    }

    private var reviewMileageMetrics: ReviewMileageMetrics {
        let calendar = Calendar.current
        let distanceByDate = Dictionary(grouping: filteredTransportRecords) {
            calendar.startOfDay(for: $0.startTime)
        }.mapValues { records in
            records.reduce(0) { $0 + $1.distance }
        }
        let dailyValues = reviewRhythmDailyCounts.map { item in
            (date: item.date, distance: distanceByDate[item.date, default: 0])
        }
        let total = dailyValues.reduce(0) { $0 + $1.distance }
        let dailyAverage = dailyValues.isEmpty ? 0 : total / Double(dailyValues.count)
        let peakDay = dailyValues.max { $0.distance < $1.distance }
        let activeDayCount = dailyValues.filter { $0.distance > 0 }.count
        var totals = Array(repeating: 0.0, count: 7)
        var occurrences = Array(repeating: 0, count: 7)
        for item in dailyValues {
            let mondayFirstIndex = (calendar.component(.weekday, from: item.date) + 5) % 7
            totals[mondayFirstIndex] += item.distance
            occurrences[mondayFirstIndex] += 1
        }
        let weekdayAverages = totals.indices.map { index in
            totals[index] / Double(max(1, occurrences[index]))
        }
        return ReviewMileageMetrics(
            dailyValues: dailyValues,
            total: total,
            dailyAverage: dailyAverage,
            peakDay: peakDay,
            activeDayCount: activeDayCount,
            weekdayAverages: weekdayAverages
        )
    }

    private var reviewRhythmActiveDayCount: Int {
        reviewRhythmDailyCounts.filter { $0.count > 0 }.count
    }

    private var reviewRhythmActiveDayRate: Int {
        let days = max(1, reviewRhythmDailyCounts.count)
        return Int((Double(reviewRhythmActiveDayCount) / Double(days) * 100).rounded())
    }

    private var reviewRhythmWeeklyAverageText: String {
        let days = max(1, reviewRhythmDailyCounts.count)
        let total = reviewRhythmDailyCounts.reduce(0) { $0 + $1.count }
        return "\(reviewRhythmCompactNumber(Double(total) * 7 / Double(days)))次"
    }

    private var reviewRhythmActiveDayAverageText: String {
        let activeDays = max(1, reviewRhythmActiveDayCount)
        let total = reviewRhythmDailyCounts.reduce(0) { $0 + $1.count }
        return "\(reviewRhythmCompactNumber(Double(total) / Double(activeDays)))次"
    }

    private var reviewRhythmPeakCount: Int {
        reviewRhythmDailyCounts.map(\.count).max() ?? 0
    }

    private var reviewRhythmLongestStreak: Int {
        var longest = 0
        var current = 0
        for item in reviewRhythmDailyCounts {
            if item.count > 0 {
                current += 1
                longest = max(longest, current)
            } else {
                current = 0
            }
        }
        return longest
    }

    private var reviewRhythmWeekdaySymbols: [String] {
        ["一", "二", "三", "四", "五", "六", "日"]
    }

    private var reviewRhythmWeekdayAverages: [CGFloat] {
        let calendar = Calendar.current
        var totals = Array(repeating: 0, count: 7)
        var occurrences = Array(repeating: 0, count: 7)
        for item in reviewRhythmDailyCounts {
            let mondayFirstIndex = (calendar.component(.weekday, from: item.date) + 5) % 7
            totals[mondayFirstIndex] += item.count
            occurrences[mondayFirstIndex] += 1
        }
        return totals.indices.map { index in
            CGFloat(totals[index]) / CGFloat(max(1, occurrences[index]))
        }
    }

    private var reviewRhythmHourlyCounts: [Int] {
        var values = Array(repeating: 0, count: 24)
        let calendar = Calendar.current
        for footprint in filteredFootprints {
            values[calendar.component(.hour, from: footprint.startTime)] += 1
        }
        return values
    }

    private func reviewRhythmCompactNumber<T: BinaryFloatingPoint>(_ value: T) -> String {
        let number = Double(value)
        if abs(number.rounded() - number) < 0.05 {
            return String(Int(number.rounded()))
        }
        return String(format: "%.1f", number)
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
        for fp in footprintsInScope {
            if let pID = fp.placeID, let place = allPlaces.first(where: { $0.placeID == pID }), place.isUserDefined, !place.name.isEmpty {
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
        allFootprints.removeAll(keepingCapacity: false)
        transportRecords.removeAll(keepingCapacity: false)
        activityTypes.removeAll(keepingCapacity: false)
        allPlaces.removeAll(keepingCapacity: false)
        reviewTimelineItemsCache.removeAll(keepingCapacity: false)
        reviewTransportOverviewPoints.removeAll(keepingCapacity: false)
        reviewMemoryCandidatesCache.removeAll(keepingCapacity: false)
        reviewSourceFingerprint = nil
        reviewRoutesReady = false
        reviewMapRegion = nil
        mapPosition = .automatic
        showingFullMap = false
        selectedReviewPlace = nil
        selectedBentoDetail = nil
        selectedReviewPlaceList = nil
        selectedBentoReviewPlace = nil
        selectedBentoReviewPlaceList = nil
        showingAllFavorites = false
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
            if fetchesData {
                sourceChanged = fetchData()
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
            updateDefaultFrequentPlaceRankScope()
            startReviewDerivedDataRefresh()
        }
    }

    private func startReviewDerivedDataRefresh() {
        reviewDerivedDataTask?.cancel()
        let requestID = UUID()
        reviewDerivedDataRequestID = requestID
        let rangeAtStart = appliedRange

        let tripRangeStart = reviewRangeStart
        let tripRangeEnd = min(reviewRangeEnd, Date())
        Task { @MainActor in
            let days = await TripScanManager.shared.tripActivityDays(from: tripRangeStart, through: tripRangeEnd)
            guard rangeAtStart == appliedRange else { return }
            reviewTripActivityDays = days
        }

        let footprintsInRange = filteredFootprints
        let records = filteredTransportRecords.map {
            ReviewTransportBuildSnapshot(
                id: $0.recordID,
                startTime: $0.startTime,
                endTime: $0.endTime,
                startLocation: $0.startLocation,
                endLocation: $0.endLocation,
                typeRaw: $0.typeRaw,
                distance: $0.distance,
                averageSpeed: $0.averageSpeed,
                pointsData: $0.pointsData,
                manualTypeRaw: $0.manualTypeRaw,
                stepCount: $0.stepCount
            )
        }
        let trajectoryBaseCellDegrees = AppConfig.shared.reviewMapTrajectoryBaseCellDegrees
        let trajectoryMaxDrawPoints = AppConfig.shared.reviewMapTrajectoryMaxDrawPoints
        let footprintCoordinates = footprintsInRange.map { (latitude: $0.latitude, longitude: $0.longitude) }

        // Footprints are immediately renderable. Route JSON decoding is the
        // expensive part and must never run on the main actor.
        // Never leave a previous range visible while its replacement is being
        // decoded. Footprints for the selected range are cheap and available
        // immediately; routes are added atomically after the request is proven
        // to still be current.
        reviewTimelineItemsCache = footprintsInRange.map(TimelineItem.footprint)
        reviewTransportOverviewPoints = []
        reviewMemoryCandidatesCache = loadCachedReviewMemories()
        reviewRoutesReady = false

        reviewDerivedDataTask = Task { @MainActor in
            async let decodedResult = Task.detached(priority: .utility) {
                let decoded = records.map { record in
                    ReviewDecodedTransport(
                        source: record,
                        points: (try? JSONDecoder().decode([CodableCoordinate].self, from: record.pointsData)) ?? []
                    )
                }
                struct Bucket {
                    var latitude = 0.0
                    var longitude = 0.0
                    var count = 0
                }
                var cellSize = trajectoryBaseCellDegrees
                var buckets: [String: Bucket] = [:]
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

                for coordinate in footprintCoordinates {
                    include(latitude: coordinate.latitude, longitude: coordinate.longitude)
                }
                for transport in decoded {
                    for point in transport.points where point.isSyntheticPadding != true {
                        guard point.lat.isFinite, point.lon.isFinite,
                              (-90...90).contains(point.lat), (-180...180).contains(point.lon),
                              !(point.lat == 0 && point.lon == 0) else { continue }
                        include(latitude: point.lat, longitude: point.lon)
                        let x = Int((point.lon / cellSize).rounded())
                        let y = Int((point.lat / cellSize).rounded())
                        let key = "\(x):\(y)"
                        var bucket = buckets[key, default: Bucket()]
                        bucket.latitude += point.lat
                        bucket.longitude += point.lon
                        bucket.count += 1
                        buckets[key] = bucket
                    }
                }

                while buckets.count > trajectoryMaxDrawPoints {
                    cellSize *= 1.6
                    var merged: [String: Bucket] = [:]
                    for bucket in buckets.values {
                        let latitude = bucket.latitude / Double(bucket.count)
                        let longitude = bucket.longitude / Double(bucket.count)
                        let x = Int((longitude / cellSize).rounded())
                        let y = Int((latitude / cellSize).rounded())
                        let key = "\(x):\(y)"
                        var target = merged[key, default: Bucket()]
                        target.latitude += bucket.latitude
                        target.longitude += bucket.longitude
                        target.count += bucket.count
                        merged[key] = target
                    }
                    buckets = merged
                }
                let overviewPoints = buckets.map { key, bucket in
                    DFKTransportOverviewPoint(
                        id: key,
                        latitude: bucket.latitude / Double(bucket.count),
                        longitude: bucket.longitude / Double(bucket.count),
                        intensity: bucket.count
                    )
                }
                let bounds: ReviewMapBounds? = minimumLatitude == Double.greatestFiniteMagnitude
                    ? nil
                    : ReviewMapBounds(
                        minimumLatitude: minimumLatitude,
                        maximumLatitude: maximumLatitude,
                        minimumLongitude: minimumLongitude,
                        maximumLongitude: maximumLongitude
                    )
                return (decoded, overviewPoints, bounds)
            }.value

            let (decoded, overviewPoints, bounds) = await decodedResult
            guard !Task.isCancelled,
                  requestID == reviewDerivedDataRequestID,
                  rangeAtStart == appliedRange else { return }
            reviewTransportOverviewPoints = overviewPoints
            if let bounds {
                let region = mapRegion(for: bounds)
                reviewMapRegion = region
                mapPosition = .region(region)
            }

            let candidates = await buildReviewMemoryCandidatesCooperatively()
            guard !Task.isCancelled,
                  requestID == reviewDerivedDataRequestID,
                  rangeAtStart == appliedRange else { return }
            reviewMemoryCandidatesCache = candidates
            saveCachedReviewMemories(candidates)
            let transportItems = decoded.map { decoded -> TimelineItem in
                let pathPoints = decoded.points.map {
                    TransportPathPoint(
                        coordinate: CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon),
                        timestamp: $0.timestamp,
                        isSyntheticPadding: $0.isSyntheticPadding ?? false
                    )
                }
                let source = decoded.source
                return .transport(Transport(
                    id: source.id,
                    startTime: source.startTime,
                    endTime: source.endTime,
                    startLocation: source.startLocation,
                    endLocation: source.endLocation,
                    type: TransportType(rawValue: source.typeRaw) ?? .slow,
                    distance: source.distance,
                    averageSpeed: source.averageSpeed,
                    points: pathPoints.map(\.coordinate),
                    pathPoints: pathPoints,
                    manualType: source.manualTypeRaw.flatMap(TransportType.init(rawValue:)),
                    stepCount: source.stepCount
                ))
            }
            guard requestID == reviewDerivedDataRequestID,
                  rangeAtStart == appliedRange else { return }
            reviewTimelineItemsCache = (footprintsInRange.map(TimelineItem.footprint) + transportItems)
                .sorted { $0.startTime < $1.startTime }
            reviewRoutesReady = true
        }
    }

    private var reviewMemoryCacheKey: String {
        "review.memory.v8.\(appliedRange.rawValue)"
    }

    private func loadCachedReviewMemories() -> [ReviewMemoryCandidate] {
        guard let data = UserDefaults.standard.data(forKey: reviewMemoryCacheKey),
              let payload = try? JSONDecoder().decode(ReviewMemoryCachePayload.self, from: data) else { return [] }
        let footprintsByID = Dictionary(uniqueKeysWithValues: allFootprints.map { ($0.footprintID, $0) })
        return payload.entries.filter {
            !$0.photoAssetIDs.isEmpty || $0.id.hasPrefix("favorite-")
        }.map { entry in
            ReviewMemoryCandidate(
                id: entry.id,
                date: entry.date,
                footprint: entry.footprintID.flatMap { footprintsByID[$0] },
                title: entry.title,
                evidence: entry.evidence,
                reason: entry.reason,
                systemImage: entry.systemImage,
                photoAssetIDs: entry.photoAssetIDs,
                score: entry.score
            )
        }
    }

    private func saveCachedReviewMemories(_ candidates: [ReviewMemoryCandidate]) {
        let entries = candidates.filter {
            !$0.photoAssetIDs.isEmpty || $0.id.hasPrefix("favorite-")
        }.map {
            ReviewMemoryCacheEntry(
                id: $0.id,
                date: $0.date,
                footprintID: $0.footprint?.footprintID,
                title: $0.title,
                evidence: $0.evidence,
                reason: $0.reason,
                systemImage: $0.systemImage,
                photoAssetIDs: $0.photoAssetIDs,
                score: $0.score
            )
        }
        let payload = ReviewMemoryCachePayload(revision: reviewMapRevision, entries: entries)
        if let data = try? JSONEncoder().encode(payload) {
            UserDefaults.standard.set(data, forKey: reviewMemoryCacheKey)
        }
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
        Picker("时间范围", selection: $selectedRange) {
            Text("7天").tag(StatisticsRange.last7Days)
            Text("30天").tag(StatisticsRange.last30Days)
            Text("90天").tag(StatisticsRange.last90Days)
            Text("1年").tag(StatisticsRange.lastYear)
            Text(isCustomYear ? "\(String(activeYearForSegment)) ▾" : "年份 ▾")
                .tag(StatisticsRange.customYear(activeYearForSegment))
        }
        .pickerStyle(.segmented)
        .overlay {
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    Spacer()
                    if !availableYears.isEmpty {
                        Menu {
                            ForEach(availableYears, id: \.self) { year in
                                Button(String(year)) {
                                    activeYearForSegment = year
                                    selectedRange = .customYear(year)
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

    private var isCustomYear: Bool {
        if case .customYear = selectedRange { return true }
        return false
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
    
    struct FrequentPlaceItem: Identifiable {
        let id: String
        let name: String
        let address: String
        let count: Int
        let duration: TimeInterval
        let footprintIDs: [UUID]
    }
    
    private func getFrequentPlacesData() -> [FrequentPlaceItem] {
        getFrequentPlacesData(for: frequentPlaceRankScope)
    }

    private func getFrequentPlacesData(for scope: FrequentPlaceRankScope) -> [FrequentPlaceItem] {
        var groups: [String: (name: String, address: String, count: Int, duration: TimeInterval, footprintIDs: [UUID])] = [:]
        let hasMultipleCountries = Set(filteredFootprints.compactMap { footprint in
            footprint.countryCode?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }).count > 1
        
        for fp in filteredFootprints {
            var address = ""
            var placeName = ""
            if let pID = fp.placeID, let place = allPlaces.first(where: { $0.placeID == pID }) {
                placeName = place.name
                address = place.address ?? fp.address ?? ""
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
                key = reviewPlaceKey(for: fp)
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
                FrequentPlaceItem(
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

    private func updateDefaultFrequentPlaceRankScope() {
        guard !hasManuallySelectedFrequentPlaceRankScope else { return }

        let countries = Set(filteredFootprints.compactMap { footprint in
            footprint.countryCode?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty })
        if countries.count > 1 {
            frequentPlaceRankScope = .country
            return
        }

        let cities = Set(filteredFootprints.compactMap { footprint -> String? in
            guard let city = footprint.cityName?.trimmingCharacters(in: .whitespacesAndNewlines), !city.isEmpty else {
                return nil
            }
            return "\(footprint.countryCode ?? "")|\(city)"
        })
        frequentPlaceRankScope = cities.count == 1 ? .place : .city
    }

    private func rankName(
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

    private func flagEmoji(for countryCode: String) -> String {
        let base: UInt32 = 127397
        return countryCode.uppercased().unicodeScalars.compactMap {
            UnicodeScalar(base + $0.value).map(String.init)
        }.joined()
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
            for transport in filteredTransportRecords {
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

    private func formatRankMileage(_ distance: Double) -> String {
        if distance < 1_000 {
            return "\(Int(distance.rounded()))米"
        }
        return String(format: "%.1f公里", distance / 1_000)
    }

    private var filteredTransportRecords: [TransportRecord] {
        let calendar = Calendar.current
        return transportRecords.filter { transport in
            switch appliedRange {
            case .last7Days:
                return transport.startTime >= calendar.date(byAdding: .day, value: -7, to: Date())!
            case .last30Days:
                return transport.startTime >= calendar.date(byAdding: .day, value: -30, to: Date())!
            case .last90Days:
                return transport.startTime >= calendar.date(byAdding: .day, value: -90, to: Date())!
            case .lastYear:
                return transport.startTime >= calendar.date(byAdding: .day, value: -365, to: Date())!
            case .customYear(let year):
                return calendar.component(.year, from: transport.startTime) == year
            }
        }
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
        for footprint in allFootprints {
            guard let result = resultsByID[footprint.footprintID] else { continue }
            footprint.countryCode = result.countryCode
            footprint.countryName = result.countryName
            footprint.cityName = result.cityName
            changed = true
        }
        guard changed else { return }
        try? modelContext.save()
        // A single refresh per completed batch keeps the ranking current
        // without repeatedly rebuilding the map and every chart.
        allFootprints = Array(allFootprints)
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
    
    private func fetchData() -> Bool {
        let footprintDescriptor = FetchDescriptor<Footprint>(
            predicate: #Predicate<Footprint> { $0.statusValue != "ignored" },
            sortBy: [SortDescriptor(\Footprint.startTime, order: .reverse)]
        )
        let fetchedFootprints = (try? modelContext.fetch(footprintDescriptor)) ?? allFootprints

        let transportRecordDescriptor = FetchDescriptor<TransportRecord>(
            predicate: #Predicate<TransportRecord> { $0.statusRaw == "active" }
        )
        let fetchedTransports = (try? modelContext.fetch(transportRecordDescriptor)) ?? transportRecords
        
        let activityDescriptor = FetchDescriptor<ActivityType>(
            sortBy: [SortDescriptor(\ActivityType.sortOrder)]
        )
        let fetchedActivities = (try? modelContext.fetch(activityDescriptor)) ?? activityTypes
        
        let placeDescriptor = FetchDescriptor<Place>()
        let fetchedPlaces = (try? modelContext.fetch(placeDescriptor)) ?? allPlaces

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
            // the entire JSON blob on the main actor for every app-wide signal.
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
        let fingerprint = hasher.finalize()
        guard fingerprint != reviewSourceFingerprint else { return false }

        reviewSourceFingerprint = fingerprint
        allFootprints = fetchedFootprints
        transportRecords = fetchedTransports
        activityTypes = fetchedActivities
        allPlaces = fetchedPlaces
        return true
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
    @State private var mapPosition: MapCameraPosition
    @State private var selectedPhotoID: IdentifiableString?

    init(selection: ReviewPlaceSelection) {
        self.selection = selection
        if let coordinate = Self.representativeCoordinate(in: selection.visits) {
            _mapPosition = State(initialValue: .region(MKCoordinateRegion(
                center: coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.012, longitudeDelta: 0.012)
            )))
        } else {
            _mapPosition = State(initialValue: .automatic)
        }
    }

    private var totalDuration: TimeInterval {
        selection.visits.reduce(0) { $0 + $1.duration }
    }

    private var representativeFootprint: Footprint? {
        selection.visits.max {
            if $0.photoAssetIDs.count != $1.photoAssetIDs.count {
                return $0.photoAssetIDs.count < $1.photoAssetIDs.count
            }
            return $0.duration < $1.duration
        }
    }

    private var geographyText: String? {
        guard let footprint = representativeFootprint else { return nil }
        let values = [footprint.countryName, footprint.cityName]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return values.isEmpty ? nil : values.joined(separator: " · ")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                // Keep the title geometry alive after it scrolls offscreen;
                // LazyVStack recycles it and resets the compact-title state.
                VStack(alignment: .leading, spacing: 22) {
                if !selection.photoAssetIDs.isEmpty {
                    ContinuousTimelinePhotoThumbnail(
                        assetIDs: selection.photoAssetIDs,
                        targetSide: 520,
                        fillsAvailableSpace: true,
                        usesHighQualityThumbnail: true
                    )
                    .frame(maxWidth: .infinity)
                    .frame(height: UIDevice.current.userInterfaceIdiom == .pad ? 340 : 280)
                    .clipped()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if let firstPhotoID = selection.photoAssetIDs.first {
                            selectedPhotoID = IdentifiableString(value: firstPhotoID)
                        }
                    }
                }

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
                .padding(.top, selection.photoAssetIDs.isEmpty ? 28 : 0)

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
                            ForEach(selection.photoAssetIDs, id: \.self) { assetID in
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
            // Keep the hero photo flush with the top while the native navigation
            // bar consistently provides the title and glass close button.
            .ignoresSafeArea(.container, edges: .top)
            .background(Color.dfkBackground)
            .navigationTitle("\(selection.rangeText) · \(selection.title)")
            .navigationBarTitleDisplayMode(.inline)
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
        let visits = selection.visits.sorted { $0.startTime < $1.startTime }
        let values = visits.map { max(0, $0.duration) }
        let average = values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
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

            if let first = visits.first, let last = visits.last {
                HStack {
                    Text(first.startTime.formatted(.dateTime.year().month().day()))
                    Spacer()
                    Text(last.startTime.formatted(.dateTime.year().month().day()))
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
        ["一", "二", "三", "四", "五", "六", "日"]
    }

    private var placeWeekdayVisitCounts: [Int] {
        let calendar = Calendar.current
        var values = Array(repeating: 0, count: 7)
        for visit in selection.visits {
            let mondayFirstIndex = (calendar.component(.weekday, from: visit.startTime) + 5) % 7
            values[mondayFirstIndex] += 1
        }
        return values
    }

    private var placeHourlyVisitCounts: [Int] {
        let calendar = Calendar.current
        var values = Array(repeating: 0, count: 24)
        for visit in selection.visits {
            values[calendar.component(.hour, from: visit.startTime)] += 1
        }
        return values
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
    @Query(sort: \Place.name) private var allPlaces: [Place]
    let title: String
    let rangeText: String
    let timelineItems: [TimelineItem]
    let transportOverviewPoints: [DFKTransportOverviewPoint]
    let initialRegion: MKCoordinateRegion?
    let initialPosition: MapCameraPosition
    
    @State private var position: MapCameraPosition
    @State private var selectedPlace: ReviewPlaceSelection?
    @State private var selectedPlaceCluster: ReviewMapPlaceCluster?
    
    init(title: String, rangeText: String, timelineItems: [TimelineItem], transportOverviewPoints: [DFKTransportOverviewPoint], initialRegion: MKCoordinateRegion?, initialPosition: MapCameraPosition) {
        self.title = title
        self.rangeText = rangeText
        self.timelineItems = timelineItems
        self.transportOverviewPoints = transportOverviewPoints
        self.initialRegion = initialRegion
        self.initialPosition = initialPosition
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
                transportOverviewPoints: transportOverviewPoints,
                onTimelineItemTap: { item in
                    guard case .footprint(let footprint) = item else { return }
                    selectedPlace = placeSelection(
                        id: "review-place-\(footprint.footprintID.uuidString)",
                        footprints: [footprint]
                    )
                },
                onAggregatedFootprintTap: { aggregated in
                    let places = placeSelections(from: aggregated.footprints)
                    if places.count > 1 {
                        selectedPlaceCluster = ReviewMapPlaceCluster(id: aggregated.id, places: places)
                    } else {
                        selectedPlace = places.first
                    }
                }
            )
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
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
        .sheet(item: $selectedPlace) { selection in
            ReviewPlaceView(selection: selection)
        }
        .sheet(item: $selectedPlaceCluster) { cluster in
            ReviewMapPlaceClusterSheet(cluster: cluster)
        }
    }

    private func placeSelections(from footprints: [Footprint]) -> [ReviewPlaceSelection] {
        let grouped = Dictionary(grouping: footprints) {
            reviewIntegratedPlaceKey(for: $0, allPlaces: allPlaces)
        }
        return grouped.compactMap { key, visits in
            placeSelection(id: key, footprints: visits)
        }.sorted {
            let leftDuration = $0.visits.reduce(0) { $0 + $1.duration }
            let rightDuration = $1.visits.reduce(0) { $0 + $1.duration }
            return leftDuration > rightDuration
        }
    }

    private func placeSelection(id: String, footprints: [Footprint]) -> ReviewPlaceSelection? {
        let visits = footprints.sorted { $0.startTime > $1.startTime }
        guard let representative = visits.first else { return nil }

        let placeName = representative.placeID.flatMap { placeID in
            allPlaces.first(where: { $0.placeID == placeID })?.name
        }?.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = representative.address?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cityName = representative.cityName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = [placeName, address, cityName]
            .compactMap { $0 }
            .first { !$0.isEmpty } ?? "地点"

        var seenPhotoIDs = Set<String>()
        let storedPhotoAssetIDs = visits
            .flatMap(\.photoAssetIDs)
            .filter { seenPhotoIDs.insert($0).inserted }
        let photoAssetIDs = PhotoService.shared.displayableAssetIDs(storedPhotoAssetIDs)

        return ReviewPlaceSelection(
            id: id,
            title: title,
            rangeText: rangeText,
            visits: visits,
            photoAssetIDs: photoAssetIDs
        )
    }
}

private struct ReviewPlaceListSheet: View {
    @Environment(\.dismiss) private var dismiss
    let selection: ReviewPlaceListSelection
    @State private var selectedPlace: ReviewPlaceSelection?

    var body: some View {
        NavigationStack {
            List(selection.places) { place in
                Button {
                    selectedPlace = place
                } label: {
                    ReviewPlaceListRow(place: place)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("\(selection.rangeText) · \(selection.title)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").dfkToolbarDismissIcon()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .sheet(item: $selectedPlace) { place in
            ReviewPlaceView(selection: place)
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

private struct ReviewMapPlaceClusterSheet: View {
    @Environment(\.dismiss) private var dismiss
    let cluster: ReviewMapPlaceCluster
    @State private var selectedPlace: ReviewPlaceSelection?

    var body: some View {
        NavigationStack {
            List(cluster.places) { place in
                Button {
                    selectedPlace = place
                } label: {
                    ReviewPlaceListRow(place: place)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(cluster.places.first.map { "\($0.rangeText) · 附近地点" } ?? "附近地点")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").dfkToolbarDismissIcon()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .sheet(item: $selectedPlace) { selection in
            ReviewPlaceView(selection: selection)
        }
    }
}

struct HistoryStatisticsView_Previews: PreviewProvider {
    static var previews: some View {
        HistoryStatisticsView()
    }
}
