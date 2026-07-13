import ImageIO
import Photos
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// Perf (docs/26 follow-up): one shared formatter for the three share-card
// dateLine properties (each previously allocated a DateFormatter per read, and
// these feed ImageRenderer which re-lays out several times per export).
private let atriaShareDateLineFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "EEE · MMM d"
    return formatter
}()

struct AtriaShareSnapshot: Equatable, Hashable {
    struct Ring: Equatable, Hashable {
        let title: String
        let value: String
        let detail: String
        let tintHex: String
        let fill: Double?
    }

    struct Stat: Equatable, Hashable, Identifiable {
        let id: String
        let title: String
        let value: String
        let detail: String
    }

    let date: Date
    let recovery: Ring
    let sleep: Ring
    let strain: Ring
    let stats: [Stat]

    var defaultStats: [Stat] {
        stats.filter { !$0.value.isEmpty && $0.value != "--" && $0.value != "Learning" && $0.value != "Building" }
    }
}

struct AtriaWorkoutShareSnapshot: Equatable, Hashable {
    struct ZoneMinute: Equatable, Hashable, Identifiable {
        let id: Int
        let label: String
        let minutes: Int
        let tintHex: String
    }

    struct PersonalRecord: Equatable, Hashable {
        let exercise: String
        let set: String
        let badge: String
    }

    struct RoutePoint: Equatable, Hashable {
        let latitude: Double
        let longitude: Double
        let startsNewSegment: Bool
    }

    let date: Date
    let activity: String
    let duration: String
    let strain: String
    let peakHeartRate: String
    let zoneMinutes: [ZoneMinute]
    var averageHeartRate: String? = nil
    var distance: String? = nil
    var pace: String? = nil
    var activitySystemImage: String = "figure.mixed.cardio"
    var routeFileURL: URL? = nil
    var routePoints: [RoutePoint] = []
    var personalRecord: PersonalRecord? = nil

    static func routePreviewPoints(from route: AtriaWorkoutRoute,
                                   limit: Int = 240) -> [RoutePoint] {
        guard limit >= 2, route.points.count >= 2 else { return [] }
        let lastIndex = route.points.count - 1
        var retained = Set([0, lastIndex])
        for index in route.points.indices where route.points[index].startsNewSegment == true {
            guard retained.count < limit else { break }
            retained.insert(index)
        }
        if route.points.count <= limit {
            retained.formUnion(route.points.indices)
        } else if retained.count < limit {
            let slots = limit - retained.count
            for slot in 1...slots {
                let fraction = Double(slot) / Double(slots + 1)
                retained.insert(Int((Double(lastIndex) * fraction).rounded()))
            }
            if retained.count < limit {
                let stride = max(1, route.points.count / limit)
                for index in Swift.stride(from: 0, through: lastIndex, by: stride) {
                    guard retained.count < limit else { break }
                    retained.insert(index)
                }
            }
        }
        return retained.sorted().map { index in
            let point = route.points[index]
            return RoutePoint(latitude: point.latitude,
                              longitude: point.longitude,
                              startsNewSegment: index == 0 || point.startsNewSegment == true)
        }
    }
}

struct AtriaWeeklyShareSnapshot: Equatable, Hashable {
    let date: Date
    let title: String
    let recoveryAverage: String
    let recoveryDelta: String
    let sleepConsistency: String
    let bestDay: String
    let hardestDay: String
    let note: String?
}

enum AtriaShareFormat: String, CaseIterable, Identifiable {
    case story
    case post

    var id: String { rawValue }

    var label: String {
        switch self {
        case .story: return "Story"
        case .post: return "Post"
        }
    }

    var pixelSize: CGSize {
        switch self {
        case .story: return CGSize(width: 1080, height: 1920)
        case .post: return CGSize(width: 1080, height: 1080)
        }
    }

    fileprivate var renderSize: CGSize {
        CGSize(width: pixelSize.width / 3, height: pixelSize.height / 3)
    }
}

enum AtriaShareCanvasStyle: String, CaseIterable, Identifiable {
    case midnight
    case pearl
    case blush
    case sage
    case sky
    case champagne

    var id: String { rawValue }

    var label: String {
        switch self {
        case .midnight: return "Midnight"
        case .pearl: return "Pearl"
        case .blush: return "Blush"
        case .sage: return "Sage"
        case .sky: return "Sky"
        case .champagne: return "Champagne"
        }
    }

    var shortLabel: String {
        switch self {
        case .midnight: return "Night"
        case .pearl: return "Pearl"
        case .blush: return "Blush"
        case .sage: return "Sage"
        case .sky: return "Sky"
        case .champagne: return "Gold"
        }
    }

    var isLight: Bool { self != .midnight }

    var foreground: Color {
        isLight ? Color(red: 0.055, green: 0.060, blue: 0.070) : .white
    }

    var chipOpacity: Double { isLight ? 0.075 : 0.10 }
    var trackOpacity: Double { isLight ? 0.18 : 0.22 }
    var blendMode: BlendMode { isLight ? .multiply : .screen }

    var background: some View {
        ZStack {
            LinearGradient(colors: backgroundColors,
                           startPoint: .topLeading,
                           endPoint: .bottomTrailing)
            LinearGradient(colors: [.clear,
                                    accentWash.opacity(isLight ? 0.34 : 0.16),
                                    .clear],
                           startPoint: .topTrailing,
                           endPoint: .bottomLeading)
                .blendMode(isLight ? .softLight : .screen)
            LinearGradient(colors: [secondaryWash.opacity(isLight ? 0.24 : 0.10),
                                    .clear,
                                    accentWash.opacity(isLight ? 0.18 : 0.08)],
                           startPoint: .leading,
                           endPoint: .trailing)
                .rotationEffect(.degrees(-18))
                .blendMode(isLight ? .multiply : .screen)
            LinearGradient(colors: [.white.opacity(isLight ? 0.44 : 0.05),
                                    .clear,
                                    foreground.opacity(isLight ? 0.035 : 0.04)],
                           startPoint: .top,
                           endPoint: .bottom)
        }
    }

    private var accentWash: Color {
        switch self {
        // Violet accent (was cyan) so the midnight canvas reads as the design's
        // premium purple-black rather than teal — reinforces the purple base + wash.
        case .midnight: return Color(red: 0.58, green: 0.35, blue: 0.95)
        case .pearl: return Color(red: 0.50, green: 0.90, blue: 0.82)
        case .blush: return Color(red: 1.00, green: 0.68, blue: 0.62)
        case .sage: return Color(red: 0.52, green: 0.82, blue: 0.56)
        case .sky: return Color(red: 0.42, green: 0.78, blue: 1.00)
        case .champagne: return Color(red: 1.00, green: 0.78, blue: 0.34)
        }
    }

    private var secondaryWash: Color {
        switch self {
        case .midnight: return Color(red: 0.40, green: 0.22, blue: 0.78)
        case .pearl: return Color(red: 0.86, green: 0.88, blue: 1.00)
        case .blush: return Color(red: 0.88, green: 0.96, blue: 0.78)
        case .sage: return Color(red: 0.98, green: 0.84, blue: 0.56)
        case .sky: return Color(red: 0.90, green: 0.72, blue: 1.00)
        case .champagne: return Color(red: 0.92, green: 0.78, blue: 1.00)
        }
    }

    private var backgroundColors: [Color] {
        switch self {
        case .midnight:
            // Design-handoff share card: a premium deep-purple → black diagonal
            // (#131022 → #000) instead of the cooler blue-black. The purple base
            // reinforces the existing secondary purple wash for a richer,
            // more shareable feel.
            return [Color(red: 0.075, green: 0.063, blue: 0.133),
                    Color(red: 0.0, green: 0.0, blue: 0.0)]
        case .pearl:
            return [Color(red: 0.992, green: 0.990, blue: 0.968),
                    Color(red: 0.890, green: 0.944, blue: 0.936)]
        case .blush:
            return [Color(red: 1.000, green: 0.916, blue: 0.890),
                    Color(red: 0.928, green: 0.970, blue: 0.936)]
        case .sage:
            return [Color(red: 0.888, green: 0.962, blue: 0.910),
                    Color(red: 0.984, green: 0.940, blue: 0.826)]
        case .sky:
            return [Color(red: 0.876, green: 0.958, blue: 1.000),
                    Color(red: 0.944, green: 0.918, blue: 1.000)]
        case .champagne:
            return [Color(red: 1.000, green: 0.940, blue: 0.782),
                    Color(red: 0.954, green: 0.900, blue: 0.984)]
        }
    }
}

private enum AtriaSharePictureBackground: String, CaseIterable, Identifiable {
    case abstractPulse
    case alpineDawn
    case neonRun
    case animeAscension

    var id: String { rawValue }

    var shortLabel: String {
        switch self {
        case .abstractPulse: return "Pulse"
        case .alpineDawn: return "Alpine"
        case .neonRun: return "Neon"
        case .animeAscension: return "Ascend"
        }
    }

    var assetName: String {
        switch self {
        case .abstractPulse: return "ShareAbstractPulse"
        case .alpineDawn: return "ShareAlpineDawn"
        case .neonRun: return "ShareNeonRun"
        case .animeAscension: return "ShareAnimeAscension"
        }
    }
}

private enum AtriaShareSaveState: Equatable {
    case idle
    case saving
    case saved
    case failed

    var label: String {
        switch self {
        case .idle: return "Save"
        case .saving: return "Saving"
        case .saved: return "Saved"
        case .failed: return "Retry"
        }
    }

