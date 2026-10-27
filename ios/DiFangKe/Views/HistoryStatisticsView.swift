import SwiftUI
import SwiftData
import MapKit

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

private struct ReviewPlaceSelection: Identifiable {
    let id: String
    let title: String
    let rangeText: String
    let visits: [Footprint]
    let photoAssetIDs: [String]
}

private struct ReviewActivitySlice: Identifiable {
    let id: String
    let name: String
    let duration: TimeInterval
    let color: Color
    let icon: String
}

private struct ReviewTransportSlice: Identifiable {
    let id: String
    let name: String
    let count: Int
    let distance: Double
    let color: Color
    let icon: String
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

    var onFootprintSelected: ((Footprint) -> Void)? = nil
    var onDateSelected: ((Date) -> Void)? = nil
    var onShowAllFavorites: (() -> Void)? = nil
    
    @State private var allFootprints: [Footprint] = []
    @State private var transportRecords: [TransportRecord] = []
    @State private var activityTypes: [ActivityType] = []
    @State private var allPlaces: [Place] = []
    
    @State private var selectedRange: StatisticsRange = .last30Days
    @State private var mapPosition: MapCameraPosition = .automatic
    @State private var reviewTimelineItemsCache: [TimelineItem] = []
    @State private var reviewTransportOverviewPoints: [DFKTransportOverviewPoint] = []
    @State private var reviewMemoryCandidatesCache: [ReviewMemoryCandidate] = []
    @State private var selectedReviewPlace: ReviewPlaceSelection?
    @State private var reviewRoutesReady = false
    @State private var reviewDerivedDataTask: Task<Void, Never>?
    
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
        switch selectedRange {
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
    
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 22) {
                rangePicker
                    .padding(.top, 8)

                reviewHeroSection

                if let pastMemoryFootprint {
                    pastMemorySection(pastMemoryFootprint)
                }

                memorableSection
                reviewBentoSection

                Spacer(minLength: 132)
            }
        }
        .background(Color.dfkBackground)
        .onChange(of: selectedRange) { _, _ in
            stopGeographyBackfill()
            geographicBackfillAttempts.removeAll()
            hasManuallySelectedFrequentPlaceRankScope = false
            updateDefaultFrequentPlaceRankScope()
            startReviewDerivedDataRefresh()
            updateMapPosition()
            resolveRankingGeographies()
        }
        .onReceive(NotificationCenter.default.publisher(for: .dfkShareHistoryStatistics)) { _ in
            prepareStatsShare()
        }
        .onAppear {
            fetchData()
            updateDefaultFrequentPlaceRankScope()
            startReviewDerivedDataRefresh()
            updateMapPosition()
            resolveRankingGeographies()
        }
        .onDisappear {
            stopGeographyBackfill()
            reviewDerivedDataTask?.cancel()
        }
        .fullScreenCover(isPresented: $showingFullMap) {
            FullReviewMapView(
                title: "\(statisticsRangeText) · \(reviewGeographyMetric.value)\(reviewGeographyMetric.label)",
                timelineItems: reviewTimelineItemsCache,
                transportOverviewPoints: reviewTransportOverviewPoints,
                initialPosition: mapPosition
            )
        }
        .fullScreenCover(item: $selectedReviewPlace) { selection in
            ReviewPlaceView(selection: selection)
        }
        .sheet(item: $sharePayload) { _ in
            DFKShareCardSheet(payload: $sharePayload)
        }
    }

    private func prepareStatsShare() {
        let footprints = filteredFootprints
        let coordinates = footprints.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        let loadingPayload = DFKShareCardFactory.loadingPayload(
            kind: .stats,
            rangeText: statisticsRangeText,
            coordinates: coordinates
        )
        sharePayload = loadingPayload
        let payloadID = loadingPayload.id

        let locations = getTopLocations(delta: 0.1)
        let maxIntensity = locations.map(\.count).max() ?? 1
        let heatmapPoints = locations.map {
            DFKMapView.HeatmapPoint(coordinate: $0.coord, intensity: $0.count, maxIntensity: maxIntensity)
        }

        DFKShareImageLoader.loadStatisticsHeatmapImages(points: heatmapPoints) { mapImages in
            var payload = DFKShareCardFactory.statsPayload(
                rangeText: statisticsRangeText,
                footprints: footprints,
                transports: filteredTransportRecords,
                places: allPlaces,
                activities: activityTypes
            )
            payload.contentMapImage = mapImages.light ?? mapImages.dark
            payload.contentMapLightImage = mapImages.light
            payload.contentMapDarkImage = mapImages.dark
            guard sharePayload?.id == payloadID else { return }
            payload.id = payloadID
            sharePayload = payload
        }
    }

    private var statisticsRangeText: String {
        switch selectedRange {
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

    private func pastMemorySection(_ footprint: Footprint) -> some View {
        Button {
            onDateSelected?(footprint.startTime)
        } label: {
            HStack(spacing: 14) {
                reviewThumbnail(for: footprint)
                    .frame(width: 104, height: 82)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                VStack(alignment: .leading, spacing: 6) {
                    Text("往年今日")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(pastMemoryDescription(for: footprint))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 4)

                HStack(spacing: 4) {
                    Text("看看那一天")
                    Image(systemName: "chevron.right")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.dfkAccent)
            }
            .padding(12)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
    }

    private var memorableSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            reviewSectionHeader("这段时间，值得记住", trailingTitle: nil, action: {})

            if reviewMemoryCandidatesCache.isEmpty {
                ContentUnavailableView("还没有特别突出的片段", systemImage: "sparkles", description: Text("停留、照片和新的经历积累后，会在这里自然出现"))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .padding(.horizontal, 16)
            } else {
                VStack(spacing: 12) {
                    if let first = reviewMemoryCandidatesCache.first {
                        reviewMemoryCard(first, isLarge: true)
                            .padding(.horizontal, 16)
                    }

                    if reviewMemoryCandidatesCache.count > 1 {
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 12) {
                                ForEach(Array(reviewMemoryCandidatesCache.dropFirst())) { candidate in
                                    reviewMemoryCard(candidate, isLarge: false)
                                        .frame(width: 176)
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                        .scrollClipDisabled()
                    }
                }
            }
        }
    }

    private func reviewMemoryCard(_ candidate: ReviewMemoryCandidate, isLarge: Bool) -> some View {
        Button {
            if let selection = reviewPlaceSelection(for: candidate) {
                selectedReviewPlace = selection
            } else {
                onDateSelected?(candidate.date)
            }
        } label: {
            Group {
                if isLarge {
                    ZStack(alignment: .bottomLeading) {
                        reviewMemoryArtwork(candidate)
                            .scaledToFill()
                            .frame(maxWidth: .infinity)
                            .frame(height: 248)
                            .clipped()

                        LinearGradient(
                            colors: [.clear, .black.opacity(0.12), .black.opacity(0.78)],
                            startPoint: .top,
                            endPoint: .bottom
                        )

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
                    }
                    .frame(height: 248)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        reviewMemoryArtwork(candidate)
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
            .background(Color(uiColor: .secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func reviewPlaceSelection(for candidate: ReviewMemoryCandidate) -> ReviewPlaceSelection? {
        guard let footprint = candidate.footprint else { return nil }
        let placeKey = reviewPlaceKey(for: footprint)
        let visits = filteredFootprints
            .filter { reviewPlaceKey(for: $0) == placeKey }
            .sorted { $0.startTime > $1.startTime }
        guard !visits.isEmpty else { return nil }

        var seenPhotoIDs: Set<String> = []
        let photoAssetIDs = visits
            .flatMap(\.photoAssetIDs)
            .filter { seenPhotoIDs.insert($0).inserted }
        return ReviewPlaceSelection(
            id: placeKey,
            title: reviewPlaceName(for: footprint),
            rangeText: statisticsRangeText,
            visits: visits,
            photoAssetIDs: photoAssetIDs
        )
    }

    @ViewBuilder
    private func reviewMemoryArtwork(_ candidate: ReviewMemoryCandidate) -> some View {
        if !candidate.photoAssetIDs.isEmpty {
            ContinuousTimelinePhotoThumbnail(
                assetIDs: candidate.photoAssetIDs,
                targetSide: 420,
                fillsAvailableSpace: true,
                usesHighQualityThumbnail: true
            )
        } else {
            ZStack {
                LinearGradient(colors: [Color.dfkAccent.opacity(0.26), Color.blue.opacity(0.1)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: candidate.systemImage)
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(Color.dfkAccent)
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
            reviewSectionHeader("你的生活切面", trailingTitle: nil, action: {})
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                reviewActivityCompositionCard
                reviewRhythmCard
                reviewTransportCard
                reviewRegionCard
            }
            .padding(.horizontal, 16)
        }
    }

    private var reviewActivityCompositionCard: some View {
        reviewBentoCard(title: "时间花在哪", icon: "clock.fill") {
            let slices = reviewActivitySlices
            let total = max(1, slices.reduce(0) { $0 + $1.duration })
            HStack(spacing: 12) {
                Canvas { context, size in
                    let rect = CGRect(origin: .zero, size: size).insetBy(dx: 8, dy: 8)
                    var start = Angle.degrees(-90)
                    for slice in slices.prefix(5) {
                        let sweep = Angle.degrees(360 * slice.duration / total)
                        var path = Path()
                        path.addArc(center: CGPoint(x: size.width / 2, y: size.height / 2), radius: rect.width / 2, startAngle: start, endAngle: start + sweep, clockwise: false)
                        context.stroke(path, with: .color(slice.color), style: StrokeStyle(lineWidth: 11, lineCap: .butt))
                        start += sweep
                    }
                }
                .frame(width: 76, height: 76)

                VStack(alignment: .leading, spacing: 7) {
                    ForEach(slices.prefix(3)) { slice in
                        HStack(spacing: 5) {
                            Circle().fill(slice.color).frame(width: 7, height: 7)
                            Text(slice.name).lineLimit(1)
                        }
                        .font(.caption)
                    }
                }
            }
        }
    }

    private var reviewRhythmCard: some View {
        reviewBentoCard(title: "出门节奏", icon: "waveform.path.ecg") {
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
            .frame(height: 76)
        }
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

    private var reviewTransportCard: some View {
        reviewBentoCard(title: "最常用交通", icon: "car.fill") {
            let slices = reviewTransportSlices
            let total = max(1, slices.reduce(0) { $0 + $1.count })
            VStack(alignment: .leading, spacing: 10) {
                ForEach(slices.prefix(3)) { slice in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Image(systemName: slice.icon).foregroundStyle(slice.color).frame(width: 18)
                            Text(slice.name).font(.caption).lineLimit(1)
                            Spacer()
                            Text("\(Int((Double(slice.count) / Double(total) * 100).rounded()))%")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                        }
                        Text("\(slice.count)次 · \(formatRankMileage(slice.distance))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 26)
                    }
                }
            }
        }
    }

    private var reviewRegionCard: some View {
        reviewBentoCard(title: "最常去的区域", icon: "map.fill") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(reviewTopRegions.prefix(3), id: \.name) { item in
                    HStack {
                        Text(item.name).font(.caption).lineLimit(1)
                        Spacer()
                        Text(formatRankDuration(item.duration))
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func reviewBentoCard<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: icon)
                .font(.subheadline.bold())
                .foregroundStyle(.primary)
                .symbolRenderingMode(.hierarchical)
            content()
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 154, alignment: .topLeading)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
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

    @ViewBuilder
    private func reviewThumbnail(for footprint: Footprint) -> some View {
        if !footprint.photoAssetIDs.isEmpty {
            ContinuousTimelinePhotoThumbnail(assetIDs: footprint.photoAssetIDs, targetSide: 300)
        } else {
            ZStack {
                LinearGradient(
                    colors: [Color.dfkAccent.opacity(0.28), Color.blue.opacity(0.14)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: footprint.isHighlight == true ? "bookmark.fill" : "mappin.and.ellipse")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(Color.white)
            }
        }
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
        switch selectedRange {
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

    private func buildReviewTimelineItems() -> [TimelineItem] {
        var items = filteredFootprints.map(TimelineItem.footprint)
        items.append(contentsOf: filteredTransportRecords.map { record in
            let decoded = (try? JSONDecoder().decode([CodableCoordinate].self, from: record.pointsData)) ?? []
            let pathPoints = decoded.map {
                TransportPathPoint(
                    coordinate: CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon),
                    timestamp: $0.timestamp,
                    isSyntheticPadding: $0.isSyntheticPadding ?? false
                )
            }
            let type = TransportType(rawValue: record.typeRaw) ?? .slow
            return .transport(Transport(
                id: record.recordID,
                startTime: record.startTime,
                endTime: record.endTime,
                startLocation: record.startLocation,
                endLocation: record.endLocation,
                type: type,
                distance: record.distance,
                averageSpeed: record.averageSpeed,
                points: pathPoints.map(\.coordinate),
                pathPoints: pathPoints,
                manualType: record.manualTypeRaw.flatMap(TransportType.init(rawValue:)),
                stepCount: record.stepCount
            ))
        })
        return items.sorted { $0.startTime < $1.startTime }
    }

    private func buildReviewMemoryCandidatesCooperatively() async -> [ReviewMemoryCandidate] {
        var candidates: [ReviewMemoryCandidate] = []
        let calendar = Calendar.current
        let footprintsInRange = filteredFootprints

        let historyByPlace = Dictionary(grouping: allFootprints, by: reviewPlaceKey)
        let visitsByPlace = Dictionary(grouping: footprintsInRange, by: reviewPlaceKey)
        let photosByPlace = visitsByPlace.mapValues { visits in
            Array(Set(visits.flatMap(\.photoAssetIDs)))
        }
        let durationByPlace = visitsByPlace.mapValues { $0.reduce(0) { $0 + $1.duration } }
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
        let mostPhotoPlaceKey = photosByPlace.max { $0.value.count < $1.value.count }?.key
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

            if firstVisit && footprint.photoAssetIDs.count >= AppConfig.shared.reviewMemoryFirstVisitPhotoMinCount {
                score += 6
                reason = "第一次来到这里"
                evidence = "\(footprint.photoAssetIDs.count)张照片 · \(formatRankDuration(footprint.duration))"
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
            if isPlaceRepresentative && longStayPlaceKeys.contains(placeKey) {
                let durationScore = min(4, placeDuration / AppConfig.shared.reviewMemoryLongStayMinDuration)
                score += durationScore
                if reason.isEmpty {
                    reason = placeKey == longestPlaceKey ? "这段时间最常停留" : "在这里度过了不少时间"
                    evidence = "累计\(formatRankDuration(placeDuration)) · \(placeVisitCount)次到访"
                    icon = "clock.fill"
                }
            }
            if averageDuration > 0 && footprint.duration >= averageDuration * AppConfig.shared.reviewMemoryUnusualDurationRatio {
                score += 2
            }
            if isPlaceRepresentative && placePhotoAssetIDs.count >= AppConfig.shared.reviewMemoryPhotoMinCount {
                score += min(4, Double(placePhotoAssetIDs.count) / Double(max(1, AppConfig.shared.reviewMemoryPhotoMinCount)))
                if reason.isEmpty || placeKey == mostPhotoPlaceKey {
                    reason = placeKey == mostPhotoPlaceKey ? "照片最多的地方" : "在这里留下了很多照片"
                    evidence = "累计拍了\(placePhotoAssetIDs.count)张照片"
                    icon = "photo.on.rectangle.angled"
                }
            }
            if daysSincePrevious >= AppConfig.shared.longTimeNoSeeDays {
                score += 4
                if reason.isEmpty {
                    reason = "很久以后又回来"
                    evidence = "相隔\(daysSincePrevious)天"
                    icon = "arrow.uturn.backward.circle.fill"
                }
            }
            if footprint.status == .manual || footprint.status == .confirmed { score += 0.8 }
            if footprint.isAddressEditedByHand { score += 0.8 }
            if !(footprint.reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty { score += 1.2 }
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

        var usedDays: Set<Date> = []
        var usedPlaces: Set<String> = []
        var selected: [ReviewMemoryCandidate] = []
        let rankedCandidates = candidates.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.date != $1.date { return $0.date < $1.date }
            return $0.id < $1.id
        }
        for candidate in rankedCandidates {
            let day = calendar.startOfDay(for: candidate.date)
            let placeKey = candidate.footprint.map(reviewPlaceKey)
            guard !usedDays.contains(day), placeKey.map({ !usedPlaces.contains($0) }) ?? true else { continue }
            selected.append(candidate)
            usedDays.insert(day)
            if let placeKey { usedPlaces.insert(placeKey) }
            if selected.count >= AppConfig.shared.reviewMemoryMaximumCount { break }
        }
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
        if let placeID = footprint.placeID { return "place:\(placeID.uuidString)" }
        let factor = 1_000.0
        return "coordinate:\((footprint.latitude * factor).rounded() / factor),\((footprint.longitude * factor).rounded() / factor)"
    }

    private var reviewActivitySlices: [ReviewActivitySlice] {
        var totals: [String: TimeInterval] = [:]
        for footprint in filteredFootprints {
            guard let activity = footprint.getActivityType(from: activityTypes) else { continue }
            totals[activity.name, default: 0] += footprint.duration
        }
        return totals.compactMap { name, duration in
            guard let activity = activityTypes.first(where: { $0.name == name }) else { return nil }
            return ReviewActivitySlice(id: name, name: name, duration: duration, color: activity.color, icon: activity.icon)
        }.sorted { $0.duration > $1.duration }
    }

    private var reviewTransportSlices: [ReviewTransportSlice] {
        var counts: [TransportType: Int] = [:]
        var distances: [TransportType: Double] = [:]
        for record in filteredTransportRecords {
            let type = record.manualTypeRaw.flatMap(TransportType.init(rawValue:)) ?? TransportType(rawValue: record.typeRaw) ?? .slow
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

    private func pastMemoryDescription(for footprint: Footprint) -> String {
        let years = max(1, Calendar.current.dateComponents([.year], from: footprint.startTime, to: Date()).year ?? 1)
        return "\(years)年前的今天，你在\(reviewPlaceName(for: footprint))停留了\(formatRankDuration(footprint.duration))"
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
        switch selectedRange {
        case .last7Days: return calendar.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        case .last30Days: return calendar.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        case .last90Days: return calendar.date(byAdding: .day, value: -90, to: Date()) ?? Date()
        case .lastYear: return calendar.date(byAdding: .day, value: -365, to: Date()) ?? Date()
        case .customYear(let year): return calendar.date(from: DateComponents(year: year, month: 1, day: 1)) ?? Date()
        }
    }

    private var reviewRangeEnd: Date {
        if case .customYear(let year) = selectedRange {
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
    
    private func updateAiSummary() {
        guard isAiAssistantEnabled else { return }
        
        let key = selectedRange.rawValue
        if let cachedData = summaryCache[key],
           let text = cachedData["text"] as? String,
           let timestamp = cachedData["timestamp"] as? Double {
            
            let date = Date(timeIntervalSince1970: timestamp)
            let expiration = getExpirationFor(selectedRange)
            
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
        let rangeAtStart = selectedRange
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
                guard rangeAtStart == self.selectedRange,
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

    private func startReviewDerivedDataRefresh() {
        reviewDerivedDataTask?.cancel()

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

        // Footprints are immediately renderable. Route JSON decoding is the
        // expensive part and must never run on the main actor.
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
                for transport in decoded {
                    for point in transport.points where point.isSyntheticPadding != true {
                        guard point.lat.isFinite, point.lon.isFinite,
                              (-90...90).contains(point.lat), (-180...180).contains(point.lon),
                              !(point.lat == 0 && point.lon == 0) else { continue }
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
                return (decoded, overviewPoints)
            }.value

            let candidates = await buildReviewMemoryCandidatesCooperatively()
            guard !Task.isCancelled else { return }
            reviewMemoryCandidatesCache = candidates
            saveCachedReviewMemories(candidates)

            let (decoded, overviewPoints) = await decodedResult
            guard !Task.isCancelled else { return }
            reviewTransportOverviewPoints = overviewPoints
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
            reviewTimelineItemsCache = (footprintsInRange.map(TimelineItem.footprint) + transportItems)
                .sorted { $0.startTime < $1.startTime }
            reviewRoutesReady = true
        }
    }

    private var reviewMemoryCacheKey: String {
        "review.memory.v3.\(selectedRange.rawValue)"
    }

    private func loadCachedReviewMemories() -> [ReviewMemoryCandidate] {
        guard let data = UserDefaults.standard.data(forKey: reviewMemoryCacheKey),
              let payload = try? JSONDecoder().decode(ReviewMemoryCachePayload.self, from: data) else { return [] }
        let footprintsByID = Dictionary(uniqueKeysWithValues: allFootprints.map { ($0.footprintID, $0) })
        return payload.entries.filter { !$0.photoAssetIDs.isEmpty }.map { entry in
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
        let entries = candidates.filter { !$0.photoAssetIDs.isEmpty }.map {
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
    
    private func updateMapPosition() {
        var coords = filteredFootprints.map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        }
        for record in filteredTransportRecords {
            let decoded = (try? JSONDecoder().decode([CodableCoordinate].self, from: record.pointsData)) ?? []
            let step = max(1, decoded.count / 300)
            coords.append(contentsOf: stride(from: 0, to: decoded.count, by: step).map {
                CLLocationCoordinate2D(latitude: decoded[$0].lat, longitude: decoded[$0].lon)
            })
        }
        coords = coords.filter(\.isRenderableMapCoordinate)
        guard !coords.isEmpty else { return }
        
        withAnimation(.easeInOut(duration: 1.0)) {
            mapPosition = .region(getRegion(for: coords))
        }
    }
    
    private func getRegion(for coords: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
        let lats = coords.map { $0.latitude }
        let lons = coords.map { $0.longitude }
        
        let center = CLLocationCoordinate2D(
            latitude: (lats.min()! + lats.max()!) / 2,
            longitude: (lons.min()! + lons.max()!) / 2
        )
        
        let delta = max(0.015, (lats.max()! - lats.min()!) * 1.6)
        let deltaLon = max(0.015, (lons.max()! - lons.min()!) * 1.6)
        
        return MKCoordinateRegion(center: center, span: MKCoordinateSpan(latitudeDelta: delta, longitudeDelta: deltaLon))
    }
    
    private var rangePicker: some View {
        Picker("时间范围", selection: $selectedRange) {
            Text("7天").tag(StatisticsRange.last7Days)
            Text("30天").tag(StatisticsRange.last30Days)
            Text("90天").tag(StatisticsRange.last90Days)
            Text("1年").tag(StatisticsRange.lastYear)
            Text(isCustomYear ? "\(String(activeYearForSegment)) ▾" : "年份 ▾").tag(StatisticsRange.customYear(activeYearForSegment))
        }
        .pickerStyle(.segmented)
        .overlay(
            GeometryReader { geo in
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
                            Color.white.opacity(0.001) // 完全透明，用于拦截第五个分段的点击
                        }
                        .frame(width: geo.size.width / 5)
                    }
                }
            }
        )
        .padding(.horizontal, 20)
        .onAppear {
            if activeYearForSegment == Calendar.current.component(.year, from: Date()) && !availableYears.isEmpty {
                activeYearForSegment = availableYears.first ?? Calendar.current.component(.year, from: Date())
            }
        }
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
                        HStack(spacing: 12) {
                            // Rank number
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
                        }
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
        let id = UUID()
        let name: String
        let address: String
        let count: Int
        let duration: TimeInterval
    }
    
    private func getFrequentPlacesData() -> [FrequentPlaceItem] {
        requestMissingRankingGeographies()
        var groups: [String: (name: String, address: String, count: Int, duration: TimeInterval)] = [:]
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
                for: frequentPlaceRankScope,
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
            if name.isEmpty || name.contains("未知") || (frequentPlaceRankScope == .place && address.isEmpty) { continue }
            
            let subtitle: String
            let key: String
            switch frequentPlaceRankScope {
            case .country:
                subtitle = ""
                key = fp.countryCode ?? name
            case .city:
                subtitle = hasMultipleCountries ? simplifiedChineseName(fp.countryName ?? "") : ""
                key = "\(fp.countryCode ?? "")|\(name)"
            case .place:
                subtitle = address
                key = name
            }
            if let existing = groups[key] {
                groups[key] = (existing.name, existing.address, existing.count + 1, existing.duration + fp.duration)
            } else {
                groups[key] = (name, subtitle, 1, fp.duration)
            }
        }
        
        return groups.values
            .filter {
                frequentPlaceRankScope != .place || $0.duration >= 3600
            }
            .map { FrequentPlaceItem(name: $0.name, address: $0.address, count: $0.count, duration: $0.duration) }
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
            switch selectedRange {
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
    
    private func fetchData() {
        let footprintDescriptor = FetchDescriptor<Footprint>(
            predicate: #Predicate<Footprint> { $0.statusValue != "ignored" },
            sortBy: [SortDescriptor(\Footprint.startTime, order: .reverse)]
        )
        if let fetched = try? modelContext.fetch(footprintDescriptor) {
            allFootprints = fetched
        }

        let transportRecordDescriptor = FetchDescriptor<TransportRecord>(
            predicate: #Predicate<TransportRecord> { $0.statusRaw == "active" }
        )
        if let fetched = try? modelContext.fetch(transportRecordDescriptor) {
            transportRecords = fetched
        }
        
        let activityDescriptor = FetchDescriptor<ActivityType>(
            sortBy: [SortDescriptor(\ActivityType.sortOrder)]
        )
        if let fetched = try? modelContext.fetch(activityDescriptor) {
            activityTypes = fetched
        }
        
        let placeDescriptor = FetchDescriptor<Place>()
        if let fetched = try? modelContext.fetch(placeDescriptor) {
            allPlaces = fetched
        }
    }
}

private struct ReviewPlaceView: View {
    @Environment(\.dismiss) private var dismiss
    let selection: ReviewPlaceSelection
    @State private var mapPosition: MapCameraPosition

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
                LazyVStack(alignment: .leading, spacing: 22) {
                    if !selection.photoAssetIDs.isEmpty {
                        ContinuousTimelinePhotoThumbnail(
                            assetIDs: selection.photoAssetIDs,
                            targetSide: 520,
                            fillsAvailableSpace: true,
                            usesHighQualityThumbnail: true
                        )
                        .frame(maxWidth: .infinity)
                        .frame(height: 238)
                        .clipped()
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
                                columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3),
                                spacing: 4
                            ) {
                                ForEach(Array(selection.photoAssetIDs.prefix(9)), id: \.self) { assetID in
                                    ContinuousTimelinePhotoThumbnail(
                                        assetIDs: [assetID],
                                        targetSide: 220,
                                        fillsAvailableSpace: true,
                                        usesHighQualityThumbnail: true
                                    )
                                    .aspectRatio(1, contentMode: .fit)
                                    .clipped()
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }
                        .padding(.horizontal, 18)
                    }

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
            .ignoresSafeArea(edges: .top)
            .navigationTitle("地点")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").dfkToolbarDismissIcon()
                    }
                }
            }
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

    private func visitRow(_ footprint: Footprint) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 2) {
                Text(footprint.startTime.formatted(.dateTime.month(.abbreviated)))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(footprint.startTime.formatted(.dateTime.day()))
                    .font(.title3.bold())
            }
            .frame(width: 42)

            VStack(alignment: .leading, spacing: 5) {
                Text("\(footprint.startTime.formatted(.dateTime.hour().minute()))–\(footprint.endTime.formatted(.dateTime.hour().minute()))")
                    .font(.headline)
                Text("停留 \(placeDurationText(footprint.duration))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if !footprint.photoAssetIDs.isEmpty {
                    Label("\(footprint.photoAssetIDs.count)张照片", systemImage: "photo")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let reason = footprint.reason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty {
                    Text(reason)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            Spacer(minLength: 0)
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
    let timelineItems: [TimelineItem]
    let transportOverviewPoints: [DFKTransportOverviewPoint]
    let initialPosition: MapCameraPosition
    
    @State private var position: MapCameraPosition
    
    init(title: String, timelineItems: [TimelineItem], transportOverviewPoints: [DFKTransportOverviewPoint], initialPosition: MapCameraPosition) {
        self.title = title
        self.timelineItems = timelineItems
        self.transportOverviewPoints = transportOverviewPoints
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
                transportOverviewPoints: transportOverviewPoints
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
    }
}

struct HistoryStatisticsView_Previews: PreviewProvider {
    static var previews: some View {
        HistoryStatisticsView()
    }
}
