import Foundation
import SwiftUI

/// The exact JSON contract consumed by tools/fit_step_calibration.swift.
struct AtriaStepCalibrationManifest: Codable, Equatable {
    struct Window: Codable, Equatable {
        enum Kind: String, Codable {
            case walk
            case rest
        }

        let label: String
        let kind: Kind
        let startMS: Int64
        let endMS: Int64
        let expectedSteps: Int

        enum CodingKeys: String, CodingKey {
            case label
            case kind
            case startMS = "start_ms"
            case endMS = "end_ms"
            case expectedSteps = "expected_steps"
        }
    }

    let windows: [Window]
}

struct AtriaStepCalibrationStage: Equatable, Identifiable {
    let label: String
    let kind: AtriaStepCalibrationManifest.Window.Kind
    let expectedSteps: Int

    var id: String { label }

    var instruction: String {
        switch kind {
        case .rest:
            return "Keep your wrist still until the rest window is complete."
        case .walk:
            return "Count exactly \(expectedSteps) steps with natural arm swing."
        }
    }

    var systemImage: String {
        switch kind {
        case .rest: return "pause.circle"
        case .walk: return "figure.walk"
        }
    }

    var minimumDurationMS: Int64 {
        kind == .rest ? 60_000 : 0
    }
}

@MainActor
final class AtriaStepCalibrationPlanStore: ObservableObject {
    struct PersistedState: Codable, Equatable {
        static let schemaVersion = 1

        var version = schemaVersion
        var sessionStartedMS: Int64?
        var activeStageIndex: Int?
        var activeStageStartMS: Int64?
        var windows: [AtriaStepCalibrationManifest.Window] = []
    }

    static let defaultsKey = "atria.stepCalibration.sequence.v1"
    static let stages: [AtriaStepCalibrationStage] = [
        AtriaStepCalibrationStage(label: "Rest before", kind: .rest, expectedSteps: 0),
        AtriaStepCalibrationStage(label: "Slow 100", kind: .walk, expectedSteps: 100),
        AtriaStepCalibrationStage(label: "Normal 100", kind: .walk, expectedSteps: 100),
        AtriaStepCalibrationStage(label: "Brisk 100", kind: .walk, expectedSteps: 100),
        AtriaStepCalibrationStage(label: "Normal 200", kind: .walk, expectedSteps: 200),
        AtriaStepCalibrationStage(label: "Rest after", kind: .rest, expectedSteps: 0),
    ]

    @Published private(set) var state: PersistedState

    private let defaults: UserDefaults
    private let now: () -> Date
    private let fileManager: FileManager

    init(defaults: UserDefaults = .standard,
         now: @escaping () -> Date = Date.init,
         fileManager: FileManager = .default) {
        self.defaults = defaults
        self.now = now
        self.fileManager = fileManager

        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode(PersistedState.self, from: data),
           Self.isValid(decoded) {
            state = decoded
        } else {
            state = PersistedState()
            defaults.removeObject(forKey: Self.defaultsKey)
        }
    }

    var currentStage: AtriaStepCalibrationStage? {
        guard state.windows.count < Self.stages.count else { return nil }
        return Self.stages[state.windows.count]
    }

    var completedStageCount: Int { state.windows.count }
    var totalStageCount: Int { Self.stages.count }
    var isRunning: Bool { state.activeStageStartMS != nil }
    var isComplete: Bool { completedStageCount == totalStageCount }
    var manifest: AtriaStepCalibrationManifest { AtriaStepCalibrationManifest(windows: state.windows) }

    func canStopCurrentStage(at date: Date? = nil) -> Bool {
        guard let stage = currentStage,
              let startMS = state.activeStageStartMS else { return false }
        let endMS = Self.unixMilliseconds(date ?? now())
        return endMS - startMS >= stage.minimumDurationMS
    }

    @discardableResult
    func startCurrentStage() -> Bool {
        guard !isRunning, let _ = currentStage else { return false }
        let timestamp = Self.unixMilliseconds(now())
        if state.sessionStartedMS == nil {
            state.sessionStartedMS = timestamp
        }
        state.activeStageIndex = state.windows.count
        state.activeStageStartMS = timestamp
        persist()
        return true
    }

    @discardableResult
    func stopCurrentStage(
        validatedQuality: AtriaStrapCalibrationArchive.CaptureQuality
    ) -> Bool {
        guard let stage = currentStage,
              state.activeStageIndex == state.windows.count,
              state.activeStageStartMS != nil,
              validatedQuality.isReady,
              let startMS = validatedQuality.alignedStartMS,
              let endMS = validatedQuality.alignedEndMSExclusive,
              endMS > startMS else { return false }
        let stoppedAt = now()
        guard canStopCurrentStage(at: stoppedAt) else { return false }
        state.windows.append(
            AtriaStepCalibrationManifest.Window(
                label: stage.label,
                kind: stage.kind,
                startMS: startMS,
                endMS: endMS,
                expectedSteps: stage.expectedSteps
            )
        )
        state.activeStageIndex = nil
        state.activeStageStartMS = nil
        persist()
        return true
    }

