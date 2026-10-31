import SwiftUI
import UIKit

// MARK: - Template catalog

/// Footprint shares (one stay or a stretch of everyday life): what the time
/// was spent on, rather than where the route went.
enum DFKFootprintShareTemplate: String, CaseIterable, Identifiable {
    case dial
    case nightMap
    case receipt
    case foldedMap
    case polaroid
    case postcard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dial: return "时间表盘"
        case .nightMap: return "夜行地图"
        case .foldedMap: return "漫游地图"
        case .receipt: return "生活小票"
        case .polaroid: return "拍立得"
        case .postcard: return "明信片"
        }
    }
}

/// Review shares: a period summed up as numbers, proportions and rhythm.
enum DFKReviewShareTemplate: String, CaseIterable, Identifiable {
    case wrapped
    case poster
    case nutrition
    case atlas
    case vinyl
    case album

    var id: String { rawValue }

    var title: String {
        switch self {
        case .wrapped: return "数字年报"
        case .poster: return "足迹海报"
        case .atlas: return "生活地图集"
        case .nutrition: return "生活成分表"
        case .vinyl: return "生活唱片"
        case .album: return "回忆相册"
        }
    }
}

enum DFKShareTemplate: Hashable, Identifiable {
    case trip(DFKTripShareTemplate)
    case footprint(DFKFootprintShareTemplate)
    case review(DFKReviewShareTemplate)

    var id: String {
        switch self {
        case .trip(let template): return "trip.\(template.rawValue)"
        case .footprint(let template): return "footprint.\(template.rawValue)"
        case .review(let template): return "review.\(template.rawValue)"
        }
    }

    var title: String {
        switch self {
        case .trip(let template): return template.title
        case .footprint(let template): return template.title
        case .review(let template): return template.title
        }
    }
}

extension DFKShareCardPayload {
    var shareTemplates: [DFKShareTemplate] {
        if isTripShare {
            return tripSummary == nil ? [] : DFKTripShareTemplate.allCases.map { .trip($0) }
        }
        switch kind {
        case .moment, .timeline: return DFKFootprintShareTemplate.allCases.map { .footprint($0) }
        case .stats: return DFKReviewShareTemplate.allCases.map { .review($0) }
        }
    }

    var usesTemplates: Bool { !shareTemplates.isEmpty }

    var template: DFKShareTemplate {
        get {
            if isTripShare { return .trip(tripTemplate) }
            switch kind {
            case .moment, .timeline: return .footprint(footprintTemplate)
            case .stats: return .review(reviewTemplate)
            }
        }
        set {
            switch newValue {
            case .trip(let template): tripTemplate = template
            case .footprint(let template): footprintTemplate = template
            case .review(let template): reviewTemplate = template
            }
        }
    }

    var templatePixelSize: CGSize {
        if case .trip(let template) = template { return template.pixelSize(for: tripSummary) }
        return CGSize(width: 1080, height: 1920)
    }
}

// MARK: - Shared drawing

/// Units, type and brand footer shared by every template. Templates are drawn
/// on a 360 pt artboard and rendered on a 1080 wide canvas.
struct DFKShareTemplateStyle {
    var displayScale: CGFloat
    var brandName: String
    var brandSlogan: String

    /// Point sizes of the template map snapshots. Markers keep a fixed point
    /// size, so each matches its map frame on the 360 pt artboard exactly:
    /// templates show the whole snapshot and never crop markers away.
    /// The wide map is used dark, the tall one light.
    static let wideMapSize = CGSize(width: 360, height: 270)
    static let tallMapSize = CGSize(width: 360, height: 400)
    /// The portrait map fills most of a card read at arm's length, so its
    /// markers are drawn larger than on the in-card strip map.
    static let portraitMapMarkerBoost: CGFloat = 1.8

    func u(_ value: CGFloat) -> CGFloat { value * 3 * displayScale }

    /// A map frame `width` artboard points wide with the snapshot's own
    /// aspect, so nothing is cropped.
    func mapFrame(width: CGFloat, snapshot: CGSize) -> CGSize {
        CGSize(width: u(width), height: u(width * snapshot.height / snapshot.width))
    }

    func serif(_ size: CGFloat, _ weight: Font.Weight = .black) -> Font {
        .system(size: u(size), weight: weight, design: .serif)
    }

    func mono(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        .system(size: u(size), weight: weight, design: .monospaced)
    }

    func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: u(size), weight: weight)
    }

    func photoTile(_ image: UIImage?, fallback: Color) -> some View {
        fallback
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            }
            .clipped()
    }

    func footer<QRCode: View>(qrCode: QRCode, foreground: Color, secondary: Color) -> some View {
        HStack(alignment: .center, spacing: u(10)) {
            Image("AppLogo")
                .resizable()
                .scaledToFit()
                .frame(width: u(30), height: u(30))
                .clipShape(RoundedRectangle(cornerRadius: u(7)))
            VStack(alignment: .leading, spacing: u(1)) {
                Text(brandName)
                    .font(sans(13, .semibold))
                    .foregroundStyle(foreground)
                Text(brandSlogan)
                    .font(sans(10))
                    .foregroundStyle(secondary)
            }
            Spacer(minLength: 0)
            qrCode.frame(width: u(44), height: u(44))
        }
    }
}

/// Tear-off edge along the bottom of a receipt.
private struct DFKReceiptEdge: Shape {
    var toothWidth: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let count = max(1, Int(rect.width / max(toothWidth, 1)))
        let step = rect.width / CGFloat(count)
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        for index in 0..<count {
            let x = rect.minX + CGFloat(index) * step
            path.addLine(to: CGPoint(x: x + step / 2, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + step, y: rect.minY))
        }
        path.closeSubpath()
        return path
    }
}

// MARK: - Footprint templates

struct DFKFootprintShareTemplateView<QRCode: View>: View {
    let template: DFKFootprintShareTemplate
    let payload: DFKShareCardPayload
    var displayScale: CGFloat = 1
    let qrCode: QRCode

    private struct Place {
        var title: String
        var timeText: String
        var tag: String?
        var icon: String?
        var color: Color
        var detail: String?
        var intervals: [(start: Date, end: Date)]
        var stay: TimeInterval
        var cityName: String?
    }

    private struct Photo {
        var image: UIImage
        var caption: String?
    }

    private var style: DFKShareTemplateStyle {
        DFKShareTemplateStyle(displayScale: displayScale, brandName: payload.brandName, brandSlogan: payload.brandSlogan)
    }

