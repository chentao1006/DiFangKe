import SwiftUI
import UIKit

/// A planned trip as the plan share cards read it: what happens each day,
/// in order, with how to get from one place to the next. Built once off the
/// main thread from the trip; templates only lay it out.
struct DFKTripPlanShare {
    struct Leg {
        var type: TransportType?
        var distanceMeters: Double?
        var duration: TimeInterval?
        /// Straight-line distance; no planned route was available.
        var isEstimate: Bool
        var originName: String?
        var notes: String
    }

    struct Stop: Identifiable {
        var id: UUID
        /// Position within its day, starting at 1, matching the day map.
        var number: Int
        var name: String
        var address: String?
        var cityName: String?
        var arrival: Date?
        var departure: Date?
        var notes: String
        var inbound: Leg?
        var isLodging: Bool
    }

    struct Day: Identifiable {
        var index: Int
        var date: Date?
        var cityNames: [String]
        var stops: [Stop]
        /// Where this day's night is spent; nil on the last day or when no
        /// lodging is planned.
        var lodging: Stop?
        /// The day has stops on the map; its map tile is laid out from the
        /// start and filled in once drawn.
        var hasMap: Bool
        var mapImage: UIImage?

        var id: Int { index }
    }

    /// Nil while the plan has no dates yet; days then read "第N天".
    var startDate: Date?
    var endDate: Date?
    var dayCount: Int
    var homeCityName: String?
    /// Destination cities in visiting order, without the home city.
    var cityNames: [String]
    var stopCount: Int
    var days: [Day]
    var routeMapImage: UIImage?
    var routeMapDarkImage: UIImage?
    /// Whole days until departure; nil once started or without dates.
    var daysUntilStart: Int?
    /// The day the trip is on today, while it is underway.
    var currentDayIndex: Int?

    /// Marks the lodging stops and works out where each night is spent: a
    /// lodging checked into that day (one at the very start of a day is last
    /// night's, being left), else the one still stayed at while the day stays
    /// in its city. The last day goes home.
    mutating func assignLodging(stopIDs: Set<UUID>) {
        var carried: Stop?
        for dayIndex in days.indices {
            for stopIndex in days[dayIndex].stops.indices {
                days[dayIndex].stops[stopIndex].isLodging = stopIDs.contains(days[dayIndex].stops[stopIndex].id)
            }
            let stops = days[dayIndex].stops
            var lodging: Stop?
            if dayIndex < days.count - 1 {
                if let tonightIndex = stops.indices.last(where: { stops[$0].isLodging && ($0 > 0 || stops.count == 1) }) {
                    lodging = stops[tonightIndex]
                } else if let stayed = carried {
                    let staysInCity = stayed.cityName.map { city in
                        days[dayIndex].cityNames.contains(city) || stops.contains { $0.cityName == city }
                    } ?? true
                    if staysInCity { lodging = stayed }
                }
            }
            days[dayIndex].lodging = lodging
            carried = lodging
        }
    }

    func day(at index: Int) -> Day? {
        days.indices.contains(index) ? days[index] : days.first
    }