    var systemImage: String {
        switch self {
        case .idle: return "square.and.arrow.down"
        case .saving: return "hourglass"
        case .saved: return "checkmark"
        case .failed: return "exclamationmark.triangle"
        }
    }
}

struct AtriaShareCardView: View {
    let snapshot: AtriaShareSnapshot
    let format: AtriaShareFormat
    let selectedStatIDs: Set<String>
    let canvasStyle: AtriaShareCanvasStyle
    let photoBackground: UIImage?

    init(snapshot: AtriaShareSnapshot,
         format: AtriaShareFormat,
         selectedStatIDs: Set<String>,
         lightCanvas: Bool) {
        self.init(snapshot: snapshot,
                  format: format,
                  selectedStatIDs: selectedStatIDs,
                  canvasStyle: lightCanvas ? .pearl : .midnight)
    }

    init(snapshot: AtriaShareSnapshot,
         format: AtriaShareFormat,
         selectedStatIDs: Set<String>,
         canvasStyle: AtriaShareCanvasStyle) {
        self.init(snapshot: snapshot,
                  format: format,
                  selectedStatIDs: selectedStatIDs,
                  canvasStyle: canvasStyle,
                  photoBackground: nil)
    }

    init(snapshot: AtriaShareSnapshot,
         format: AtriaShareFormat,
         selectedStatIDs: Set<String>,
         canvasStyle: AtriaShareCanvasStyle,
         photoBackground: UIImage?) {
        self.snapshot = snapshot
        self.format = format
        self.selectedStatIDs = selectedStatIDs
        self.canvasStyle = canvasStyle
        self.photoBackground = photoBackground
    }

    private var selectedStats: [AtriaShareSnapshot.Stat] {
        let selected = shareableStats.filter { selectedStatIDs.contains($0.id) }
        return Array((selected.isEmpty ? Array(shareableStats.prefix(3)) : selected).prefix(3))
    }

    private var shareableStats: [AtriaShareSnapshot.Stat] {
        [
            AtriaShareSnapshot.Stat(id: "recovery",
                                    title: "Recovery",
                                    value: recoveryHeroValue,
                                    detail: recoveryEvidenceLine),
            AtriaShareSnapshot.Stat(id: "strain",
                                    title: "Day strain",
                                    value: displayValue(snapshot.strain.value),
                                    detail: snapshot.strain.detail),
            AtriaShareSnapshot.Stat(id: "sleep",
                                    title: "Sleep",
                                    value: displayValue(snapshot.sleep.value),
                                    detail: snapshot.sleep.detail)
        ]
    }

    var body: some View {
        ZStack {
            backgroundLayer
            radialGlow

            VStack(spacing: 0) {
                HStack {
                    Text(dateLine)
                        .font(.system(size: format == .story ? 10 : 9, weight: .medium, design: .rounded))
                        .textCase(.uppercase)
                        .tracking(1.2)
                        .foregroundStyle(foreground.opacity(0.48))
                    Spacer(minLength: 0)
                }
                .padding(.top, format == .story ? 46 : 34)

                Spacer(minLength: format == .story ? 34 : 24)

                shareRings
                    .frame(width: dailyHeroSize, height: dailyHeroSize)

                Spacer(minLength: format == .story ? 22 : 18)

                atriaSafeWordmark

                VStack(spacing: format == .story ? 8 : 9) {
                    ForEach(selectedStats) { stat in
                        statChip(stat)
                    }
                }
                .frame(maxWidth: format == .story ? 314 : 306)
                .padding(.top, format == .story ? 22 : 16)

                Spacer(minLength: format == .story ? 170 : 48)
            }
            .padding(.horizontal, format == .story ? 36 : 34)
        }
        .frame(width: format.renderSize.width, height: format.renderSize.height)
    }

    private var foreground: Color { canvasStyle.foreground }

    private var dailyHeroSize: CGFloat {
        format == .story ? 244 : 220
    }

    private var radialGlow: some View {
        RadialGradient(colors: [snapshot.recovery.tint.opacity(canvasStyle.isLight ? 0.13 : 0.08), .clear],
                       center: .center,
                       startRadius: 20,
                       endRadius: format == .story ? 270 : 210)
            .blendMode(canvasStyle.blendMode)
    }