    private func u(_ value: CGFloat) -> CGFloat { style.u(value) }
    private func serif(_ size: CGFloat, _ weight: Font.Weight = .black) -> Font { style.serif(size, weight) }
    private func mono(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font { style.mono(size, weight) }
    private func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { style.sans(size, weight) }

    var body: some View {
        Group {
            switch template {
            case .dial: dial
            case .nightMap: nightMap
            case .receipt: receipt
            case .foldedMap: foldedMap
            case .polaroid: polaroid
            case .postcard: postcard
            }
        }
        .frame(width: 1080 * displayScale, height: 1920 * displayScale)
        .clipped()
    }

    // MARK: Data

    /// Only the places still switched on in the share list.
    private var places: [Place] {
        let footprintsByID = Dictionary(payload.mapFootprints.map { ($0.footprintID, $0) }, uniquingKeysWith: { first, _ in first })
        return payload.entries.filter(\.isIncluded).map { entry in
            let footprints = entry.footprintIDs.compactMap { footprintsByID[$0] }
            let intervals = footprints.map { (start: $0.startTime, end: $0.endTime) }
            return Place(
                title: entry.title,
                timeText: entry.time,
                tag: entry.tag,
                icon: entry.activityIcon,
                color: entry.activityColor ?? Color.dfkAccent,
                detail: entry.detail.flatMap { $0.isEmpty ? nil : $0 },
                intervals: intervals,
                stay: footprints.reduce(0) { $0 + $1.duration },
                cityName: footprints.first?.cityName
            )
        }
    }

    /// Photos of the included places, captioned with the place they were taken at.
    private var photos: [Photo] {
        let hasAssetIDs = payload.heroImageAssetIDs.count == payload.heroImages.count
        guard hasAssetIDs else { return payload.heroImages.map { Photo(image: $0, caption: nil) } }
        let includedIDs = Set(payload.entries.filter(\.isIncluded).flatMap(\.footprintIDs))
        var placeByAssetID: [String: (title: String, isIncluded: Bool)] = [:]
        for entry in payload.entries {
            for footprint in payload.mapFootprints where entry.footprintIDs.contains(footprint.footprintID) {
                for assetID in footprint.photoAssetIDs {
                    placeByAssetID[assetID] = (entry.title, includedIDs.contains(footprint.footprintID))
                }
            }
        }
        return zip(payload.heroImages, payload.heroImageAssetIDs).compactMap { image, assetID in
            let place = placeByAssetID[assetID]
            if place?.isIncluded == false { return nil }
            return Photo(image: image, caption: place?.title)
        }
    }

    private var mapImage: UIImage? {
        payload.contentMapLightImage ?? payload.contentMapImage ?? payload.backgroundMapLightImage
    }

    private var moveDistance: Double {
        payload.mapTransports.reduce(0) { $0 + $1.distance }
    }

    private var cityName: String {
        let names = places.compactMap(\.cityName).filter { !$0.isEmpty }
        return names.first ?? payload.locationText?.components(separatedBy: "·").last?.components(separatedBy: "、").first ?? "这里"
    }

    private func durationText(_ seconds: TimeInterval) -> String {
        DFKTripShareSummary.durationText(seconds)
    }

    private func header(ink: Color, muted: Color) -> some View {
        VStack(alignment: .leading, spacing: u(6)) {
            Text(payload.rangeText).font(mono(11, .semibold)).tracking(u(1)).foregroundStyle(muted)
            Text(payload.title).font(serif(26)).foregroundStyle(ink).lineLimit(2).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Dial

    /// The day as a 24-hour clock face: each stay is an arc in its activity
    /// colour, travel runs on the inner ring. Several days overlay by hour.
    private var dial: some View {
        let paper = Color(red: 0.96, green: 0.94, blue: 0.90)
        let ink = Color(red: 0.13, green: 0.13, blue: 0.12)
        let muted = Color(red: 0.45, green: 0.43, blue: 0.40)
        let diameter = u(250)
        let ring = u(26)
        let places = places
        let calendar = Calendar.current
        func fraction(_ date: Date, from dayStart: Date) -> Double {
            date.timeIntervalSince(dayStart) / 86_400
        }
        func arcs(_ intervals: [(start: Date, end: Date)]) -> [(from: Double, to: Double)] {
            intervals.compactMap { interval in
                let dayStart = calendar.startOfDay(for: interval.start)
                let from = max(0, fraction(interval.start, from: dayStart))
                let to = min(1, fraction(interval.end, from: dayStart))
                guard to > from else { return nil }
                return (from, max(to, from + 0.004))
            }
        }
        let stayArcs = places.flatMap { place in arcs(place.intervals).map { (arc: $0, color: place.color) } }
        let moveArcs = arcs(payload.mapTransports.map { (start: $0.startTime, end: $0.endTime) })
        let totalStay = places.reduce(0) { $0 + $1.stay }
        let legend = Array(activityTotals(places).prefix(4))
        let labelRadius = diameter / 2 + ring / 2 + u(16)

        return VStack(alignment: .leading, spacing: u(18)) {
            header(ink: ink, muted: muted)
            ZStack {
                Circle().stroke(ink.opacity(0.07), lineWidth: ring)
                ForEach(Array(stayArcs.enumerated()), id: \.offset) { _, item in
                    Circle()
                        .trim(from: item.arc.from, to: item.arc.to)
                        .stroke(item.color, style: StrokeStyle(lineWidth: ring, lineCap: .butt))
                        .rotationEffect(.degrees(-90))
                }
                ForEach(Array(moveArcs.enumerated()), id: \.offset) { _, arc in
                    Circle()
                        .trim(from: arc.from, to: arc.to)
                        .stroke(ink, style: StrokeStyle(lineWidth: u(4), lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(ring / 2 + u(9))
                }
                ForEach(0..<24, id: \.self) { hour in
                    Rectangle()
                        .fill(ink.opacity(hour.isMultiple(of: 6) ? 0.8 : 0.25))
                        .frame(width: u(1.5), height: u(hour.isMultiple(of: 6) ? 9 : 4))
                        .offset(y: -(diameter / 2 + ring / 2 + u(5)))
                        .rotationEffect(.degrees(Double(hour) * 15))
                }
                ForEach([0, 6, 12, 18], id: \.self) { hour in
                    let angle = Double(hour) / 24 * 2 * .pi
                    Text("\(hour)")
                        .font(mono(10, .semibold))
                        .foregroundStyle(muted)
                        .offset(x: labelRadius * CGFloat(sin(angle)), y: -labelRadius * CGFloat(cos(angle)))
                }
                if let photo = photos.first {
                    style.photoTile(photo.image, fallback: muted)
                        .frame(width: u(132), height: u(132))
                        .clipShape(Circle())
                        .overlay(Circle().stroke(paper, lineWidth: u(4)))
                } else {
                    VStack(spacing: u(2)) {
                        Text("\(places.count)").font(serif(44)).foregroundStyle(ink)
                        Text("个地方").font(sans(11, .semibold)).foregroundStyle(muted)
                    }
                }
            }
            .frame(width: diameter, height: diameter)
            .frame(maxWidth: .infinity)
            .padding(.vertical, u(22))

            VStack(alignment: .leading, spacing: u(8)) {
                ForEach(Array(legend.enumerated()), id: \.offset) { _, item in
                    HStack(spacing: u(8)) {
                        Circle().fill(item.color).frame(width: u(9), height: u(9))
                        Text(item.name).font(sans(12, .semibold)).foregroundStyle(ink)
                        Spacer(minLength: u(8))
                        Text(durationText(item.stay)).font(mono(11, .medium)).foregroundStyle(muted)
                    }
                }
            }

            Spacer(minLength: 0)
            HStack(alignment: .top) {
                dialStat("\(places.count)", "停留地点", ink: ink, muted: muted)
                dialStat(durationText(totalStay), "停留时长", ink: ink, muted: muted)
                if moveDistance > 0 {
                    dialStat(DFKTripShareSummary.distanceText(moveDistance), "移动距离", ink: ink, muted: muted)
                }
            }
            .padding(.top, u(12))
            .overlay(alignment: .top) { Rectangle().fill(ink.opacity(0.15)).frame(height: max(1, u(0.5))) }
            style.footer(qrCode: qrCode, foreground: ink, secondary: muted)
        }
        .padding(.horizontal, u(24))
        .padding(.top, u(28))
        .padding(.bottom, u(22))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(paper)
    }

    /// Stay time per activity, longest first.
    private func activityTotals(_ places: [Place]) -> [(name: String, icon: String?, color: Color, stay: TimeInterval)] {
        var totals: [(name: String, icon: String?, color: Color, stay: TimeInterval)] = []
        for place in places {
            let name = place.tag ?? "其他"
            if let index = totals.firstIndex(where: { $0.name == name }) {
                totals[index].stay += place.stay
            } else {
                totals.append((name, place.icon, place.color, place.stay))
            }
        }
        return totals.sorted { $0.stay > $1.stay }
    }

    // MARK: Night map

    /// The day's own map at night: the route glows on top, the stops run
    /// down underneath as a timeline, photos float on the map.
    private var nightMap: some View {
        let ground = Color(red: 0.05, green: 0.07, blue: 0.10)
        let paper = Color(red: 0.95, green: 0.96, blue: 0.97)
        let muted = Color(red: 0.58, green: 0.63, blue: 0.68)
        let accent = Color(red: 0.98, green: 0.78, blue: 0.36)
        let places = places
        let rows = Array(places.prefix(4))
        let bubbles = Array(photos.prefix(3))
        let mapSize = style.mapFrame(width: 360, snapshot: DFKShareTemplateStyle.wideMapSize)
        let map = payload.templateWideMapImage ?? payload.contentMapDarkImage ?? payload.backgroundMapDarkImage

        return VStack(alignment: .leading, spacing: 0) {
            header(ink: paper, muted: muted)
                .padding(.horizontal, u(24))
                .padding(.top, u(28))
                .padding(.bottom, u(10))
            // Only the outer edges fade, so no marker is hidden.
            style.photoTile(map, fallback: ground)
                .frame(width: mapSize.width, height: mapSize.height)
                .overlay {
                    LinearGradient(
                        stops: [
                            .init(color: ground, location: 0),
                            .init(color: .clear, location: 0.08),
                            .init(color: .clear, location: 0.92),
                            .init(color: ground, location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }

            HStack(alignment: .top, spacing: u(12)) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, place in
                        HStack(alignment: .top, spacing: u(12)) {
                            VStack(spacing: 0) {
                                Circle()
                                    .fill(place.color)
                                    .frame(width: u(22), height: u(22))
                                    .overlay(Image(systemName: place.icon ?? "mappin").font(sans(10, .bold)).foregroundStyle(.white))
                                if index < rows.count - 1 {
                                    Rectangle().fill(muted.opacity(0.4)).frame(width: u(1.5)).frame(maxHeight: .infinity)
                                }
                            }
                            VStack(alignment: .leading, spacing: u(2)) {
                                Text(place.timeText).font(mono(10, .semibold)).foregroundStyle(accent)
                                Text(place.title).font(sans(13, .semibold)).foregroundStyle(paper).lineLimit(1)
                            }
                            .padding(.bottom, u(12))
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    if places.count > rows.count {
                        Text("还有 \(places.count - rows.count) 个地方")
                            .font(sans(10))
                            .foregroundStyle(muted)
                            .padding(.leading, u(34))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if !bubbles.isEmpty {
                    VStack(spacing: u(8)) {
                        ForEach(Array(bubbles.enumerated()), id: \.offset) { _, photo in
                            style.photoTile(photo.image, fallback: muted)
                                .frame(width: u(52), height: u(52))
                                .clipShape(Circle())
                                .overlay(Circle().stroke(paper, lineWidth: u(2)))
                        }
                    }
                }
            }
            .padding(.horizontal, u(24))
            .padding(.top, u(10))

            Spacer(minLength: 0)
            style.footer(qrCode: qrCode, foreground: paper, secondary: muted)
                .padding(.horizontal, u(24))
                .padding(.bottom, u(22))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(ground)
    }

    // MARK: Folded map

    /// A printed city walking map: fold creases, compass, scale bar and a
    /// legend of what each colour meant that day.
    private var foldedMap: some View {
        let paper = Color(red: 0.97, green: 0.95, blue: 0.90)
        let ink = Color(red: 0.16, green: 0.20, blue: 0.24)
        let muted = Color(red: 0.47, green: 0.48, blue: 0.47)
        let accent = Color(red: 0.80, green: 0.30, blue: 0.22)
        let mapSize = style.mapFrame(width: 312, snapshot: DFKShareTemplateStyle.tallMapSize)
        let legend = Array(activityTotals(places).prefix(6))
        let legendRows = stride(from: 0, to: legend.count, by: 2).map { Array(legend[$0..<min($0 + 2, legend.count)]) }
        let map = payload.templateTallMapImage ?? payload.contentMapLightImage ?? payload.backgroundMapLightImage

        return VStack(alignment: .leading, spacing: u(14)) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: u(3)) {
                    Text("\(cityName) 漫游图").font(serif(26)).foregroundStyle(ink).lineLimit(1).minimumScaleFactor(0.6)
                    Text("\(payload.rangeText) · \(payload.title)").font(mono(9.5, .semibold)).foregroundStyle(muted).lineLimit(1)
                }
                Spacer(minLength: u(8))
                VStack(spacing: u(1)) {
                    Text("N").font(mono(9)).foregroundStyle(ink)
                    Image(systemName: "location.north.fill").font(sans(16, .bold)).foregroundStyle(accent)
                }
                .frame(width: u(36), height: u(36))
                .overlay(Circle().stroke(ink, lineWidth: u(1)))
            }
            ZStack(alignment: .bottomLeading) {
                style.photoTile(map, fallback: muted.opacity(0.2))
                    .frame(width: mapSize.width, height: mapSize.height)
                // Three vertical panels and one horizontal crease, like a map unfolded.
                HStack(spacing: 0) {
                    ForEach(0..<3, id: \.self) { panel in
                        LinearGradient(
                            colors: panel.isMultiple(of: 2)
                                ? [.black.opacity(0.10), .clear, .white.opacity(0.10)]
                                : [.white.opacity(0.12), .clear, .black.opacity(0.12)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    }
                }
                Rectangle()
                    .fill(.black.opacity(0.10))
                    .frame(height: max(1, u(0.8)))
                    .frame(maxHeight: .infinity, alignment: .center)
                if moveDistance > 0 {
                    HStack(spacing: u(6)) {
                        HStack(spacing: 0) {
                            Rectangle().fill(ink).frame(width: u(22), height: u(4))
                            Rectangle().fill(Color.white).frame(width: u(22), height: u(4))
                        }
                        .overlay(Rectangle().stroke(ink, lineWidth: max(1, u(0.6))))
                        Text("移动 \(DFKTripShareSummary.distanceText(moveDistance))").font(mono(9)).foregroundStyle(ink)
                    }
                    .padding(u(7))
                    .background(paper.opacity(0.92))
                    .padding(u(10))
                }
            }
            .frame(width: mapSize.width, height: mapSize.height)
            .clipped()
            .overlay(Rectangle().stroke(ink, lineWidth: u(1.5)))

            VStack(alignment: .leading, spacing: u(7)) {
                Text("图例 LEGEND").font(mono(9)).tracking(u(1)).foregroundStyle(muted)
                ForEach(Array(legendRows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: u(12)) {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, item in
                            HStack(spacing: u(6)) {
                                Image(systemName: item.icon ?? "mappin")
                                    .font(sans(9, .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: u(18), height: u(18))
                                    .background(item.color, in: Circle())
                                Text(item.name).font(sans(11, .semibold)).foregroundStyle(ink).lineLimit(1)
                                Spacer(minLength: u(4))
                                Text(durationText(item.stay)).font(mono(9.5, .medium)).foregroundStyle(muted)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        if row.count == 1 { Spacer().frame(maxWidth: .infinity) }
                    }
                }
            }

            Spacer(minLength: 0)
            style.footer(qrCode: qrCode, foreground: ink, secondary: muted)
        }
        .padding(.horizontal, u(24))
        .padding(.top, u(26))
        .padding(.bottom, u(22))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(paper)
    }

    private func dialStat(_ value: String, _ label: String, ink: Color, muted: Color) -> some View {
        VStack(alignment: .leading, spacing: u(2)) {
            Text(value).font(mono(16)).foregroundStyle(ink).lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(sans(10)).foregroundStyle(muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Receipt

    /// A shop receipt for the day: every place is a line item priced in time.
    private var receipt: some View {
        let ground = Color(red: 0.84, green: 0.87, blue: 0.88)
        let paper = Color.white
        let ink = Color(red: 0.12, green: 0.12, blue: 0.13)
        let muted = Color(red: 0.45, green: 0.47, blue: 0.49)
        let places = places
        let rows = Array(places.prefix(8))
        let totalStay = places.reduce(0) { $0 + $1.stay }
        let photo = photos.first
        let dashed = DFKShareRuleLine()
            .stroke(style: StrokeStyle(lineWidth: u(1), dash: [u(3), u(3)]))
            .foregroundStyle(muted.opacity(0.6))
            .frame(height: u(1))

        return VStack(spacing: u(18)) {
            VStack(alignment: .leading, spacing: u(10)) {
                HStack(alignment: .top, spacing: u(10)) {
                    VStack(alignment: .leading, spacing: u(5)) {
                        Text("地方客 · 生活小票").font(mono(15))
                        Text("LIFE RECEIPT").font(mono(9, .medium)).tracking(u(3)).foregroundStyle(muted)
                        Text(payload.rangeText).font(mono(10, .medium)).padding(.top, u(6))
                        if let location = payload.locationText {
                            Text(location).font(mono(9, .medium)).foregroundStyle(muted).lineLimit(2)
                        }
                    }
                    Spacer(minLength: 0)
                    if let photo {
                        style.photoTile(photo.image, fallback: muted)
                            .frame(width: u(78), height: u(78))
                            .padding(u(4))
                            .background(paper)
                            .overlay(alignment: .top) {
                                Rectangle().fill(Color(red: 0.95, green: 0.88, blue: 0.62).opacity(0.85))
                                    .frame(width: u(36), height: u(11))
                                    .rotationEffect(.degrees(-6))
                                    .offset(y: -u(5))
                            }
                            .shadow(color: .black.opacity(0.18), radius: u(3), y: u(1))
                            .rotationEffect(.degrees(6))
                    }
                }
                dashed
                HStack {
                    Text("品名").font(mono(9, .semibold)).foregroundStyle(muted)
                    Spacer()
                    Text("停留").font(mono(9, .semibold)).foregroundStyle(muted)
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, place in
                    VStack(alignment: .leading, spacing: u(2)) {
                        HStack(alignment: .firstTextBaseline, spacing: u(8)) {
                            Text(place.title).font(mono(11, .semibold)).lineLimit(1)
                            Spacer(minLength: u(4))
                            Text(durationText(place.stay)).font(mono(11, .semibold)).fixedSize()
                        }
                        Text([place.timeText, place.tag].compactMap { $0 }.joined(separator: " · "))
                            .font(mono(8.5, .medium)).foregroundStyle(muted).lineLimit(1)
                    }
                }
                if places.count > rows.count {
                    Text("…另有 \(places.count - rows.count) 处").font(mono(9, .medium)).foregroundStyle(muted)
                }
                dashed
                receiptLine("地点", "\(places.count) 处")
                if moveDistance > 0 {
                    receiptLine("移动", DFKTripShareSummary.distanceText(moveDistance))
                }
                if !photos.isEmpty {
                    receiptLine("照片", "\(photos.count) 张")
                }
                HStack(alignment: .firstTextBaseline) {
                    Text("合计").font(mono(15))
                    Spacer()
                    Text(durationText(totalStay)).font(mono(20))
                }
                dashed
                Text("谢谢光临，生活欢迎再来").font(mono(10, .medium)).foregroundStyle(muted).frame(maxWidth: .infinity)
            }
            .foregroundStyle(ink)
            .padding(u(20))
            .frame(width: u(296))
            .background(paper)
            .background(alignment: .bottom) {
                DFKReceiptEdge(toothWidth: u(10)).fill(paper).frame(height: u(8)).offset(y: u(8))
            }
            .padding(.top, u(26))

            Spacer(minLength: 0)
            style.footer(qrCode: qrCode, foreground: ink, secondary: muted)
        }
        .padding(.horizontal, u(24))
        .padding(.bottom, u(22))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(ground)
    }

    private func receiptLine(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(mono(10, .medium))
            Spacer()
            Text(value).font(mono(10, .semibold))
        }
    }

    // MARK: Polaroid

    /// Instant photos pinned to a board, each captioned with where it was taken.
    private var polaroid: some View {
        let board = Color(red: 0.16, green: 0.17, blue: 0.19)
        let paper = Color(red: 0.97, green: 0.96, blue: 0.94)
        let muted = Color(red: 0.62, green: 0.64, blue: 0.66)
        var frames = Array(photos.prefix(5))
        if frames.isEmpty, let mapImage {
            frames = [Photo(image: mapImage, caption: payload.locationText)]
        }
        let layout = polaroidLayout(frames.count)

        return VStack(alignment: .leading, spacing: u(12)) {
            VStack(alignment: .leading, spacing: u(6)) {
                Text(payload.rangeText).font(mono(11, .semibold)).tracking(u(1)).foregroundStyle(muted)
                Text(payload.title).font(serif(26)).foregroundStyle(paper).lineLimit(2).minimumScaleFactor(0.6)
            }
            ZStack(alignment: .topLeading) {
                ForEach(Array(frames.enumerated()), id: \.offset) { index, photo in
                    let slot = layout[index]
                    VStack(spacing: u(7)) {
                        style.photoTile(photo.image, fallback: muted)
                            .frame(width: u(slot.size), height: u(slot.size))
                        Text(photo.caption ?? payload.rangeText)
                            .font(.system(size: u(11), weight: .medium, design: .serif))
                            .foregroundStyle(Color(red: 0.22, green: 0.22, blue: 0.24))
                            .lineLimit(1)
                            .frame(width: u(slot.size))
                    }
                    .padding([.horizontal, .top], u(8))
                    .padding(.bottom, u(13))
                    .background(paper)
                    .shadow(color: .black.opacity(0.4), radius: u(6), y: u(3))
                    .rotationEffect(.degrees(slot.rotation))
                    .position(x: u(slot.x), y: u(slot.y))
                }
            }
            .frame(width: u(312), height: u(470), alignment: .topLeading)

            Spacer(minLength: 0)
            style.footer(qrCode: qrCode, foreground: paper, secondary: muted)
        }
        .padding(.horizontal, u(24))
        .padding(.top, u(28))
        .padding(.bottom, u(22))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(board)
    }

    private func polaroidLayout(_ count: Int) -> [(x: CGFloat, y: CGFloat, size: CGFloat, rotation: Double)] {
        switch count {
        case 1: return [(156, 220, 250, -3)]
        case 2: return [(108, 140, 170, -6), (204, 330, 170, 5)]
        case 3: return [(95, 120, 150, -6), (220, 215, 150, 6), (118, 360, 150, -3)]
        case 4: return [(85, 110, 135, -6), (226, 125, 135, 5), (90, 325, 135, 4), (226, 340, 135, -5)]
        default: return [(80, 95, 122, -7), (228, 105, 122, 5), (155, 250, 122, -2), (80, 390, 122, 4), (230, 395, 122, -5)]
        }
    }

    // MARK: Postcard

    /// The picture on the front, a note and postmark on the back.
    private var postcard: some View {
        let ground = Color(red: 0.91, green: 0.89, blue: 0.85)
        let ink = Color(red: 0.17, green: 0.16, blue: 0.15)
        let muted = Color(red: 0.48, green: 0.46, blue: 0.43)
        let stampInk = Color(red: 0.72, green: 0.24, blue: 0.20)
        let places = places
        let city = cityName
        let front = photos.first?.image ?? mapImage
        let main = places.max { $0.stay < $1.stay }
        let message: String = {
            if places.count == 1, let detail = places.first?.detail { return detail }
            let names = places.prefix(4).map(\.title).joined(separator: "、")
            let more = places.count > 4 ? "等 \(places.count) 个地方" : ""
            let stay = places.reduce(0) { $0 + $1.stay }
            return "去了\(names)\(more)。停留\(durationText(stay))\(moveDistance > 0 ? "，走过 \(DFKTripShareSummary.distanceText(moveDistance))" : "")。"
        }()

        return VStack(spacing: u(16)) {
            ZStack(alignment: .bottomLeading) {
                style.photoTile(front, fallback: muted)
                LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: u(2)) {
                    Text("来自").font(sans(12, .semibold))
                    Text(city).font(serif(34)).lineLimit(1).minimumScaleFactor(0.5)
                    Text(DFKTripShareSummary.latinName(for: city)).font(mono(10, .semibold)).tracking(u(3)).lineLimit(1)
                }
                .foregroundStyle(.white)
                .padding(u(16))
            }
            .frame(width: u(296), height: u(250))
            .clipped()
            .padding(u(8))
            .background(Color.white)
            .shadow(color: .black.opacity(0.14), radius: u(5), y: u(2))
            .rotationEffect(.degrees(-1.5))

            HStack(alignment: .top, spacing: u(14)) {
                VStack(alignment: .leading, spacing: u(10)) {
                    Text(payload.title).font(serif(17)).foregroundStyle(ink).lineLimit(2)
                    Text(message)
                        .font(.system(size: u(12), weight: .regular, design: .serif))
                        .foregroundStyle(ink)
                        .lineSpacing(u(5))
                        .lineLimit(7)
                    Spacer(minLength: 0)
                    Text("— \(payload.rangeText)").font(mono(9, .medium)).foregroundStyle(muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Rectangle().fill(muted.opacity(0.35)).frame(width: max(1, u(0.6)))
                VStack(alignment: .trailing, spacing: u(14)) {
                    ZStack(alignment: .bottomLeading) {
                        VStack(spacing: u(4)) {
                            Image(systemName: main?.icon ?? "mappin.and.ellipse").font(sans(22, .semibold))
                            Text(main?.tag ?? "地方客").font(sans(8, .bold)).lineLimit(1)
                        }
                        .foregroundStyle(main?.color ?? stampInk)
                        .frame(width: u(60), height: u(72))
                        .overlay(
                            RoundedRectangle(cornerRadius: u(2))
                                .stroke(style: StrokeStyle(lineWidth: u(1.5), dash: [u(3), u(2)]))
                                .foregroundStyle((main?.color ?? stampInk).opacity(0.7))
                        )
                        Circle()
                            .stroke(stampInk.opacity(0.7), lineWidth: u(1.5))
                            .frame(width: u(70), height: u(70))
                            .overlay(
                                VStack(spacing: u(1)) {
                                    Text(city).font(sans(8, .bold)).lineLimit(1).minimumScaleFactor(0.6)
                                    Text(payload.rangeText).font(mono(6.5, .semibold)).lineLimit(1).minimumScaleFactor(0.5)
                                }
                                .foregroundStyle(stampInk.opacity(0.85))
                                .frame(width: u(54))
                            )
                            .rotationEffect(.degrees(-14))
                            .offset(x: -u(36), y: u(22))
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .leading, spacing: u(9)) {
                        Text("寄给").font(sans(9)).foregroundStyle(muted)
                        Text("未来的自己").font(.system(size: u(12), weight: .semibold, design: .serif)).foregroundStyle(ink)
                        Rectangle().fill(muted.opacity(0.4)).frame(height: max(1, u(0.6)))
                        Rectangle().fill(muted.opacity(0.4)).frame(height: max(1, u(0.6)))
                    }
                }
                .frame(width: u(96))
            }
            .padding(u(16))
            .frame(width: u(312), height: u(250))
            .background(Color.white)
            .shadow(color: .black.opacity(0.14), radius: u(5), y: u(2))
            .rotationEffect(.degrees(1))

            Spacer(minLength: 0)
            style.footer(qrCode: qrCode, foreground: ink, secondary: muted)
        }
        .padding(.horizontal, u(24))
        .padding(.top, u(26))
        .padding(.bottom, u(22))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(ground)
    }
}

// MARK: - Review templates

struct DFKReviewShareTemplateView<QRCode: View>: View {
    let template: DFKReviewShareTemplate
    let payload: DFKShareCardPayload
    var displayScale: CGFloat = 1
    let qrCode: QRCode

    private var style: DFKShareTemplateStyle {
        DFKShareTemplateStyle(displayScale: displayScale, brandName: payload.brandName, brandSlogan: payload.brandSlogan)
    }

    private func u(_ value: CGFloat) -> CGFloat { style.u(value) }
    private func serif(_ size: CGFloat, _ weight: Font.Weight = .black) -> Font { style.serif(size, weight) }
    private func mono(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font { style.mono(size, weight) }
    private func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { style.sans(size, weight) }

    var body: some View {
        Group {
            switch template {
            case .wrapped: wrapped
            case .poster: poster
            case .nutrition: nutrition
            case .atlas: atlas
            case .vinyl: vinyl
            case .album: album
            }
        }
        .frame(width: 1080 * displayScale, height: 1920 * displayScale)
        .clipped()
    }

    private struct ReviewPhoto {
        var image: UIImage
        var caption: String?
    }

    /// Photos drawn at random from the whole period, captioned with the place
    /// each was taken. Falls back to the memories' photos.
    private var reviewPhotos: [ReviewPhoto] {
        if !payload.heroImages.isEmpty {
            let ids = payload.heroImageAssetIDs.count == payload.heroImages.count ? payload.heroImageAssetIDs : []
            return payload.heroImages.enumerated().map { index, image in
                ReviewPhoto(image: image, caption: ids.isEmpty ? nil : payload.photoCaptionsByAssetID[ids[index]])
            }
        }
        return memoryPhotoPool.map { ReviewPhoto(image: $0, caption: nil) }
    }

    /// Every loaded memory photo, taken round-robin across memories so that
    /// neighbouring slots show different moments.
    private var memoryPhotoPool: [UIImage] {
        let lists = payload.reviewMemories.map { ([$0.image].compactMap { $0 }) + $0.extraImages }
        let depth = lists.map(\.count).max() ?? 0
        return (0..<depth).flatMap { level in lists.compactMap { level < $0.count ? $0[level] : nil } }
    }

    private func percentText(_ fraction: Double?) -> String? {
        fraction.map { "\(Int(($0 * 100).rounded()))%" }
    }

    // MARK: Wrapped

    /// The period as bold colour blocks: each block leads with one number and
    /// carries the ranking behind it.
    private var wrapped: some View {
        let ground = Color(red: 0.07, green: 0.07, blue: 0.08)
        let lime = Color(red: 0.78, green: 0.95, blue: 0.41)
        let pink = Color(red: 1.0, green: 0.56, blue: 0.69)
        let blue = Color(red: 0.48, green: 0.66, blue: 1.0)
        let orange = Color(red: 1.0, green: 0.62, blue: 0.26)
        let stats = payload.stats
        let activities = payload.activityRankings
        let memories = Array(payload.reviewMemories.prefix(3))
        let values = payload.reviewRhythmValues
        let peak = CGFloat(max(1, values.max() ?? 1))
        let innerWidth = u(312) - u(28)

        return VStack(alignment: .leading, spacing: u(10)) {
            VStack(alignment: .leading, spacing: u(3)) {
                Text(payload.rangeText).font(mono(12)).foregroundStyle(lime)
                Text(payload.title).font(serif(28)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.6)
            }
            .padding(.bottom, u(2))

            // Places: the headline count beside where the time went.
            HStack(alignment: .top, spacing: u(12)) {
                if let first = stats.first {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(first.value).font(.system(size: u(50), weight: .black)).lineLimit(1).minimumScaleFactor(0.4)
                        Text(first.label).font(sans(12, .semibold))
                    }
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: u(5)) {
                    Text("最常待在").font(sans(9, .bold)).opacity(0.65)
                    ForEach(Array(payload.placeRankings.prefix(3).enumerated()), id: \.offset) { index, entry in
                        HStack(spacing: u(6)) {
                            Text(entry.title).font(sans(index == 0 ? 15 : 12, .heavy)).lineLimit(1)
                            Text(entry.value).font(mono(9.5, .semibold)).opacity(0.7)
                        }
                    }
                }
            }
            .foregroundStyle(ground)
            .padding(u(14))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(lime, in: RoundedRectangle(cornerRadius: u(14)))

            // Distance by transport, and how the activity rose and fell.
            HStack(alignment: .top, spacing: u(10)) {
                VStack(alignment: .leading, spacing: u(4)) {
                    if stats.count > 1 {
                        Text(stats[1].value).font(.system(size: u(22), weight: .black)).lineLimit(1).minimumScaleFactor(0.5)
                        Text(stats[1].label).font(sans(10, .semibold)).opacity(0.75)
                    }
                    ForEach(Array(payload.transportRankings.prefix(3).enumerated()), id: \.offset) { _, entry in
                        HStack(spacing: u(4)) {
                            Image(systemName: entry.icon).font(sans(9, .bold)).frame(width: u(12))
                            Text(entry.title).font(sans(10, .bold)).lineLimit(1)
                            Spacer(minLength: u(2))
                            Text(entry.detail ?? entry.value).font(mono(8.5, .semibold)).lineLimit(1)
                        }
                    }
                }
                .padding(u(12))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(pink, in: RoundedRectangle(cornerRadius: u(14)))

                VStack(alignment: .leading, spacing: u(4)) {
                    if stats.count > 2 {
                        Text(stats[2].value).font(.system(size: u(22), weight: .black)).lineLimit(1).minimumScaleFactor(0.5)
                        Text(stats[2].label).font(sans(10, .semibold)).opacity(0.75)
                    }
                    Spacer(minLength: u(4))
                    if !values.isEmpty {
                        Path { path in
                            let width = (u(312) - u(10)) / 2 - u(24)
                            let height = u(34)
                            let step = width / CGFloat(values.count)
                            for (index, value) in values.enumerated() {
                                let x = step * (CGFloat(index) + 0.5)
                                path.move(to: CGPoint(x: x, y: height))
                                path.addLine(to: CGPoint(x: x, y: height - max(u(1), height * CGFloat(value) / peak)))
                            }
                        }
                        .stroke(ground, style: StrokeStyle(lineWidth: max(1, u(1.6)), lineCap: .round))
                        .frame(height: u(34))
                        if let start = payload.reviewRhythmStartText, let end = payload.reviewRhythmEndText {
                            HStack {
                                Text(start)
                                Spacer(minLength: 0)
                                Text(end)
                            }
                            .font(mono(7.5, .semibold))
                            .opacity(0.7)
                        }
                    }
                }
                .padding(u(12))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(blue, in: RoundedRectangle(cornerRadius: u(14)))
            }
            .foregroundStyle(ground)
            .fixedSize(horizontal: false, vertical: true)

            // Time: the top activity, then the whole mix as one bar.
            if let top = activities.first {
                VStack(alignment: .leading, spacing: u(8)) {
                    HStack(alignment: .center, spacing: u(12)) {
                        Image(systemName: top.icon).font(sans(24, .bold))
                        VStack(alignment: .leading, spacing: 0) {
                            Text("最常在").font(sans(10, .semibold)).opacity(0.75)
                            Text(top.title).font(.system(size: u(24), weight: .black)).lineLimit(1).minimumScaleFactor(0.5)
                        }
                        Spacer(minLength: 0)
                        VStack(alignment: .trailing, spacing: 0) {
                            Text(percentText(top.fraction) ?? top.value).font(.system(size: u(24), weight: .black))
                            Text(top.value).font(sans(10, .semibold)).opacity(0.75)
                        }
                    }
                    HStack(spacing: u(2)) {
                        ForEach(Array(activities.enumerated()), id: \.offset) { _, entry in
                            Rectangle()
                                .fill(entry.color)
                                .overlay(Rectangle().stroke(ground.opacity(0.25), lineWidth: max(1, u(0.5))))
                                .frame(width: max(u(3), (innerWidth - u(2) * CGFloat(activities.count - 1)) * CGFloat(entry.fraction ?? 0)))
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(height: u(10))
                    .clipShape(RoundedRectangle(cornerRadius: u(3)))
                    Text(activities.dropFirst().map { "\($0.title) \(percentText($0.fraction) ?? $0.value)" }.joined(separator: "  ·  "))
                        .font(sans(10, .semibold))
                        .lineLimit(2)
                        .opacity(0.8)
                }
                .foregroundStyle(ground)
                .padding(u(14))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(orange, in: RoundedRectangle(cornerRadius: u(14)))
            }

            // Moments worth keeping from the same period.
            if !memories.isEmpty {
                HStack(alignment: .top, spacing: u(10)) {
                    ForEach(memories) { memory in
                        VStack(alignment: .leading, spacing: u(4)) {
                            style.photoTile(memory.image, fallback: Color.white.opacity(0.12))
                                .frame(height: u(62))
                                .frame(maxWidth: .infinity)
                                .clipShape(RoundedRectangle(cornerRadius: u(8)))
                            Text(memory.title).font(sans(10, .bold)).foregroundStyle(.white).lineLimit(1)
                            Text(memory.reason).font(sans(8.5, .semibold)).foregroundStyle(lime).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(memories.count..<3, id: \.self) { _ in
                        Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                    }
                }
            }

            Spacer(minLength: 0)
            style.footer(qrCode: qrCode, foreground: .white, secondary: .white.opacity(0.6))
        }
        .padding(.horizontal, u(24))
        .padding(.top, u(26))
        .padding(.bottom, u(22))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(ground)
    }

    // MARK: Poster

    /// The period's whole map as a travel poster, framed between the title
    /// and the moments, distances and totals that drew it.
    private var poster: some View {
        let ground = Color(red: 0.04, green: 0.06, blue: 0.09)
        let paper = Color(red: 0.96, green: 0.96, blue: 0.95)
        let muted = Color(red: 0.62, green: 0.66, blue: 0.70)
        let accent = Color(red: 0.98, green: 0.78, blue: 0.36)
        let map = payload.templateWideMapImage ?? payload.contentMapDarkImage
        let mapSize = style.mapFrame(width: 360, snapshot: DFKShareTemplateStyle.wideMapSize)
        let photos = Array(reviewPhotos.prefix(4))

        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: u(6)) {
                Text(payload.rangeText).font(mono(12)).tracking(u(2)).foregroundStyle(accent)
                Text(payload.title).font(serif(30)).foregroundStyle(paper).lineLimit(1).minimumScaleFactor(0.5)
                HStack(spacing: u(10)) {
                    ForEach(Array(payload.placeRankings.prefix(3).enumerated()), id: \.offset) { index, entry in
                        HStack(spacing: u(5)) {
                            Text("\(index + 1)")
                                .font(mono(9))
                                .foregroundStyle(ground)
                                .frame(width: u(15), height: u(15))
                                .background(index == 0 ? accent : paper.opacity(0.75), in: Circle())
                            Text(entry.title).font(sans(11, .bold)).foregroundStyle(paper)
                            Text(entry.value).font(mono(9, .medium)).foregroundStyle(muted)
                        }
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.top, u(2))
            }
            .padding(.horizontal, u(24))
            .padding(.top, u(28))
            .padding(.bottom, u(10))

            // The whole snapshot, edges only lightly faded so no marker is lost.
            style.photoTile(map, fallback: ground)
                .frame(width: mapSize.width, height: mapSize.height)
                .overlay {
                    LinearGradient(
                        stops: [
                            .init(color: ground, location: 0),
                            .init(color: .clear, location: 0.08),
                            .init(color: .clear, location: 0.92),
                            .init(color: ground, location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }

            VStack(alignment: .leading, spacing: u(10)) {
                if !photos.isEmpty {
                    HStack(alignment: .top, spacing: u(8)) {
                        ForEach(Array(photos.enumerated()), id: \.offset) { _, photo in
                            VStack(alignment: .leading, spacing: u(3)) {
                                style.photoTile(photo.image, fallback: muted)
                                    .frame(height: u(50))
                                    .frame(maxWidth: .infinity)
                                    .clipShape(RoundedRectangle(cornerRadius: u(6)))
                                    .overlay(RoundedRectangle(cornerRadius: u(6)).stroke(paper.opacity(0.5), lineWidth: max(1, u(0.6))))
                                Text(photo.caption ?? "").font(sans(8.5, .semibold)).foregroundStyle(paper).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                if !payload.transportRankings.isEmpty {
                    HStack(spacing: u(14)) {
                        ForEach(Array(payload.transportRankings.prefix(3).enumerated()), id: \.offset) { _, entry in
                            HStack(spacing: u(4)) {
                                Image(systemName: entry.icon).font(sans(10, .bold)).foregroundStyle(entry.color)
                                Text("\(entry.title) \(entry.detail ?? entry.value)").font(mono(9.5, .semibold)).foregroundStyle(paper).lineLimit(1)
                            }
                        }
                    }
                    .minimumScaleFactor(0.6)
                }
                statColumns(ink: paper, muted: muted, valueSize: 22)
                    .padding(.top, u(10))
                    .overlay(alignment: .top) { Rectangle().fill(paper.opacity(0.3)).frame(height: max(1, u(0.5))) }
                Spacer(minLength: 0)
                style.footer(qrCode: qrCode, foreground: paper, secondary: muted)
            }
            .padding(.horizontal, u(24))
            .padding(.top, u(10))
            .padding(.bottom, u(22))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(ground)
    }

    /// The headline stats in fixed equal columns, the unit set smaller than
    /// the number so a long distance never runs into its neighbour.
    private func statColumns(ink: Color, muted: Color, valueSize: CGFloat) -> some View {
        let stats = Array(payload.stats.prefix(3))
        let gap = u(14)
        let width = (u(312) - gap * CGFloat(max(0, stats.count - 1))) / CGFloat(max(1, stats.count))
        return HStack(alignment: .top, spacing: gap) {
            ForEach(stats) { stat in
                let parts = stat.value.split(separator: " ", maxSplits: 1).map(String.init)
                VStack(alignment: .leading, spacing: u(2)) {
                    // Full size when it fits, otherwise the next size down;
                    // never an arbitrary shrink.
                    ViewThatFits(in: .horizontal) {
                        ForEach([1.0, 0.8, 0.65], id: \.self) { factor in
                            HStack(alignment: .firstTextBaseline, spacing: u(2)) {
                                Text(parts.first ?? stat.value).font(.system(size: u(valueSize * factor), weight: .black))
                                if parts.count > 1 {
                                    Text(parts[1]).font(sans(10, .bold))
                                }
                            }
                            .fixedSize()
                        }
                    }
                    .foregroundStyle(ink)
                    Text(stat.label).font(sans(10)).foregroundStyle(muted).lineLimit(1)
                }
                .frame(width: width, alignment: .leading)
            }
        }
    }

    // MARK: Atlas

    /// An atlas page: the map on a lettered grid with an index of the places
    /// and routes that filled it.
    private var atlas: some View {
        let paper = Color(red: 0.96, green: 0.95, blue: 0.92)
        let ink = Color(red: 0.14, green: 0.18, blue: 0.22)
        let muted = Color(red: 0.47, green: 0.49, blue: 0.50)
        let mapSize = style.mapFrame(width: 298, snapshot: DFKShareTemplateStyle.tallMapSize)
        let map = payload.templateTallMapImage ?? payload.contentMapLightImage ?? payload.contentMapImage

        return VStack(alignment: .leading, spacing: u(12)) {
            VStack(alignment: .leading, spacing: u(4)) {
                HStack(alignment: .firstTextBaseline) {
                    Text("生活地图集").font(serif(26)).foregroundStyle(ink)
                    Spacer()
                    Text("ATLAS").font(mono(10)).tracking(u(3)).foregroundStyle(muted)
                }
                Text("\(payload.rangeText) · \(payload.title)").font(sans(11, .medium)).foregroundStyle(muted).lineLimit(1)
            }
            VStack(alignment: .leading, spacing: u(3)) {
                HStack(spacing: 0) {
                    Color.clear.frame(width: u(12), height: u(1))
                    ForEach(["A", "B", "C", "D"], id: \.self) { column in
                        Text(column).font(mono(8)).foregroundStyle(muted).frame(width: mapSize.width / 4)
                    }
                }
                HStack(spacing: u(3)) {
                    VStack(spacing: 0) {
                        ForEach(1...4, id: \.self) { row in
                            Text("\(row)").font(mono(8)).foregroundStyle(muted).frame(width: u(9), height: mapSize.height / 4)
                        }
                    }
                    ZStack {
                        style.photoTile(map, fallback: muted.opacity(0.2))
                            .frame(width: mapSize.width, height: mapSize.height)
                        Path { path in
                            for index in 1..<4 {
                                let x = mapSize.width * CGFloat(index) / 4
                                let y = mapSize.height * CGFloat(index) / 4
                                path.move(to: CGPoint(x: x, y: 0))
                                path.addLine(to: CGPoint(x: x, y: mapSize.height))
                                path.move(to: CGPoint(x: 0, y: y))
                                path.addLine(to: CGPoint(x: mapSize.width, y: y))
                            }
                        }
                        .stroke(ink.opacity(0.22), lineWidth: max(1, u(0.6)))
                    }
                    .frame(width: mapSize.width, height: mapSize.height)
                    // Printed-atlas insets: legend, compass and one photo plate.
                    .overlay(alignment: .topLeading) {
                        if !payload.activityRankings.isEmpty {
                            VStack(alignment: .leading, spacing: u(4)) {
                                Text("图例 · 时间").font(mono(7.5)).foregroundStyle(muted)
                                ForEach(Array(payload.activityRankings.prefix(4).enumerated()), id: \.offset) { _, entry in
                                    HStack(spacing: u(5)) {
                                        Image(systemName: entry.icon)
                                            .font(sans(7, .bold))
                                            .foregroundStyle(.white)
                                            .frame(width: u(13), height: u(13))
                                            .background(entry.color, in: Circle())
                                        Text(entry.title).font(sans(9, .semibold)).foregroundStyle(ink).lineLimit(1)
                                        Text(percentText(entry.fraction) ?? entry.value).font(mono(8, .medium)).foregroundStyle(muted)
                                    }
                                }
                            }
                            .padding(u(8))
                            .background(paper.opacity(0.92))
                            .overlay(Rectangle().stroke(ink, lineWidth: max(1, u(0.6))))
                            .padding(u(8))
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        VStack(spacing: u(1)) {
                            Text("N").font(mono(8)).foregroundStyle(ink)
                            Image(systemName: "location.north.fill").font(sans(13, .bold)).foregroundStyle(Color(red: 0.80, green: 0.30, blue: 0.22))
                        }
                        .frame(width: u(32), height: u(32))
                        .background(paper.opacity(0.92), in: Circle())
                        .overlay(Circle().stroke(ink, lineWidth: max(1, u(0.6))))
                        .padding(u(8))
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if let photo = reviewPhotos.first {
                            VStack(alignment: .leading, spacing: u(3)) {
                                style.photoTile(photo.image, fallback: muted)
                                    .frame(width: u(92), height: u(70))
                                if let caption = photo.caption {
                                    Text(caption).font(sans(8, .semibold)).foregroundStyle(ink).lineLimit(1)
                                }
                            }
                            .frame(width: u(92))
                            .padding(u(5))
                            .background(Color.white)
                            .shadow(color: .black.opacity(0.2), radius: u(3), y: u(1))
                            .rotationEffect(.degrees(3))
                            .padding(u(12))
                        }
                    }
                    .clipped()
                    .overlay(Rectangle().stroke(ink, lineWidth: u(1.2)))
                }
            }
            HStack(alignment: .top, spacing: u(18)) {
                VStack(alignment: .leading, spacing: u(6)) {
                    Text("常去地区").font(mono(9)).foregroundStyle(muted)
                    ForEach(Array(payload.placeRankings.prefix(3))) { entry in
                        HStack(spacing: u(6)) {
                            Text(entry.title).font(sans(12, .semibold)).foregroundStyle(ink).lineLimit(1)
                            Spacer(minLength: u(4))
                            Text(entry.value).font(mono(9.5, .medium)).foregroundStyle(muted)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: u(6)) {
                    Text("交通里程").font(mono(9)).foregroundStyle(muted)
                    ForEach(Array(payload.transportRankings.prefix(3))) { entry in
                        HStack(spacing: u(6)) {
                            Image(systemName: entry.icon).font(sans(10, .bold)).foregroundStyle(entry.color).frame(width: u(14))
                            Text(entry.title).font(sans(12, .semibold)).foregroundStyle(ink).lineLimit(1)
                            Spacer(minLength: u(4))
                            Text(entry.detail ?? entry.value).font(mono(9.5, .medium)).foregroundStyle(muted)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            statColumns(ink: ink, muted: muted, valueSize: 20)
                .padding(.top, u(10))
                .overlay(alignment: .top) { Rectangle().fill(ink.opacity(0.2)).frame(height: max(1, u(0.5))) }

            Spacer(minLength: 0)
            style.footer(qrCode: qrCode, foreground: ink, secondary: muted)
        }
        .padding(.horizontal, u(24))
        .padding(.top, u(26))
        .padding(.bottom, u(22))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(paper)
    }

    // MARK: Nutrition

    /// A food nutrition label for the period: activities are the ingredients,
    /// transport the minerals, regions the origin.
    private var nutrition: some View {
        let ground = Color(red: 0.95, green: 0.94, blue: 0.91)
        let ink = Color.black
        let distance = payload.stats.first { $0.label == "路程" } ?? payload.stats.dropFirst().first
        let others = payload.stats.filter { $0.label != distance?.label }

        return VStack(spacing: u(16)) {
            VStack(alignment: .leading, spacing: 0) {
                Text("生活成分表").font(.system(size: u(32), weight: .black))
                Text("LIFE FACTS").font(sans(10, .heavy)).tracking(u(2))
                nutritionRule(1).padding(.top, u(6))
                HStack {
                    Text("统计周期").font(sans(12, .bold))
                    Spacer()
                    Text(payload.rangeText).font(sans(12, .bold))
                }
                .padding(.vertical, u(4))
                if !others.isEmpty {
                    // These labels are measure words ("座城市", "段路程"): number first.
                    Text(others.map { "\($0.value) \($0.label)" }.joined(separator: " · "))
                        .font(sans(10, .medium))
                        .padding(.bottom, u(4))
                }
                nutritionRule(8)
                if let distance {
                    HStack(alignment: .firstTextBaseline) {
                        Text("总\(distance.label)").font(sans(14, .heavy))
                        Spacer()
                        Text(distance.value).font(.system(size: u(30), weight: .black)).lineLimit(1).minimumScaleFactor(0.5)
                    }
                    .padding(.vertical, u(2))
                    nutritionRule(4)
                }
                HStack {
                    Spacer()
                    Text("时间占比").font(sans(9, .heavy))
                }
                .padding(.vertical, u(3))
                nutritionRule(0.6)
                ForEach(payload.activityRankings) { entry in
                    nutritionRow(
                        icon: entry.icon,
                        color: entry.color,
                        title: entry.title,
                        detail: entry.value,
                        value: percentText(entry.fraction) ?? ""
                    )
                    nutritionRule(0.6)
                }
                if !payload.transportRankings.isEmpty {
                    nutritionRule(4)
                    Text("交通（矿物质）").font(sans(11, .heavy)).padding(.vertical, u(3))
                    nutritionRule(0.6)
                    ForEach(payload.transportRankings) { entry in
                        nutritionRow(icon: entry.icon, color: entry.color, title: entry.title, detail: entry.detail ?? "", value: entry.value)
                        nutritionRule(0.6)
                    }
                }
                if !payload.placeRankings.isEmpty {
                    nutritionRule(4)
                    Text("产地").font(sans(11, .heavy)).padding(.vertical, u(3))
                    nutritionRule(0.6)
                    ForEach(payload.placeRankings) { entry in
                        nutritionRow(icon: nil, color: ink, title: entry.title, detail: "", value: entry.value)
                        nutritionRule(0.6)
                    }
                }
                nutritionRule(8)
                Text("* 占比按记录到的停留时长计算。成分随生活方式变化，不同时期含量可能不同。")
                    .font(sans(8.5))
                    .padding(.top, u(4))
            }
            .foregroundStyle(ink)
            .padding(u(12))
            .background(Color.white)
            .overlay(Rectangle().stroke(ink, lineWidth: u(2)))
            .padding(.top, u(28))

            Spacer(minLength: 0)
            style.footer(qrCode: qrCode, foreground: ink, secondary: Color(red: 0.40, green: 0.40, blue: 0.38))
        }
        .padding(.horizontal, u(24))
        .padding(.bottom, u(22))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(ground)
    }

    private func nutritionRule(_ weight: CGFloat) -> some View {
        Rectangle().frame(height: max(1, u(weight)))
    }

    private func nutritionRow(icon: String?, color: Color, title: String, detail: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: u(6)) {
            if let icon {
                Image(systemName: icon).font(sans(10, .bold)).foregroundStyle(color).frame(width: u(14))
            }
            Text(title).font(sans(12, .bold)).lineLimit(1)
            Text(detail).font(sans(11)).lineLimit(1)
            Spacer(minLength: u(4))
            Text(value).font(sans(12, .heavy))
        }
        .padding(.vertical, u(3.5))
    }

    // MARK: Vinyl

    /// The activity rhythm pressed into a record's groove, top places as the track list.
    private var vinyl: some View {
        let ground = Color(red: 0.11, green: 0.11, blue: 0.13)
        let accent = Color(red: 0.98, green: 0.55, blue: 0.36)
        let paper = Color(red: 0.95, green: 0.94, blue: 0.92)
        let muted = Color(red: 0.58, green: 0.58, blue: 0.62)
        let diameter = u(250)
        let values = payload.reviewRhythmValues
        let peak = CGFloat(max(1, values.max() ?? 1))
        let pool = reviewPhotos.map(\.image)
        let cover = pool.first ?? payload.heroImage
        // Liner-note photos: every one different from the label and each other.
        let liner = Array(pool.dropFirst().prefix(4))
        let tracks: [(side: String, entry: DFKShareRankingEntry)] =
            payload.activityRankings.prefix(2).enumerated().map { (side: "A\($0.offset + 1)", entry: $0.element) }
            + payload.placeRankings.prefix(2).enumerated().map { (side: "B\($0.offset + 1)", entry: $0.element) }

        return VStack(alignment: .leading, spacing: u(12)) {
            VStack(alignment: .leading, spacing: u(6)) {
                Text("SIDE A · \(payload.rangeText)").font(mono(11, .semibold)).tracking(u(1)).foregroundStyle(accent)
                Text(payload.title).font(serif(28)).foregroundStyle(paper).lineLimit(2).minimumScaleFactor(0.6)
            }
            ZStack {
                Circle().fill(Color.black)
                ForEach(0..<12, id: \.self) { index in
                    Circle()
                        .stroke(Color.white.opacity(0.06), lineWidth: max(1, u(0.6)))
                        .frame(width: diameter * (0.44 + 0.045 * CGFloat(index)))
                }
                if !values.isEmpty {
                    Path { path in
                        let center = CGPoint(x: diameter / 2, y: diameter / 2)
                        let inner = diameter * 0.27
                        let reach = diameter * 0.2
                        for (index, value) in values.enumerated() {
                            let angle = Double(index) / Double(values.count) * 2 * .pi - .pi / 2
                            let length = max(u(1.5), reach * CGFloat(value) / peak)
                            let direction = CGPoint(x: CGFloat(cos(angle)), y: CGFloat(sin(angle)))
                            path.move(to: CGPoint(x: center.x + direction.x * inner, y: center.y + direction.y * inner))
                            path.addLine(to: CGPoint(x: center.x + direction.x * (inner + length), y: center.y + direction.y * (inner + length)))
                        }
                    }
                    .stroke(accent, style: StrokeStyle(lineWidth: u(2.2), lineCap: .round))
                }
                style.photoTile(cover, fallback: accent)
                    .frame(width: diameter * 0.4, height: diameter * 0.4)
                    .clipShape(Circle())
                Circle().fill(ground).frame(width: u(9), height: u(9))
            }
            .frame(width: diameter, height: diameter)
            .overlay(alignment: .topLeading) { tonearm(diameter: diameter) }
            .frame(maxWidth: .infinity)

            if let start = payload.reviewRhythmStartText, let end = payload.reviewRhythmEndText {
                HStack {
                    Text(start)
                    Spacer()
                    Text("顺时针 · 这段时间的生活节奏")
                    Spacer()
                    Text(end)
                }
                .font(mono(9, .medium))
                .foregroundStyle(muted)
            }

            if !liner.isEmpty {
                HStack(spacing: u(6)) {
                    ForEach(Array(liner.enumerated()), id: \.offset) { _, image in
                        style.photoTile(image, fallback: muted)
                            .aspectRatio(1, contentMode: .fit)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: u(4)))
                    }
                    ForEach(liner.count..<4, id: \.self) { _ in
                        Color.clear.aspectRatio(1, contentMode: .fit).frame(maxWidth: .infinity)
                    }
                }
            }

            VStack(spacing: u(8)) {
                ForEach(Array(tracks.enumerated()), id: \.offset) { _, track in
                    HStack(alignment: .firstTextBaseline, spacing: u(10)) {
                        Text(track.side).font(mono(11)).foregroundStyle(accent).frame(width: u(24), alignment: .leading)
                        Text(track.entry.title).font(sans(13, .semibold)).foregroundStyle(paper).lineLimit(1)
                        Spacer(minLength: u(6))
                        Text(track.entry.value).font(mono(11, .medium)).foregroundStyle(muted)
                    }
                }
            }
            .padding(.top, u(4))

            Spacer(minLength: 0)
            style.footer(qrCode: qrCode, foreground: paper, secondary: muted)
        }
        .padding(.horizontal, u(24))
        .padding(.top, u(28))
        .padding(.bottom, u(22))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(ground)
    }

    /// A turntable tonearm: pivot off the record's top-right, needle resting
    /// in the outer grooves, so the disc reads as a record being played.
    private func tonearm(diameter: CGFloat) -> some View {
        let metal = Color(red: 0.80, green: 0.81, blue: 0.83)
        let base = Color(red: 0.26, green: 0.26, blue: 0.29)
        let pivot = CGPoint(x: diameter + u(14), y: u(16))
        let elbow = CGPoint(x: diameter + u(4), y: diameter * 0.40)
        let needle = CGPoint(x: diameter * 0.84, y: diameter * 0.52)
        let headAngle = Angle(radians: atan2(Double(needle.y - elbow.y), Double(needle.x - elbow.x)) - .pi / 2)
        return ZStack(alignment: .topLeading) {
            // Counterweight behind the pivot.
            RoundedRectangle(cornerRadius: u(2))
                .fill(base)
                .frame(width: u(14), height: u(12))
                .position(x: pivot.x + u(2), y: pivot.y - u(12))
            Path { path in
                path.move(to: pivot)
                path.addLine(to: elbow)
                path.addLine(to: needle)
            }
            .stroke(metal, style: StrokeStyle(lineWidth: u(3.5), lineCap: .round, lineJoin: .round))
            Circle()
                .fill(base)
                .frame(width: u(30), height: u(30))
                .overlay(Circle().fill(metal).frame(width: u(12), height: u(12)))
                .position(pivot)
            // Headshell holding the stylus.
            RoundedRectangle(cornerRadius: u(2))
                .fill(metal)
                .frame(width: u(11), height: u(20))
                .rotationEffect(headAngle)
                .position(needle)
        }
        .frame(width: diameter, height: diameter, alignment: .topLeading)
    }

    // MARK: Album

    /// The period's memorable moments taped into a scrapbook.
    private var album: some View {
        let kraft = Color(red: 0.91, green: 0.86, blue: 0.78)
        let ink = Color(red: 0.20, green: 0.16, blue: 0.12)
        let muted = Color(red: 0.47, green: 0.41, blue: 0.34)
        let tagInk = Color(red: 0.70, green: 0.33, blue: 0.20)
        let memories = Array(payload.reviewMemories.prefix(4))
        let mapImage = payload.contentMapLightImage ?? payload.contentMapImage

        return VStack(alignment: .leading, spacing: u(12)) {
            VStack(alignment: .leading, spacing: u(6)) {
                Text(payload.rangeText).font(mono(11, .semibold)).tracking(u(1)).foregroundStyle(muted)
                Text(payload.title).font(serif(28)).foregroundStyle(ink).lineLimit(2).minimumScaleFactor(0.6)
            }
            .padding(.bottom, u(4))
            if memories.isEmpty {
                style.photoTile(mapImage, fallback: muted.opacity(0.3))
                    .frame(width: u(300), height: u(360))
                    .padding(u(6))
                    .background(Color.white)
                    .rotationEffect(.degrees(-2))
                    .frame(maxWidth: .infinity)
            }
            ForEach(Array(memories.enumerated()), id: \.element.id) { index, memory in
                let photo = style.photoTile(memory.image ?? mapImage, fallback: muted.opacity(0.3))
                    .frame(width: u(112), height: u(86))
                    .padding(u(5))
                    .background(Color.white)
                    // A second shot of the same moment, pinned on the corner.
                    .overlay(alignment: index.isMultiple(of: 2) ? .bottomTrailing : .bottomLeading) {
                        if let extra = memory.extraImages.first {
                            style.photoTile(extra, fallback: muted.opacity(0.3))
                                .frame(width: u(50), height: u(40))
                                .padding(u(3))
                                .background(Color.white)
                                .shadow(color: .black.opacity(0.2), radius: u(2), y: u(1))
                                .rotationEffect(.degrees(index.isMultiple(of: 2) ? 7 : -7))
                                .offset(x: index.isMultiple(of: 2) ? u(16) : -u(16), y: u(12))
                        }
                    }
                    .overlay(alignment: .top) {
                        Rectangle().fill(Color.white.opacity(0.65))
                            .frame(width: u(40), height: u(11))
                            .rotationEffect(.degrees(index.isMultiple(of: 2) ? -5 : 5))
                            .offset(y: -u(5))
                    }
                    .shadow(color: .black.opacity(0.15), radius: u(3), y: u(1))
                    .rotationEffect(.degrees(index.isMultiple(of: 2) ? -3 : 3))
                let text = VStack(alignment: .leading, spacing: u(4)) {
                    Text(memory.reason)
                        .font(sans(9, .bold))
                        .foregroundStyle(tagInk)
                        .padding(.horizontal, u(6))
                        .padding(.vertical, u(2))
                        .background(tagInk.opacity(0.14), in: Capsule())
                    Text(memory.title).font(serif(15)).foregroundStyle(ink).lineLimit(2)
                    Text(memory.detail).font(sans(10)).foregroundStyle(muted).lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(alignment: .center, spacing: u(14)) {
                    if index.isMultiple(of: 2) {
                        photo
                        text
                    } else {
                        text
                        photo
                    }
                }
            }
            Spacer(minLength: 0)
            style.footer(qrCode: qrCode, foreground: ink, secondary: muted)
        }
        .padding(.horizontal, u(24))
        .padding(.top, u(28))
        .padding(.bottom, u(22))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(kraft)
    }
}