    // MARK: Text

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = format
        return formatter
    }

    private static let dayDateFormatter = formatter("M月d日 EEE")
    private static let shortDateFormatter = formatter("M/d")
    private static let timeFormatter = formatter("HH:mm")

    static func timeText(_ date: Date?) -> String? {
        date.map { timeFormatter.string(from: $0) }
    }

    /// "11月14日 周五", or "第1天" before the plan has dates.
    func dayTitle(_ day: Day) -> String {
        day.date.map { Self.dayDateFormatter.string(from: $0) } ?? "第\(day.index + 1)天"
    }

    /// Short label for the day picker: "D1 11/14".
    func dayChipText(_ day: Day) -> String {
        guard let date = day.date else { return "第\(day.index + 1)天" }
        return "D\(day.index + 1) \(Self.shortDateFormatter.string(from: date))"
    }

    var rangeText: String {
        guard let startDate, let endDate else { return "共\(dayCount)天" }
        let start = Self.dayDateFormatter.string(from: startDate)
        guard dayCount > 1 else { return start }
        return "\(start) — \(Self.dayDateFormatter.string(from: endDate)) · \(dayCount)天"
    }

    var routeText: String {
        cityNames.isEmpty ? "" : cityNames.joined(separator: " → ")
    }

    /// "飞机 · 约1960km · 2小时30分"
    static func legSummary(_ leg: Leg) -> String {
        var parts = [leg.type?.localizedName ?? "前往"]
        if let distance = leg.distanceMeters, distance > 0 {
            let text = DFKTripShareSummary.distanceText(distance)
            parts.append(leg.isEstimate ? "约\(text)" : text)
        }
        if let duration = leg.duration, duration > 0 {
            parts.append("约\(DFKTripShareSummary.durationText(duration))")
        }
        return parts.joined(separator: " · ")
    }

    /// The plan as plain text for pasting into a chat: every day, or one.
    func plainText(title: String, dayIndex: Int? = nil) -> String {
        var lines: [String] = []
        let shownDays = dayIndex.flatMap { day(at: $0) }.map { [$0] } ?? days
        lines.append("【\(title)】")
        if dayIndex == nil {
            lines.append([rangeText, routeText].filter { !$0.isEmpty }.joined(separator: " · "))
            if let homeCityName, !homeCityName.isEmpty {
                lines.append("从\(homeCityName)出发")
            }
        }
        for day in shownDays {
            lines.append("")
            let cities = day.cityNames.joined(separator: " → ")
            lines.append(["第\(day.index + 1)天", day.date == nil ? nil : dayTitle(day), cities.isEmpty ? nil : cities]
                .compactMap { $0 }
                .joined(separator: " · "))
            if day.stops.isEmpty {
                lines.append("（暂未安排地点）")
            }
            for stop in day.stops {
                if let leg = stop.inbound {
                    var legLine = "  ↓ \(Self.legSummary(leg))"
                    if let notes = leg.notes.trimmedNilIfEmpty {
                        legLine += "（\(notes.replacingOccurrences(of: "\n", with: "，"))）"
                    }
                    lines.append(legLine)
                }
                let time = Self.timeText(stop.arrival).map { "\($0) " } ?? ""
                lines.append("\(time)\(stop.number). \(stop.name)\(stop.isLodging ? "（住宿）" : "")")
                if let address = stop.address?.trimmedNilIfEmpty {
                    lines.append("    地址：\(address)")
                }
                if let notes = stop.notes.trimmedNilIfEmpty {
                    lines.append("    备注：\(notes.replacingOccurrences(of: "\n", with: "；"))")
                }
            }
            if let lodging = day.lodging {
                let address = lodging.address?.trimmedNilIfEmpty.map { "（\($0)）" } ?? ""
                lines.append("🛏 今晚住：\(lodging.name)\(address)")
            }
        }
        lines.append("")
        lines.append("—— 来自地方客")
        return lines.joined(separator: "\n")
    }
}