    private var shareRings: some View {
        ZStack {
            ring(snapshot.sleep, diameter: format == .story ? 244 : 220, lineWidth: format == .story ? 15 : 14)
            ring(snapshot.recovery, diameter: format == .story ? 198 : 182, lineWidth: format == .story ? 12 : 12)
            ring(snapshot.strain, diameter: format == .story ? 160 : 148, lineWidth: format == .story ? 10 : 10)
            VStack(spacing: 9) {
                Text(recoveryHeroValue)
                    .font(.system(size: format == .story ? 58 : 40, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(foreground)
                    .lineLimit(1)
                    .minimumScaleFactor(0.58)
                Text("recovery")
                    .font(.system(size: format == .story ? 12 : 10, weight: .medium, design: .rounded))
                    .tracking(3.0)
                    .textCase(.uppercase)
                    .foregroundStyle(foreground.opacity(0.48))
            }
            .frame(width: format == .story ? 188 : 120)
        }
    }

    private func ring(_ ring: AtriaShareSnapshot.Ring, diameter: CGFloat, lineWidth: CGFloat) -> some View {
        ZStack {
            Circle()
                .stroke(ring.tint.opacity(canvasStyle.trackOpacity),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            if let fill = ring.fill {
                Circle()
                    .trim(from: 0, to: min(max(fill, 0), 1))
                    .stroke(ring.tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: diameter, height: diameter)
    }

    private var recoveryHeroValue: String {
        displayValue(snapshot.recovery.value)
    }

    private var recoveryEvidenceLine: String {
        let hrv = statValue(for: "hrv")
        let rhr = statValue(for: "rhr")
        if let hrv, let rhr {
            return "HRV \(hrv) · RHR \(rhr)"
        } else if let hrv {
            return "HRV \(hrv)"
        } else if let rhr {
            return "RHR \(rhr)"
        }
        return snapshot.recovery.detail
    }

    private func statValue(for id: String) -> String? {
        guard let stat = snapshot.stats.first(where: { $0.id == id }) else { return nil }
        let value = displayValue(stat.value)
        return value == "--" ? nil : value
    }

    private func displayValue(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "--" : trimmed
    }

    private func statChip(_ stat: AtriaShareSnapshot.Stat) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(stat.title)
                    .font(.system(size: format == .story ? 9 : 10, weight: .semibold, design: .rounded))
                    .tracking(1.4)
                    .foregroundStyle(foreground.opacity(0.50))
                    .textCase(.uppercase)
                Text(stat.detail)
                    .font(.system(size: format == .story ? 11 : 10, weight: .medium, design: .rounded))
                    .foregroundStyle(foreground.opacity(0.50))
                    .lineLimit(1)
            }
            Spacer(minLength: 14)
            Text(stat.value)
                .font(.system(size: format == .story ? 26 : 20, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(foreground)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .padding(.horizontal, format == .story ? 20 : 14)
        .padding(.vertical, format == .story ? 9 : 8)
        .background(foreground.opacity(canvasStyle.chipOpacity * 0.34),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(foreground.opacity(canvasStyle.isLight ? 0.05 : 0.07), lineWidth: 1)
        }
    }

    private var atriaSafeWordmark: some View {
        Text("A T R I A")
            .font(.system(size: format == .story ? 20 : 14, weight: .thin, design: .rounded))
            .tracking(format == .story ? 11.0 : 6.2)
            .foregroundStyle(foreground.opacity(0.76))
            .textCase(.uppercase)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, format == .story ? 34 : 6)
    }

    @ViewBuilder
    private var backgroundLayer: some View {
        if let photoBackground {
            Image(uiImage: photoBackground)
                .resizable()
                .scaledToFill()
                .frame(width: format.renderSize.width, height: format.renderSize.height)
                .clipped()
                .overlay(Color.black.opacity(canvasStyle.isLight ? 0.16 : 0.36))
                .overlay(
                    LinearGradient(colors: [.black.opacity(0.54), .clear, .black.opacity(0.48)],
                                   startPoint: .top,
                                   endPoint: .bottom)
                )
        } else {
            canvasStyle.background
        }
    }

    private var dateLine: String {
        atriaShareDateLineFormatter.string(from: snapshot.date)
    }
}

struct AtriaWorkoutShareCardView: View {
    private struct WorkoutStat: Identifiable {
        let title: String
        let value: String
        var id: String { title }
    }

    let snapshot: AtriaWorkoutShareSnapshot
    let format: AtriaShareFormat
    let canvasStyle: AtriaShareCanvasStyle
    let photoBackground: UIImage?

    init(snapshot: AtriaWorkoutShareSnapshot,
         format: AtriaShareFormat,
         lightCanvas: Bool) {
        self.init(snapshot: snapshot,
                  format: format,
                  canvasStyle: lightCanvas ? .pearl : .midnight,
                  photoBackground: nil)
    }

    init(snapshot: AtriaWorkoutShareSnapshot,
         format: AtriaShareFormat,
         canvasStyle: AtriaShareCanvasStyle,
         photoBackground: UIImage? = nil) {
        self.snapshot = snapshot
        self.format = format
        self.canvasStyle = canvasStyle
        self.photoBackground = photoBackground
    }

    var body: some View {
        ZStack {
            backgroundLayer
            radialGlow

            VStack(spacing: contentSpacing) {
                Spacer(minLength: topSpacing)

                Text(dateLine)
                    .font(.system(size: format == .story ? 15 : 13, weight: .bold, design: .rounded))
                    .textCase(.uppercase)
                    .foregroundStyle(foreground.opacity(0.72))

                atriaSafeWordmark

                workoutRing
                    .frame(width: workoutRingSize, height: workoutRingSize)

                if hasRoute {
                    routeTrace
                        .frame(maxWidth: format == .story ? 306 : 320)
                        .frame(height: format == .story ? 108 : 92)
                }

                if let personalRecord = snapshot.personalRecord {
                    personalRecordSpotlight(personalRecord)
                        .frame(maxWidth: format == .story ? 306 : 320)
                }

                HStack(spacing: 10) {
                    ForEach(workoutStats) { stat in
                        workoutStat(stat.title, stat.value)
                    }
                }
                .frame(maxWidth: format == .story ? 306 : 320)

                if snapshot.zoneMinutes.contains(where: { $0.minutes > 0 }) {
                    zoneMinuteBar
                        .frame(maxWidth: format == .story ? 306 : 320)
                }

                Spacer(minLength: bottomSpacing)
            }
            .padding(.horizontal, 30)
        }
        .frame(width: format.renderSize.width, height: format.renderSize.height)
    }

    private var foreground: Color { canvasStyle.foreground }

    @ViewBuilder
    private var backgroundLayer: some View {
        if let photoBackground {
            Image(uiImage: photoBackground)
                .resizable()
                .scaledToFill()
                .frame(width: format.renderSize.width, height: format.renderSize.height)
                .clipped()
                .overlay(Color.black.opacity(0.38))
                .overlay(
                    LinearGradient(colors: [.black.opacity(0.54), .clear, .black.opacity(0.52)],
                                   startPoint: .top,
                                   endPoint: .bottom)
                )
        } else {
            canvasStyle.background
        }
    }

    private var hasRoute: Bool { snapshot.routePoints.count >= 2 }
    private var contentSpacing: CGFloat { hasRoute ? (format == .story ? 13 : 9) : (format == .story ? 22 : 15) }
    private var topSpacing: CGFloat { hasRoute ? (format == .story ? 30 : 16) : (format == .story ? 78 : 40) }
    private var bottomSpacing: CGFloat { hasRoute ? (format == .story ? 24 : 12) : (format == .story ? 74 : 28) }
    private var workoutRingSize: CGFloat { hasRoute ? (format == .story ? 176 : 164) : (format == .story ? 220 : 204) }

    private var accent: Color {
        snapshot.zoneMinutes.first?.tint ?? Color(red: 1.0, green: 0.54, blue: 0.24)
    }

    private var radialGlow: some View {
        RadialGradient(colors: [accent.opacity(canvasStyle.isLight ? 0.14 : 0.10), .clear],
                       center: .center,
                       startRadius: 20,
                       endRadius: format == .story ? 240 : 210)
            .blendMode(canvasStyle.blendMode)
    }

    private var workoutRing: some View {
        ZStack {
            Circle()
                .stroke(accent.opacity(canvasStyle.isLight ? 0.16 : 0.20),
                        style: StrokeStyle(lineWidth: 18, lineCap: .round))
            Circle()
                .trim(from: 0, to: strainFill)
                .stroke(accent, style: StrokeStyle(lineWidth: 18, lineCap: .round))
                .rotationEffect(.degrees(-90))

            VStack(spacing: 5) {
                Image(systemName: snapshot.activitySystemImage)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(accent)
                Text(snapshot.activity)
                    .font(.system(size: 17, weight: .black, design: .rounded))
                    .foregroundStyle(foreground.opacity(0.68))
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
                Text(snapshot.strain)
                    .font(.system(size: 58, weight: .black, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(foreground)
                    .lineLimit(1)
                    .minimumScaleFactor(0.60)
                Text("workout strain")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(foreground.opacity(0.62))
            }
            .frame(width: 170)
        }
    }

    private var strainFill: Double {
        let value = Double(snapshot.strain) ?? 0
        return min(max(value / 21, 0.12), 1)
    }

    private var workoutStats: [WorkoutStat] {
        if let distance = snapshot.distance {
            return [WorkoutStat(title: "Distance", value: distance),
                    WorkoutStat(title: snapshot.pace == nil ? "Avg HR" : "Pace",
                                value: snapshot.pace ?? snapshot.averageHeartRate ?? "--"),
                    WorkoutStat(title: "Duration", value: snapshot.duration)]
        }
        return [
            WorkoutStat(title: "Duration", value: snapshot.duration),
            WorkoutStat(title: "Avg HR", value: snapshot.averageHeartRate ?? "--"),
            WorkoutStat(title: "Peak HR", value: snapshot.peakHeartRate)
        ]
    }

    private var routeTrace: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                Text("Route")
                Spacer(minLength: 8)
                if let distance = snapshot.distance {
                    Text(distance)
                        .monospacedDigit()
                }
            }
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .textCase(.uppercase)
            .foregroundStyle(foreground.opacity(0.64))

            AtriaWorkoutShareRouteShape(points: snapshot.routePoints)
                .stroke(accent,
                        style: StrokeStyle(lineWidth: format == .story ? 4.5 : 3.5,
                                           lineCap: .round,
                                           lineJoin: .round))
                .shadow(color: accent.opacity(0.30), radius: 5)
                .padding(5)
        }
        .padding(11)
        .background(foreground.opacity(canvasStyle.chipOpacity),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(foreground.opacity(0.08), lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Workout route trace\(snapshot.distance.map { ", \($0)" } ?? "")")
    }

    private func workoutStat(_ title: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .textCase(.uppercase)
                .foregroundStyle(foreground.opacity(0.58))
            Text(value)
                .font(.system(size: 18, weight: .black, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(foreground)
                .lineLimit(1)
                .minimumScaleFactor(0.64)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(foreground.opacity(canvasStyle.chipOpacity),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func personalRecordSpotlight(_ personalRecord: AtriaWorkoutShareSnapshot.PersonalRecord) -> some View {
        HStack(spacing: 10) {
            Text(personalRecord.badge)
                .font(.system(size: 12, weight: .black, design: .rounded))
                .foregroundStyle(canvasStyle.isLight ? .white : .black)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(accent, in: Capsule())

            VStack(alignment: .leading, spacing: 2) {
                Text(personalRecord.exercise)
                    .font(.system(size: 13, weight: .black, design: .rounded))
                    .foregroundStyle(foreground)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Text(personalRecord.set)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(foreground.opacity(0.64))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(foreground.opacity(canvasStyle.chipOpacity),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var zoneMinuteBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Zone minutes")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .textCase(.uppercase)
                    .foregroundStyle(foreground.opacity(0.58))
                Spacer()
                Text(zoneSummaryText)
                    .font(.system(size: 11, weight: .black, design: .rounded))
                    .foregroundStyle(accent)
            }

            HStack(spacing: 5) {
                ForEach(snapshot.zoneMinutes) { zone in
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(zone.tint)
                        .frame(maxWidth: .infinity)
                        .frame(height: 12)
                        .opacity(zone.minutes > 0 ? 0.95 : 0.22)
                }
            }
        }
        .padding(12)
        .background(foreground.opacity(canvasStyle.chipOpacity),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var zoneSummaryText: String {
        let active = snapshot.zoneMinutes.filter { $0.minutes > 0 }
        if active.isEmpty { return "learning" }
        return active.map { "\($0.label) \($0.minutes)m" }.joined(separator: " · ")
    }

    private var atriaSafeWordmark: some View {
        Text("A T R I A")
            .font(.system(size: format == .story ? 18 : 15, weight: .light, design: .rounded))
            .foregroundStyle(foreground.opacity(0.88))
            .textCase(.uppercase)
    }

    private var dateLine: String {
        atriaShareDateLineFormatter.string(from: snapshot.date)
    }
}

private struct AtriaWorkoutShareRouteShape: Shape {
    let points: [AtriaWorkoutShareSnapshot.RoutePoint]

    func path(in rect: CGRect) -> Path {
        guard points.count >= 2 else { return Path() }
        let meanLatitude = points.map(\.latitude).reduce(0, +) / Double(points.count)
        let longitudeScale = max(cos(meanLatitude * .pi / 180), 0.01)
        let projected = points.map { point in
            CGPoint(x: point.longitude * longitudeScale, y: point.latitude)
        }
        let minX = projected.map(\.x).min() ?? 0
        let maxX = projected.map(\.x).max() ?? 0
        let minY = projected.map(\.y).min() ?? 0
        let maxY = projected.map(\.y).max() ?? 0
        let sourceWidth = max(maxX - minX, 0.000_000_1)
        let sourceHeight = max(maxY - minY, 0.000_000_1)
        let scale = min(rect.width / sourceWidth, rect.height / sourceHeight)
        let drawnWidth = sourceWidth * scale
        let drawnHeight = sourceHeight * scale
        let originX = rect.minX + (rect.width - drawnWidth) / 2
        let originY = rect.minY + (rect.height - drawnHeight) / 2

        var path = Path()
        for (index, projectedPoint) in projected.enumerated() {
            let point = CGPoint(x: originX + (projectedPoint.x - minX) * scale,
                                y: originY + (maxY - projectedPoint.y) * scale)
            if index == 0 || points[index].startsNewSegment {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        return path
    }
}

struct AtriaWeeklyShareCardView: View {
    let snapshot: AtriaWeeklyShareSnapshot
    let format: AtriaShareFormat
    let canvasStyle: AtriaShareCanvasStyle

    init(snapshot: AtriaWeeklyShareSnapshot,
         format: AtriaShareFormat,
         lightCanvas: Bool) {
        self.init(snapshot: snapshot,
                  format: format,
                  canvasStyle: lightCanvas ? .pearl : .midnight)
    }

    init(snapshot: AtriaWeeklyShareSnapshot,
         format: AtriaShareFormat,
         canvasStyle: AtriaShareCanvasStyle) {
        self.snapshot = snapshot
        self.format = format
        self.canvasStyle = canvasStyle
    }

    var body: some View {
        ZStack {
            canvasStyle.background
            radialGlow

            VStack(spacing: format == .story ? 20 : 7) {
                Spacer(minLength: format == .story ? 76 : 8)

                if format == .story {
                    Text(dateLine)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .textCase(.uppercase)
                        .foregroundStyle(foreground.opacity(0.72))
                }

                atriaSafeWordmark

                weeklyHero
                    .frame(width: weeklyHeroSize, height: weeklyHeroSize)

                VStack(spacing: format == .story ? 10 : 6) {
                    weeklyStat("Sleep routine", snapshot.sleepConsistency, "bedtime consistency")
                    weeklyStat("Best day", snapshot.bestDay, "highest recovery")
                    weeklyStat("Hardest day", snapshot.hardestDay, "highest strain")
                }
                .frame(maxWidth: format == .story ? 306 : 320)

                if format == .story, let note = snapshot.note, !note.isEmpty {
                    Text(note)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(accent)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(12)
                        .frame(maxWidth: format == .story ? 306 : 320, alignment: .leading)
                        .background(accent.opacity(canvasStyle.isLight ? 0.12 : 0.16),
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }

                Spacer(minLength: format == .story ? 78 : 8)
            }
            .padding(.horizontal, 30)
        }
        .frame(width: format.renderSize.width, height: format.renderSize.height)
    }

    private var foreground: Color { canvasStyle.foreground }

    private var accent: Color { Color(red: 0.26, green: 0.96, blue: 0.61) }

    private var weeklyHeroSize: CGFloat {
        format == .story ? 286 : 132
    }

    private var radialGlow: some View {
        RadialGradient(colors: [accent.opacity(canvasStyle.isLight ? 0.14 : 0.10), .clear],
                       center: .center,
                       startRadius: 20,
                       endRadius: format == .story ? 240 : 210)
            .blendMode(canvasStyle.blendMode)
    }

    private var weeklyHero: some View {
        ZStack {
            Circle()
                .stroke(accent.opacity(canvasStyle.isLight ? 0.15 : 0.20),
                        style: StrokeStyle(lineWidth: format == .story ? 18 : 10, lineCap: .round))
            Circle()
                .trim(from: 0, to: recoveryFill)
                .stroke(accent, style: StrokeStyle(lineWidth: format == .story ? 18 : 10, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 5) {
                Text(snapshot.title)
                    .font(.system(size: format == .story ? 16 : 13, weight: .black, design: .rounded))
                    .foregroundStyle(foreground.opacity(0.68))
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
                Text(snapshot.recoveryAverage)
                    .font(.system(size: format == .story ? 56 : 42, weight: .black, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(foreground)
                    .lineLimit(1)
                    .minimumScaleFactor(0.60)
                Text(snapshot.recoveryDelta)
                    .font(.system(size: format == .story ? 13 : 9, weight: .bold, design: .rounded))
                    .foregroundStyle(accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .frame(width: format == .story ? 180 : 104)
        }
    }

    private var recoveryFill: Double {
        let digits = snapshot.recoveryAverage.filter(\.isNumber)
        let value = Double(digits) ?? 0
        return min(max(value / 100, 0.12), 1)
    }

    private func weeklyStat(_ title: String, _ value: String, _ detail: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: format == .story ? 11 : 8, weight: .bold, design: .rounded))
                    .textCase(.uppercase)
                    .foregroundStyle(foreground.opacity(0.58))
                Text(detail)
                    .font(.system(size: format == .story ? 11 : 8, weight: .semibold, design: .rounded))
                    .foregroundStyle(foreground.opacity(0.54))
            }
            Spacer(minLength: 14)
            Text(value)
                .font(.system(size: format == .story ? 20 : 15, weight: .black, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(foreground)
                .lineLimit(1)
                .minimumScaleFactor(0.64)
        }
        .padding(.horizontal, format == .story ? 14 : 9)
        .padding(.vertical, format == .story ? 10 : 5)
        .background(foreground.opacity(canvasStyle.chipOpacity),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var atriaSafeWordmark: some View {
        Text("A T R I A")
            .font(.system(size: format == .story ? 18 : 15, weight: .light, design: .rounded))
            .foregroundStyle(foreground.opacity(0.88))
            .textCase(.uppercase)
    }

    private var dateLine: String {
        atriaShareDateLineFormatter.string(from: snapshot.date)
    }
}

struct AtriaShareSheet: View {
    let snapshot: AtriaShareSnapshot
    /// Optional Recovery Face-Off deep link ("Challenge a friend"); nil hides the button.
    var challengeURL: URL? = nil
    @State private var canvasStyle: AtriaShareCanvasStyle = .midnight
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var photoBackground: UIImage?
    @State private var selectedPictureBackground: AtriaSharePictureBackground?
    @State private var photoBackgroundID = UUID()
    @State private var showCamera = false
    @State private var shareURL: URL?
    @State private var controlsRefreshID = UUID()
    @Environment(\.dismiss) private var dismiss

    init(snapshot: AtriaShareSnapshot, challengeURL: URL? = nil) {
        self.snapshot = snapshot
        self.challengeURL = challengeURL
    }

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                previewStage(in: proxy.size)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color.black.ignoresSafeArea())
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        shareCornerButton(systemImage: "xmark")
                    }
                    .accessibilityLabel("Cancel")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if let shareURL {
                        ShareLink(item: shareURL,
                                  preview: SharePreview("Today on Atria", image: Image(uiImage: previewImage))) {
                            shareCornerButton(systemImage: "square.and.arrow.up")
                        }
                        .accessibilityLabel("Share")
                    } else {
                        Button {} label: {
                            shareCornerButton(systemImage: "square.and.arrow.up")
                        }
                        .disabled(true)
                    }
                }
            }
            .task(id: renderKey) {
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
                let renderedURL = try? await AtriaShareCardRenderer.renderURL(
                    snapshot: snapshot,
                    format: .story,
                    selectedStatIDs: Self.fixedDailyStatIDs(),
                    canvasStyle: effectiveCanvasStyle,
                    photoBackground: photoBackground
                )
                guard !Task.isCancelled else { return }
                shareURL = renderedURL
            }
            .task(id: selectedPhotoItem) {
                guard let selectedPhotoItem,
                      let data = try? await selectedPhotoItem.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) else {
                    return
                }
                photoBackground = image
                selectedPictureBackground = nil
                photoBackgroundID = UUID()
                controlsRefreshID = UUID()
                canvasStyle = .midnight
            }
            .sheet(isPresented: $showCamera) {
                AtriaShareCameraPicker(image: Binding {
                    photoBackground
                } set: { image in
                    photoBackground = image
                    selectedPictureBackground = nil
                    photoBackgroundID = UUID()
                    controlsRefreshID = UUID()
                    if image != nil {
                        canvasStyle = .midnight
                    }
                })
            }
        }
        .presentationDetents([.large])
    }

    private func previewStage(in size: CGSize) -> some View {
        ZStack(alignment: .bottom) {
            ZStack {
                AtriaShareCardView(snapshot: snapshot,
                                   format: .story,
                                   selectedStatIDs: Self.fixedDailyStatIDs(),
                                   canvasStyle: effectiveCanvasStyle,
                                   photoBackground: photoBackground)
                    .id(renderKey)
                    .frame(width: AtriaShareFormat.story.renderSize.width,
                           height: AtriaShareFormat.story.renderSize.height)
                    .scaleEffect(previewScale(for: size), anchor: .top)
                    .frame(width: previewSize(for: size).width,
                           height: previewSize(for: size).height)
                    .offset(y: previewYOffset(for: size))
                    .clipShape(RoundedRectangle(cornerRadius: previewCornerRadius(for: size), style: .continuous))
                    .clipped()

                VStack {
                    LinearGradient(colors: [.black.opacity(0.36), .clear],
                                   startPoint: .top,
                                   endPoint: .bottom)
                        .frame(height: 150)
                    Spacer()
                    LinearGradient(colors: [.clear, .black.opacity(0.66)],
                                   startPoint: .top,
                                   endPoint: .bottom)
                        .frame(height: 196)
                }
                .allowsHitTesting(false)
            }
            .clipped()
            .frame(maxWidth: .infinity)
            .frame(maxHeight: .infinity, alignment: .center)

            controlDock
                .padding(.bottom, max(size.height * 0.012, 10))
        }
        .frame(maxWidth: .infinity)
        .frame(maxHeight: .infinity)
        .accessibilityLabel("Share preview")
    }

    private var controlDock: some View {
        canvasPicker
            .padding(.vertical, 8)
            .background {
                LinearGradient(colors: [.clear, .black.opacity(0.58)],
                               startPoint: .top,
                               endPoint: .bottom)
                    .frame(height: 144)
                    .allowsHitTesting(false)
            }
            .id(controlsRefreshID)
    }

    private var canvasPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(AtriaShareCanvasStyle.allCases) { style in
                    Button {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                            selectCanvas(style)
                        }
                    } label: {
                        canvasButtonLabel(title: style.shortLabel,
                                          systemImage: nil,
                                          isSelected: canvasStyle == style && photoBackground == nil,
                                          swatch: style)
                    }
                    .buttonStyle(.plain)
                }

                ForEach(AtriaSharePictureBackground.allCases) { background in
                    Button {
                        selectPictureBackground(background)
                    } label: {
                        canvasButtonLabel(title: background.shortLabel,
                                          systemImage: nil,
                                          isSelected: selectedPictureBackground == background,
                                          swatch: nil,
                                          assetName: background.assetName)
                    }
                    .buttonStyle(.plain)
                }

                PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                    canvasButtonLabel(title: "Photo",
                                      systemImage: "photo",
                                      isSelected: photoBackground != nil && selectedPictureBackground == nil,
                                      swatch: nil)
                }
                .buttonStyle(.plain)

                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                        showCamera = true
                    }
                } label: {
                    canvasButtonLabel(title: "Camera",
                                      systemImage: "camera",
                                      isSelected: false,
                                      swatch: nil)
                }
                .buttonStyle(.plain)

                if photoBackground != nil {
                    Button {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                            photoBackground = nil
                            selectedPictureBackground = nil
                            selectedPhotoItem = nil
                            photoBackgroundID = UUID()
                        }
                    } label: {
                        canvasButtonLabel(title: "Clear",
                                          systemImage: "xmark",
                                          isSelected: false,
                                          swatch: nil)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
        }
        .frame(height: 74)
        .contentMargins(.horizontal, 6, for: .scrollContent)
    }

    private func shareCornerButton(systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.callout.weight(.semibold))
            .frame(width: 38, height: 38)
            .glassEffect(.regular.interactive(), in: Circle())
            .contentShape(Circle())
    }

    private func selectCanvas(_ style: AtriaShareCanvasStyle) {
        canvasStyle = style
        photoBackground = nil
        selectedPictureBackground = nil
        selectedPhotoItem = nil
        photoBackgroundID = UUID()
        controlsRefreshID = UUID()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func selectPictureBackground(_ background: AtriaSharePictureBackground) {
        guard let image = UIImage(named: background.assetName) else { return }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            selectedPictureBackground = background
            selectedPhotoItem = nil
            photoBackground = image
            photoBackgroundID = UUID()
            controlsRefreshID = UUID()
            canvasStyle = .midnight
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func canvasButtonLabel(title: String,
                                   systemImage: String?,
                                   isSelected: Bool,
                                   swatch: AtriaShareCanvasStyle?,
                                   assetName: String? = nil) -> some View {
        VStack(spacing: 5) {
            if let assetName {
                Image(assetName)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 52, height: 52)
                    .clipShape(Circle())
                    .overlay {
                        Circle()
                            .stroke(Color.white.opacity(isSelected ? 0.98 : 0.28), lineWidth: isSelected ? 2 : 1)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white, Color.black.opacity(0.56))
                                .offset(x: 3, y: 3)
                        }
                    }
                    .scaleEffect(isSelected ? 1.04 : 1)
                    .shadow(color: .black.opacity(isSelected ? 0.34 : 0.18), radius: isSelected ? 10 : 5, x: 0, y: 5)
            } else if let swatch {
                swatch.background
                    .frame(width: 52, height: 52)
                    .clipShape(Circle())
                    .overlay {
                        Circle()
                            .stroke(Color.white.opacity(isSelected ? 0.98 : 0.28), lineWidth: isSelected ? 2 : 1)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white, Color.black.opacity(0.56))
                                .offset(x: 3, y: 3)
                        }
                    }
                    .scaleEffect(isSelected ? 1.04 : 1)
                    .shadow(color: .black.opacity(isSelected ? 0.34 : 0.18), radius: isSelected ? 10 : 5, x: 0, y: 5)
            } else if let systemImage {
                Image(systemName: systemImage)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(Color.white.opacity(isSelected ? 0.22 : 0.12),
                                in: Circle())
                    .overlay {
                        Circle()
                            .stroke(Color.white.opacity(isSelected ? 0.95 : 0.26), lineWidth: isSelected ? 2 : 1)
                    }
                    .scaleEffect(isSelected ? 1.04 : 1)
                    .shadow(color: .black.opacity(0.22), radius: 7, x: 0, y: 5)
            }

            Text(title)
                .font(.caption2.weight(isSelected ? .bold : .semibold))
                .foregroundStyle(.white.opacity(isSelected ? 0.96 : 0.74))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .frame(width: 66, height: 72)
        .contentShape(Rectangle())
    }

    private var previewImage: UIImage {
        UIImage(systemName: "circle.hexagongrid.fill") ?? UIImage()
    }

    private var renderKey: String {
        "\(AtriaShareFormat.story.rawValue)-\(effectiveCanvasStyle.rawValue)-picture-\(selectedPictureBackground?.rawValue ?? "custom")-photo-\(photoBackground != nil)-\(photoBackgroundID.uuidString)-fixed-daily-trio"
    }

    private var effectiveCanvasStyle: AtriaShareCanvasStyle {
        photoBackground == nil ? canvasStyle : .midnight
    }

    private func previewSize(for size: CGSize) -> CGSize {
        let aspect = AtriaShareFormat.story.renderSize.width / AtriaShareFormat.story.renderSize.height
        let availableWidth = max(size.width, 1)
        let availableHeight = max(size.height - 82, 1)
        let widthFromHeight = availableHeight * aspect
        let width = min(availableWidth, widthFromHeight)
        return CGSize(width: width, height: width / aspect)
    }

    private func previewCornerRadius(for size: CGSize) -> CGFloat {
        let preview = previewSize(for: size)
        let fillsStage = preview.width >= size.width && preview.height >= size.height
        return fillsStage ? 0 : 8
    }

    private func previewScale(for size: CGSize) -> CGFloat {
        previewSize(for: size).height / AtriaShareFormat.story.renderSize.height
    }

    private func previewYOffset(for size: CGSize) -> CGFloat {
        0
    }

    private static func fixedDailyStatIDs() -> Set<String> {
        ["recovery", "strain", "sleep"]
    }
}

struct AtriaWorkoutShareSheet: View {
    let snapshot: AtriaWorkoutShareSnapshot
    @State private var canvasStyle: AtriaShareCanvasStyle = .midnight
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var photoBackground: UIImage?
    @State private var selectedPictureBackground: AtriaSharePictureBackground?
    @State private var photoBackgroundID = UUID()
    @State private var showCamera = false
    @State private var shareURL: URL?
    @State private var portableRecapURL: URL?
    @State private var saveState: AtriaShareSaveState = .idle
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                ZStack {
                    Color.black.ignoresSafeArea()
                    AtriaWorkoutShareCardView(snapshot: snapshot,
                                              format: .story,
                                              canvasStyle: effectiveCanvasStyle,
                                              photoBackground: photoBackground)
                        .frame(width: AtriaShareFormat.story.renderSize.width,
                               height: AtriaShareFormat.story.renderSize.height)
                        .scaleEffect(previewScale(for: proxy.size), anchor: .center)
                        .frame(width: previewSize(for: proxy.size).width,
                               height: previewSize(for: proxy.size).height)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .shadow(color: .black.opacity(0.26), radius: 24, x: 0, y: 14)

                    VStack {
                        Spacer()
                        canvasPicker
                            .padding(.vertical, 6)
                            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color.white.opacity(0.16), lineWidth: 1)
                            }
                            .padding(.horizontal, 8)
                            .padding(.bottom, 6)
                    }
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        shareCornerButton(systemImage: "xmark")
                    }
                    .accessibilityLabel("Cancel")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if let shareURL {
                        ShareLink(item: shareURL) {
                            shareCornerButton(systemImage: "square.and.arrow.up")
                        }
                        .accessibilityLabel("Share workout image")
                    } else {
                        Button {} label: {
                            shareCornerButton(systemImage: "square.and.arrow.up")
                        }
                        .disabled(true)
                    }
                }
            }
            .task(id: renderKey) {
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
                let renderedURL = try? await AtriaShareCardRenderer.renderURL(
                    snapshot: snapshot,
                    format: .story,
                    canvasStyle: effectiveCanvasStyle,
                    photoBackground: photoBackground
                )
                guard !Task.isCancelled else { return }
                shareURL = renderedURL
                portableRecapURL = try? await AtriaShareCardRenderer.renderPortableWorkoutURL(
                    snapshot: snapshot,
                    canvasStyle: effectiveCanvasStyle,
                    renderedImageURL: photoBackground == nil ? renderedURL : nil
                )
                saveState = .idle
            }
            .task(id: selectedPhotoItem) {
                guard let selectedPhotoItem,
                      let data = try? await selectedPhotoItem.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) else { return }
                photoBackground = image
                selectedPictureBackground = nil
                photoBackgroundID = UUID()
                canvasStyle = .midnight
            }
            .sheet(isPresented: $showCamera) {
                AtriaShareCameraPicker(image: Binding {
                    photoBackground
                } set: { image in
                    photoBackground = image
                    selectedPictureBackground = nil
                    photoBackgroundID = UUID()
                    if image != nil { canvasStyle = .midnight }
                })
            }
        }
    }

    private var canvasPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 9) {
                ForEach(AtriaShareCanvasStyle.allCases) { style in
                    Button {
                        canvasStyle = style
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } label: {
                        shareCanvasButtonLabel(title: style.shortLabel,
                                               isSelected: canvasStyle == style && photoBackground == nil,
                                               swatch: style)
                    }
                    .buttonStyle(.plain)
                }
                ForEach(AtriaSharePictureBackground.allCases) { background in
                    Button { selectPictureBackground(background) } label: {
                        shareCanvasButtonLabel(title: background.shortLabel,
                                               isSelected: selectedPictureBackground == background,
                                               assetName: background.assetName)
                    }
                    .buttonStyle(.plain)
                }
                PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                    shareCanvasButtonLabel(title: "Photo",
                                           isSelected: photoBackground != nil && selectedPictureBackground == nil,
                                           systemImage: "photo")
                }
                Button { showCamera = true } label: {
                    shareCanvasButtonLabel(title: "Camera", isSelected: false, systemImage: "camera")
                }
                if photoBackground != nil {
                    Button {
                        photoBackground = nil
                        selectedPictureBackground = nil
                        selectedPhotoItem = nil
                        photoBackgroundID = UUID()
                    } label: {
                        shareCanvasButtonLabel(title: "Clear", isSelected: false, systemImage: "xmark")
                    }
                }
                if portableRecapURL != nil || snapshot.routeFileURL != nil {
                    Menu {
                        if let portableRecapURL {
                            ShareLink(item: portableRecapURL) {
                                Label("Portable workout recap", systemImage: "doc.richtext")
                            }
                            .accessibilityLabel("Share portable workout recap without route")
                        }
                        if let routeFileURL = snapshot.routeFileURL {
                            ShareLink(item: routeFileURL) {
                                Label("Exact GPX route", systemImage: "map")
                            }
                            .accessibilityLabel("Share exact GPX route")
                        }
                    } label: {
                        shareCanvasButtonLabel(title: "Files", isSelected: false, systemImage: "ellipsis")
                    }
                    .accessibilityLabel("More workout sharing formats")
                }
            }
            .padding(.horizontal, 10)
        }
        .frame(height: 76)
    }

    private func shareCornerButton(systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.callout.weight(.semibold))
            .frame(width: 38, height: 38)
            .glassEffect(.regular.interactive(), in: Circle())
            .contentShape(Circle())
    }

    private func saveShareCardToPhotos() {
        guard let shareURL else { return }
        saveState = .saving
        Task {
            do {
                try await AtriaShareCardRenderer.savePNGToPhotoLibrary(from: shareURL)
                await MainActor.run {
                    saveState = .saved
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
            } catch {
                await MainActor.run {
                    saveState = .failed
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                }
            }
        }
    }

    private func shareCanvasButtonLabel(title: String,
                                        isSelected: Bool,
                                        swatch: AtriaShareCanvasStyle? = nil,
                                        assetName: String? = nil,
                                        systemImage: String? = nil) -> some View {
        VStack(spacing: 4) {
            Group {
                if let assetName {
                    Image(assetName).resizable().scaledToFill()
                } else if let swatch {
                    swatch.background
                } else {
                    Image(systemName: systemImage ?? "circle")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.white.opacity(0.12))
                }
            }
            .frame(width: 52, height: 52)
            .clipShape(Circle())
            .overlay(Circle().stroke(Color.white.opacity(isSelected ? 0.98 : 0.28), lineWidth: isSelected ? 2 : 1))

            Text(title)
                .font(.caption2.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .frame(width: 66, height: 72)
    }

    private func previewSize(for size: CGSize) -> CGSize {
        let availableWidth = max(size.width - 4, 1)
        let availableHeight = max(size.height - 4, 1)
        let aspect = AtriaShareFormat.story.renderSize.width / AtriaShareFormat.story.renderSize.height
        let width = min(availableWidth, availableHeight * aspect)
        return CGSize(width: width, height: width / aspect)
    }

    private func previewScale(for size: CGSize) -> CGFloat {
        previewSize(for: size).height / AtriaShareFormat.story.renderSize.height
    }

    private func selectPictureBackground(_ background: AtriaSharePictureBackground) {
        guard let image = UIImage(named: background.assetName) else { return }
        selectedPictureBackground = background
        selectedPhotoItem = nil
        photoBackground = image
        photoBackgroundID = UUID()
        canvasStyle = .midnight
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private var effectiveCanvasStyle: AtriaShareCanvasStyle {
        photoBackground == nil ? canvasStyle : .midnight
    }

    private var renderKey: String {
        "\(AtriaShareFormat.story.rawValue)-\(effectiveCanvasStyle.rawValue)-photo-\(photoBackground != nil)-\(photoBackgroundID.uuidString)-\(snapshot.personalRecord?.exercise ?? "no-pr")-\(snapshot.personalRecord?.set ?? "no-set")"
    }
}

private struct AtriaShareCameraPicker: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    @Binding var image: UIImage?

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.allowsEditing = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: AtriaShareCameraPicker

        init(parent: AtriaShareCameraPicker) {
            self.parent = parent
        }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            parent.image = info[.originalImage] as? UIImage
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

struct AtriaWeeklyShareSheet: View {
    let snapshot: AtriaWeeklyShareSnapshot
    @Environment(\.dismiss) private var dismiss
    @State private var canvasStyle: AtriaShareCanvasStyle = .midnight
    @State private var shareURL: URL?
    @State private var saveState: AtriaShareSaveState = .idle

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                ZStack {
                    Color.black.ignoresSafeArea()
                    AtriaWeeklyShareCardView(snapshot: snapshot,
                                             format: .story,
                                             canvasStyle: canvasStyle)
                        .frame(width: previewSize(for: proxy.size).width,
                               height: previewSize(for: proxy.size).height)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .shadow(color: .black.opacity(0.26), radius: 24, x: 0, y: 14)

                    VStack {
                        Spacer()
                        canvasPicker
                            .padding(.vertical, 6)
                            .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color.white.opacity(0.16), lineWidth: 1)
                            }
                            .padding(.horizontal, 8)
                            .padding(.bottom, 6)
                    }
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 8) {
                        if let shareURL {
                            ShareLink(item: shareURL,
                                      preview: SharePreview("My week on Atria",
                                                            image: Image(systemName: "calendar.badge.clock"))) {
                                shareToolbarLabel("Share", systemImage: "square.and.arrow.up")
                            }
                            .accessibilityLabel("Share week")
                            Button {
                                saveShareCardToPhotos()
                            } label: {
                                shareToolbarLabel(saveState.label, systemImage: saveState.systemImage)
                            }
                            .accessibilityLabel("Save weekly image to Photos")
                            .disabled(saveState == .saving)
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        shareToolbarLabel("Done", systemImage: "checkmark")
                    }
                }
            }
            .task(id: renderKey) {
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
                let renderedURL = try? await AtriaShareCardRenderer.renderURL(snapshot: snapshot,
                                                                               format: .story,
                                                                               canvasStyle: canvasStyle)
                guard !Task.isCancelled else { return }
                shareURL = renderedURL
                saveState = .idle
            }
        }
    }

    private var canvasPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 9) {
                ForEach(AtriaShareCanvasStyle.allCases) { style in
                    Button {
                        canvasStyle = style
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } label: {
                        shareCanvasButtonLabel(title: style.shortLabel,
                                               isSelected: canvasStyle == style,
                                               swatch: style)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
        }
        .frame(height: 76)
    }

    private func shareToolbarLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
    }

    private func saveShareCardToPhotos() {
        guard let shareURL else { return }
        saveState = .saving
        Task {
            do {
                try await AtriaShareCardRenderer.savePNGToPhotoLibrary(from: shareURL)
                await MainActor.run {
                    saveState = .saved
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
            } catch {
                await MainActor.run {
                    saveState = .failed
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                }
            }
        }
    }

    private func shareCanvasButtonLabel(title: String,
                                        isSelected: Bool,
                                        swatch: AtriaShareCanvasStyle) -> some View {
        VStack(spacing: 4) {
            swatch.background
                .frame(width: 34, height: 34)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.primary.opacity(0.12), lineWidth: 1))

            Text(title)
                .font(.caption2.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .frame(width: 68, height: 64)
        .background(isSelected ? Color.white.opacity(0.42) : Color.black.opacity(0.20),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isSelected ? Color.white.opacity(0.86) : Color.white.opacity(0.18), lineWidth: 1)
        }
    }

    private func previewSize(for size: CGSize) -> CGSize {
        let availableWidth = max(size.width - 4, 1)
        let availableHeight = max(size.height - 4, 1)
        let aspect = AtriaShareFormat.story.renderSize.width / AtriaShareFormat.story.renderSize.height
        let width = min(availableWidth, availableHeight * aspect)
        return CGSize(width: width, height: width / aspect)
    }

    private var renderKey: String {
        "\(AtriaShareFormat.story.rawValue)-\(canvasStyle.rawValue)"
    }
}

