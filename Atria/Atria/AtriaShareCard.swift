import ImageIO
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Custom camera/library images can be tens of megapixels, while Atria's
/// largest exported canvas is 1080 x 1920. Keeping the original decode alive
/// makes every SwiftUI preview pass and ImageRenderer export carry unnecessary
/// image pressure, and `UIImage(data:)` in a view `.task` can perform that
/// decode on the main actor. Prepare one orientation-correct, display-decoded
/// image at the actual export ceiling before publishing it to SwiftUI state.
enum AtriaSharePhotoPreparation {
    static let maximumPixelDimension = 1_920

    private struct PreparedCGImage: @unchecked Sendable {
        let value: CGImage
    }

    static func preparedImage(from data: Data,
                              maximumPixelDimension: Int = maximumPixelDimension) async -> UIImage? {
        guard maximumPixelDimension > 0 else { return nil }
        let preparationTask = Task.detached(priority: .userInitiated) {
            guard !Task.isCancelled,
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(
                    source,
                    0,
                    [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: maximumPixelDimension,
                        kCGImageSourceShouldCacheImmediately: true,
                    ] as CFDictionary
                  ) else { return nil as PreparedCGImage? }
            return PreparedCGImage(value: image)
        }
        let prepared = await withTaskCancellationHandler {
            await preparationTask.value
        } onCancel: {
            preparationTask.cancel()
        }
        guard !Task.isCancelled, let prepared else { return nil }
        return UIImage(cgImage: prepared.value, scale: 1, orientation: .up)
    }

    /// `UIImagePickerController` has already produced a UIImage. UIKit's async
    /// thumbnail preparation runs on its private queue and preserves camera
    /// orientation, keeping the picker callback and share-sheet transition
    /// responsive. Images already within the export bound are display-prepared
    /// without changing their resolution.
    static func preparedImage(from image: UIImage,
                              maximumPixelDimension: Int = maximumPixelDimension) async -> UIImage? {
        guard maximumPixelDimension > 0 else { return nil }
        let pixelWidth = image.cgImage?.width ?? Int((image.size.width * image.scale).rounded())
        let pixelHeight = image.cgImage?.height ?? Int((image.size.height * image.scale).rounded())
        let largestPixelDimension = max(pixelWidth, pixelHeight)
        if largestPixelDimension <= maximumPixelDimension {
            return await image.byPreparingForDisplay() ?? image
        }
        let ratio = CGFloat(maximumPixelDimension) / CGFloat(max(largestPixelDimension, 1))
        let targetSize = CGSize(width: max(1, CGFloat(pixelWidth) * ratio),
                                height: max(1, CGFloat(pixelHeight) * ratio))
        return await image.byPreparingThumbnail(ofSize: targetSize)
    }

    static func acceptsResult(generation: UInt64,
                              currentGeneration: UInt64,
                              requestedRenderKey: String,
                              currentRenderKey: String) -> Bool {
        generation == currentGeneration && requestedRenderKey == currentRenderKey
    }
}

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
        let stateTintHex: String?
        let targetFraction: Double?

        init(title: String,
             value: String,
             detail: String,
             tintHex: String,
             fill: Double?,
             stateTintHex: String? = nil,
             targetFraction: Double? = nil) {
            self.title = title
            self.value = value
            self.detail = detail
            self.tintHex = tintHex
            self.fill = fill
            self.stateTintHex = stateTintHex
            self.targetFraction = targetFraction
        }
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

struct AtriaWorkoutShareSnapshot: Equatable, Hashable, Sendable {
    struct ZoneMinute: Equatable, Hashable, Identifiable, Sendable {
        let id: Int
        let label: String
        let minutes: Int
        let tintHex: String
    }

    struct PersonalRecord: Equatable, Hashable, Sendable {
        let exercise: String
        let set: String
        let badge: String
    }

    struct RoutePoint: Equatable, Hashable, Sendable {
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
    var steps: String? = nil
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

/// Truth-preserving projections used by the workout social card. Share images
/// must not turn an unavailable metric into visible progress or make equal-size
/// zone blocks imply equal time in every zone.
enum AtriaWorkoutSharePresentation {
    struct CompletedSteps: Equatable {
        let valueText: String
        let detailText: String
        let isAvailable: Bool
    }

    /// A social card should contain only measured values. Internal learning or
    /// sparse-evidence sentinels are useful inside Atria, but exporting them as
    /// a visible stat makes an unfinished calculation look like part of the
    /// workout recap.
    static func metricIsAvailable(_ text: String?) -> Bool {
        guard let text else { return false }
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        return !["--", "learning", "building", "incomplete", "unknown", "unavailable"]
            .contains(normalized)
    }

    /// An unvalidated detector returning zero is absence of usable evidence,
    /// not a social statistic. Keep a reference-validated zero available (for
    /// an intentionally stationary or immediately-ended activity), but never
    /// export the misleading `~0 steps` seen on a recorded walking workout.
    static func stepsText(count: Int?,
                          isEstimated: Bool?,
                          activity: AtriaWorkoutActivityType) -> String? {
        guard [.walking, .running, .hiking].contains(activity),
              let count,
              count >= 0 else { return nil }
        // The only current estimated workout source is the disproven sparse
        // v24 cadence model. Sharing accepts detector-measured strap steps
        // only; a research estimate must never look like a workout result.
        guard isEstimated == false else { return nil }
        return "\(count)"
    }

    /// A completed-workout card must never turn an in-flight/stale counter into
    /// a whole-workout claim. The capture must be the same fresh packet evidence
    /// that was accepted at End; missing legacy provenance stays omitted.
    static func completedStepsText(count: Int?,
                                   isEstimated: Bool?,
                                   capturedAt: Date?,
                                   workoutEndedAt: Date,
                                   activity: AtriaWorkoutActivityType) -> String? {
        guard let presentation = completedStepsPresentation(
            count: count,
            isEstimated: isEstimated,
            capturedAt: capturedAt,
            workoutEndedAt: workoutEndedAt,
            activity: activity
        ), presentation.isAvailable else { return nil }
        return presentation.valueText
    }

    /// Saved walking workouts always explain their strap-step state. Sharing
    /// remains measured-values-only, but the in-app workout detail must not
    /// make missing/stale motion evidence disappear as if steps were
    /// irrelevant.
    static func completedStepsPresentation(
        count: Int?,
        isEstimated: Bool?,
        capturedAt: Date?,
        workoutEndedAt: Date,
        activity: AtriaWorkoutActivityType
    ) -> CompletedSteps? {
        guard [.walking, .running, .hiking].contains(activity) else { return nil }
        guard let capturedAt else {
            return CompletedSteps(
                valueText: "--",
                detailText: "No verified strap motion for this workout",
                isAvailable: false
            )
        }
        guard capturedAt <= workoutEndedAt.addingTimeInterval(
            AtriaLiveWorkoutStepProjection.futureTolerance
        ), workoutEndedAt.timeIntervalSince(capturedAt)
            <= AtriaLiveWorkoutStepProjection.freshnessInterval else {
            return CompletedSteps(
                valueText: "--",
                detailText: "Strap motion was not verified at workout end",
                isAvailable: false
            )
        }
        guard let valueText = stepsText(
            count: count,
            isEstimated: isEstimated,
            activity: activity
        ) else {
            return CompletedSteps(
                valueText: "--",
                detailText: "No verified strap step count for this workout",
                isAvailable: false
            )
        }
        return CompletedSteps(
            valueText: valueText,
            detailText: "WHOOP strap motion",
            isAvailable: true
        )
    }