private extension String {
    var trimmedNilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum DFKTripPlanShareTemplate: String, CaseIterable, Identifiable {
    /// Every day in full, for the people travelling along.
    case itinerary
    /// One day, sent to the group that morning.
    case day
    /// The trip announced: countdown, route and map.
    case announce
    /// The whole route on one map, a line per day, for discussing the plan.
    case overview
    /// Every place with its full address, day by day, for a driver or guide.
    case addresses
    /// Every place as a box to tick.
    case checklist

    var id: String { rawValue }

    var title: String {
        switch self {
        case .itinerary: return "详细行程单"
        case .day: return "单日安排"
        case .announce: return "出发预告"
        case .overview: return "路线总览"
        case .addresses: return "地址清单"
        case .checklist: return "打卡清单"
        }
    }

    /// Shows one day, picked below the preview.
    var isSingleDay: Bool { self == .day }

    func pixelSize(for plan: DFKTripPlanShare?, dayIndex: Int) -> CGSize {
        let minimum: CGFloat = 640 // artboard points; 1920 px
        guard let plan else { return CGSize(width: 1080, height: minimum * 3) }
        let layout = DFKTripPlanShareLayout.self
        let height: CGFloat
        switch self {
        case .announce:
            height = layout.announceHeight
        case .itinerary:
            height = layout.headerHeight(titleLines: 2, hasHome: plan.homeCityName != nil)
                + plan.days.reduce(CGFloat.zero) { $0 + layout.daySectionHeight($1, mapHeight: layout.itineraryMapHeight) }
                + layout.footerHeight
        case .day:
            let day = plan.day(at: dayIndex)
            height = layout.headerHeight(titleLines: 1, hasHome: false) + 40
                + (day.map { layout.daySectionHeight($0, mapHeight: layout.dayMapHeight) } ?? 0)
                + layout.footerHeight
        case .overview:
            height = layout.headerHeight(titleLines: 2, hasHome: false)
                + layout.overviewMapHeight + 18
                + CGFloat(plan.days.count) * layout.overviewRowHeight
                + layout.footerHeight
        case .addresses:
            height = layout.headerHeight(titleLines: 2, hasHome: false)
                + plan.days.reduce(CGFloat.zero) { total, day in
                    total + 32 + 4 + day.stops.reduce(CGFloat.zero) { $0 + layout.addressRowHeight($1) } + (day.stops.isEmpty ? 30 : 0) + 18
                }
                + layout.footerHeight
        case .checklist:
            height = layout.headerHeight(titleLines: 2, hasHome: false)
                + plan.days.reduce(CGFloat.zero) { total, day in
                    total + layout.checklistDayHeader + layout.checklistRowHeight * CGFloat(max(1, day.stops.count)) + 14
                }
                + layout.footerHeight
        }
        return CGSize(width: 1080, height: (max(minimum, height) * 3).rounded(.up))
    }
}

/// Artboard metrics shared by the plan templates and their height estimates.
/// Text is line-limited, so each estimate is an upper bound: a card may end
/// with a little room above its footer but never cuts its content off.
enum DFKTripPlanShareLayout {
    static let contentWidth: CGFloat = 312
    static let timeColumnWidth: CGFloat = 44
    static let markerColumnWidth: CGFloat = 30
    static var textColumnWidth: CGFloat { contentWidth - timeColumnWidth - markerColumnWidth - 8 }
    /// The itinerary and single-day cards share one day map aspect.
    static let itineraryMapHeight: CGFloat = 170
    static let dayMapHeight: CGFloat = 170
    static let overviewMapHeight: CGFloat = 300
    static let announceMapHeight: CGFloat = 250
    /// Route lines on the plan maps, relative to the trip card map's: the
    /// legs are what these maps are about.
    static let routeLineScale: CGFloat = 2
    static let overviewRowHeight: CGFloat = 46
    static let footerHeight: CGFloat = 92
    static let checklistDayHeader: CGFloat = 34
    static let checklistRowHeight: CGFloat = 30
    static let nameLineLimit = 2
    static let addressLineLimit = 1
    static let notesLineLimit = 4
    static let legNotesLineLimit = 3

    /// Lines `text` takes at `fontSize` in `width`; CJK glyphs count as a full
    /// em, everything else as a little over half.
    static func lineCount(_ text: String, fontSize: CGFloat, width: CGFloat, limit: Int) -> Int {
        let paragraphs = text.split(separator: "\n", omittingEmptySubsequences: false)
        var lines = 0
        for paragraph in paragraphs {
            let units = paragraph.unicodeScalars.reduce(CGFloat.zero) { total, scalar in
                total + (scalar.value >= 0x2E80 ? 1 : 0.58)
            }
            lines += max(1, Int(ceil(units * fontSize / max(width, 1))))
            if lines >= limit { return limit }
        }
        return max(1, min(limit, lines))
    }

    /// The countdown card: kicker, countdown, two-line title and dates, the
    /// route map, the city chain, the stats row and the footer.
    static var announceHeight: CGFloat {
        28 + 16 + 4 + 115 + 8 + 2 * 36 + 8 + 17 + 18
            + announceMapHeight + 18
            + 22
            + 16 + 16 + 46
            + footerHeight
    }

    static func headerHeight(titleLines: Int, hasHome: Bool) -> CGFloat {
        28 + 16 + 8 + CGFloat(titleLines) * 36 + 8 + 2 * 17 + (hasHome ? 22 : 0) + 22
    }

    static func stopRowHeight(_ stop: DFKTripPlanShare.Stop) -> CGFloat {
        var height: CGFloat = 16
        height += CGFloat(lineCount(stop.name, fontSize: 15, width: textColumnWidth, limit: nameLineLimit)) * 20
        if stop.address?.isEmpty == false { height += 17 }
        if !stop.notes.isEmpty {
            height += 8 + 12 + CGFloat(lineCount(stop.notes, fontSize: 11, width: textColumnWidth - 16, limit: notesLineLimit)) * 15
        }
        return max(height, 44)
    }

    static func legRowHeight(_ leg: DFKTripPlanShare.Leg) -> CGFloat {
        var height: CGFloat = 12 + 17
        if !leg.notes.isEmpty {
            height += 5 + 10 + CGFloat(lineCount(leg.notes, fontSize: 11, width: textColumnWidth - 16, limit: legNotesLineLimit)) * 15
        }
        return height
    }

