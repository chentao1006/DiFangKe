import SwiftUI
import UIKit
import MapKit

enum DFKTripShareTemplate: String, CaseIterable, Identifiable {
    case ticket
    case trail
    case ribbon
    case magazine
    case film
    case passport

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ticket: return "行程票根"
        case .trail: return "一笔路线"
        case .ribbon: return "路线地图"
        case .magazine: return "杂志封面"
        case .film: return "逐日胶片"
        case .passport: return "足迹护照"
        }
    }

    func pixelSize(for summary: DFKTripShareSummary?) -> CGSize {
        switch self {
        case .film:
            // Days without photos collapse to their text line.
            let daysHeight = (summary?.days ?? []).reduce(CGFloat.zero) { total, day in
                total + (day.photos.isEmpty ? 190 : 350)
            }
            return CGSize(width: 1080, height: max(1920, 520 + daysHeight))
        default:
            return CGSize(width: 1080, height: 1920)
        }
    }
}

/// Trip facts shared by every template. Built once from the trip's items,
/// transport routes and photos; templates only lay it out.
struct DFKTripShareSummary {
    struct City {
        var name: String
        var latinName: String
        var countryCode: String
        var countryName: String
        var firstDay: Date
        var dayCount: Int
        var isHome: Bool
    }

    struct Leg {
        var type: TransportType?
        var distanceMeters: Double
        var duration: TimeInterval?
        var startName: String?
        var endName: String?
        var startTime: Date?
    }

    struct Day {
        var date: Date
        var cityNames: [String]
        var placeNames: [String]
        var transportSummary: String?
        /// When the day reached the city its card node shows; travel before
        /// it belongs to the stretch leading into that node.
        var arrivalTime: Date?
        var photos: [UIImage]
        var photoCaptions: [String]
    }

    /// One place's photos; the source every card photo is drawn from.
    struct PlacePhotos {
        var caption: String
        var assetIDs: [String]
        var dayIndex: Int
        var isPinCandidate: Bool
    }

    struct PhotoPin {
        var image: UIImage
        var caption: String
    }

    var startDate: Date
    var endDate: Date
    var dayCount: Int
    var homeCityName: String?
    var cities: [City] = []
    var legs: [Leg] = []
    var days: [Day] = []
    var stopCount = 0
    var photoCount = 0
    var totalDistanceMeters: Double = 0
    var walkingDistanceMeters: Double = 0
    var routeMapImage: UIImage?
    var photoPins: [PhotoPin] = []
    var coverImage: UIImage?
    var placePhotos: [PlacePhotos] = []
    var defaultCoverAssetID: String?
    /// Extra photos spread across the trip, excluding the cover.
    var galleryImages: [UIImage] = []
    var hourlyDistances: [Double] = []
    var tripOrdinal = 1
    var newCityCount = 0
    var firstPlaceName: String?
    var lastPlaceName: String?

    var destinationCities: [City] {
        let away = cities.filter { !$0.isHome }
        return away.isEmpty ? cities : away
    }

    static func latinName(for name: String) -> String {
        let latin = name.applyingTransform(.toLatin, reverse: false)?
            .applyingTransform(.stripDiacritics, reverse: false) ?? name
        return latin.replacingOccurrences(of: " ", with: "").uppercased()
    }

    static func distanceText(_ meters: Double) -> String {
        meters >= 10_000 ? "\(Int((meters / 1000).rounded()))km" : String(format: "%.1fkm", meters / 1000)
    }

    static func durationText(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(minutes)分钟" }
        return minutes % 60 == 0 ? "\(minutes / 60)小时" : "\(minutes / 60)小时\(minutes % 60)分"
    }
}

struct DFKTripShareTemplateView<QRCode: View>: View {
    let template: DFKTripShareTemplate
    let summary: DFKTripShareSummary
    let title: String
    let brandName: String
    let brandSlogan: String
    var displayScale: CGFloat = 1
    let qrCode: QRCode

    private var style: DFKShareTemplateStyle {
        DFKShareTemplateStyle(displayScale: displayScale, brandName: brandName, brandSlogan: brandSlogan)
    }

    private func u(_ value: CGFloat) -> CGFloat { style.u(value) }
    private func serif(_ size: CGFloat, _ weight: Font.Weight = .black) -> Font { style.serif(size, weight) }
    private func mono(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font { style.mono(size, weight) }
    private func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { style.sans(size, weight) }

    var body: some View {
        let size = template.pixelSize(for: summary)
        Group {
            switch template {
            case .ticket: ticket
            case .trail: trail
            case .ribbon: ribbon
            case .magazine: magazine
            case .film: film
            case .passport: passport
            }
        }
        .frame(width: size.width * displayScale, height: size.height * displayScale)
        .clipped()
    }

    private func footer(foreground: Color, secondary: Color) -> some View {
        style.footer(qrCode: qrCode, foreground: foreground, secondary: secondary)
    }

    private var monthDay: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "M.dd"
        return formatter
    }

    private var rangeText: String {
        "\(monthDay.string(from: summary.startDate)) — \(monthDay.string(from: summary.endDate))"
    }