    static func strainFraction(_ text: String) -> Double? {
        guard let value = Double(text), value.isFinite, value >= 0 else { return nil }
        return min(value / 21, 1)
    }

    static func zoneFractions(_ zones: [AtriaWorkoutShareSnapshot.ZoneMinute]) -> [Int: Double] {
        let positive = zones.filter { $0.minutes > 0 }
        let total = positive.reduce(0) { $0 + $1.minutes }
        guard total > 0 else { return [:] }
        return Dictionary(uniqueKeysWithValues: positive.map {
            ($0.id, Double($0.minutes) / Double(total))
        })
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

/// Geometry shared by the daily-ring and workout composers. The top actions
/// and style rail are deliberately siblings of the preview, so neither can
/// cover any part of the exported 9:16 story while the user is editing it.
enum AtriaShareComposerLayout {
    static let topControlsHeight: CGFloat = 52
    static let styleRailHeight: CGFloat = 82
    static let storyAspectRatio: CGFloat = 9.0 / 16.0

    static func fittedStorySize(in availableSize: CGSize) -> CGSize {
        let availableWidth = max(availableSize.width, 1)
        let availableHeight = max(availableSize.height, 1)
        let width = min(availableWidth, availableHeight * storyAspectRatio)
        return CGSize(width: width, height: width / storyAspectRatio)
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
    case dawnRidgeline
    case kineticTopo
    case neonCircuit
    case concreteAscent

    var id: String { rawValue }

    var shortLabel: String {
        switch self {
        case .abstractPulse: return "Pulse"
        case .alpineDawn: return "Alpine"
        case .neonRun: return "Neon"
        case .animeAscension: return "Ascend"
        case .dawnRidgeline: return "Ridgeline"
        case .kineticTopo: return "Topo"
        case .neonCircuit: return "Circuit"
        case .concreteAscent: return "Ascent"
        }
    }

    var assetName: String {
        switch self {
        case .abstractPulse: return "ShareAbstractPulse"
        case .alpineDawn: return "ShareAlpineDawn"
        case .neonRun: return "ShareNeonRun"
        case .animeAscension: return "ShareAnimeAscension"
        case .dawnRidgeline: return "ShareDawnRidgeline"
        case .kineticTopo: return "ShareKineticTopo"
        case .neonCircuit: return "ShareNeonCircuit"
        case .concreteAscent: return "ShareConcreteAscent"
        }
    }
}

/// Export work is user initiated. The card itself remains a live SwiftUI
/// preview; changing a canvas or photo must never schedule a full 1080 x 1920
/// `ImageRenderer` pass behind the user's interaction.
private enum AtriaSharePreparationState: Equatable {
    case idle
    case preparing
    case failed

    var isPreparing: Bool { self == .preparing }
}

private struct AtriaShareActivityPayload: Identifiable {
    let id = UUID()
    let url: URL
}

private struct AtriaSystemShareSheet: UIViewControllerRepresentable {
    let url: URL
    let onCompletion: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCompletion: onCompletion)
    }

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in
            Task { @MainActor in
                context.coordinator.finishOnce()
            }
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController,
                                context: Context) {}

    @MainActor
    final class Coordinator: NSObject {
        private let onCompletion: () -> Void
        private var didFinish = false

        init(onCompletion: @escaping () -> Void) {
            self.onCompletion = onCompletion
        }

        func finishOnce() {
            guard !didFinish else { return }
            didFinish = true
            onCompletion()
        }
    }
}

struct AtriaShareCardView: View {
    let snapshot: AtriaShareSnapshot
    let format: AtriaShareFormat
    let selectedStatIDs: Set<String>
    let canvasStyle: AtriaShareCanvasStyle
    let photoBackground: UIImage?
    /// Honors the same Today-rings layout preference so a shared card matches
    /// what the wearer sees in the app (concentric vs WHOOP-style separate).
    @AtriaDefault(AtriaRingLayoutStyle.defaultsKey) private var ringLayoutRaw: String = "concentric"
    private var ringLayout: AtriaRingLayoutStyle { AtriaRingLayoutStyle(rawValue: ringLayoutRaw) ?? .concentric }

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
                .padding(.top, format == .story ? 52 : 34)

                Spacer(minLength: format == .story ? 20 : 24)

                shareRings

                Spacer(minLength: format == .story ? 14 : 18)

                atriaSafeWordmark

                VStack(spacing: format == .story ? 8 : 9) {
                    ForEach(selectedStats) { stat in
                        statChip(stat)
                    }
                }
                .frame(maxWidth: format == .story ? 300 : 306)
                .padding(.top, format == .story ? 18 : 16)