@MainActor
enum AtriaShareCardRenderer {
    private static var cache: [String: URL] = [:]

    static func renderURL(snapshot: AtriaShareSnapshot,
                          format: AtriaShareFormat,
                          selectedStatIDs: Set<String>,
                          lightCanvas: Bool) async throws -> URL {
        try await renderURL(snapshot: snapshot,
                            format: format,
                            selectedStatIDs: selectedStatIDs,
                            canvasStyle: lightCanvas ? .pearl : .midnight)
    }

    static func renderURL(snapshot: AtriaShareSnapshot,
                          format: AtriaShareFormat,
                          selectedStatIDs: Set<String>,
                          canvasStyle: AtriaShareCanvasStyle,
                          photoBackground: UIImage? = nil) async throws -> URL {
        let key = cacheKey(snapshot: snapshot,
                           format: format,
                           selectedStatIDs: selectedStatIDs,
                           canvasStyle: canvasStyle)
        if photoBackground == nil,
           let cached = cache[key],
           FileManager.default.fileExists(atPath: cached.path) {
            return cached
        }
        let data = try await renderPNGDataForExport(snapshot: snapshot,
                                                    format: format,
                                                    selectedStatIDs: selectedStatIDs,
                                                    canvasStyle: canvasStyle,
                                                    photoBackground: photoBackground)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("atria-share-\(key)")
            .appendingPathExtension("png")
        try await writeExportData(data, to: url)
        if photoBackground == nil {
            cache[key] = url
        }
        return url
    }