    static func daySectionHeight(_ day: DFKTripPlanShare.Day, mapHeight: CGFloat) -> CGFloat {
        var height: CGFloat = 32 + 10
        if day.hasMap { height += mapHeight + 10 }
        height += day.stops.reduce(CGFloat.zero) { total, stop in
            total + stopRowHeight(stop) + (stop.inbound.map(legRowHeight) ?? 0)
        }
        if day.stops.isEmpty { height += 30 }
        if let lodging = day.lodging {
            height += 10 + 26 + 18 + (lodging.address?.isEmpty == false ? 32 : 0)
        }
        return height + 26
    }

    static func addressRowHeight(_ stop: DFKTripPlanShare.Stop) -> CGFloat {
        let nameLines = CGFloat(lineCount(stop.name, fontSize: 17, width: contentWidth - 96, limit: 2))
        let addressLines = stop.address.map {
            CGFloat(lineCount($0, fontSize: 13, width: contentWidth - 46, limit: 3))
        } ?? 0
        return 24 + nameLines * 22 + addressLines * 18 + 6 + (stop.inbound != nil ? 20 : 0)
    }
}

extension TransportType {
    /// Leg colour on the share cards: walking warm, road and rail slate,
    /// long distance in the accent.
    var shareTint: Color {
        switch category {
        case 1: return Color(red: 0.76, green: 0.34, blue: 0.17)
        case 2, 3: return Color(red: 0.25, green: 0.35, blue: 0.40)
        case 4: return self == .subway ? Color(red: 0.25, green: 0.35, blue: 0.40) : Color.dfkAccent
        default: return .gray
        }
    }
}

struct DFKTripPlanShareTemplateView<QRCode: View>: View {
    let template: DFKTripPlanShareTemplate
    let plan: DFKTripPlanShare
    let title: String
    let dayIndex: Int
    let brandName: String
    let brandSlogan: String
    var displayScale: CGFloat = 1
    let qrCode: QRCode

    private typealias Layout = DFKTripPlanShareLayout

    private var style: DFKShareTemplateStyle {
        DFKShareTemplateStyle(displayScale: displayScale, brandName: brandName, brandSlogan: brandSlogan)
    }

    private func u(_ value: CGFloat) -> CGFloat { style.u(value) }
    private func serif(_ size: CGFloat, _ weight: Font.Weight = .black) -> Font { style.serif(size, weight) }
    private func mono(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font { style.mono(size, weight) }
    private func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { style.sans(size, weight) }

    // One light, print-like palette: these cards are read, not admired.
    private let paper = Color(red: 0.97, green: 0.97, blue: 0.95)
    private let ink = Color(red: 0.11, green: 0.12, blue: 0.14)
    private let muted = Color(red: 0.42, green: 0.45, blue: 0.48)
    private let rule = Color(red: 0.86, green: 0.87, blue: 0.86)
    private let lodgingTint = Color(red: 0.36, green: 0.33, blue: 0.62)
    private var accent: Color { Color.dfkAccent }

    var body: some View {
        let size = template.pixelSize(for: plan, dayIndex: dayIndex)
        Group {
            switch template {
            case .itinerary: itinerary
            case .day: singleDay
            case .announce: announce
            case .overview: overview
            case .addresses: addresses
            case .checklist: checklist
            }
        }
        .frame(width: size.width * displayScale, height: size.height * displayScale, alignment: .top)
        .clipped()
    }

    // MARK: Shared pieces

    private func page<Content: View>(background: Color, foreground: Color, secondary: Color, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
            Spacer(minLength: u(20))
            style.footer(qrCode: qrCode, foreground: foreground, secondary: secondary)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, u(24))
        .padding(.top, u(28))
        .padding(.bottom, u(22))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(background)
    }

    private func header(kicker: String, trailing: String?, titleLines: Int, showsHome: Bool) -> some View {
        VStack(alignment: .leading, spacing: u(8)) {
            HStack(alignment: .firstTextBaseline) {
                Text(kicker).font(sans(11, .semibold)).tracking(u(2)).foregroundStyle(muted)
                Spacer(minLength: u(8))
                if let trailing {
                    Text(trailing).font(mono(11, .semibold)).foregroundStyle(muted)
                }
            }
            Text(title).font(serif(28)).lineLimit(titleLines).minimumScaleFactor(0.7)
            VStack(alignment: .leading, spacing: u(2)) {
                Text(plan.rangeText).font(sans(12, .semibold)).lineLimit(1).minimumScaleFactor(0.7)
                if !plan.routeText.isEmpty {
                    Text(plan.routeText).font(sans(12)).foregroundStyle(muted).lineLimit(1).minimumScaleFactor(0.7)
                }
            }
            if showsHome, let home = plan.homeCityName, !home.isEmpty {
                Label("从\(home)出发", systemImage: "house.fill")
                    .font(sans(11, .medium))
                    .foregroundStyle(muted)
            }
        }
        .padding(.bottom, u(22))
    }