                // Keep the social-network reply/send controls clear of Atria's
                // metrics while still showing the complete card in preview.
                Spacer(minLength: format == .story ? 88 : 48)
            }
            .padding(.leading, format == .story ? 36 : 34)
            .padding(.trailing, format == .story ? 44 : 34)
        }
        .frame(width: format.renderSize.width, height: format.renderSize.height)
    }

    private var foreground: Color { canvasStyle.foreground }

    private var dailyHeroSize: CGFloat {
        format == .story ? 218 : 220
    }

    private var radialGlow: some View {
        RadialGradient(colors: [snapshot.recovery.tint.opacity(canvasStyle.isLight ? 0.13 : 0.08), .clear],
                       center: .center,
                       startRadius: 20,
                       endRadius: format == .story ? 270 : 210)
            .blendMode(canvasStyle.blendMode)
    }

    /// Concentric (default) vs WHOOP-style separate rings, honoring the same
    /// AtriaRingLayoutStyle preference the Today rings use.
    @ViewBuilder
    private var shareRings: some View {
        switch ringLayout {
        case .concentric:
            shareRingsConcentric
                .frame(width: dailyHeroSize, height: dailyHeroSize)
        case .separate:
            shareRingsSeparate
                .frame(maxWidth: .infinity)
                .frame(height: dailyHeroSize * 0.7)
        }
    }

    /// WHOOP-style row of three labeled rings for the share card. Ring size
    /// adapts to the available card width so all three fit every format.
    private var shareRingsSeparate: some View {
        GeometryReader { geo in
            let spacing: CGFloat = format == .story ? 18 : 14
            let diameter = min(format == .story ? 108 : 96,
                               (geo.size.width - spacing * 2) / 3)
            let lineWidth = max(8, diameter * 0.1)
            HStack(spacing: spacing) {
                shareSeparateRing(snapshot.sleep, label: "Sleep", diameter: diameter, lineWidth: lineWidth)
                shareSeparateRing(snapshot.recovery, label: "Recovery", diameter: diameter, lineWidth: lineWidth)
                shareSeparateRing(snapshot.strain, label: "Strain", diameter: diameter, lineWidth: lineWidth)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
        }
    }

    private func shareSeparateRing(_ ringData: AtriaShareSnapshot.Ring,
                                   label: String,
                                   diameter: CGFloat,
                                   lineWidth: CGFloat) -> some View {
        VStack(spacing: 9) {
            ZStack {
                ring(ringData, diameter: diameter, lineWidth: lineWidth)
                Text(ringData.value)
                    .font(.system(size: diameter * 0.26, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(foreground)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .frame(width: diameter * 0.72)
            }
            .frame(width: diameter, height: diameter)
            Text(label)
                .font(.system(size: format == .story ? 12 : 10, weight: .medium, design: .rounded))
                .tracking(1.5)
                .textCase(.uppercase)
                .foregroundStyle(foreground.opacity(0.48))
        }
        .frame(maxWidth: .infinity)
    }

    private var shareRingsConcentric: some View {
        ZStack {
            ring(snapshot.sleep, diameter: format == .story ? 218 : 220, lineWidth: format == .story ? 14 : 14)
            ring(snapshot.recovery, diameter: format == .story ? 178 : 182, lineWidth: format == .story ? 11 : 12)
            ring(snapshot.strain, diameter: format == .story ? 144 : 148, lineWidth: format == .story ? 9 : 10)
            VStack(spacing: 9) {
                Text(recoveryHeroValue)
                    .font(.system(size: format == .story ? 52 : 40, weight: .light, design: .rounded))
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
            if let targetFraction = ring.targetFraction {
                targetMarker(diameter: diameter,
                             lineWidth: lineWidth,
                             tint: ring.stateTint ?? ring.tint,
                             fraction: targetFraction)
            }
        }
        .frame(width: diameter, height: diameter)
    }

    private func targetMarker(diameter: CGFloat,
                              lineWidth: CGFloat,
                              tint: Color,
                              fraction: Double) -> some View {
        let clamped = min(max(fraction, 0), 1)
        let theta = Angle.degrees(-90 + 360 * clamped)
        let radius = diameter / 2
        return Capsule()
            .fill(tint)
            .overlay(Capsule().strokeBorder(Color.black.opacity(0.45), lineWidth: 1))
            .frame(width: 3, height: lineWidth + 5)
            .rotationEffect(theta + .degrees(90))
            .offset(x: radius * cos(theta.radians), y: radius * sin(theta.radians))
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

    /// Uppercases only the first letter; acronyms and the rest stay as written.
    static func sentenceCased(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    private func statChip(_ stat: AtriaShareSnapshot.Stat) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(stat.title)
                    .font(.system(size: format == .story ? 9 : 10, weight: .semibold, design: .rounded))
                    .tracking(1.4)
                    .foregroundStyle(foreground.opacity(0.50))
                    .textCase(.uppercase)
                // Details arrive from three vocabularies ("no sleep yet",
                // "learning", "No sleep this cycle"); on one designed card
                // they read as one voice (2026-09-02 share-sheet screenshot).
                Text(Self.sentenceCased(stat.detail))
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

                if hasRoute {
                    routeTrace
                        .frame(maxWidth: format == .story ? 310 : 320)
                        .frame(height: routeHeroHeight)

                    workoutRing
                        .frame(width: workoutRingSize, height: workoutRingSize)
                } else {
                    workoutRing
                        .frame(width: workoutRingSize, height: workoutRingSize)
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
            .padding(.leading, 30)
            .padding(.trailing, format == .story ? 40 : 30)
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
    private var contentSpacing: CGFloat { hasRoute ? (format == .story ? 7 : 8) : (format == .story ? 16 : 15) }
    private var topSpacing: CGFloat { hasRoute ? (format == .story ? 24 : 10) : (format == .story ? 70 : 40) }
    private var bottomSpacing: CGFloat { hasRoute ? (format == .story ? 42 : 10) : (format == .story ? 88 : 28) }
    private var workoutRingSize: CGFloat { hasRoute ? (format == .story ? 124 : 132) : (format == .story ? 200 : 204) }
    private var routeHeroHeight: CGFloat { format == .story ? 148 : 118 }

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
            if let strainFill {
                Circle()
                    .stroke(accent.opacity(canvasStyle.isLight ? 0.16 : 0.20),
                            style: StrokeStyle(lineWidth: ringLineWidth, lineCap: .round))
                Circle()
                    .trim(from: 0, to: strainFill)
                    .stroke(accent, style: StrokeStyle(lineWidth: ringLineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            } else {
                // Preserve the card's visual anchor without drawing an empty
                // progress track that could be mistaken for a measured zero.
                Circle()
                    .fill(foreground.opacity(canvasStyle.isLight ? 0.05 : 0.07))
            }

            VStack(spacing: 5) {
                Image(systemName: snapshot.activitySystemImage)
                    .font(.system(size: hasRoute ? 18 : 24, weight: .bold))
                    .foregroundStyle(accent)
                Text(snapshot.activity)
                    .font(.system(size: hasRoute ? 13 : 17, weight: .black, design: .rounded))
                    .foregroundStyle(foreground.opacity(0.68))
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
                if strainFill != nil {
                    Text(snapshot.strain)
                        .font(.system(size: hasRoute ? 38 : 58, weight: .black, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(foreground)
                        .lineLimit(1)
                        .minimumScaleFactor(0.60)
                    Text("workout strain")
                        .font(.system(size: hasRoute ? 10 : 13, weight: .bold, design: .rounded))
                        .foregroundStyle(foreground.opacity(0.62))
                }
            }
            .frame(width: hasRoute ? 112 : 170)
        }
    }

    private var ringLineWidth: CGFloat { hasRoute ? 12 : 18 }

    private var strainFill: Double? {
        AtriaWorkoutSharePresentation.strainFraction(snapshot.strain)
    }

    private var workoutStats: [WorkoutStat] {
        let candidates: [WorkoutStat]
        if let distance = snapshot.distance {
            candidates = [WorkoutStat(title: "Distance", value: distance),
                          WorkoutStat(title: snapshot.pace == nil ? "Avg HR" : "Pace",
                                      value: snapshot.pace ?? snapshot.averageHeartRate ?? "--"),
                          WorkoutStat(title: "Duration", value: snapshot.duration)]
        } else if let steps = snapshot.steps {
            candidates = [
                WorkoutStat(title: "Duration", value: snapshot.duration),
                WorkoutStat(title: "Steps", value: steps),
                WorkoutStat(title: "Peak HR", value: snapshot.peakHeartRate)
            ]
        } else {
            candidates = [
                WorkoutStat(title: "Duration", value: snapshot.duration),
                WorkoutStat(title: "Avg HR", value: snapshot.averageHeartRate ?? "--"),
                WorkoutStat(title: "Peak HR", value: snapshot.peakHeartRate)
            ]
        }
        return candidates.filter { AtriaWorkoutSharePresentation.metricIsAvailable($0.value) }
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
                if let steps = snapshot.steps {
                    Text("· \(steps) steps")
                        .monospacedDigit()
                }
            }
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .textCase(.uppercase)
            .foregroundStyle(foreground.opacity(0.64))

            AtriaWorkoutShareRouteTrace(points: snapshot.routePoints,
                                        tint: accent,
                                        lineWidth: format == .story ? 5.5 : 4.5)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(foreground.opacity(canvasStyle.chipOpacity))
                .overlay {
                    LinearGradient(colors: [accent.opacity(0.12), .clear],
                                   startPoint: .topLeading,
                                   endPoint: .bottomTrailing)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(foreground.opacity(0.12), lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Workout route trace\(snapshot.distance.map { ", \($0)" } ?? "")\(snapshot.steps.map { ", \($0) steps" } ?? "")"
        )
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
        .padding(.vertical, format == .story ? 8 : 10)
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
        .padding(format == .story ? 10 : 12)
        .background(foreground.opacity(canvasStyle.chipOpacity),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var zoneMinuteBar: some View {
        let activeZones = snapshot.zoneMinutes.filter { $0.minutes > 0 }
        let fractions = AtriaWorkoutSharePresentation.zoneFractions(activeZones)
        return VStack(alignment: .leading, spacing: 8) {
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

            GeometryReader { proxy in
                HStack(spacing: 4) {
                    ForEach(activeZones) { zone in
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(zone.tint)
                            .frame(width: max(1,
                                              (proxy.size.width
                                                  - CGFloat(max(0, activeZones.count - 1)) * 4)
                                                  * (fractions[zone.id] ?? 0)))
                    }
                }
            }
            .frame(height: 12)
            .accessibilityHidden(true)
        }
        .padding(12)
        .background(foreground.opacity(canvasStyle.chipOpacity),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var zoneSummaryText: String {
        let active = snapshot.zoneMinutes.filter { $0.minutes > 0 }
        return active.map { "\($0.label) \($0.minutes)m" }.joined(separator: " · ")
    }

    private var atriaSafeWordmark: some View {
        Text("ATRIA")
            .font(.system(size: format == .story ? 19 : 16, weight: .semibold, design: .rounded))
            .fontWidth(.expanded)
            .tracking(format == .story ? 4.8 : 3.6)
            .foregroundStyle(foreground.opacity(0.88))
            .textCase(.uppercase)
            .accessibilityLabel("Atria")
    }

    private var dateLine: String {
        atriaShareDateLineFormatter.string(from: snapshot.date)
    }
}

enum AtriaWorkoutShareRouteProjection {
    static func projectedPoints(_ points: [AtriaWorkoutShareSnapshot.RoutePoint],
                                in rect: CGRect) -> [CGPoint] {
        guard points.count >= 2 else { return [] }
        // Keep the 9-point endpoint dots fully inside the exported canvas.
        // Projecting exactly onto maxX/maxY lets the route line render, but
        // clips half of a start/finish marker at an extreme coordinate.
        let horizontalInset = min(5, max(0, rect.width / 2))
        let verticalInset = min(5, max(0, rect.height / 2))
        let drawingRect = rect.insetBy(dx: horizontalInset, dy: verticalInset)
        let meanLatitude = points.map(\.latitude).reduce(0, +) / Double(points.count)
        let longitudeScale = max(cos(meanLatitude * .pi / 180), 0.01)
        let source = points.map { point in
            CGPoint(x: point.longitude * longitudeScale, y: point.latitude)
        }
        let minX = source.map(\.x).min() ?? 0
        let maxX = source.map(\.x).max() ?? 0
        let minY = source.map(\.y).min() ?? 0
        let maxY = source.map(\.y).max() ?? 0
        let sourceWidth = max(maxX - minX, 0.000_000_1)
        let sourceHeight = max(maxY - minY, 0.000_000_1)
        let scale = min(drawingRect.width / sourceWidth, drawingRect.height / sourceHeight)
        let drawnWidth = sourceWidth * scale
        let drawnHeight = sourceHeight * scale
        let originX = drawingRect.minX + (drawingRect.width - drawnWidth) / 2
        let originY = drawingRect.minY + (drawingRect.height - drawnHeight) / 2

        return source.map { point in
            CGPoint(x: originX + (point.x - minX) * scale,
                    y: originY + (maxY - point.y) * scale)
        }
    }
}

private struct AtriaWorkoutShareRouteTrace: View {
    let points: [AtriaWorkoutShareSnapshot.RoutePoint]
    let tint: Color
    let lineWidth: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let projected = AtriaWorkoutShareRouteProjection.projectedPoints(
                points,
                in: CGRect(origin: .zero, size: proxy.size)
            )
            ZStack {
                AtriaWorkoutShareRouteShape(points: points)
                    .stroke(tint,
                            style: StrokeStyle(lineWidth: lineWidth,
                                               lineCap: .round,
                                               lineJoin: .round))
                    .shadow(color: tint.opacity(0.30), radius: 5)

                if let start = projected.first {
                    routeEndpoint(at: start, tint: .green)
                }
                if let finish = projected.last {
                    routeEndpoint(at: finish, tint: .red)
                }
            }
        }
    }

    private func routeEndpoint(at point: CGPoint, tint: Color) -> some View {
        Circle()
            .fill(tint)
            .overlay(Circle().stroke(.white.opacity(0.92), lineWidth: 1.5))
            .frame(width: 9, height: 9)
            .position(point)
    }
}

private struct AtriaWorkoutShareRouteShape: Shape {
    let points: [AtriaWorkoutShareSnapshot.RoutePoint]

    func path(in rect: CGRect) -> Path {
        let projected = AtriaWorkoutShareRouteProjection.projectedPoints(points, in: rect)
        guard projected.count == points.count else { return Path() }

        var path = Path()
        for (index, projectedPoint) in projected.enumerated() {
            if index == 0 || points[index].startsNewSegment {
                path.move(to: projectedPoint)
            } else {
                path.addLine(to: projectedPoint)
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
    @State private var sharePayload: AtriaShareActivityPayload?
    @State private var sharePreparationState: AtriaSharePreparationState = .idle
    @State private var exportGeneration: UInt64 = 0
    @State private var exportTask: Task<Void, Never>?
    @State private var cameraPreparationGeneration: UInt64 = 0
    @State private var cameraPreparationTask: Task<Void, Never>?
    @State private var controlsRefreshID = UUID()
    @Environment(\.dismiss) private var dismiss

    init(snapshot: AtriaShareSnapshot, challengeURL: URL? = nil) {
        self.snapshot = snapshot
        self.challengeURL = challengeURL
    }

    var body: some View {
        shareComposer
            .background(Color.black.ignoresSafeArea())
            .task(id: selectedPhotoItem) {
                guard let selectedPhotoItem,
                      let data = try? await selectedPhotoItem.loadTransferable(type: Data.self),
                      let image = await AtriaSharePhotoPreparation.preparedImage(from: data),
                      !Task.isCancelled else {
                    return
                }
                invalidateShareExport()
                photoBackground = image
                selectedPictureBackground = nil
                photoBackgroundID = UUID()
                controlsRefreshID = UUID()
                canvasStyle = .midnight
            }
            .onChange(of: selectedPhotoItem) { _, _ in
                invalidateCameraPreparation()
                invalidateShareExport()
            }
            .sheet(isPresented: $showCamera) {
                AtriaShareCameraPicker(image: Binding {
                    nil
                } set: { image in
                    prepareCameraImage(image)
                })
            }
            .sheet(item: $sharePayload) { payload in
                AtriaSystemShareSheet(url: payload.url) {
                    completeShare(payload)
                }
            }
            .onDisappear {
                exportTask?.cancel()
                cameraPreparationTask?.cancel()
            }
        .presentationDetents([.large])
    }

    private var shareComposer: some View {
        VStack(spacing: 0) {
            topControls
                .frame(height: AtriaShareComposerLayout.topControlsHeight)

            GeometryReader { proxy in
                AtriaShareCardView(snapshot: snapshot,
                                   format: .story,
                                   selectedStatIDs: Self.fixedDailyStatIDs(),
                                   canvasStyle: effectiveCanvasStyle,
                                   photoBackground: photoBackground)
                    .id(renderKey)
                    .frame(width: AtriaShareFormat.story.renderSize.width,
                           height: AtriaShareFormat.story.renderSize.height)
                    .scaleEffect(previewScale(for: proxy.size), anchor: .center)
                    .frame(width: previewSize(for: proxy.size).width,
                           height: previewSize(for: proxy.size).height)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .shadow(color: .black.opacity(0.26), radius: 18, x: 0, y: 10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            controlDock
                .frame(height: AtriaShareComposerLayout.styleRailHeight)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel("Share preview")
    }

    private var topControls: some View {
        GlassEffectContainer(spacing: 12) {
            HStack {
                Button { dismiss() } label: {
                    shareCornerButton(systemImage: "xmark")
                }
                .buttonStyle(AtriaGlassIconButtonStyle(tint: .white, size: 38))
                .accessibilityLabel("Cancel")

                Spacer(minLength: 12)

                Button {
                    prepareShare()
                } label: {
                    if sharePreparationState.isPreparing {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(.white)
                            .frame(width: 18, height: 18)
                    } else {
                        shareCornerButton(systemImage: "square.and.arrow.up")
                    }
                }
                .buttonStyle(AtriaGlassIconButtonStyle(tint: .white, size: 38))
                .disabled(sharePreparationState.isPreparing)
                .accessibilityLabel(sharePreparationState == .failed ? "Retry share" :
                                    (sharePreparationState.isPreparing ? "Preparing share" : "Share"))
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 16)
    }

    private var controlDock: some View {
        canvasPicker
            .padding(.vertical, 4)
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
                            invalidateCameraPreparation()
                            invalidateShareExport()
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
            .frame(width: 18, height: 18)
    }

    private func selectCanvas(_ style: AtriaShareCanvasStyle) {
        invalidateCameraPreparation()
        invalidateShareExport()
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
        invalidateCameraPreparation()
        invalidateShareExport()
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

    private var renderKey: String {
        "\(AtriaShareFormat.story.rawValue)-\(effectiveCanvasStyle.rawValue)-picture-\(selectedPictureBackground?.rawValue ?? "custom")-photo-\(photoBackground != nil)-\(photoBackgroundID.uuidString)-fixed-daily-trio"
    }

    private var effectiveCanvasStyle: AtriaShareCanvasStyle {
        photoBackground == nil ? canvasStyle : .midnight
    }

    private func previewSize(for size: CGSize) -> CGSize {
        AtriaShareComposerLayout.fittedStorySize(in: size)
    }

    private func previewScale(for size: CGSize) -> CGFloat {
        previewSize(for: size).height / AtriaShareFormat.story.renderSize.height
    }

    private static func fixedDailyStatIDs() -> Set<String> {
        ["recovery", "strain", "sleep"]
    }

    private func prepareShare() {
        invalidateShareExport()
        let generation = exportGeneration
        let requestedRenderKey = renderKey
        let requestedCanvasStyle = effectiveCanvasStyle
        let requestedPhotoBackground = photoBackground
        sharePreparationState = .preparing
        exportTask = Task { @MainActor in
            var pendingURL: URL?
            do {
                let url = try await AtriaShareCardRenderer.renderURL(
                    snapshot: snapshot,
                    format: .story,
                    selectedStatIDs: Self.fixedDailyStatIDs(),
                    canvasStyle: requestedCanvasStyle,
                    photoBackground: requestedPhotoBackground
                )
                pendingURL = url
                try Task.checkCancellation()
                guard exportGeneration == generation,
                      renderKey == requestedRenderKey else {
                    await AtriaShareCardRenderer.releaseTemporaryExport(at: url)
                    return
                }
                sharePreparationState = .idle
                sharePayload = AtriaShareActivityPayload(url: url)
                pendingURL = nil
                exportTask = nil
            } catch is CancellationError {
                if let pendingURL { await AtriaShareCardRenderer.releaseTemporaryExport(at: pendingURL) }
                return
            } catch {
                if let pendingURL { await AtriaShareCardRenderer.releaseTemporaryExport(at: pendingURL) }
                guard exportGeneration == generation else { return }
                sharePreparationState = .failed
                exportTask = nil
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }

    private func prepareCameraImage(_ image: UIImage?) {
        invalidateCameraPreparation()
        guard let image else { return }
        invalidateShareExport()
        let generation = cameraPreparationGeneration
        let requestedRenderKey = renderKey
        cameraPreparationTask = Task { @MainActor in
            guard let prepared = await AtriaSharePhotoPreparation.preparedImage(from: image),
                  !Task.isCancelled,
                  AtriaSharePhotoPreparation.acceptsResult(
                    generation: generation,
                    currentGeneration: cameraPreparationGeneration,
                    requestedRenderKey: requestedRenderKey,
                    currentRenderKey: renderKey
                  ) else { return }
            photoBackground = prepared
            selectedPictureBackground = nil
            photoBackgroundID = UUID()
            controlsRefreshID = UUID()
            canvasStyle = .midnight
            cameraPreparationTask = nil
        }
    }

    private func invalidateCameraPreparation() {
        cameraPreparationTask?.cancel()
        cameraPreparationTask = nil
        cameraPreparationGeneration &+= 1
    }

    private func completeShare(_ payload: AtriaShareActivityPayload) {
        if sharePayload?.id == payload.id { sharePayload = nil }
        Task { await AtriaShareCardRenderer.releaseTemporaryExport(at: payload.url) }
    }

    private func invalidateShareExport() {
        exportTask?.cancel()
        exportTask = nil
        exportGeneration &+= 1
        sharePreparationState = .idle
        sharePayload = nil
    }
}

struct AtriaWorkoutShareSheet: View {
    private enum ExportKind {
        case image
        case portableRecap
    }

    let snapshot: AtriaWorkoutShareSnapshot
    @State private var canvasStyle: AtriaShareCanvasStyle = .midnight
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var photoBackground: UIImage?
    @State private var selectedPictureBackground: AtriaSharePictureBackground?
    @State private var photoBackgroundID = UUID()
    @State private var showCamera = false
    @State private var sharePayload: AtriaShareActivityPayload?
    @State private var sharePreparationState: AtriaSharePreparationState = .idle
    @State private var exportGeneration: UInt64 = 0
    @State private var exportTask: Task<Void, Never>?
    @State private var cameraPreparationGeneration: UInt64 = 0
    @State private var cameraPreparationTask: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        shareComposer
            .background(Color.black.ignoresSafeArea())
            .task(id: selectedPhotoItem) {
                guard let selectedPhotoItem,
                      let data = try? await selectedPhotoItem.loadTransferable(type: Data.self),
                      let image = await AtriaSharePhotoPreparation.preparedImage(from: data),
                      !Task.isCancelled else { return }
                invalidateShareExport()
                photoBackground = image
                selectedPictureBackground = nil
                photoBackgroundID = UUID()
                canvasStyle = .midnight
            }
            .onChange(of: selectedPhotoItem) { _, _ in
                invalidateCameraPreparation()
                invalidateShareExport()
            }
            .sheet(isPresented: $showCamera) {
                AtriaShareCameraPicker(image: Binding {
                    nil
                } set: { image in
                    prepareCameraImage(image)
                })
            }
            .sheet(item: $sharePayload) { payload in
                AtriaSystemShareSheet(url: payload.url) {
                    completeShare(payload)
                }
            }
            .onDisappear {
                exportTask?.cancel()
                cameraPreparationTask?.cancel()
            }
            .presentationDetents([.large])
    }

    private var shareComposer: some View {
        VStack(spacing: 0) {
            topControls
                .frame(height: AtriaShareComposerLayout.topControlsHeight)

            GeometryReader { proxy in
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
                    .shadow(color: .black.opacity(0.26), radius: 18, x: 0, y: 10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            controlDock
                .frame(height: AtriaShareComposerLayout.styleRailHeight)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel("Workout share preview")
    }

    private var topControls: some View {
        GlassEffectContainer(spacing: 12) {
            HStack {
                Button { dismiss() } label: {
                    shareCornerButton(systemImage: "xmark")
                }
                .buttonStyle(AtriaGlassIconButtonStyle(tint: .white, size: 38))
                .accessibilityLabel("Cancel")

                Spacer(minLength: 12)

                Button {
                    prepareShare(.image)
                } label: {
                    if sharePreparationState.isPreparing {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(.white)
                            .frame(width: 18, height: 18)
                    } else {
                        shareCornerButton(systemImage: "square.and.arrow.up")
                    }
                }
                .buttonStyle(AtriaGlassIconButtonStyle(tint: .white, size: 38))
                .disabled(sharePreparationState.isPreparing)
                .accessibilityLabel(sharePreparationState == .failed ? "Retry workout share" :
                                    (sharePreparationState.isPreparing
                                        ? "Preparing workout share" : "Share workout image"))
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 16)
    }

    private var controlDock: some View {
        canvasPicker
            .padding(.vertical, 4)
    }

    private var canvasPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 9) {
                ForEach(AtriaShareCanvasStyle.allCases) { style in
                    Button {
                        selectCanvas(style)
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
                        invalidateCameraPreparation()
                        invalidateShareExport()
                        photoBackground = nil
                        selectedPictureBackground = nil
                        selectedPhotoItem = nil
                        photoBackgroundID = UUID()
                    } label: {
                        shareCanvasButtonLabel(title: "Clear", isSelected: false, systemImage: "xmark")
                    }
                }
                Menu {
                    Button {
                        prepareShare(.portableRecap)
                    } label: {
                        Label("Portable workout recap", systemImage: "doc.richtext")
                    }
                    .disabled(sharePreparationState.isPreparing)
                    .accessibilityLabel("Share portable workout recap without route")

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
            .padding(.horizontal, 10)
        }
        .frame(height: 76)
    }

    private func shareCornerButton(systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.callout.weight(.semibold))
            .frame(width: 18, height: 18)
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
        AtriaShareComposerLayout.fittedStorySize(in: size)
    }

    private func previewScale(for size: CGSize) -> CGFloat {
        previewSize(for: size).height / AtriaShareFormat.story.renderSize.height
    }

    private func selectCanvas(_ style: AtriaShareCanvasStyle) {
        invalidateCameraPreparation()
        invalidateShareExport()
        canvasStyle = style
        photoBackground = nil
        selectedPictureBackground = nil
        selectedPhotoItem = nil
        photoBackgroundID = UUID()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func selectPictureBackground(_ background: AtriaSharePictureBackground) {
        guard let image = UIImage(named: background.assetName) else { return }
        invalidateCameraPreparation()
        invalidateShareExport()
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

    private func prepareShare(_ kind: ExportKind) {
        invalidateShareExport()
        let generation = exportGeneration
        let requestedRenderKey = renderKey
        let requestedCanvasStyle = effectiveCanvasStyle
        let requestedPhotoBackground = photoBackground
        sharePreparationState = .preparing
        exportTask = Task { @MainActor in
            var pendingURL: URL?
            do {
                let imageURL = try await AtriaShareCardRenderer.renderURL(
                    snapshot: snapshot,
                    format: .story,
                    canvasStyle: requestedCanvasStyle,
                    photoBackground: requestedPhotoBackground
                )
                pendingURL = imageURL
                try Task.checkCancellation()
                let exportURL: URL
                switch kind {
                case .image:
                    exportURL = imageURL
                case .portableRecap:
                    exportURL = try await AtriaShareCardRenderer.renderPortableWorkoutURL(
                        snapshot: snapshot,
                        canvasStyle: requestedCanvasStyle,
                        renderedImageURL: imageURL,
                        cacheResult: requestedPhotoBackground == nil,
                        removeRenderedImageAfterEmbedding: requestedPhotoBackground != nil
                    )
                    pendingURL = exportURL
                }
                try Task.checkCancellation()
                guard exportGeneration == generation,
                      renderKey == requestedRenderKey else {
                    await AtriaShareCardRenderer.releaseTemporaryExport(at: exportURL)
                    return
                }
                sharePreparationState = .idle
                sharePayload = AtriaShareActivityPayload(url: exportURL)
                pendingURL = nil
                exportTask = nil
            } catch is CancellationError {
                if let pendingURL { await AtriaShareCardRenderer.releaseTemporaryExport(at: pendingURL) }
                return
            } catch {
                if let pendingURL { await AtriaShareCardRenderer.releaseTemporaryExport(at: pendingURL) }
                guard exportGeneration == generation else { return }
                sharePreparationState = .failed
                exportTask = nil
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }

    private func prepareCameraImage(_ image: UIImage?) {
        invalidateCameraPreparation()
        guard let image else { return }
        invalidateShareExport()
        let generation = cameraPreparationGeneration
        let requestedRenderKey = renderKey
        cameraPreparationTask = Task { @MainActor in
            guard let prepared = await AtriaSharePhotoPreparation.preparedImage(from: image),
                  !Task.isCancelled,
                  AtriaSharePhotoPreparation.acceptsResult(
                    generation: generation,
                    currentGeneration: cameraPreparationGeneration,
                    requestedRenderKey: requestedRenderKey,
                    currentRenderKey: renderKey
                  ) else { return }
            photoBackground = prepared
            selectedPictureBackground = nil
            photoBackgroundID = UUID()
            canvasStyle = .midnight
            cameraPreparationTask = nil
        }
    }

    private func invalidateCameraPreparation() {
        cameraPreparationTask?.cancel()
        cameraPreparationTask = nil
        cameraPreparationGeneration &+= 1
    }

    private func completeShare(_ payload: AtriaShareActivityPayload) {
        if sharePayload?.id == payload.id { sharePayload = nil }
        Task { await AtriaShareCardRenderer.releaseTemporaryExport(at: payload.url) }
    }

    private func invalidateShareExport() {
        exportTask?.cancel()
        exportTask = nil
        exportGeneration &+= 1
        sharePreparationState = .idle
        sharePayload = nil
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
    @State private var sharePayload: AtriaShareActivityPayload?
    @State private var sharePreparationState: AtriaSharePreparationState = .idle
    @State private var exportGeneration: UInt64 = 0
    @State private var exportTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            topControls
                .frame(height: AtriaShareComposerLayout.topControlsHeight)

            GeometryReader { proxy in
                AtriaWeeklyShareCardView(snapshot: snapshot,
                                         format: .story,
                                         canvasStyle: canvasStyle)
                    .frame(width: AtriaShareFormat.story.renderSize.width,
                           height: AtriaShareFormat.story.renderSize.height)
                    .scaleEffect(previewScale(for: proxy.size), anchor: .center)
                    .frame(width: previewSize(for: proxy.size).width,
                           height: previewSize(for: proxy.size).height)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .shadow(color: .black.opacity(0.26), radius: 18, x: 0, y: 10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            canvasPicker
                .padding(.vertical, 4)
                .frame(height: AtriaShareComposerLayout.styleRailHeight)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .accessibilityLabel("Weekly share preview")
        .sheet(item: $sharePayload) { payload in
            AtriaSystemShareSheet(url: payload.url) {
                completeShare(payload)
            }
        }
        .onDisappear {
            exportTask?.cancel()
        }
        .presentationDetents([.large])
    }

    private var topControls: some View {
        GlassEffectContainer(spacing: 12) {
            HStack {
                Button { dismiss() } label: {
                    shareCornerButton(systemImage: "xmark")
                }
                .buttonStyle(AtriaGlassIconButtonStyle(tint: .white, size: 38))
                .accessibilityLabel("Cancel")

                Spacer(minLength: 12)

                Button {
                    prepareWeeklyShare()
                } label: {
                    if sharePreparationState.isPreparing {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(.white)
                            .frame(width: 18, height: 18)
                    } else {
                        shareCornerButton(systemImage: "square.and.arrow.up")
                    }
                }
                .buttonStyle(AtriaGlassIconButtonStyle(tint: .white, size: 38))
                .disabled(sharePreparationState.isPreparing)
                .accessibilityLabel(sharePreparationState == .failed
                                    ? "Retry weekly share"
                                    : (sharePreparationState.isPreparing ? "Preparing weekly share" : "Share week"))
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 16)
    }

    private var canvasPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 9) {
                ForEach(AtriaShareCanvasStyle.allCases) { style in
                    Button {
                        invalidateShareExport()
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

    private func shareCornerButton(systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.callout.weight(.semibold))
            .frame(width: 18, height: 18)
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
        AtriaShareComposerLayout.fittedStorySize(in: size)
    }

    private func previewScale(for size: CGSize) -> CGFloat {
        previewSize(for: size).height / AtriaShareFormat.story.renderSize.height
    }

    private var renderKey: String {
        "\(AtriaShareFormat.story.rawValue)-\(canvasStyle.rawValue)"
    }

    private func prepareWeeklyShare() {
        invalidateShareExport()
        let generation = exportGeneration
        let requestedRenderKey = renderKey
        let requestedCanvasStyle = canvasStyle
        sharePreparationState = .preparing
        exportTask = Task { @MainActor in
            var pendingURL: URL?
            do {
                let url = try await AtriaShareCardRenderer.renderURL(snapshot: snapshot,
                                                                      format: .story,
                                                                      canvasStyle: requestedCanvasStyle)
                pendingURL = url
                try Task.checkCancellation()
                guard exportGeneration == generation,
                      renderKey == requestedRenderKey else {
                    await AtriaShareCardRenderer.releaseTemporaryExport(at: url)
                    return
                }
                sharePreparationState = .idle
                sharePayload = AtriaShareActivityPayload(url: url)
                pendingURL = nil
                exportTask = nil
            } catch is CancellationError {
                if let pendingURL { await AtriaShareCardRenderer.releaseTemporaryExport(at: pendingURL) }
                return
            } catch {
                if let pendingURL { await AtriaShareCardRenderer.releaseTemporaryExport(at: pendingURL) }
                guard exportGeneration == generation else { return }
                sharePreparationState = .failed
                exportTask = nil
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }

    private func invalidateShareExport() {
        exportTask?.cancel()
        exportTask = nil
        exportGeneration &+= 1
        sharePreparationState = .idle
        sharePayload = nil
    }

    private func completeShare(_ payload: AtriaShareActivityPayload) {
        if sharePayload?.id == payload.id { sharePayload = nil }
        Task { await AtriaShareCardRenderer.releaseTemporaryExport(at: payload.url) }
    }
}

@MainActor
enum AtriaShareCardRenderer {
    private static var cache: [String: URL] = [:]
    private static var cacheRecency: [String] = []
    private static let cacheCapacity = 24
    private static var inFlightExportURLCounts: [URL: Int] = [:]
    private static var currentExportURLCounts: [URL: Int] = [:]

    private static func incrementReferenceCount(for url: URL,
                                                in counts: inout [URL: Int]) {
        counts[url, default: 0] += 1
    }

    @discardableResult
    private static func decrementReferenceCount(for url: URL,
                                                in counts: inout [URL: Int]) -> Int {
        guard let count = counts[url] else { return 0 }
        if count <= 1 {
            counts.removeValue(forKey: url)
            return 0
        }
        counts[url] = count - 1
        return count - 1
    }

    private static func beginExport(to url: URL) {
        incrementReferenceCount(for: url, in: &inFlightExportURLCounts)
    }

    private static func finishExport(to url: URL) {
        decrementReferenceCount(for: url, in: &inFlightExportURLCounts)
    }

    private static func retainCurrentExport(at url: URL) {
        incrementReferenceCount(for: url, in: &currentExportURLCounts)
    }

    private static var protectedExportURLs: Set<URL> {
        Set(inFlightExportURLCounts.keys).union(currentExportURLCounts.keys)
    }

    private static func cachedURL(for key: String) -> URL? {
        guard let url = cache[key] else { return nil }
        guard FileManager.default.fileExists(atPath: url.path) else {
            cache.removeValue(forKey: key)
            cacheRecency.removeAll { $0 == key }
            return nil
        }
        cacheRecency.removeAll { $0 == key }
        cacheRecency.append(key)
        retainCurrentExport(at: url)
        return url
    }

    private static func storeCachedURL(_ url: URL, for key: String) {
        cache[key] = url
        cacheRecency.removeAll { $0 == key }
        cacheRecency.append(key)
        while cacheRecency.count > cacheCapacity {
            let evictedKey = cacheRecency.removeFirst()
            guard let evictedURL = cache.removeValue(forKey: evictedKey), evictedURL != url else { continue }
            guard currentExportURLCounts[evictedURL, default: 0] == 0,
                  inFlightExportURLCounts[evictedURL, default: 0] == 0 else { continue }
            Task { await removeExportFile(evictedURL) }
        }
    }

    static func releaseTemporaryExport(at url: URL) async {
        guard decrementReferenceCount(for: url, in: &currentExportURLCounts) == 0 else {
            return
        }
        let removedKeys = cache.compactMap { key, value in value == url ? key : nil }
        removedKeys.forEach { cache.removeValue(forKey: $0) }
        cacheRecency.removeAll { removedKeys.contains($0) }
        // Two same-key renders can share a destination while their atomic
        // writes complete. The last in-flight writer owns cleanup/publication.
        guard inFlightExportURLCounts[url, default: 0] == 0 else { return }
        await removeExportFile(url)
    }

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
        let key = dailyCacheKey(snapshot: snapshot,
                                format: format,
                                selectedStatIDs: selectedStatIDs,
                                canvasStyle: canvasStyle)
        if photoBackground == nil,
           let cached = cachedURL(for: key) {
            return cached
        }
        let data = try await renderPNGDataForExport(snapshot: snapshot,
                                                    format: format,
                                                    selectedStatIDs: selectedStatIDs,
                                                    canvasStyle: canvasStyle,
                                                    photoBackground: photoBackground)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("atria-share-\(key)-\(photoBackground == nil ? "canvas" : UUID().uuidString)")
            .appendingPathExtension("png")
        beginExport(to: url)
        do {
            try await writeExportData(data, to: url)
        } catch {
            finishExport(to: url)
            throw error
        }
        retainCurrentExport(at: url)
        if photoBackground == nil {
            storeCachedURL(url, for: key)
        }
        await pruneDailyShareCards(preserving: protectedExportURLs)
        finishExport(to: url)
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
           let cached = cachedURL(for: key) {
            return cached
        }
        let data = try await renderPNGDataForExport(snapshot: snapshot,
                                                    format: format,
                                                    canvasStyle: canvasStyle,
                                                    photoBackground: photoBackground)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("atria-workout-share-\(key)-\(photoBackground == nil ? "canvas" : UUID().uuidString)")
            .appendingPathExtension("png")
        beginExport(to: url)
        do {
            try await writeExportData(data, to: url)
        } catch {
            finishExport(to: url)
            throw error
        }
        retainCurrentExport(at: url)
        if photoBackground == nil { storeCachedURL(url, for: key) }
        await pruneGeneratedArtifacts(
            policy: AtriaGeneratedArtifactRetention.workoutShareCards,
            preserving: protectedExportURLs
        )
        finishExport(to: url)
        return url
    }

    /// Creates a single-file recap that opens in any browser and remains useful
    /// to recipients who do not have Atria. Exact route coordinates are
    /// deliberately excluded; GPX remains a separate, explicit share action.
    static func renderPortableWorkoutURL(snapshot: AtriaWorkoutShareSnapshot,
                                         canvasStyle: AtriaShareCanvasStyle,
                                         renderedImageURL: URL,
                                         cacheResult: Bool = true,
                                         removeRenderedImageAfterEmbedding: Bool = false) async throws -> URL {
        let key = portableWorkoutCacheKey(snapshot: snapshot, canvasStyle: canvasStyle)
        let cacheKey = "portable-\(key)"
        if cacheResult, let cached = cachedURL(for: cacheKey) {
            if removeRenderedImageAfterEmbedding { await releaseTemporaryExport(at: renderedImageURL) }
            return cached
        }

        let imageData: Data
        do {
            imageData = try await readExportData(from: renderedImageURL)
        } catch {
            if removeRenderedImageAfterEmbedding { await releaseTemporaryExport(at: renderedImageURL) }
            throw error
        }
        if removeRenderedImageAfterEmbedding { await releaseTemporaryExport(at: renderedImageURL) }
        let html = portableWorkoutHTML(snapshot: snapshot, imageData: imageData)
        let activity = fileSafeSlug(snapshot.activity)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Atria-\(activity)-\(stableDigest(key))-\(cacheResult ? "canvas" : UUID().uuidString)")
            .appendingPathExtension("html")
        beginExport(to: url)
        do {
            try await writeExportData(Data(html.utf8), to: url)
        } catch {
            finishExport(to: url)
            throw error
        }
        retainCurrentExport(at: url)
        if cacheResult { storeCachedURL(url, for: cacheKey) }
        await pruneGeneratedArtifacts(
            policy: AtriaGeneratedArtifactRetention.portableWorkoutExports,
            preserving: protectedExportURLs
        )
        finishExport(to: url)
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
        if let cached = cachedURL(for: key) {
            return cached
        }
        let data = try await renderPNGDataForExport(snapshot: snapshot,
                                                    format: format,
                                                    canvasStyle: canvasStyle)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("atria-weekly-share-\(key)")
            .appendingPathExtension("png")
        try await writeExportData(data, to: url)
        storeCachedURL(url, for: key)
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
        let encodingTask = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            guard let data = pngData(from: image.value) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try Task.checkCancellation()
            return data
        }
        return try await withTaskCancellationHandler {
            try await encodingTask.value
        } onCancel: {
            encodingTask.cancel()
        }
    }

    nonisolated private static func writeExportData(_ data: Data, to url: URL) async throws {
        let writingTask = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            do {
                try data.write(to: url, options: [.atomic, .completeFileProtection])
                try FileManager.default.setAttributes(
                    [.protectionKey: FileProtectionType.completeUnlessOpen],
                    ofItemAtPath: url.path
                )
                try Task.checkCancellation()
            } catch {
                try? FileManager.default.removeItem(at: url)
                throw error
            }
        }
        do {
            try await withTaskCancellationHandler {
                try await writingTask.value
                try Task.checkCancellation()
            } onCancel: {
                writingTask.cancel()
            }
        } catch {
            writingTask.cancel()
            await removeExportFile(url)
            throw error
        }
    }

    static func writeExportDataForTesting(_ data: Data, to url: URL) async throws {
        try await writeExportData(data, to: url)
    }

    nonisolated private static func readExportData(from url: URL) async throws -> Data {
        try await Task.detached(priority: .utility) {
            try Data(contentsOf: url)
        }.value
    }

    nonisolated private static func removeExportFile(_ url: URL) async {
        await Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: url)
        }.value
    }

    nonisolated private static func pruneDailyShareCards(preserving protectedURLs: Set<URL>) async {
        await pruneGeneratedArtifacts(
            policy: AtriaGeneratedArtifactRetention.shareCards,
            preserving: protectedURLs
        )
    }

    nonisolated private static func pruneGeneratedArtifacts(
        policy: AtriaGeneratedArtifactRetention.Policy,
        preserving protectedURLs: Set<URL>
    ) async {
        await Task.detached(priority: .utility) {
            _ = AtriaGeneratedArtifactRetention.prune(
                in: FileManager.default.temporaryDirectory,
                policy: policy,
                preserving: protectedURLs
            )
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

    static func dailyCacheKey(snapshot: AtriaShareSnapshot,
                              format: AtriaShareFormat,
                              selectedStatIDs: Set<String>,
                              canvasStyle: AtriaShareCanvasStyle) -> String {
        let chips = selectedStatIDs.sorted().joined(separator: "-")
        let rings = [snapshot.recovery, snapshot.sleep, snapshot.strain].map {
            "\($0.title):\($0.value):\($0.detail):\($0.tintHex):\($0.fill.map { String($0) } ?? "nil"):" +
                "\($0.stateTintHex ?? "nil"):\($0.targetFraction.map { String($0) } ?? "nil")"
        }.joined(separator: "|")
        let stats = snapshot.stats.map {
            "\($0.id):\($0.title):\($0.value):\($0.detail)"
        }.joined(separator: "|")
        let content = [String(snapshot.date.timeIntervalSince1970),
                       rings, stats, format.rawValue, canvasStyle.rawValue, chips]
            .joined(separator: "\u{1f}")
        return "daily-\(stableDigest(content))"
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
            snapshot.steps ?? "",
            snapshot.activitySystemImage, zones,
            snapshot.routePoints.map {
                "\($0.latitude):\($0.longitude):\($0.startsNewSegment ? 1 : 0)"
            }.joined(separator: "|"),
            snapshot.personalRecord?.exercise ?? "", snapshot.personalRecord?.set ?? "",
            snapshot.personalRecord?.badge ?? "", format.rawValue, canvasStyle.rawValue
        ].joined(separator: "\u{1f}")
        return "workout-\(fileSafeSlug(snapshot.activity))-\(stableDigest(content))"
    }

    static func portableWorkoutCacheKey(snapshot: AtriaWorkoutShareSnapshot,
                                        canvasStyle: AtriaShareCanvasStyle) -> String {
        let workout = workoutCacheKey(snapshot: snapshot, format: .story, canvasStyle: canvasStyle)
        let routePresence = snapshot.routeFileURL == nil ? "route-absent" : "route-present"
        return "\(workout)-\(routePresence)"
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

    static func weeklyCacheKey(snapshot: AtriaWeeklyShareSnapshot,
                               format: AtriaShareFormat,
                               canvasStyle: AtriaShareCanvasStyle) -> String {
        let content = [String(snapshot.date.timeIntervalSince1970), snapshot.title,
                       snapshot.recoveryAverage, snapshot.recoveryDelta,
                       snapshot.sleepConsistency, snapshot.bestDay,
                       snapshot.hardestDay, snapshot.note ?? "",
                       format.rawValue, canvasStyle.rawValue]
            .joined(separator: "\u{1f}")
        return "weekly-\(stableDigest(content))"
    }
}

private extension AtriaShareSnapshot.Ring {
    var tint: Color { Color(hex: tintHex) }
    var stateTint: Color? { stateTintHex.map { Color(hex: $0) } }
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