    static func renderURL(snapshot: AtriaWorkoutShareSnapshot,
                          format: AtriaShareFormat,
                          lightCanvas: Bool) async throws -> URL {
        try await renderURL(snapshot: snapshot,
                            format: format,
                            canvasStyle: lightCanvas ? .pearl : .midnight)
    }

    static func renderURL(snapshot: AtriaWorkoutShareSnapshot,
                          format: AtriaShareFormat,
                          canvasStyle: AtriaShareCanvasStyle,
                          photoBackground: UIImage? = nil) async throws -> URL {
        let key = workoutCacheKey(snapshot: snapshot,
                                  format: format,
                                  canvasStyle: canvasStyle)
        if photoBackground == nil,
           let cached = cache[key], FileManager.default.fileExists(atPath: cached.path) {
            return cached
        }
        let data = try await renderPNGDataForExport(snapshot: snapshot,
                                                    format: format,
                                                    canvasStyle: canvasStyle,
                                                    photoBackground: photoBackground)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("atria-workout-share-\(key)-\(photoBackground == nil ? "canvas" : UUID().uuidString)")
            .appendingPathExtension("png")
        try await writeExportData(data, to: url)
        if photoBackground == nil { cache[key] = url }
        return url
    }

    /// Creates a single-file recap that opens in any browser and remains useful
    /// to recipients who do not have Atria. Exact route coordinates are
    /// deliberately excluded; GPX remains a separate, explicit share action.
    static func renderPortableWorkoutURL(snapshot: AtriaWorkoutShareSnapshot,
                                         canvasStyle: AtriaShareCanvasStyle,
                                         renderedImageURL: URL? = nil) async throws -> URL {
        let key = workoutCacheKey(snapshot: snapshot,
                                  format: .story,
                                  canvasStyle: canvasStyle)
        let cacheKey = "portable-\(key)"
        if let cached = cache[cacheKey], FileManager.default.fileExists(atPath: cached.path) {
            return cached
        }

        let imageData: Data
        if let renderedImageURL {
            imageData = try await readExportData(from: renderedImageURL)
        } else {
            imageData = try await renderPNGDataForExport(snapshot: snapshot,
                                                         format: .story,
                                                         canvasStyle: canvasStyle)
        }
        let html = portableWorkoutHTML(snapshot: snapshot, imageData: imageData)
        let activity = fileSafeSlug(snapshot.activity)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Atria-\(activity)-\(stableDigest(key))")
            .appendingPathExtension("html")
        try await writeExportData(Data(html.utf8), to: url)
        cache[cacheKey] = url
        return url
    }