    /// A failed window is never spliced with later frames. Keep every earlier
    /// validated stage, but require the current counted/rest segment to start
    /// again from a fresh device-time boundary.
    func discardCurrentStage() {
        guard isRunning else { return }
        state.activeStageIndex = nil
        state.activeStageStartMS = nil
        persist()
    }

    func restart() {
        state = PersistedState()
        defaults.removeObject(forKey: Self.defaultsKey)
    }

    func writeManifest() throws -> URL {
        guard isComplete else { throw ExportError.incompleteSequence }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        let timestamp = state.sessionStartedMS ?? Self.unixMilliseconds(now())
        let url = fileManager.temporaryDirectory
            .appendingPathComponent("atria-step-calibration-\(timestamp).json")
        try data.write(to: url, options: .atomic)
        return url
    }

    enum ExportError: LocalizedError {
        case incompleteSequence

        var errorDescription: String? {
            "Complete all six calibration stages before sharing the manifest."
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    private static func isValid(_ state: PersistedState) -> Bool {
        guard state.version == PersistedState.schemaVersion,
              state.windows.count <= stages.count else { return false }
        for (index, window) in state.windows.enumerated() {
            let stage = stages[index]
            guard window.label == stage.label,
                  window.kind == stage.kind,
                  window.expectedSteps == stage.expectedSteps,
                  window.startMS < window.endMS else { return false }
        }
        switch (state.activeStageIndex, state.activeStageStartMS) {
        case (nil, nil):
            return true
        case let (index?, startMS?):
            return index == state.windows.count
                && index < stages.count
                && startMS > 0
        default:
            return false
        }
    }

    private static func unixMilliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}

/// Research-only workflow. Its sole integration point is the developer
/// validation section, so it never appears in the consumer activity flow.
struct AtriaStepCalibrationSequenceCard: View {
    @ObservedObject var ble: AtriaBLEManager

    @StateObject private var plan = AtriaStepCalibrationPlanStore()
    @State private var exportURL: URL?
    @State private var showsRestartConfirmation = false
    @State private var validationMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if let stage = plan.currentStage {
                currentStageCard(stage)
            } else {
                Label("Sequence complete", systemImage: "checkmark.seal.fill")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .atriaInsetCard(tint: .green)
            }

            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Calibration stage failed. \(validationMessage)")
            }

            completedStages
            actions
        }
        .padding(18)
        .atriaCard(emphasis: .soft)
        .task {
            if plan.isRunning {
                ble.armStepCalibrationCapture()
            }
        }
        .confirmationDialog(
            "Restart step calibration?",
            isPresented: $showsRestartConfirmation,
            titleVisibility: .visible
        ) {
            Button("Restart sequence", role: .destructive) {
                ble.finishStepCalibrationCapture(reason: "restart")
                plan.restart()
                exportURL = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears every saved calibration window in the current sequence.")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            AtriaPanelSectionHeader(title: "Step calibration", subtitle: "Developer research")
            Spacer(minLength: 0)
            AtriaStatusChip(
                text: "\(plan.completedStageCount)/\(plan.totalStageCount)",
                systemImage: plan.isRunning ? "record.circle" : "figure.walk.motion",
                tint: plan.isRunning ? .red : (plan.isComplete ? .green : .indigo)
            )
        }
    }

    private func currentStageCard(_ stage: AtriaStepCalibrationStage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: stage.systemImage)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(stage.kind == .rest ? .cyan : .indigo)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Stage \(plan.completedStageCount + 1) · \(stage.label)")
                        .font(.subheadline.weight(.semibold))
                    if plan.isRunning, let startMS = plan.state.activeStageStartMS {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(elapsedText(since: startMS, now: context.date))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text(stage.kind == .walk ? "Expected: \(stage.expectedSteps) steps" : "Expected: 0 steps")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }

            Text(stage.instruction)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if plan.isRunning {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    stageControl(stage, referenceDate: context.date)
                }
            } else {
                stageControl(stage, referenceDate: Date())
            }
        }
        .padding(14)
        .atriaInsetCard(tint: stage.kind == .rest ? .cyan : .indigo)
    }

    private func stageControl(_ stage: AtriaStepCalibrationStage, referenceDate: Date) -> some View {
        let stopIsReady = plan.canStopCurrentStage(at: referenceDate)
        return Button {
            if plan.isRunning {
                guard let startMS = plan.state.activeStageStartMS else { return }
                let endMS = Int64((referenceDate.timeIntervalSince1970 * 1_000).rounded())
                let quality = AtriaStrapCalibrationArchive.shared.captureQuality(
                    startMS: startMS,
                    endMS: endMS
                )
                if plan.stopCurrentStage(validatedQuality: quality) {
                    validationMessage = nil
                    AtriaStrapCalibrationArchive.shared.flush()
                    if plan.isComplete {
                        exportURL = try? plan.writeManifest()
                        ble.finishStepCalibrationCapture()
                    }
                } else if stopIsReady {
                    plan.discardCurrentStage()
                    validationMessage = quality.failureSummary
                }
            } else if ble.stepCalibrationCaptureArmedAt == nil {
                ble.armStepCalibrationCapture()
            } else if ble.stepCalibrationMotionStreamReady {
                validationMessage = nil
                _ = plan.startCurrentStage()
            }
        } label: {
            Label(controlTitle(stage: stage, referenceDate: referenceDate), systemImage: controlSystemImage)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 42)
        }
        .atriaCardAction(prominent: true, tint: plan.isRunning ? .red : .indigo)
        .disabled((plan.isRunning && !stopIsReady)
                  || (!plan.isRunning
                      && ble.stepCalibrationCaptureArmedAt != nil
                      && !ble.stepCalibrationMotionStreamReady))
        .accessibilityHint(controlAccessibilityHint(stopIsReady: stopIsReady))
    }

    private func controlTitle(stage: AtriaStepCalibrationStage, referenceDate: Date) -> String {
        guard plan.isRunning else {
            if ble.stepCalibrationCaptureArmedAt == nil { return "Prepare motion stream" }
            return ble.stepCalibrationMotionStreamReady ? "Start stage" : "Waiting for fresh motion…"
        }
        guard
              stage.minimumDurationMS > 0,
              let startMS = plan.state.activeStageStartMS else {
            return "Stop stage"
        }
        let elapsedMS = Int64(referenceDate.timeIntervalSince1970 * 1_000) - startMS
        let remainingSeconds = max(0, Int(ceil(Double(stage.minimumDurationMS - elapsedMS) / 1_000)))
        return remainingSeconds > 0 ? "Rest · \(remainingSeconds)s remaining" : "Stop stage"
    }

    private var controlSystemImage: String {
        if plan.isRunning { return "stop.fill" }
        if ble.stepCalibrationCaptureArmedAt == nil { return "antenna.radiowaves.left.and.right" }
        return ble.stepCalibrationMotionStreamReady ? "play.fill" : "hourglass"
    }

    private func controlAccessibilityHint(stopIsReady: Bool) -> String {
        if plan.isRunning {
            return stopIsReady ? "Saves the current timed window" : "Rest windows require sixty seconds"
        }
        if ble.stepCalibrationCaptureArmedAt == nil {
            return "Prepares high-resolution strap motion for the timed sequence"
        }
        if !ble.stepCalibrationMotionStreamReady {
            return "Start becomes available after a fresh strap motion frame arrives"
        }
        return "Begins machine timestamping this window"
    }

    @ViewBuilder
    private var completedStages: some View {
        if !plan.state.windows.isEmpty {
            VStack(spacing: 8) {
                ForEach(Array(plan.state.windows.enumerated()), id: \.offset) { index, window in
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(window.label)
                            .font(.caption.weight(.semibold))
                        Spacer(minLength: 0)
                        Text(window.expectedSteps == 0 ? "rest" : "\(window.expectedSteps) steps")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text(Self.windowTimeFormatter.string(
                            from: Date(timeIntervalSince1970: Double(window.startMS) / 1_000)
                        ))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .accessibilityLabel("stage \(index + 1) started")
                    }
                }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            if let exportURL {
                ShareLink(item: exportURL) {
                    Label("Share JSON", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity, minHeight: 38)
                }
                .atriaCardAction(prominent: false, tint: .indigo)
            } else if plan.isComplete {
                Button {
                    exportURL = try? plan.writeManifest()
                } label: {
                    Label("Prepare JSON", systemImage: "doc.badge.gearshape")
                        .frame(maxWidth: .infinity, minHeight: 38)
                }
                .atriaCardAction(prominent: false, tint: .indigo)
            }

            Button(role: .destructive) {
                showsRestartConfirmation = true
            } label: {
                Label("Restart", systemImage: "arrow.counterclockwise")
                    .frame(maxWidth: .infinity, minHeight: 38)
            }
            .atriaCardAction(prominent: false, tint: .secondary)
            .disabled(plan.isRunning)
        }
    }

    private func elapsedText(since startMS: Int64, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince1970 - Double(startMS) / 1_000))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private static let windowTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()
}