    private func mapTile(_ image: UIImage?, height: CGFloat) -> some View {
        style.photoTile(image, fallback: rule)
            .frame(height: u(height))
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: u(12), style: .continuous))
    }

    private func dayBadge(_ day: DFKTripPlanShare.Day) -> some View {
        Text("D\(day.index + 1)")
            .font(sans(12, .heavy))
            .foregroundStyle(.white)
            .padding(.horizontal, u(9))
            .padding(.vertical, u(4))
            .background(accent, in: Capsule())
    }

    private func dayHeader(_ day: DFKTripPlanShare.Day) -> some View {
        HStack(alignment: .center, spacing: u(10)) {
            dayBadge(day)
            Text(plan.dayTitle(day)).font(sans(14, .bold)).lineLimit(1)
            Spacer(minLength: u(6))
            Text(day.cityNames.joined(separator: " → "))
                .font(sans(12, .semibold))
                .foregroundStyle(muted)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(height: u(32))
    }

    private func numberCircle(_ number: Int, size: CGFloat = 22) -> some View {
        Text("\(number)")
            .font(sans(size * 0.55, .heavy))
            .foregroundStyle(.white)
            .frame(width: u(size), height: u(size))
            .background(accent, in: Circle())
    }

    /// The day's stops on one continuous line, each leg between them.
    private func timeline(_ day: DFKTripPlanShare.Day) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if day.stops.isEmpty {
                Text("暂未安排地点").font(sans(12)).foregroundStyle(muted).frame(height: u(30))
            }
            ForEach(Array(day.stops.enumerated()), id: \.element.id) { index, stop in
                if let leg = stop.inbound {
                    legRow(leg, connectsAbove: index > 0)
                }
                stopRow(stop, connectsAbove: index > 0 || stop.inbound != nil, connectsBelow: index < day.stops.count - 1)
            }
        }
    }

    private func timelineLine(top: Bool, bottom: Bool, markerTop: CGFloat, markerHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            Rectangle().fill(rule).frame(width: u(2), height: u(markerTop)).opacity(top ? 1 : 0)
            Color.clear.frame(width: u(2), height: u(markerHeight))
            Rectangle().fill(rule).frame(width: u(2)).opacity(bottom ? 1 : 0)
        }
        .frame(width: u(Layout.markerColumnWidth))
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func legRow(_ leg: DFKTripPlanShare.Leg, connectsAbove: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Color.clear.frame(width: u(Layout.timeColumnWidth))
            // Drawn like the trip timeline's transport marker: accent icon
            // in an accent ring, whatever the transport type.
            Image(systemName: leg.type?.icon ?? "arrow.down")
                .font(sans(9, .bold))
                .foregroundStyle(accent)
                .frame(width: u(18), height: u(18))
                .background(paper, in: Circle())
                .overlay(Circle().stroke(accent, lineWidth: u(1.2)))
                .frame(width: u(Layout.markerColumnWidth))
                .padding(.top, u(6))
            VStack(alignment: .leading, spacing: u(5)) {
                legSummaryText(leg)
                    .font(sans(11.5))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                if !leg.notes.isEmpty {
                    Text(leg.notes)
                        .font(sans(11, .medium))
                        .foregroundStyle(ink)
                        .lineLimit(Layout.legNotesLineLimit)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, u(8))
                        .padding(.vertical, u(5))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(accent.opacity(0.1), in: RoundedRectangle(cornerRadius: u(6), style: .continuous))
                }
            }
            .padding(.leading, u(8))
            .padding(.vertical, u(6))
        }
        .background(alignment: .topLeading) {
            HStack(spacing: 0) {
                Color.clear.frame(width: u(Layout.timeColumnWidth))
                timelineLine(top: true, bottom: true, markerTop: 0, markerHeight: 0)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func legSummaryText(_ leg: DFKTripPlanShare.Leg) -> Text {
        let summary = DFKTripPlanShare.legSummary(leg)
        guard let range = summary.range(of: " · ") else {
            return Text(summary).fontWeight(.semibold).foregroundColor(ink)
        }
        return Text(summary[..<range.lowerBound]).fontWeight(.semibold).foregroundColor(ink)
            + Text(summary[range.lowerBound...]).foregroundColor(muted)
    }

    private func stopRow(_ stop: DFKTripPlanShare.Stop, connectsAbove: Bool, connectsBelow: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: u(1)) {
                Text(DFKTripPlanShare.timeText(stop.arrival) ?? "")
                    .font(mono(12.5))
                if let departure = DFKTripPlanShare.timeText(stop.departure), stop.departure != stop.arrival {
                    Text("–\(departure)").font(mono(9.5, .medium)).foregroundStyle(muted)
                }
            }
            .frame(width: u(Layout.timeColumnWidth), alignment: .leading)
            .padding(.top, u(9))
            numberCircle(stop.number)
                .frame(width: u(Layout.markerColumnWidth))
                .padding(.top, u(7))
            VStack(alignment: .leading, spacing: u(2)) {
                HStack(alignment: .firstTextBaseline, spacing: u(6)) {
                    Text(stop.name)
                        .font(sans(15, .semibold))
                        .lineLimit(Layout.nameLineLimit)
                        .fixedSize(horizontal: false, vertical: true)
                    if stop.isLodging {
                        Text("住宿")
                            .font(sans(9, .bold))
                            .foregroundStyle(lodgingTint)
                            .padding(.horizontal, u(5))
                            .padding(.vertical, u(1.5))
                            .overlay(Capsule().stroke(lodgingTint, lineWidth: u(1)))
                    }
                }
                if let address = stop.address, !address.isEmpty {
                    Text(address).font(sans(10.5)).foregroundStyle(muted).lineLimit(Layout.addressLineLimit)
                }
                if !stop.notes.isEmpty {
                    Text(stop.notes)
                        .font(sans(11))
                        .foregroundStyle(ink.opacity(0.82))
                        .lineLimit(Layout.notesLineLimit)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, u(8))
                        .padding(.vertical, u(6))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.black.opacity(0.04), in: RoundedRectangle(cornerRadius: u(6), style: .continuous))
                        .padding(.top, u(6))
                }
            }
            .padding(.leading, u(8))
            .padding(.vertical, u(8))
        }
        .background(alignment: .topLeading) {
            HStack(spacing: 0) {
                Color.clear.frame(width: u(Layout.timeColumnWidth))
                timelineLine(top: connectsAbove, bottom: connectsBelow, markerTop: 7, markerHeight: 22)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func lodgingBlock(_ lodging: DFKTripPlanShare.Stop) -> some View {
        HStack(alignment: .top, spacing: u(10)) {
            Image(systemName: "bed.double.fill")
                .font(sans(13, .semibold))
                .foregroundStyle(lodgingTint)
                .frame(width: u(22))
            VStack(alignment: .leading, spacing: u(2)) {
                Text("今晚住").font(sans(10, .semibold)).foregroundStyle(lodgingTint)
                Text(lodging.name).font(sans(14, .semibold)).lineLimit(1)
                if let address = lodging.address, !address.isEmpty {
                    Text(address).font(sans(10.5)).foregroundStyle(muted).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(u(12))
        .background(lodgingTint.opacity(0.08), in: RoundedRectangle(cornerRadius: u(10), style: .continuous))
        .padding(.top, u(10))
    }

    private func daySection(_ day: DFKTripPlanShare.Day, mapHeight: CGFloat, showsHeader: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsHeader {
                dayHeader(day)
                    .padding(.bottom, u(10))
            }
            if day.hasMap {
                mapTile(day.mapImage, height: mapHeight)
                    .padding(.bottom, u(10))
            }
            timeline(day)
            if let lodging = day.lodging {
                lodgingBlock(lodging)
            }
        }
        .padding(.bottom, u(26))
    }

    // MARK: Itinerary

    private var itinerary: some View {
        page(background: paper, foreground: ink, secondary: muted) {
            header(kicker: "行程安排", trailing: "\(plan.stopCount)个地点", titleLines: 2, showsHome: true)
            ForEach(plan.days) { day in
                daySection(day, mapHeight: Layout.itineraryMapHeight, showsHeader: true)
            }
        }
    }

    // MARK: One day

    private var singleDay: some View {
        let day = plan.day(at: dayIndex)
        return page(background: paper, foreground: ink, secondary: muted) {
            if let day {
                VStack(alignment: .leading, spacing: u(6)) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(title).font(sans(11, .semibold)).foregroundStyle(muted).lineLimit(1)
                        Spacer(minLength: u(8))
                        Text("\(day.stops.count)个地点").font(mono(11, .semibold)).foregroundStyle(muted)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: u(10)) {
                        Text("第\(day.index + 1)天").font(serif(40))
                        if day.date != nil {
                            Text(plan.dayTitle(day)).font(sans(15, .semibold))
                        }
                    }
                    if !day.cityNames.isEmpty {
                        Text(day.cityNames.joined(separator: " → "))
                            .font(sans(13, .semibold))
                            .foregroundStyle(accent)
                            .lineLimit(1)
                    }
                }
                .padding(.bottom, u(22))
                daySection(day, mapHeight: Layout.dayMapHeight, showsHeader: false)
            }
        }
    }

    // MARK: Announce

    private var announce: some View {
        let ground = Color(red: 0.06, green: 0.11, blue: 0.14)
        let light = Color(red: 0.95, green: 0.96, blue: 0.96)
        let soft = Color(red: 0.60, green: 0.67, blue: 0.70)
        let highlight = Color(red: 0.37, green: 0.83, blue: 0.85)
        return page(background: ground, foreground: light, secondary: soft) {
            VStack(alignment: .leading, spacing: u(4)) {
                Text(announceKicker).font(sans(12, .semibold)).tracking(u(3)).foregroundStyle(soft)
                HStack(alignment: .firstTextBaseline, spacing: u(8)) {
                    Text(announceNumber).font(serif(96)).foregroundStyle(highlight)
                    Text(announceUnit).font(sans(18, .bold))
                }
                Text(title).font(serif(28)).lineLimit(2).minimumScaleFactor(0.7)
                    .padding(.top, u(4))
                Text(plan.rangeText).font(sans(12, .semibold)).foregroundStyle(soft).lineLimit(1)
                    .padding(.top, u(4))
            }
            .padding(.bottom, u(18))

            mapTile(plan.routeMapDarkImage ?? plan.routeMapImage, height: Layout.announceMapHeight)
                .padding(.bottom, u(18))

            announceRoute(light: light, soft: soft, highlight: highlight)

            HStack(alignment: .top) {
                announceStat("\(plan.dayCount)", "天", soft: soft)
                announceStat("\(max(1, plan.cityNames.count))", "座城市", soft: soft)
                announceStat("\(plan.stopCount)", "个地点", soft: soft)
            }
            .padding(.top, u(16))
            .overlay(alignment: .top) { Rectangle().fill(Color(red: 0.16, green: 0.25, blue: 0.29)).frame(height: max(1, u(0.5))) }
            .padding(.top, u(16))
        }
    }

    private var announceKicker: String {
        if plan.currentDayIndex != nil { return "旅途中" }
        if let days = plan.daysUntilStart { return days == 0 ? "今天出发" : "倒计时" }
        return "即将出发"
    }

    private var announceNumber: String {
        if let current = plan.currentDayIndex { return "D\(current + 1)" }
        if let days = plan.daysUntilStart, days > 0 { return "\(days)" }
        return "\(plan.dayCount)"
    }

    private var announceUnit: String {
        if plan.currentDayIndex != nil { return "/ 共\(plan.dayCount)天" }
        if let days = plan.daysUntilStart, days > 0 { return "天后出发" }
        return "天行程"
    }

    private func announceRoute(light: Color, soft: Color, highlight: Color) -> some View {
        let home = plan.homeCityName?.isEmpty == false ? plan.homeCityName : nil
        let stops = ([home].compactMap { $0 } + Array(plan.cityNames.prefix(5)))
        return HStack(alignment: .center, spacing: u(6)) {
            ForEach(Array(stops.enumerated()), id: \.offset) { index, name in
                if index > 0 {
                    Image(systemName: "arrow.right").font(sans(10, .bold)).foregroundStyle(soft)
                }
                Text(name)
                    .font(sans(index == 0 && home != nil ? 12 : 15, index == 0 && home != nil ? .medium : .bold))
                    .foregroundStyle(index == 0 && home != nil ? soft : light)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            if plan.cityNames.count > 5 {
                Text("…").font(sans(15, .bold)).foregroundStyle(soft)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func announceStat(_ value: String, _ label: String, soft: Color) -> some View {
        VStack(alignment: .leading, spacing: u(2)) {
            Text(value).font(mono(22))
            Text(label).font(sans(11)).foregroundStyle(soft)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Overview

    private var overview: some View {
        page(background: paper, foreground: ink, secondary: muted) {
            header(kicker: "路线总览", trailing: "\(plan.dayCount)天", titleLines: 2, showsHome: false)
            mapTile(plan.routeMapImage, height: Layout.overviewMapHeight)
                .padding(.bottom, u(18))
            ForEach(plan.days) { day in
                overviewRow(day)
            }
        }
    }

    private func overviewRow(_ day: DFKTripPlanShare.Day) -> some View {
        let types = day.stops.compactMap { $0.inbound?.type }.reduce(into: [TransportType]()) { result, type in
            if !result.contains(type) { result.append(type) }
        }
        return HStack(alignment: .center, spacing: u(10)) {
            dayBadge(day)
            VStack(alignment: .leading, spacing: u(2)) {
                Text(day.cityNames.isEmpty ? plan.dayTitle(day) : day.cityNames.joined(separator: " → "))
                    .font(sans(13, .bold))
                    .lineLimit(1)
                Text(day.stops.isEmpty ? "暂未安排地点" : day.stops.map(\.name).joined(separator: " → "))
                    .font(sans(11))
                    .foregroundStyle(muted)
                    .lineLimit(1)
            }
            Spacer(minLength: u(6))
            HStack(spacing: u(4)) {
                ForEach(Array(types.prefix(3).enumerated()), id: \.offset) { _, type in
                    Image(systemName: type.icon).font(sans(11, .semibold)).foregroundStyle(accent)
                }
            }
        }
        .frame(height: u(Layout.overviewRowHeight))
        .overlay(alignment: .bottom) { Rectangle().fill(rule).frame(height: max(1, u(0.5))) }
    }

    // MARK: Addresses

    private var addresses: some View {
        page(background: .white, foreground: ink, secondary: muted) {
            header(kicker: "地址清单", trailing: "\(plan.stopCount)个地点", titleLines: 2, showsHome: false)
            ForEach(plan.days) { day in
                VStack(alignment: .leading, spacing: 0) {
                    dayHeader(day)
                        .padding(.bottom, u(4))
                    if day.stops.isEmpty {
                        Text("暂未安排地点").font(sans(12)).foregroundStyle(muted).frame(height: u(30))
                    }
                    ForEach(day.stops) { stop in
                        addressRow(stop)
                    }
                }
                .padding(.bottom, u(18))
            }
        }
    }

    private func addressRow(_ stop: DFKTripPlanShare.Stop) -> some View {
        HStack(alignment: .top, spacing: u(12)) {
            numberCircle(stop.number, size: 30)
            VStack(alignment: .leading, spacing: u(3)) {
                HStack(alignment: .firstTextBaseline) {
                    Text(stop.name).font(sans(17, .bold)).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: u(8))
                    if let time = DFKTripPlanShare.timeText(stop.arrival) {
                        Text(time).font(mono(14))
                    }
                }
                if let address = stop.address, !address.isEmpty {
                    Text(address).font(sans(13)).foregroundStyle(ink.opacity(0.75)).lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let leg = stop.inbound {
                    Label(DFKTripPlanShare.legSummary(leg), systemImage: leg.type?.icon ?? "arrow.down")
                        .font(sans(11))
                        .foregroundStyle(muted)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, u(12))
        .overlay(alignment: .bottom) { Rectangle().fill(rule).frame(height: max(1, u(0.5))) }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Checklist

    private var checklist: some View {
        let journal = Color(red: 0.98, green: 0.95, blue: 0.88)
        let brown = Color(red: 0.66, green: 0.42, blue: 0.24)
        return page(background: journal, foreground: ink, secondary: muted) {
            header(kicker: "打卡清单", trailing: "0 / \(plan.stopCount)", titleLines: 2, showsHome: false)
            ForEach(plan.days) { day in
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: u(8)) {
                        Text("D\(day.index + 1)").font(mono(13)).foregroundStyle(brown)
                        Text(day.cityNames.isEmpty ? plan.dayTitle(day) : day.cityNames.joined(separator: " · "))
                            .font(sans(13, .bold))
                            .lineLimit(1)
                    }
                    .frame(height: u(Layout.checklistDayHeader), alignment: .center)
                    if day.stops.isEmpty {
                        Text("暂未安排地点").font(sans(12)).foregroundStyle(muted)
                            .frame(height: u(Layout.checklistRowHeight))
                    }
                    ForEach(day.stops) { stop in
                        HStack(spacing: u(10)) {
                            RoundedRectangle(cornerRadius: u(3))
                                .stroke(brown, lineWidth: u(1.5))
                                .frame(width: u(15), height: u(15))
                            Text(stop.name).font(sans(14, .medium)).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .frame(height: u(Layout.checklistRowHeight))
                    }
                }
                .padding(.bottom, u(14))
            }
        }
    }
}