    static func portableWorkoutHTML(snapshot: AtriaWorkoutShareSnapshot,
                                    imageData: Data) -> String {
        let image = imageData.base64EncodedString()
        let date = atriaShareDateLineFormatter.string(from: snapshot.date)
        let optionalMetrics = [
            snapshot.averageHeartRate.map { ("Average heart rate", $0) },
            snapshot.distance.map { ("Distance", $0) },
            snapshot.pace.map { ("Pace", $0) }
        ].compactMap { $0 }
        let metrics = [
            ("Duration", snapshot.duration),
            ("Workout strain", snapshot.strain),
            ("Peak heart rate", snapshot.peakHeartRate)
        ] + optionalMetrics
        let metricHTML = metrics.map { label, value in
            "<div class=\"metric\"><span>\(htmlEscaped(label))</span><strong>\(htmlEscaped(value))</strong></div>"
        }.joined()
        let zoneHTML = snapshot.zoneMinutes
            .filter { $0.minutes > 0 }
            .map { "<li>\(htmlEscaped($0.label)): \($0.minutes) min</li>" }
            .joined()
        let routeNote = snapshot.routeFileURL == nil
            ? ""
            : "<p class=\"privacy\">Precise route omitted for privacy.</p>"

        return """
        <!doctype html><html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>\(htmlEscaped(snapshot.activity)) · Atria</title>
        <style>
        :root{color-scheme:dark}*{box-sizing:border-box}body{margin:0;background:#08090b;color:#f7f7f8;font:16px -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}main{width:min(720px,100%);margin:auto;padding:24px}img{display:block;width:min(100%,420px);margin:0 auto 28px;border-radius:24px}h1{margin:0;font-size:2rem}p{color:#a8abb2}.metrics{display:grid;grid-template-columns:repeat(auto-fit,minmax(145px,1fr));gap:10px;margin:22px 0}.metric{padding:14px;border:1px solid #30333a;border-radius:14px;background:#15171b}.metric span{display:block;color:#999da6;font-size:.78rem;text-transform:uppercase}.metric strong{display:block;margin-top:5px;font-size:1.25rem}ul{padding-left:20px}.privacy{padding:12px 14px;border-radius:12px;background:#17191d;font-size:.9rem}footer{margin-top:28px;color:#777b84;font-size:.82rem}
        </style></head><body><main>
        <img src="data:image/png;base64,\(image)" alt="Atria workout card">
        <h1>\(htmlEscaped(snapshot.activity))</h1><p>\(htmlEscaped(date))</p>
        <section class="metrics">\(metricHTML)</section>
        \(zoneHTML.isEmpty ? "" : "<h2>Zone minutes</h2><ul>\(zoneHTML)</ul>")
        \(routeNote)<footer>Recorded with Atria · This recap is self-contained and works without the app.</footer>
        </main></body></html>
        """
    }