    private func photoTile(_ image: UIImage?, fallback: Color) -> some View {
        style.photoTile(image, fallback: fallback)
    }

    private static func color(for type: TransportType?) -> Color {
        switch type?.category ?? 0 {
        case 1: return Color(red: 0.76, green: 0.34, blue: 0.17)
        case 2, 3: return Color(red: 0.25, green: 0.35, blue: 0.40)
        case 4: return type == .subway ? Color(red: 0.25, green: 0.35, blue: 0.40) : Color.dfkAccent
        default: return .gray
        }
    }

    // MARK: Ticket

    private var ticket: some View {
        let paper = Color.white
        let ground = Color(red: 0.86, green: 0.90, blue: 0.91)
        let ink = Color(red: 0.11, green: 0.12, blue: 0.14)
        let muted = Color(red: 0.35, green: 0.39, blue: 0.42)
        // The city stayed in longest is the headline; the strip keeps every
        // stop in visiting order so the middle of the trip is never lost.
        let mainCity = summary.destinationCities.max { lhs, rhs in
            lhs.dayCount == rhs.dayCount ? lhs.firstDay > rhs.firstDay : lhs.dayCount < rhs.dayCount
        }
        let routeStops = ticketRouteStops(mainCity: mainCity)
        let legGroups = Dictionary(grouping: summary.legs) { $0.type?.rawValue ?? "" }
            .map { _, legs -> (leg: DFKTripShareSummary.Leg, route: String) in
                var merged = legs[0]
                merged.distanceMeters = legs.reduce(0) { $0 + $1.distanceMeters }
                // A single leg names its ends only when both are known.
                let route = legs.count > 1
                    ? "\(legs.count) 段"
                    : merged.startName.flatMap { start in merged.endName.map { "\(start) → \($0)" } } ?? ""
                return (merged, route)
            }
            .sorted { $0.leg.distanceMeters > $1.leg.distanceMeters }
            .prefix(4)
        let photos = summary.days.flatMap(\.photos)

        return VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: u(16)) {
                HStack {
                    Text("\(brandName) · 行程票根").font(sans(11, .semibold)).tracking(u(2)).foregroundStyle(muted)
                    Spacer()
                    Text(String(format: "No.%02d", summary.tripOrdinal)).font(mono(11)).foregroundStyle(muted)
                }
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: u(2)) {
                        Text(DFKTripShareSummary.latinName(for: mainCity?.name ?? title)).font(mono(11)).foregroundStyle(muted).lineLimit(1)
                        Text(mainCity.map { ticketShortName($0.name) } ?? title).font(serif(40)).lineLimit(1).minimumScaleFactor(0.5)
                    }
                    Spacer(minLength: u(8))
                    if let mainCity {
                        Text("停留 \(mainCity.dayCount) 天").font(sans(12, .semibold)).foregroundStyle(Color.dfkAccent)
                            .padding(.bottom, u(6))
                    }
                }
                if routeStops.count >= 2 {
                    ticketRouteStrip(routeStops, mainCity: mainCity, ink: ink, muted: muted, track: ground)
                }
                HStack(alignment: .top) {
                    ticketField("出发", monthDay.string(from: summary.startDate), muted: muted)
                    ticketField("天数", "\(summary.dayCount)天", muted: muted)
                    ticketField("地点", "\(summary.stopCount)处", muted: muted)
                    ticketField("里程", DFKTripShareSummary.distanceText(summary.totalDistanceMeters), muted: muted)
                }
                if !legGroups.isEmpty {
                    VStack(spacing: u(8)) {
                        ForEach(Array(legGroups.enumerated()), id: \.offset) { _, group in
                            let leg = group.leg
                            HStack(spacing: u(10)) {
                                Circle().fill(Self.color(for: leg.type)).frame(width: u(8), height: u(8))
                                Text(leg.type?.localizedName ?? "交通").font(sans(13, .semibold)).lineLimit(1)
                                Text(group.route)
                                    .font(sans(12)).foregroundStyle(muted).lineLimit(1)
                                Spacer(minLength: 0)
                                Text(DFKTripShareSummary.distanceText(leg.distanceMeters)).font(mono(12))
                            }
                        }
                    }
                    .padding(.top, u(14))
                    .overlay(alignment: .top) { Rectangle().fill(ground).frame(height: max(1, u(0.5))) }
                }
                Text(title).font(serif(18)).lineLimit(2).padding(.top, u(4))
            }
            .padding(u(20))
            .background(paper, in: UnevenRoundedRectangle(topLeadingRadius: u(18), bottomLeadingRadius: u(6), bottomTrailingRadius: u(6), topTrailingRadius: u(18)))

            HStack(spacing: u(6)) {
                Circle().fill(ground).frame(width: u(22), height: u(22)).offset(x: -u(11))
                DFKShareRuleLine().stroke(style: StrokeStyle(lineWidth: u(2), dash: [u(6), u(4)])).foregroundStyle(Color(red: 0.80, green: 0.83, blue: 0.84)).frame(height: u(2))
                Circle().fill(ground).frame(width: u(22), height: u(22)).offset(x: u(11))
            }
            .frame(height: u(22))
            .background(paper)
            .clipped()

            VStack(alignment: .leading, spacing: u(12)) {
                HStack(spacing: u(6)) {
                    ForEach(0..<4, id: \.self) { index in
                        photoTile(index < photos.count ? photos[index] : nil, fallback: ground)
                            .frame(height: u(72))
                            .frame(maxWidth: .infinity)
                            .overlay {
                                if index == 3, summary.photoCount > 4 {
                                    Color.black.opacity(0.45)
                                    Text("+\(summary.photoCount - 3)").font(sans(14, .bold)).foregroundStyle(.white)
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: u(6)))
                    }
                }
                HStack(alignment: .bottom, spacing: u(12)) {
                    HStack(alignment: .bottom, spacing: u(2)) {
                        ForEach(Array(barcodeWidths.enumerated()), id: \.offset) { _, width in
                            Rectangle().fill(ink).frame(width: u(width), height: u(40))
                        }
                    }
                    Spacer(minLength: 0)
                    Text("这几天走过的路\n都藏在这串条码里").font(sans(9)).foregroundStyle(muted).multilineTextAlignment(.trailing)
                }
                Spacer(minLength: 0)
                footer(foreground: ink, secondary: muted)
            }
            .padding(u(20))
            .frame(maxHeight: .infinity, alignment: .top)
            .background(paper, in: UnevenRoundedRectangle(topLeadingRadius: u(6), bottomLeadingRadius: u(18), bottomTrailingRadius: u(18), topTrailingRadius: u(6)))
        }
        .foregroundStyle(ink)
        .padding(.horizontal, u(22))
        .padding(.vertical, u(28))
        .background(ground)
    }

    private var barcodeWidths: [CGFloat] {
        let values = summary.hourlyDistances
        guard !values.isEmpty else { return Array(repeating: 1, count: 40) }
        let bucket = max(1, Int(ceil(Double(values.count) / 44)))
        let grouped = stride(from: 0, to: values.count, by: bucket).map { start in
            values[start..<min(values.count, start + bucket)].reduce(0, +)
        }
        let maximum = grouped.max() ?? 0
        return grouped.map { value in
            guard maximum > 0, value > 0 else { return 1 }
            return 2 + CGFloat(min(2, Int(3 * value / maximum)))
        }
    }

    private func ticketShortName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasSuffix("市") ? String(trimmed.dropLast()) : trimmed
    }

    /// Every city in visiting order; long trips keep the ends plus the
    /// cities stayed in longest, still in visiting order.
    private func ticketRouteStops(mainCity: DFKTripShareSummary.City?) -> [DFKTripShareSummary.City] {
        let cities = summary.cities
        guard cities.count > 5 else { return cities }
        let middle = cities.dropFirst().dropLast()
        let keptMiddle = middle.enumerated()
            .sorted { $0.element.dayCount > $1.element.dayCount }
            .prefix(3)
            .sorted { $0.offset < $1.offset }
            .map(\.element)
        return [cities[0]] + keptMiddle + [cities[cities.count - 1]]
    }

    private func ticketRouteStrip(_ stops: [DFKTripShareSummary.City], mainCity: DFKTripShareSummary.City?, ink: Color, muted: Color, track: Color) -> some View {
        // Ticket body is 276 pt wide on the 360 pt artboard.
        let columnWidth = u(276) / CGFloat(stops.count)
        return ZStack(alignment: .top) {
            Rectangle()
                .fill(track)
                .frame(height: u(2))
                .padding(.horizontal, columnWidth / 2)
                .padding(.top, u(6))
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(stops.enumerated()), id: \.offset) { _, city in
                    let isMain = city.name == mainCity?.name && city.countryCode == mainCity?.countryCode
                    VStack(spacing: u(4)) {
                        Circle()
                            .fill(isMain ? Color.dfkAccent : Color.white)
                            .overlay(Circle().stroke(isMain ? Color.dfkAccent : muted, lineWidth: u(2)))
                            .frame(width: u(isMain ? 14 : 10), height: u(isMain ? 14 : 10))
                            .frame(height: u(14))
                        Text(ticketShortName(city.name))
                            .font(sans(13, isMain ? .bold : .semibold))
                            .foregroundStyle(isMain ? Color.dfkAccent : ink)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        Text(monthDay.string(from: city.firstDay)).font(mono(10, .medium)).foregroundStyle(muted)
                    }
                    .frame(width: columnWidth)
                }
            }
        }
    }

    private func ticketField(_ label: String, _ value: String, muted: Color) -> some View {
        VStack(alignment: .leading, spacing: u(3)) {
            Text(label).font(sans(10)).foregroundStyle(muted)
            Text(value).font(mono(14)).lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Ribbon

    private var ribbon: some View {
        let ground = Color(red: 0.06, green: 0.11, blue: 0.14)
        let paper = Color(red: 0.95, green: 0.96, blue: 0.96)
        let muted = Color(red: 0.60, green: 0.67, blue: 0.70)
        let pins = Array(summary.photoPins.prefix(4))

        return VStack(alignment: .leading, spacing: u(14)) {
            VStack(alignment: .leading, spacing: u(6)) {
                Text(rangeText).font(sans(11, .semibold)).tracking(u(2)).foregroundStyle(muted)
                Text(title).font(serif(28)).lineLimit(2).minimumScaleFactor(0.6)
            }
            // The trip page's own card map; photos overlap its lower edge.
            ZStack(alignment: .bottom) {
                photoTile(summary.routeMapImage, fallback: Color(red: 0.11, green: 0.18, blue: 0.22))
                    .frame(height: u(380))
                    .clipShape(RoundedRectangle(cornerRadius: u(16)))
                HStack(alignment: .top, spacing: u(8)) {
                    ForEach(Array(pins.enumerated()), id: \.offset) { index, pin in
                        VStack(spacing: u(4)) {
                            photoTile(pin.image, fallback: muted)
                                .frame(width: u(68), height: u(68))
                                .clipShape(RoundedRectangle(cornerRadius: u(4)))
                                .overlay(RoundedRectangle(cornerRadius: u(4)).stroke(paper, lineWidth: u(3)))
                            Text(pin.caption).font(sans(10)).foregroundStyle(Color(red: 0.78, green: 0.82, blue: 0.84)).lineLimit(1)
                                .frame(width: u(72))
                        }
                        .rotationEffect(.degrees(index.isMultiple(of: 2) ? -4 : 3))
                    }
                }
                .offset(y: u(56))
            }
            .padding(.bottom, u(56))

            Spacer(minLength: 0)
            HStack(alignment: .top) {
                ribbonStat(DFKTripShareSummary.distanceText(summary.totalDistanceMeters).replacingOccurrences(of: "km", with: ""), "公里轨迹", muted: muted)
                ribbonStat("\(summary.stopCount)", "停留地点", muted: muted)
                ribbonStat("\(summary.photoCount)", "张照片", muted: muted)
            }
            .padding(.top, u(14))
            .overlay(alignment: .top) { Rectangle().fill(Color(red: 0.16, green: 0.25, blue: 0.29)).frame(height: max(1, u(0.5))) }
            footer(foreground: paper, secondary: muted)
        }
        .foregroundStyle(paper)
        .padding(.horizontal, u(24))
        .padding(.top, u(28))
        .padding(.bottom, u(22))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(ground)
    }

    // MARK: Trail

    /// Days spread down the card as nodes on one hand-drawn curve; photos sit
    /// on the far side of each node. Not geographic on purpose, but ordered by
    /// time: travel sits on the stretch leading into the node it reached, and
    /// travel from or back to the home city gets its own end node.
    private struct TrailStation {
        var day: DFKTripShareSummary.Day?
        var number: Int
        var caption: String
        var label: String?
        var arrival: Date
    }

    private static func isLongDistance(_ type: TransportType?) -> Bool {
        (type?.category ?? 0) == 4 && type != .subway
    }

    private var trailStations: [TrailStation] {
        let timedLegs = summary.legs.compactMap { leg in leg.startTime.map { (leg, $0) } }
        let arrivals = summary.days.map { $0.arrivalTime ?? $0.date }
        let homeName = summary.homeCityName.flatMap { $0.isEmpty ? nil : $0 } ?? "家"
        let leavesHome = arrivals.min().map { first in timedLegs.contains { $0.1 < first } } ?? false
        let returnsHome = arrivals.max().map { last in
            timedLegs.contains { $0.1 > last && Self.isLongDistance($0.0.type) }
        } ?? false
        let dayBudget = 6 - (leavesHome ? 1 : 0) - (returnsHome ? 1 : 0)
        let dayIndices = summary.days.count > dayBudget
            ? (0..<dayBudget).map { Int((Double($0) * Double(summary.days.count - 1) / Double(dayBudget - 1)).rounded()) }
            : Array(summary.days.indices)
        let formatter = DateFormatter()
        formatter.dateFormat = "M.dd"
        var stations = dayIndices.map { index in
            TrailStation(
                day: summary.days[index],
                number: index + 1,
                caption: formatter.string(from: summary.days[index].date),
                label: summary.days[index].cityNames.last,
                arrival: arrivals[index]
            )
        }
        if leavesHome {
            stations.insert(TrailStation(day: nil, number: 0, caption: "出发", label: homeName, arrival: .distantPast), at: 0)
        }
        if returnsHome {
            stations.append(TrailStation(day: nil, number: 0, caption: "返程", label: homeName, arrival: .distantFuture))
        }
        return stations
    }

    /// Long-distance travel between two stations, in the order it happened.
    private func trailLongLegs(from start: TrailStation, to end: TrailStation) -> [DFKTripShareSummary.Leg] {
        summary.legs.filter { leg in
            guard let time = leg.startTime, Self.isLongDistance(leg.type) else { return false }
            return time >= start.arrival && time < end.arrival
        }
    }

    private var trail: some View {
        let ground = Color(red: 0.06, green: 0.11, blue: 0.14)
        let paper = Color(red: 0.95, green: 0.96, blue: 0.96)
        let muted = Color(red: 0.60, green: 0.67, blue: 0.70)
        let walkInk = Color(red: 0.76, green: 0.34, blue: 0.17)
        let railInk = Color(red: 0.37, green: 0.83, blue: 0.85)
        let stations = trailStations
        let area = CGSize(width: u(312), height: u(440))
        let spacing = stations.count > 1 ? (area.height - u(70)) / CGFloat(stations.count - 1) : area.height
        let nodes: [CGPoint] = stations.indices.map { index in
            CGPoint(x: index.isMultiple(of: 2) ? u(58) : u(254), y: u(24) + spacing * CGFloat(index))
        }
        // Fewer days leave more room, so each node carries more photos.
        let dayCount = stations.filter { $0.day != nil }.count
        let photosPerNode = dayCount <= 2 ? 3 : (dayCount <= 3 ? 2 : 1)
        let photoSide = min(u(92), max(u(56), (spacing - u(22) * CGFloat(photosPerNode)) / CGFloat(photosPerNode)))

        return VStack(alignment: .leading, spacing: u(14)) {
            VStack(alignment: .leading, spacing: u(6)) {
                Text(rangeText).font(sans(11, .semibold)).tracking(u(2)).foregroundStyle(muted)
                Text(title).font(serif(28)).lineLimit(2).minimumScaleFactor(0.6)
            }
            ZStack(alignment: .topLeading) {
                ForEach(Array(nodes.indices.dropLast()), id: \.self) { index in
                    let start = nodes[index]
                    let end = nodes[index + 1]
                    let longLegs = trailLongLegs(from: stations[index], to: stations[index + 1])
                    let isLongDistance = !longLegs.isEmpty
                    Path { path in
                        let dy = end.y - start.y
                        path.move(to: start)
                        path.addCurve(
                            to: end,
                            control1: CGPoint(x: start.x, y: start.y + dy * 0.62),
                            control2: CGPoint(x: end.x, y: end.y - dy * 0.62)
                        )
                    }
                    .stroke(
                        isLongDistance ? railInk : walkInk,
                        style: isLongDistance
                            ? StrokeStyle(lineWidth: u(4), lineCap: .round)
                            : StrokeStyle(lineWidth: u(4), lineCap: .round, dash: [u(0.5), u(8)])
                    )
                    if isLongDistance {
                        let types = longLegs.compactMap(\.type).reduce(into: [TransportType]()) { result, type in
                            if result.last != type { result.append(type) }
                        }
                        let distance = longLegs.reduce(0) { $0 + $1.distanceMeters }
                        HStack(spacing: u(4)) {
                            ForEach(Array(types.enumerated()), id: \.offset) { _, type in
                                Image(systemName: type.icon).font(sans(10, .semibold))
                            }
                            Text(([types.map(\.localizedName).joined(separator: " · ")]
                                + (distance > 0 ? [DFKTripShareSummary.distanceText(distance)] : []))
                                .joined(separator: " "))
                                .font(sans(10, .semibold)).lineLimit(1)
                        }
                        .foregroundStyle(railInk)
                        .padding(.horizontal, u(8))
                        .padding(.vertical, u(3))
                        .background(Color(red: 0.12, green: 0.21, blue: 0.25), in: Capsule())
                        .fixedSize()
                        .position(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
                    }
                }
                ForEach(Array(stations.enumerated()), id: \.offset) { index, station in
                    let node = nodes[index]
                    let onLeft = index.isMultiple(of: 2)
                    let photos = station.day?.photos ?? []
                    let captions = station.day?.photoCaptions ?? []
                    ForEach(Array(photos.prefix(photosPerNode).enumerated()), id: \.offset) { photoIndex, photo in
                        VStack(spacing: u(4)) {
                            photoTile(photo, fallback: muted)
                                .frame(width: photoSide, height: photoSide)
                                .clipShape(RoundedRectangle(cornerRadius: u(4)))
                                .overlay(RoundedRectangle(cornerRadius: u(4)).stroke(paper, lineWidth: u(3)))
                            if photoIndex < captions.count {
                                Text(captions[photoIndex]).font(sans(10)).foregroundStyle(Color(red: 0.78, green: 0.82, blue: 0.84))
                                    .lineLimit(1).frame(maxWidth: photoSide + u(24))
                            }
                        }
                        .rotationEffect(.degrees((index + photoIndex).isMultiple(of: 2) ? 4 : -4))
                        .position(
                            x: onLeft ? u(190) - CGFloat(photoIndex % 2) * u(18) : u(122) + CGFloat(photoIndex % 2) * u(18),
                            y: node.y + photoSide / 2 + CGFloat(photoIndex) * (photoSide + u(22))
                        )
                    }
                    VStack(spacing: u(3)) {
                        Group {
                            if station.day == nil {
                                Image(systemName: "house.fill").font(sans(11, .heavy))
                            } else {
                                Text("D\(station.number)").font(sans(11, .heavy))
                            }
                        }
                        .foregroundStyle(ground)
                        .frame(width: u(26), height: u(26))
                        .background(paper, in: Circle())
                        Text(station.caption).font(station.day == nil ? sans(9, .semibold) : mono(9, .medium)).foregroundStyle(muted)
                        if let label = station.label {
                            Text(label).font(sans(10, .semibold)).foregroundStyle(paper).lineLimit(1).fixedSize()
                        }
                    }
                    .position(x: node.x, y: node.y + u(14))
                }
            }
            .frame(width: area.width, height: area.height, alignment: .topLeading)

            Spacer(minLength: 0)
            HStack(alignment: .top) {
                ribbonStat(DFKTripShareSummary.distanceText(summary.totalDistanceMeters).replacingOccurrences(of: "km", with: ""), "公里轨迹", muted: muted)
                ribbonStat("\(summary.stopCount)", "停留地点", muted: muted)
                ribbonStat("\(summary.photoCount)", "张照片", muted: muted)
            }
            .padding(.top, u(14))
            .overlay(alignment: .top) { Rectangle().fill(Color(red: 0.16, green: 0.25, blue: 0.29)).frame(height: max(1, u(0.5))) }
            footer(foreground: paper, secondary: muted)
        }
        .foregroundStyle(paper)
        .padding(.horizontal, u(24))
        .padding(.top, u(28))
        .padding(.bottom, u(22))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(ground)
    }

    private func ribbonStat(_ value: String, _ label: String, muted: Color) -> some View {
        VStack(alignment: .leading, spacing: u(2)) {
            Text(value).font(mono(20))
            Text(label).font(sans(11)).foregroundStyle(muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Magazine

    private var magazine: some View {
        let cream = Color(red: 0.96, green: 0.90, blue: 0.86)
        let accent = Color(red: 0.76, green: 0.34, blue: 0.17)
        let calendar = Calendar.current
        let year = calendar.component(.year, from: summary.startDate)
        let month = calendar.component(.month, from: summary.startDate)
        let cityCount = summary.destinationCities.count
        let lead: String = {
            var parts: [String] = []
            if let first = summary.firstPlaceName, let last = summary.lastPlaceName, first != last {
                parts.append("从\(first)到\(last)")
            }
            if let leg = summary.legs.max(by: { $0.distanceMeters < $1.distanceMeters }),
               let type = leg.type, type.category >= 3, let duration = leg.duration {
                parts.append("\(type.localizedName) \(DFKTripShareSummary.durationText(duration))")
            }
            return parts.joined(separator: "——")
        }()

        return ZStack(alignment: .topLeading) {
            photoTile(summary.coverImage, fallback: Color(red: 0.48, green: 0.29, blue: 0.21))
            LinearGradient(colors: [.black.opacity(0.35), .clear, .clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)

            VStack(alignment: .leading, spacing: u(4)) {
                HStack(alignment: .firstTextBaseline) {
                    Text(brandName).font(serif(64)).tracking(-u(2)).lineLimit(1).minimumScaleFactor(0.5)
                    Spacer()
                    Text(String(format: "%d / %02d\nISSUE %02d", year, month, summary.tripOrdinal))
                        .font(mono(11)).multilineTextAlignment(.trailing)
                }
                Text("我的第 \(summary.tripOrdinal) 次出行").font(sans(11, .semibold)).tracking(u(3))

                VStack(alignment: .leading, spacing: u(14)) {
                    magazineStat("\(summary.dayCount)", cityCount > 1 ? "天 · \(cityCount)座城" : "天")
                    magazineStat("\(summary.stopCount)", "处停留")
                    if summary.walkingDistanceMeters >= 1_000 {
                        magazineStat(String(format: "%.1f", summary.walkingDistanceMeters / 1000), "公里步行")
                    } else {
                        magazineStat("\(summary.photoCount)", "张照片")
                    }
                }
                .padding(.top, u(56))

                Spacer(minLength: 0)

                VStack(alignment: .leading, spacing: u(12)) {
                    Text("封面故事")
                        .font(sans(11, .bold)).tracking(u(1))
                        .padding(.horizontal, u(8)).padding(.vertical, u(3))
                        .background(accent)
                    Text(title).font(serif(32)).lineLimit(3).minimumScaleFactor(0.6)
                    if !lead.isEmpty {
                        Text(lead).font(sans(12)).foregroundStyle(cream).lineLimit(2)
                    }
                    HStack {
                        Text(summary.destinationCities.prefix(3).map(\.name).joined(separator: " · ")).font(sans(11, .semibold)).lineLimit(1)
                        Spacer()
                        Text(rangeText).font(mono(11))
                    }
                    .padding(.top, u(10))
                    .overlay(alignment: .top) { Rectangle().fill(cream).frame(height: max(1, u(0.5))) }
                    footer(foreground: .white, secondary: cream)
                }
            }
            .padding(.horizontal, u(22))
            .padding(.top, u(22))
            .padding(.bottom, u(22))
        }
        .foregroundStyle(.white)
    }

    private func magazineStat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(serif(34))
            Text(label).font(sans(11, .semibold))
        }
        .shadow(color: .black.opacity(0.35), radius: u(4))
    }

    // MARK: Film

    private var film: some View {
        let ground = Color(red: 0.08, green: 0.08, blue: 0.08)
        let hole = Color(red: 0.17, green: 0.17, blue: 0.17)
        let paper = Color(red: 0.95, green: 0.94, blue: 0.92)
        let muted = Color(red: 0.71, green: 0.69, blue: 0.66)
        let accent = Color(red: 0.95, green: 0.71, blue: 0.27)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "M.dd EEE"
        let header = summary.destinationCities.prefix(3).map(\.name).joined(separator: " → ")

        return HStack(spacing: 0) {
            filmHoles(hole)
            VStack(alignment: .leading, spacing: u(10)) {
                HStack(alignment: .firstTextBaseline) {
                    Text(header.isEmpty ? title : header).font(serif(24)).lineLimit(1).minimumScaleFactor(0.5)
                    Spacer()
                    Text("\(summary.dayCount) DAYS").font(mono(10)).foregroundStyle(accent)
                }
                Text(title).font(sans(12)).foregroundStyle(muted).lineLimit(1)
                ForEach(Array(summary.days.enumerated()), id: \.offset) { _, day in
                    VStack(alignment: .leading, spacing: u(6)) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(formatter.string(from: day.date)).font(mono(12)).foregroundStyle(accent)
                            Spacer()
                            Text(day.cityNames.joined(separator: " → ")).font(sans(12, .semibold)).lineLimit(1)
                        }
                        if !day.photos.isEmpty {
                            HStack(spacing: u(4)) {
                                ForEach(Array(day.photos.enumerated()), id: \.offset) { _, photo in
                                    photoTile(photo, fallback: hole)
                                        .frame(height: u(64))
                                        .frame(maxWidth: .infinity)
                                }
                            }
                        }
                        Text(([day.placeNames.prefix(day.photos.isEmpty ? 5 : 3).joined(separator: " → ")] + [day.transportSummary].compactMap { $0 }).filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(sans(11)).foregroundStyle(muted).lineLimit(day.photos.isEmpty ? 2 : 1)
                    }
                    .padding(.top, u(9))
                    .overlay(alignment: .top) { Rectangle().fill(hole).frame(height: max(1, u(0.5))) }
                }
                Spacer(minLength: 0)
                footer(foreground: paper, secondary: muted)
            }
            .padding(.horizontal, u(4))
            .padding(.top, u(20))
            .padding(.bottom, u(16))
            filmHoles(hole)
        }
        .foregroundStyle(paper)
        .background(ground)
    }

    private func filmHoles(_ color: Color) -> some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { _ in
                Spacer(minLength: 0)
                RoundedRectangle(cornerRadius: u(2)).fill(color).frame(width: u(10), height: u(14))
            }
            Spacer(minLength: 0)
        }
        .frame(width: u(22))
    }

    // MARK: Passport

    private var passport: some View {
        let paper = Color(red: 0.94, green: 0.91, blue: 0.86)
        let ink = Color(red: 0.17, green: 0.16, blue: 0.15)
        let muted = Color(red: 0.42, green: 0.39, blue: 0.33)
        let inks = [Color(red: 0.70, green: 0.23, blue: 0.23), Color(red: 0.18, green: 0.29, blue: 0.48), Color(red: 0.30, green: 0.42, blue: 0.31), Color(red: 0.48, green: 0.23, blue: 0.36)]
        // Six slots zigzag down the page. Stamps take them first; photos
        // fill whatever is left so a short trip never leaves the page empty.
        let slots: [(x: CGFloat, y: CGFloat, angle: Double)] = [
            (86, 82, -10), (232, 92, 6), (226, 228, -5), (84, 236, 7), (232, 360, -7), (86, 372, 5)
        ]
        let cities = Array(summary.destinationCities.prefix(4))
        let longestLeg = summary.legs.max { $0.distanceMeters < $1.distanceMeters }
        var stamps: [PassportPiece] = cities.enumerated().map { .city($0.element, $0.offset) }
        if let longestLeg, longestLeg.type != nil { stamps.append(.transport(longestLeg)) }
        stamps.append(.count)
        let photos = ([summary.coverImage].compactMap { $0 } + summary.galleryImages).map(PassportPiece.photo)
        var pieces: [PassportPiece] = []
        var stampIndex = 0
        var photoIndex = 0
        while pieces.count < slots.count, stampIndex < stamps.count || photoIndex < photos.count {
            if stampIndex < stamps.count { pieces.append(stamps[stampIndex]); stampIndex += 1 }
            if pieces.count < slots.count, photoIndex < photos.count { pieces.append(photos[photoIndex]); photoIndex += 1 }
        }
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy.MM.dd"
        let compactDate = DateFormatter()
        compactDate.dateFormat = "yyyyMMdd"
        let machineLine = "P<\(cities.first?.countryCode.uppercased() ?? "XX")<<\(cities.map(\.latinName).joined(separator: "<"))<<\(compactDate.string(from: summary.startDate))<\(summary.dayCount)D<<<"

        return VStack(alignment: .leading, spacing: u(12)) {
            HStack {
                Text("足迹护照 · PASSPORT").font(sans(11, .bold)).tracking(u(3)).foregroundStyle(muted)
                Spacer()
                Text(String(format: "P.%02d", summary.tripOrdinal)).font(mono(11)).foregroundStyle(muted)
            }
            .padding(.bottom, u(10))
            .overlay(alignment: .bottom) { Rectangle().fill(muted.opacity(0.4)).frame(height: max(1, u(0.5))) }

            ZStack {
                ForEach(Array(pieces.enumerated()), id: \.offset) { index, piece in
                    let slot = slots[index]
                    passportPiece(piece, inks: inks, dateFormatter: dateFormatter)
                        .rotationEffect(.degrees(slot.angle))
                        .position(x: u(slot.x), y: u(slot.y))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(alignment: .leading, spacing: u(6)) {
                Text(summary.newCityCount > 0 ? "第 \(summary.tripOrdinal) 页 · 新点亮 \(summary.newCityCount) 座城" : "第 \(summary.tripOrdinal) 页 · \(title)")
                    .font(serif(18)).lineLimit(1).minimumScaleFactor(0.6)
                Text(machineLine).font(mono(10, .medium)).foregroundStyle(muted).lineLimit(1).minimumScaleFactor(0.5)
            }
            .padding(.top, u(10))
            .overlay(alignment: .top) { Rectangle().fill(muted.opacity(0.4)).frame(height: max(1, u(0.5))) }
            footer(foreground: ink, secondary: muted)
        }
        .foregroundStyle(ink)
        .padding(.horizontal, u(24))
        .padding(.top, u(26))
        .padding(.bottom, u(22))
        .background(paper)
    }

    @ViewBuilder
    private func passportPiece(_ piece: PassportPiece, inks: [Color], dateFormatter: DateFormatter) -> some View {
        switch piece {
        case .city(let city, let index):
            passportCityStamp(city, ink: inks[index % inks.count], isRound: index.isMultiple(of: 2), dateFormatter: dateFormatter)
                .opacity(0.9)
        case .transport(let leg):
            HStack(spacing: u(8)) {
                Image(systemName: leg.type?.icon ?? "arrow.triangle.swap").font(sans(20, .semibold))
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(leg.type?.localizedName ?? "交通") \(DFKTripShareSummary.distanceText(leg.distanceMeters))").font(sans(13, .heavy))
                    if let duration = leg.duration {
                        Text(DFKTripShareSummary.durationText(duration)).font(mono(10))
                    }
                }
            }
            .padding(.horizontal, u(16)).padding(.vertical, u(10))
            .overlay(Capsule().stroke(inks[2], lineWidth: u(2)))
            .foregroundStyle(inks[2])
            .opacity(0.9)
        case .count:
            VStack(spacing: u(2)) {
                Text("\(summary.stopCount)").font(serif(30))
                Text("处足迹").font(sans(11, .bold))
                if summary.newCityCount > 0 {
                    Text("NEW \(summary.newCityCount)").font(mono(10))
                }
            }
            .frame(width: u(104), height: u(104))
            .overlay(RoundedRectangle(cornerRadius: u(6)).stroke(inks[3], style: StrokeStyle(lineWidth: u(2), dash: [u(5), u(3)])))
            .foregroundStyle(inks[3])
            .opacity(0.9)
        case .photo(let image):
            photoTile(image, fallback: .gray)
                .frame(width: u(128), height: u(96))
                .overlay(Rectangle().stroke(.white, lineWidth: u(4)))
                .shadow(color: .black.opacity(0.12), radius: u(3), y: u(1))
        }
    }

    private func passportCityStamp(_ city: DFKTripShareSummary.City, ink: Color, isRound: Bool, dateFormatter: DateFormatter) -> some View {
        VStack(spacing: u(2)) {
            Text("\(city.countryCode.uppercased()) · \(city.latinName)").font(mono(10)).tracking(u(1)).lineLimit(1).minimumScaleFactor(0.5)
            Text(city.name).font(serif(32)).lineLimit(1).minimumScaleFactor(0.5)
            Text(dateFormatter.string(from: city.firstDay)).font(mono(12))
            Text("停留 \(city.dayCount) 天").font(sans(10, .semibold))
        }
        .padding(u(14))
        .frame(width: u(isRound ? 150 : 168), height: u(isRound ? 150 : 112))
        .overlay {
            if isRound {
                Circle().stroke(ink, lineWidth: u(3))
            } else {
                RoundedRectangle(cornerRadius: u(10)).stroke(ink, lineWidth: u(3))
                RoundedRectangle(cornerRadius: u(7)).stroke(ink, lineWidth: u(1)).padding(u(5))
            }
        }
        .foregroundStyle(ink)
    }
}

private enum PassportPiece {
    case city(DFKTripShareSummary.City, Int)
    case transport(DFKTripShareSummary.Leg)
    case count
    case photo(UIImage)
}

/// A horizontal rule through the middle of its frame.
struct DFKShareRuleLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}
