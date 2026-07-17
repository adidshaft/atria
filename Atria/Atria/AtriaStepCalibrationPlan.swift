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
            return "Keep the strap wrist still for GO, then count exactly \(expectedSteps) steps with natural arm swing."
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
        var activeStageFinishRequestedMS: Int64?
        var windows: [AtriaStepCalibrationManifest.Window] = []
    }

    static let defaultsKey = "atria.stepCalibration.sequence.v1"
    static let boundaryGuardDurationMS: Int64 = 2_000
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
    var isFinishing: Bool { state.activeStageFinishRequestedMS != nil }
    var isComplete: Bool { completedStageCount == totalStageCount }
    var manifest: AtriaStepCalibrationManifest { AtriaStepCalibrationManifest(windows: state.windows) }

    func canBeginCountedMotion(at date: Date? = nil) -> Bool {
        guard let startMS = state.activeStageStartMS else { return false }
        return Self.unixMilliseconds(date ?? now()) - startMS >= Self.boundaryGuardDurationMS
    }

    func canRequestFinish(at date: Date? = nil) -> Bool {
        guard let stage = currentStage,
              let startMS = state.activeStageStartMS,
              state.activeStageFinishRequestedMS == nil else { return false }
        let endMS = Self.unixMilliseconds(date ?? now())
        return endMS - startMS >= max(stage.minimumDurationMS, Self.boundaryGuardDurationMS)
    }

    var fixedCaptureEndMS: Int64? {
        state.activeStageFinishRequestedMS.map { $0 + Self.boundaryGuardDurationMS }
    }

    func canValidateCurrentStage(at date: Date? = nil) -> Bool {
        guard let fixedCaptureEndMS else { return false }
        return Self.unixMilliseconds(date ?? now()) >= fixedCaptureEndMS
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
        state.activeStageFinishRequestedMS = nil
        persist()
        return true
    }

    /// Freezes the end of counted motion. Validation deliberately uses this
    /// timestamp plus a two-second still guard, never the time of a later tap
    /// or foreground resume.
    @discardableResult
    func requestFinishCurrentStage() -> Bool {
        guard canRequestFinish() else { return false }
        state.activeStageFinishRequestedMS = Self.unixMilliseconds(now())
        persist()
        return true
    }

    @discardableResult
    func stopCurrentStage(
        validatedQuality: AtriaStrapCalibrationArchive.CaptureQuality
    ) -> Bool {
        guard let stage = currentStage,
              state.activeStageIndex == state.windows.count,
              let requestedStartMS = state.activeStageStartMS,
              let requestedEndMS = fixedCaptureEndMS,
              canValidateCurrentStage(),
              validatedQuality.durationMS == requestedEndMS - requestedStartMS,
              validatedQuality.isReady,
              let startMS = validatedQuality.alignedStartMS,
              let endMS = validatedQuality.alignedEndMSExclusive,
              endMS > startMS else { return false }
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
        state.activeStageFinishRequestedMS = nil
        persist()
        return true
    }

    /// A failed window is never spliced with later frames. Keep every earlier
    /// validated stage, but require the current counted/rest segment to start
    /// again from a fresh device-time boundary.
    func retryCurrentStage() {
        guard isRunning else { return }
        state.activeStageIndex = nil
        state.activeStageStartMS = nil
        state.activeStageFinishRequestedMS = nil
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
        switch (state.activeStageIndex, state.activeStageStartMS, state.activeStageFinishRequestedMS) {
        case (nil, nil, nil):
            return true
        case let (index?, startMS?, finishMS):
            guard index == state.windows.count,
                  index < stages.count,
                  startMS > 0 else { return false }
            guard let finishMS else { return true }
            return finishMS - startMS >= max(stages[index].minimumDurationMS,
                                             boundaryGuardDurationMS)
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
            stageProgressRail

            if let stage = plan.currentStage {
                currentStageCard(stage)
                if !plan.isRunning {
                    Text("For a valid fit, walk on a treadmill at a steady belt speed (or one long straight path). Short back-and-forth laps fail calibration.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Label("Sequence complete", systemImage: "checkmark.seal.fill")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .atriaInsetCard(tint: .green)
            }

            if let failureText = validationMessage {
                VStack(alignment: .leading, spacing: 10) {
                    Label(failureText, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Calibration stage failed. \(failureText)")
                    Button {
                        plan.retryCurrentStage()
                        validationMessage = nil
                    } label: {
                        Label("Retry stage", systemImage: "arrow.counterclockwise")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .atriaCardAction(prominent: false, tint: .orange)
                }
                .padding(12)
                .atriaInsetCard(tint: .orange)
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

    private var stageProgressRail: some View {
        HStack(spacing: 6) {
            ForEach(Array(AtriaStepCalibrationPlanStore.stages.enumerated()),
                    id: \.element.id) { index, stage in
                let isDone = index < plan.completedStageCount
                let isCurrent = index == plan.completedStageCount
                VStack(spacing: 4) {
                    Image(systemName: isDone ? "checkmark.circle.fill" : stage.systemImage)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(isDone ? .green : (isCurrent ? .indigo : .secondary))
                    Text(stage.expectedSteps == 0 ? "Rest" : "\(stage.expectedSteps)")
                        .font(.caption2.weight(isCurrent ? .bold : .regular).monospacedDigit())
                        .foregroundStyle(isCurrent ? .primary : .secondary)
                    Capsule()
                        .fill(isDone ? Color.green : (isCurrent ? Color.indigo : Color.secondary.opacity(0.25)))
                        .frame(height: 3)
                }
                .frame(maxWidth: .infinity)
                .accessibilityLabel("\(stage.label): \(isDone ? "complete" : (isCurrent ? "current" : "upcoming"))")
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Large glanceable state line for treadmill use: the phone sits on the
    /// console, so the current obligation (wait / GO + target / hold-still
    /// countdown) must be readable at arm's length.
    private func stageStateHeadline(_ stage: AtriaStepCalibrationStage,
                                    referenceDate: Date) -> some View {
        let nowMS = Int64((referenceDate.timeIntervalSince1970 * 1_000).rounded())
        let text: String
        let tint: Color
        if let fixedEndMS = plan.fixedCaptureEndMS {
            let remaining = max(0, Int(ceil(Double(fixedEndMS - nowMS) / 1_000)))
            text = remaining > 0 ? "HOLD STILL · \(remaining)s" : "Ready to validate"
            tint = remaining > 0 ? .orange : .green
        } else if plan.isRunning, stage.kind == .walk {
            if plan.canBeginCountedMotion(at: referenceDate) {
                text = "GO · \(stage.expectedSteps) steps"
                tint = .green
            } else {
                text = "GET SET…"
                tint = .orange
            }
        } else if plan.isRunning, let startMS = plan.state.activeStageStartMS {
            let requiredMS = max(stage.minimumDurationMS,
                                 AtriaStepCalibrationPlanStore.boundaryGuardDurationMS)
            let remaining = max(0, Int(ceil(Double(requiredMS - (nowMS - startMS)) / 1_000)))
            text = remaining > 0 ? "REST · \(remaining)s left" : "Rest done"
            tint = remaining > 0 ? .cyan : .green
        } else {
            text = stage.expectedSteps == 0
                ? "Rest · keep wrist still"
                : "Next: \(stage.expectedSteps) steps"
            tint = .secondary
        }
        return Text(text)
            .font(.title2.weight(.bold).monospacedDigit())
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentTransition(.numericText())
    }

    private func currentStageCard(_ stage: AtriaStepCalibrationStage) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: stage.systemImage)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(stage.kind == .rest ? .cyan : .indigo)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Stage \(plan.completedStageCount + 1) of \(plan.totalStageCount)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Text(stage.label)
                        .font(.title3.weight(.bold))
                }
                Spacer(minLength: 0)
                if plan.isRunning, let startMS = plan.state.activeStageStartMS {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(elapsedText(since: startMS, now: context.date))
                            .font(.title3.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(alignment: .leading, spacing: 8) {
                    stageStateHeadline(stage, referenceDate: context.date)
                    Text(stageInstruction(stage, referenceDate: context.date))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if plan.isRunning {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    stageControl(stage, referenceDate: context.date)
                }
            } else {
                stageControl(stage, referenceDate: Date())
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .atriaInsetCard(tint: stage.kind == .rest ? .cyan : .indigo)
    }

    private func stageControl(_ stage: AtriaStepCalibrationStage, referenceDate: Date) -> some View {
        let finishIsReady = plan.canRequestFinish(at: referenceDate)
        let validationIsReady = plan.canValidateCurrentStage(at: referenceDate)
        return Button {
            handleStageControl(referenceDate: referenceDate)
        } label: {
            Label(controlTitle(stage: stage, referenceDate: referenceDate), systemImage: controlSystemImage)
                .font(.headline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 56)
        }
        .atriaCardAction(prominent: true, tint: plan.isRunning ? .red : .indigo)
        .disabled((plan.isRunning && !(plan.isFinishing ? validationIsReady : finishIsReady))
                  || (!plan.isRunning
                      && ble.stepCalibrationCaptureArmedAt != nil
                      && !ble.stepCalibrationMotionStreamReady))
        .accessibilityHint(controlAccessibilityHint(finishIsReady: finishIsReady,
                                                    validationIsReady: validationIsReady))
    }

    private func handleStageControl(referenceDate: Date) {
        if !plan.isRunning {
            if ble.stepCalibrationCaptureArmedAt == nil {
                ble.armStepCalibrationCapture()
            } else if ble.stepCalibrationMotionStreamReady {
                validationMessage = nil
                _ = plan.startCurrentStage()
            }
            return
        }
        if !plan.isFinishing {
            if plan.requestFinishCurrentStage() { validationMessage = nil }
            return
        }
        guard plan.canValidateCurrentStage(at: referenceDate),
              let startMS = plan.state.activeStageStartMS,
              let endMS = plan.fixedCaptureEndMS else { return }
        let quality = AtriaStrapCalibrationArchive.shared.captureQuality(startMS: startMS,
                                                                         endMS: endMS)
        if plan.stopCurrentStage(validatedQuality: quality) {
            validationMessage = nil
            AtriaStrapCalibrationArchive.shared.flush()
            if plan.isComplete {
                exportURL = try? plan.writeManifest()
                ble.finishStepCalibrationCapture()
            }
        } else {
            validationMessage = quality.failureSummary
        }
    }

    private func controlTitle(stage: AtriaStepCalibrationStage, referenceDate: Date) -> String {
        guard plan.isRunning else {
            if ble.stepCalibrationCaptureArmedAt == nil { return "Prepare motion stream" }
            return ble.stepCalibrationMotionStreamReady ? "Start stage" : "Waiting for fresh motion…"
        }
        if let fixedEndMS = plan.fixedCaptureEndMS {
            let nowMS = Int64((referenceDate.timeIntervalSince1970 * 1_000).rounded())
            let remaining = max(0, Int(ceil(Double(fixedEndMS - nowMS) / 1_000)))
            return remaining > 0 ? "Hold still · \(remaining)s" : "Validate stage"
        }
        guard let startMS = plan.state.activeStageStartMS else { return "Start stage" }
        let elapsedMS = Int64(referenceDate.timeIntervalSince1970 * 1_000) - startMS
        let requiredMS = max(stage.minimumDurationMS, AtriaStepCalibrationPlanStore.boundaryGuardDurationMS)
        let remainingSeconds = max(0, Int(ceil(Double(requiredMS - elapsedMS) / 1_000)))
        if remainingSeconds > 0 { return "Hold still · \(remainingSeconds)s" }
        return stage.kind == .walk ? "Steps complete" : "Rest complete"
    }

    private var controlSystemImage: String {
        if plan.isRunning { return "stop.fill" }
        if ble.stepCalibrationCaptureArmedAt == nil { return "antenna.radiowaves.left.and.right" }
        return ble.stepCalibrationMotionStreamReady ? "play.fill" : "hourglass"
    }

    private func controlAccessibilityHint(finishIsReady: Bool, validationIsReady: Bool) -> String {
        if plan.isRunning {
            if plan.isFinishing {
                return validationIsReady
                    ? "Validates and saves the fixed calibration window"
                    : "Keep the strap wrist still for the trailing boundary guard"
            }
            return finishIsReady
                ? "Freezes the end of counted motion"
                : "Keep the strap wrist still until the stage is ready"
        }
        if ble.stepCalibrationCaptureArmedAt == nil {
            return "Prepares high-resolution strap motion for the timed sequence"
        }
        if !ble.stepCalibrationMotionStreamReady {
            return "Start becomes available after a fresh strap motion frame arrives"
        }
        return "Begins machine timestamping this window"
    }

    private func stageInstruction(_ stage: AtriaStepCalibrationStage,
                                  referenceDate: Date) -> String {
        if plan.isFinishing { return "Keep the strap wrist still until this stage is ready." }
        if plan.isRunning,
           stage.kind == .walk,
           !plan.canBeginCountedMotion(at: referenceDate) {
            return "Keep the strap wrist still. Begin only when GO appears."
        }
        if plan.isRunning, stage.kind == .walk {
            return "Count exactly \(stage.expectedSteps) steps at this pace, then tap Steps complete."
        }
        return stage.instruction
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