    static func renderURL(snapshot: AtriaWeeklyShareSnapshot,
                          format: AtriaShareFormat,
                          lightCanvas: Bool) async throws -> URL {
        try await renderURL(snapshot: snapshot,
                            format: format,
                            canvasStyle: lightCanvas ? .pearl : .midnight)
    }

    static func renderURL(snapshot: AtriaWeeklyShareSnapshot,
                          format: AtriaShareFormat,
                          canvasStyle: AtriaShareCanvasStyle) async throws -> URL {
        let key = weeklyCacheKey(snapshot: snapshot,
                                 format: format,
                                 canvasStyle: canvasStyle)
        if let cached = cache[key], FileManager.default.fileExists(atPath: cached.path) {
            return cached
        }
        let data = try await renderPNGDataForExport(snapshot: snapshot,
                                                    format: format,
                                                    canvasStyle: canvasStyle)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("atria-weekly-share-\(key)")
            .appendingPathExtension("png")
        try await writeExportData(data, to: url)
        cache[key] = url
        return url
    }

    static func renderPNGData(snapshot: AtriaShareSnapshot,
                              format: AtriaShareFormat,
                              selectedStatIDs: Set<String>,
                              lightCanvas: Bool) throws -> Data {
        try renderPNGData(snapshot: snapshot,
                          format: format,
                          selectedStatIDs: selectedStatIDs,
                          canvasStyle: lightCanvas ? .pearl : .midnight)
    }

    static func renderPNGData(snapshot: AtriaShareSnapshot,
                              format: AtriaShareFormat,
                              selectedStatIDs: Set<String>,
                              canvasStyle: AtriaShareCanvasStyle,
                              photoBackground: UIImage? = nil) throws -> Data {
        guard let data = pngData(from: try renderedCGImage(snapshot: snapshot,
                                                           format: format,
                                                           selectedStatIDs: selectedStatIDs,
                                                           canvasStyle: canvasStyle,
                                                           photoBackground: photoBackground)) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data
    }

    private static func renderedCGImage(snapshot: AtriaShareSnapshot,
                                        format: AtriaShareFormat,
                                        selectedStatIDs: Set<String>,
                                        canvasStyle: AtriaShareCanvasStyle,
                                        photoBackground: UIImage? = nil) throws -> CGImage {
        let view = AtriaShareCardView(snapshot: snapshot,
                                      format: format,
                                      selectedStatIDs: selectedStatIDs,
                                      canvasStyle: canvasStyle,
                                      photoBackground: photoBackground)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        renderer.proposedSize = ProposedViewSize(format.renderSize)
        renderer.isOpaque = true
        guard let image = renderer.uiImage,
              let cgImage = image.cgImage else {
            throw CocoaError(.fileWriteUnknown)
        }
        return cgImage
    }

    static func renderPNGData(snapshot: AtriaWeeklyShareSnapshot,
                              format: AtriaShareFormat,
                              lightCanvas: Bool) throws -> Data {
        try renderPNGData(snapshot: snapshot,
                          format: format,
                          canvasStyle: lightCanvas ? .pearl : .midnight)
    }

    static func renderPNGData(snapshot: AtriaWeeklyShareSnapshot,
                              format: AtriaShareFormat,
                              canvasStyle: AtriaShareCanvasStyle) throws -> Data {
        guard let data = pngData(from: try renderedCGImage(snapshot: snapshot,
                                                           format: format,
                                                           canvasStyle: canvasStyle)) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data
    }

    private static func renderedCGImage(snapshot: AtriaWeeklyShareSnapshot,
                                        format: AtriaShareFormat,
                                        canvasStyle: AtriaShareCanvasStyle) throws -> CGImage {
        let view = AtriaWeeklyShareCardView(snapshot: snapshot,
                                            format: format,
                                            canvasStyle: canvasStyle)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        renderer.proposedSize = ProposedViewSize(format.renderSize)
        renderer.isOpaque = true
        guard let image = renderer.uiImage,
              let cgImage = image.cgImage else {
            throw CocoaError(.fileWriteUnknown)
        }
        return cgImage
    }

    static func renderPNGData(snapshot: AtriaWorkoutShareSnapshot,
                              format: AtriaShareFormat,
                              lightCanvas: Bool) throws -> Data {
        try renderPNGData(snapshot: snapshot,
                          format: format,
                          canvasStyle: lightCanvas ? .pearl : .midnight)
    }

    static func renderPNGData(snapshot: AtriaWorkoutShareSnapshot,
                              format: AtriaShareFormat,
                              canvasStyle: AtriaShareCanvasStyle,
                              photoBackground: UIImage? = nil) throws -> Data {
        guard let data = pngData(from: try renderedCGImage(snapshot: snapshot,
                                                           format: format,
                                                           canvasStyle: canvasStyle,
                                                           photoBackground: photoBackground)) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data
    }

    private static func renderedCGImage(snapshot: AtriaWorkoutShareSnapshot,
                                        format: AtriaShareFormat,
                                        canvasStyle: AtriaShareCanvasStyle,
                                        photoBackground: UIImage? = nil) throws -> CGImage {
        let view = AtriaWorkoutShareCardView(snapshot: snapshot,
                                             format: format,
                                             canvasStyle: canvasStyle,
                                             photoBackground: photoBackground)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        renderer.proposedSize = ProposedViewSize(format.renderSize)
        renderer.isOpaque = true
        guard let image = renderer.uiImage,
              let cgImage = image.cgImage else {
            throw CocoaError(.fileWriteUnknown)
        }
        return cgImage
    }

    private struct SendableCGImage: @unchecked Sendable {
        let value: CGImage
    }

    private static func renderPNGDataForExport(snapshot: AtriaShareSnapshot,
                                               format: AtriaShareFormat,
                                               selectedStatIDs: Set<String>,
                                               canvasStyle: AtriaShareCanvasStyle,
                                               photoBackground: UIImage? = nil) async throws -> Data {
        let image = SendableCGImage(value: try renderedCGImage(snapshot: snapshot,
                                                               format: format,
                                                               selectedStatIDs: selectedStatIDs,
                                                               canvasStyle: canvasStyle,
                                                               photoBackground: photoBackground))
        return try await encodePNGForExport(image)
    }

    private static func renderPNGDataForExport(snapshot: AtriaWeeklyShareSnapshot,
                                               format: AtriaShareFormat,
                                               canvasStyle: AtriaShareCanvasStyle) async throws -> Data {
        let image = SendableCGImage(value: try renderedCGImage(snapshot: snapshot,
                                                               format: format,
                                                               canvasStyle: canvasStyle))
        return try await encodePNGForExport(image)
    }

    private static func renderPNGDataForExport(snapshot: AtriaWorkoutShareSnapshot,
                                               format: AtriaShareFormat,
                                               canvasStyle: AtriaShareCanvasStyle,
                                               photoBackground: UIImage? = nil) async throws -> Data {
        let image = SendableCGImage(value: try renderedCGImage(snapshot: snapshot,
                                                               format: format,
                                                               canvasStyle: canvasStyle,
                                                               photoBackground: photoBackground))
        return try await encodePNGForExport(image)
    }

    nonisolated private static func encodePNGForExport(_ image: SendableCGImage) async throws -> Data {
        try await Task.detached(priority: .utility) {
            guard let data = pngData(from: image.value) else {
                throw CocoaError(.fileWriteUnknown)
            }
            return data
        }.value
    }

    nonisolated private static func writeExportData(_ data: Data, to url: URL) async throws {
        try await Task.detached(priority: .utility) {
            try data.write(to: url, options: .atomic)
        }.value
    }

    nonisolated private static func readExportData(from url: URL) async throws -> Data {
        try await Task.detached(priority: .utility) {
            try Data(contentsOf: url)
        }.value
    }

    static func pngPixelSize(_ data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat else {
            return nil
        }
        return CGSize(width: width, height: height)
    }

    static func containsEXIFOrGPS(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return false
        }
        return hasIdentifyingEXIFPayload(properties[kCGImagePropertyExifDictionary])
            || hasMetadataPayload(properties[kCGImagePropertyGPSDictionary])
    }

    static func savePNGToPhotoLibrary(from url: URL) async throws {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        switch status {
        case .authorized, .limited:
            break
        case .notDetermined:
            let requested = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard requested == .authorized || requested == .limited else {
                throw photoLibraryError()
            }
        case .denied, .restricted:
            throw photoLibraryError()
        @unknown default:
            throw photoLibraryError()
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                let options = PHAssetResourceCreationOptions()
                options.uniformTypeIdentifier = UTType.png.identifier
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, fileURL: url, options: options)
            } completionHandler: { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: photoLibraryError())
                }
            }
        }
    }

    nonisolated private static func pngData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyPNGDictionary: [:]] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return data as Data
    }

    private static func hasMetadataPayload(_ value: Any?) -> Bool {
        guard let value else { return false }
        if let dictionary = value as? [AnyHashable: Any] {
            return !dictionary.isEmpty
        }
        return true
    }

    private static func hasIdentifyingEXIFPayload(_ value: Any?) -> Bool {
        guard let dictionary = value as? [AnyHashable: Any] else {
            return value != nil
        }
        let technicalKeys: Set<String> = [
            String(describing: kCGImagePropertyExifPixelXDimension),
            String(describing: kCGImagePropertyExifPixelYDimension),
            String(describing: kCGImagePropertyExifColorSpace),
            String(describing: kCGImagePropertyExifComponentsConfiguration)
        ]
        return dictionary.keys.contains { key in
            !technicalKeys.contains(String(describing: key))
        }
    }

    private nonisolated static func photoLibraryError() -> NSError {
        NSError(domain: "AtriaSharePhotos", code: 1, userInfo: nil)
    }

    private static func cacheKey(snapshot: AtriaShareSnapshot,
                                 format: AtriaShareFormat,
                                 selectedStatIDs: Set<String>,
                                 canvasStyle: AtriaShareCanvasStyle) -> String {
        let day = Int(snapshot.date.timeIntervalSince1970 / 86_400)
        let chips = selectedStatIDs.sorted().joined(separator: "-")
        return "\(day)-\(format.rawValue)-\(canvasStyle.rawValue)-\(chips)"
    }

    static func workoutCacheKey(snapshot: AtriaWorkoutShareSnapshot,
                                format: AtriaShareFormat,
                                canvasStyle: AtriaShareCanvasStyle) -> String {
        let zones = snapshot.zoneMinutes.map {
            "\($0.id):\($0.label):\($0.minutes):\($0.tintHex)"
        }.joined(separator: "|")
        let content = [
            String(snapshot.date.timeIntervalSince1970), snapshot.activity,
            snapshot.duration, snapshot.strain, snapshot.peakHeartRate,
            snapshot.averageHeartRate ?? "", snapshot.distance ?? "", snapshot.pace ?? "",
            snapshot.activitySystemImage, zones,
            snapshot.routePoints.map {
                "\($0.latitude):\($0.longitude):\($0.startsNewSegment ? 1 : 0)"
            }.joined(separator: "|"),
            snapshot.personalRecord?.exercise ?? "", snapshot.personalRecord?.set ?? "",
            snapshot.personalRecord?.badge ?? "", format.rawValue, canvasStyle.rawValue
        ].joined(separator: "\u{1f}")
        return "workout-\(fileSafeSlug(snapshot.activity))-\(stableDigest(content))"
    }

    private static func fileSafeSlug(_ value: String) -> String {
        let slug = value.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : "-"
        }
        return String(slug).split(separator: "-").joined(separator: "-").prefix(40).description
    }

    private static func stableDigest(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private static func htmlEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func weeklyCacheKey(snapshot: AtriaWeeklyShareSnapshot,
                                       format: AtriaShareFormat,
                                       canvasStyle: AtriaShareCanvasStyle) -> String {
        let day = Int(snapshot.date.timeIntervalSince1970 / 86_400)
        return "\(day)-weekly-\(format.rawValue)-\(canvasStyle.rawValue)"
    }
}

private extension AtriaShareSnapshot.Ring {
    var tint: Color { Color(hex: tintHex) }
}

private extension AtriaWorkoutShareSnapshot.ZoneMinute {
    var tint: Color { Color(hex: tintHex) }
}

private extension Color {
    init(hex: String) {
        let clean = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let value = UInt64(clean, radix: 16) ?? 0xffffff
        let red = Double((value >> 16) & 0xff) / 255.0
        let green = Double((value >> 8) & 0xff) / 255.0
        let blue = Double(value & 0xff) / 255.0
        self.init(red: red, green: green, blue: blue)
    }
}
