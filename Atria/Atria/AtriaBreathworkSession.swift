import SwiftUI

/// A timestamped value emitted by Atria's existing live stress engine.
/// Breathwork never derives stress from heart rate on its own: callers pass a
/// reading only when `AtriaStressMonitorStore` produced a scored state.
struct AtriaBreathworkStressReading: Equatable {
    static let freshnessInterval: TimeInterval = 90
    static let futureTolerance: TimeInterval = 5

    let score: Double
    let measuredAt: Date

    init?(score: Double, measuredAt: Date) {
        guard score.isFinite else { return nil }
        self.score = min(max(score, 0), 3)
        self.measuredAt = measuredAt
    }

    init?(state: AtriaStressState, measuredAt: Date?) {
        guard state.kind == .scored,
              state.level != nil,
              state.rawActivation.isFinite,
              let measuredAt else { return nil }
        self.score = min(max(state.rawActivation * 3, 0), 3)
        self.measuredAt = measuredAt
    }

    func fresh(at now: Date,
               maximumAge: TimeInterval = freshnessInterval) -> AtriaBreathworkStressReading? {
        let age = now.timeIntervalSince(measuredAt)
        guard age >= -Self.futureTolerance, age <= maximumAge else { return nil }
        return self
    }
}

/// Pure presentation model for the active session's measured stress feedback.
/// A missing baseline still permits a current score, but never a delta. A stale
/// current value fails closed so the UI cannot present an old score as live.
struct AtriaBreathworkStressFeedback: Equatable {
    enum Direction: Equatable {
        case down
        case steady
        case up
    }

    let currentScore: Double
    let baselineScore: Double?
    let delta: Double?
    let direction: Direction?

    static func make(current: AtriaBreathworkStressReading?,
                     baseline: AtriaBreathworkStressReading?,
                     now: Date) -> AtriaBreathworkStressFeedback? {
        guard let current = current?.fresh(at: now) else { return nil }
        guard let baseline else {
            return AtriaBreathworkStressFeedback(currentScore: current.score,
                                                 baselineScore: nil,
                                                 delta: nil,
                                                 direction: nil)
        }
        let delta = current.score - baseline.score
        let direction: Direction
        if abs(delta) < 0.05 {
            direction = .steady
        } else {
            direction = delta < 0 ? .down : .up
        }
        return AtriaBreathworkStressFeedback(currentScore: current.score,
                                             baselineScore: baseline.score,
                                             delta: delta,
                                             direction: direction)
    }

    var valueText: String { String(format: "%.1f", currentScore) }

    var changeText: String? {
        guard let baselineScore, let delta, let direction else { return nil }
        switch direction {
        case .down:
            return "down \(String(format: "%.1f", abs(delta))) from \(String(format: "%.1f", baselineScore))"
        case .steady:
            return "unchanged from \(String(format: "%.1f", baselineScore))"
        case .up:
            return "up \(String(format: "%.1f", abs(delta))) from \(String(format: "%.1f", baselineScore))"
        }
    }
}

struct AtriaBreathworkSession: View {
    struct HeartSample: Equatable {
        let date: Date
        let bpm: Int
    }

    struct RRSample: Equatable {
        let date: Date
        let ms: Int
        let source: AtriaRRSourceProvenance?

        init(date: Date,
             ms: Int,
             source: AtriaRRSourceProvenance? = nil) {
            self.date = date
            self.ms = ms
            self.source = source
        }
    }

    private struct RRInputKey: Equatable {
        let count: Int
        let lastDate: Date?
        let lastMS: Int?

        init(_ samples: [RRSample]) {
            count = samples.count
            lastDate = samples.last?.date
            lastMS = samples.last?.ms
        }
    }

    private struct FinishArtifacts {
        let result: Result
        let session: SavedSession?
    }

    /// Restarts only at session/pause/accessibility boundaries. The orb itself
    /// is animated by Core Animation between phase endpoints; it does not need
    /// a display-link `TimelineView` to rebuild SwiftUI content every frame.
    private struct BreathAnimationKey: Hashable {
        let startedAt: Date
        let pausedAt: Date?
        let accumulatedPause: TimeInterval
        let reduceMotion: Bool
    }

    private struct BreathCue {
        let instruction: String
        let secondsRemaining: Int
        let visualProgress: Double
    }

    struct Result: Equatable {
        let startingHR: Int?
        let endingHR: Int?
        let rmssdDelta: Int?

        var hrText: String {
            guard let startingHR, let endingHR else { return "HR learning" }
            let delta = endingHR - startingHR
            return "HR \(startingHR) -> \(endingHR) · \(delta >= 0 ? "+" : "")\(delta) bpm"
        }

        var rmssdText: String? {
            rmssdDelta.map { "RMSSD \($0 >= 0 ? "+" : "")\($0) ms" }
        }
    }

    let currentHeartRate: Int
    let currentRRSamples: [RRSample]
    let currentStress: AtriaBreathworkStressReading?
    let onSave: (SavedSession) -> Void
    let onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedDuration: TimeInterval = 180
    @State private var startedAt: Date?
    @State private var samples: [HeartSample] = []
    @State private var rrSamples: [RRSample] = []
    @State private var result: Result?
    @State private var pausedAt: Date?
    @State private var accumulatedPause: TimeInterval = 0
    @State private var breathVisualProgress = 0.0
    @State private var startingStress: AtriaBreathworkStressReading?

    private let breathCycle: TimeInterval = 10.9

    private var currentRRInputKey: RRInputKey {
        RRInputKey(currentRRSamples)
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [
                Color.black,
                Metrics.electricStrain.opacity(0.28),
                Color.black
            ], startPoint: .topLeading, endPoint: .bottomTrailing)
            .ignoresSafeArea()

            VStack(spacing: 20) {
                header

                Spacer(minLength: 0)

                if let result {
                    resultView(result)
                } else if let startedAt {
                    activeSession(startedAt: startedAt)
                } else {
                    setupView
                }

                Spacer(minLength: 0)
            }
            .padding(22)
        }
        .onChange(of: currentHeartRate) { _, bpm in
            guard startedAt != nil, result == nil, pausedAt == nil, bpm > 0 else { return }
            samples.append(HeartSample(date: Date(), bpm: bpm))
        }
        .onChange(of: currentRRInputKey) { _, _ in
            appendNewRRSamples(currentRRSamples)
        }
        .onAppear {
            #if DEBUG
            if Self.debugShowsResultFixture(arguments: ProcessInfo.processInfo.arguments) {
                seedDebugResultFixture()
            }
            #endif
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                if let startedAt, result == nil {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let elapsed = activeElapsed(at: context.date, startedAt: startedAt)
                        let remaining = max(0, selectedDuration - elapsed)
                        Text("Relax · \(timeText(remaining))")
                            .font(.headline.weight(.black).monospacedDigit())
                            .foregroundStyle(.white)
                            .contentTransition(reduceMotion ? .identity : .numericText())
                    }
                } else {
                    Text("Breathwork")
                        .font(.title2.weight(.black))
                        .foregroundStyle(.white)
                }
                if startedAt == nil || result != nil {
                    Text("5.5 breaths/min")
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.68))
                }
            }

            Spacer()

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(.white.opacity(0.12), in: Circle())
                    .glassEffect(.regular.tint(.white.opacity(0.08)), in: Circle())
            }
            .accessibilityLabel("Close breathwork")
        }
    }

    private var setupView: some View {
        VStack(spacing: 18) {
            Image(systemName: "lungs.fill")
                .font(.system(size: 54, weight: .bold))
                .foregroundStyle(Metrics.electricStrain)

            Text("Settle your breathing")
                .font(.title.weight(.black))
                .foregroundStyle(.white)

            Picker("Duration", selection: $selectedDuration) {
                Text("1 min").tag(TimeInterval(60))
                Text("3 min").tag(TimeInterval(180))
                Text("5 min").tag(TimeInterval(300))
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 320)

            Button {
                startedAt = Date()
                pausedAt = nil
                accumulatedPause = 0
                startingStress = currentStress?.fresh(at: Date())
                samples.removeAll(keepingCapacity: true)
                rrSamples.removeAll(keepingCapacity: true)
                if currentHeartRate > 0 {
                    samples.append(HeartSample(date: Date(), bpm: currentHeartRate))
                }
                appendNewRRSamples(currentRRSamples)
            } label: {
                Label("Start", systemImage: "play.fill")
                    .font(.headline.weight(.black))
                    .frame(maxWidth: 260)
            }
            .buttonStyle(.glassProminent)
            .tint(Metrics.electricStrain)
            .controlSize(.large)
        }
        .multilineTextAlignment(.center)
    }

    private func activeSession(startedAt: Date) -> some View {
        VStack(spacing: 20) {
            animatedBreathCircle(startedAt: startedAt)

            TimelineView(.periodic(from: .now, by: 1)) { context in
                let elapsed = activeElapsed(at: context.date, startedAt: startedAt)
                VStack(spacing: 14) {
                    stressFeedback(at: context.date)

                    HStack(spacing: 12) {
                        HStack(spacing: 8) {
                            ForEach(0..<4, id: \.self) { index in
                                Capsule(style: .continuous)
                                    .fill(progressFill(index: index, elapsed: elapsed))
                                    .frame(width: 24, height: 5)
                            }
                        }
                        .accessibilityHidden(true)

                        Spacer(minLength: 4)

                        Label(currentHeartRate > 0 ? "\(currentHeartRate) bpm" : "HR learning",
                              systemImage: "heart.fill")
                            .font(.subheadline.weight(.bold).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.72))
                    }
                }
                .onChange(of: Int(elapsed)) { _, _ in
                    if elapsed >= selectedDuration, result == nil {
                        finish()
                    }
                }
            }

            Button(action: togglePause) {
                Label(pausedAt == nil ? "Pause" : "Resume",
                      systemImage: pausedAt == nil ? "pause.fill" : "play.fill")
                    .font(.headline.weight(.bold))
                    .frame(maxWidth: .infinity, minHeight: 30)
            }
            .buttonStyle(.glassProminent)
            .tint(pausedAt == nil ? .white.opacity(0.16) : Metrics.electricStrain)
            .controlSize(.large)
            .accessibilityHint(pausedAt == nil ? "Freezes the breathing clock" : "Continues the breathing session")
        }
    }

    @ViewBuilder
    private func stressFeedback(at now: Date) -> some View {
        let feedback = AtriaBreathworkStressFeedback.make(current: currentStress,
                                                          baseline: startingStress,
                                                          now: now)
        VStack(spacing: 3) {
            Text("Live stress")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.58))

            if let feedback {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(feedback.valueText)
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    if let direction = feedback.direction {
                        Image(systemName: stressDirectionSymbol(direction))
                            .font(.headline.weight(.black))
                            .foregroundStyle(stressDirectionTint(direction))
                            .accessibilityHidden(true)
                    }
                }
                .foregroundStyle(.white)
                .contentTransition(reduceMotion ? .identity : .numericText())

                Text(feedback.changeText ?? "Start reading unavailable")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(feedback.direction.map(stressDirectionTint) ?? .white.opacity(0.52))
            } else {
                Text("—")
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.56))
                Text("Measured stress unavailable")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.52))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 78)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(stressAccessibilityLabel(feedback))
    }

    private func stressDirectionSymbol(_ direction: AtriaBreathworkStressFeedback.Direction) -> String {
        switch direction {
        case .down: return "arrow.down"
        case .steady: return "minus"
        case .up: return "arrow.up"
        }
    }

    private func stressDirectionTint(_ direction: AtriaBreathworkStressFeedback.Direction) -> Color {
        switch direction {
        case .down: return Metrics.electricGreen
        case .steady: return .white.opacity(0.64)
        case .up: return Metrics.electricStress
        }
    }

    private func stressAccessibilityLabel(_ feedback: AtriaBreathworkStressFeedback?) -> String {
        guard let feedback else { return "Live stress unavailable" }
        guard let changeText = feedback.changeText else {
            return "Live stress \(feedback.valueText), start reading unavailable"
        }
        return "Live stress \(feedback.valueText), \(changeText)"
    }

    /// Copy changes at one-second cadence. Smooth motion comes from infrequent
    /// phase-endpoint state changes whose scale/opacity interpolation stays on
    /// the compositor, so the gradient + native-glass subtree is not rebuilt at
    /// display-link cadence.
    private func animatedBreathCircle(startedAt: Date) -> some View {
        ZStack {
            breathOrb(progress: breathVisualProgress)

            TimelineView(.periodic(from: .now, by: 1)) { context in
                let elapsed = activeElapsed(at: context.date, startedAt: startedAt)
                let cue = breathCue(elapsed: elapsed)
                VStack(spacing: 5) {
                    Text(cue.instruction)
                        .font(.title3.weight(.black))
                    Text("\(cue.secondsRemaining) seconds")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.68))
                }
                .foregroundStyle(.white)
                .contentTransition(.opacity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(cue.instruction), \(cue.secondsRemaining) seconds")
            }
        }
        .frame(width: 260, height: 260)
        .task(id: BreathAnimationKey(startedAt: startedAt,
                                     pausedAt: pausedAt,
                                     accumulatedPause: accumulatedPause,
                                     reduceMotion: reduceMotion)) {
            await runBreathOrbAnimation(startedAt: startedAt)
        }
    }

    private func breathCue(elapsed: TimeInterval) -> BreathCue {
        let cyclePosition = (elapsed.truncatingRemainder(dividingBy: breathCycle)) / breathCycle
        // Preserve the evidence-based 5.5 breaths/min cadence while matching
        // the design archive's softer 45/10/45 motion curve: expand, briefly
        // settle at full size, then contract. The plateau prevents an abrupt
        // direction change and makes the instruction easier to follow.
        let inhaleEnd = 0.45
        let exhaleStart = 0.55
        let inhale = cyclePosition < inhaleEnd
        let holding = cyclePosition >= inhaleEnd && cyclePosition < exhaleStart
        let phaseProgress: Double = if inhale {
            cyclePosition / inhaleEnd
        } else if holding {
            1
        } else {
            max(0, 1 - ((cyclePosition - exhaleStart) / (1 - exhaleStart)))
        }
        let instruction = inhale ? "Breathe in" : (holding ? "Hold" : "Breathe out")
        let secondsRemaining: TimeInterval = if inhale {
            (inhaleEnd - cyclePosition) * breathCycle
        } else if holding {
            (exhaleStart - cyclePosition) * breathCycle
        } else {
            (1 - cyclePosition) * breathCycle
        }
        return BreathCue(instruction: instruction,
                         secondsRemaining: max(1, Int(secondsRemaining.rounded(.up))),
                         visualProgress: phaseProgress)
    }

    private func breathOrb(progress: Double) -> some View {
        let clampedProgress = min(max(progress, 0), 1)
        let scale = reduceMotion ? 1.0 : 0.82 + 0.30 * clampedProgress

        return ZStack {
            Circle()
                .fill(
                    RadialGradient(colors: [
                        Metrics.electricStrain.opacity(0.25),
                        .clear
                    ], center: .center, startRadius: 0, endRadius: 130)
                )
                .frame(width: 260, height: 260)
                .scaleEffect(reduceMotion ? 1 : 0.8 + 0.35 * clampedProgress)
                .opacity(reduceMotion ? 0.6 : 0.35 + 0.5 * clampedProgress)

            Circle()
                .stroke(Metrics.electricStrain.opacity(0.30), lineWidth: 1.5)
                .frame(width: 210, height: 210)
                .scaleEffect(reduceMotion ? 1 : 0.86 + 0.22 * clampedProgress)
                .opacity(reduceMotion ? 0.72 : 0.5 + 0.5 * clampedProgress)

            Circle()
                .fill(
                    RadialGradient(colors: [
                        Metrics.electricStrain.opacity(0.76),
                        Metrics.electricStrain.opacity(0.30)
                    ], center: .center, startRadius: 0, endRadius: 120)
                )
                .overlay {
                    Circle()
                        .stroke(.white.opacity(0.40), lineWidth: 1)
                }
                .frame(width: 170, height: 170)
                .scaleEffect(scale)
                .glassEffect(.regular.tint(Metrics.electricStrain.opacity(0.20)), in: Circle())
        }
        .frame(width: 260, height: 260)
        .accessibilityHidden(true)
    }

    @MainActor
    private func runBreathOrbAnimation(startedAt: Date) async {
        let initialElapsed = activeElapsed(at: Date(), startedAt: startedAt)
        setBreathVisualProgressImmediately(reduceMotion ? 0 : breathCue(elapsed: initialElapsed).visualProgress)

        guard !reduceMotion, pausedAt == nil else { return }

        while !Task.isCancelled {
            let elapsed = activeElapsed(at: Date(), startedAt: startedAt)
            let cyclePosition = (elapsed.truncatingRemainder(dividingBy: breathCycle)) / breathCycle
            let duration: TimeInterval
            let target: Double
            let animation: Animation?

            if cyclePosition < 0.45 {
                duration = (0.45 - cyclePosition) * breathCycle
                target = 1
                animation = .easeInOut(duration: duration)
            } else if cyclePosition < 0.55 {
                duration = (0.55 - cyclePosition) * breathCycle
                target = 1
                animation = nil
            } else {
                duration = (1 - cyclePosition) * breathCycle
                target = 0
                animation = .easeInOut(duration: duration)
            }

            if let animation {
                withAnimation(animation) {
                    breathVisualProgress = target
                }
            } else {
                setBreathVisualProgressImmediately(target)
            }

            do {
                try await Task.sleep(for: .seconds(max(duration, 0.01)))
            } catch {
                return
            }
        }
    }

    @MainActor
    private func setBreathVisualProgressImmediately(_ progress: Double) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            breathVisualProgress = progress
        }
    }

    private func resultView(_ result: Result) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 62, weight: .bold))
                .foregroundStyle(.mint)

            Text(result.hrText)
                .font(.title2.weight(.black).monospacedDigit())
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)

            if let rmssdText = result.rmssdText {
                Text(rmssdText)
                    .font(.headline.weight(.bold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.74))
            }

            Button(action: onClose) {
                Text("Done")
                    .font(.headline.weight(.black))
                    .frame(maxWidth: 220)
            }
            .buttonStyle(.glassProminent)
            .tint(.mint)
            .controlSize(.large)
        }
    }

    private func finish() {
        let start = startedAt ?? Date()
        let end = Date()
        let artifacts = Self.finishArtifacts(samples: samples, rrSamples: rrSamples, start: start, end: end)
        result = artifacts.result
        if let session = artifacts.session {
            onSave(session)
        }
    }

    private func togglePause() {
        let now = Date()
        if let pausedAt {
            accumulatedPause += max(0, now.timeIntervalSince(pausedAt))
            self.pausedAt = nil
        } else {
            pausedAt = now
        }
    }

    private func activeElapsed(at now: Date, startedAt: Date) -> TimeInterval {
        let clock = pausedAt ?? now
        return max(0, clock.timeIntervalSince(startedAt) - accumulatedPause)
    }

    private func progressFill(index: Int, elapsed: TimeInterval) -> Color {
        let fraction = selectedDuration > 0 ? min(max(elapsed / selectedDuration, 0), 1) : 0
        return fraction >= Double(index + 1) / 4
            ? Metrics.electricStrain
            : .white.opacity(0.22)
    }

    private func timeText(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func summarize(samples: [HeartSample],
                          rrSamples: [RRSample] = [],
                          start: Date,
                          end: Date) -> Result {
        finishArtifacts(samples: samples, rrSamples: rrSamples, start: start, end: end).result
    }

    static func savedSession(samples: [HeartSample],
                             rrSamples: [RRSample] = [],
                             start: Date,
                             end: Date) -> SavedSession? {
        finishArtifacts(samples: samples, rrSamples: rrSamples, start: start, end: end).session
    }

    private static func finishArtifacts(samples: [HeartSample],
                                        rrSamples: [RRSample],
                                        start: Date,
                                        end: Date) -> FinishArtifacts {
        let firstWindowEnd = start.addingTimeInterval(60)
        let finalWindowStart = end.addingTimeInterval(-60)
        var startingSum = 0
        var startingCount = 0
        var endingSum = 0
        var endingCount = 0
        var points: [SavedSession.Point] = []
        points.reserveCapacity(samples.count)

        for sample in samples where sample.bpm > 0 {
            if sample.date >= start && sample.date <= end {
                points.append(SavedSession.Point(t: max(0, sample.date.timeIntervalSince(start)), bpm: sample.bpm))
            }
            if sample.date >= start && sample.date <= firstWindowEnd {
                startingSum += sample.bpm
                startingCount += 1
            }
            if sample.date >= finalWindowStart && sample.date <= end {
                endingSum += sample.bpm
                endingCount += 1
            }
        }

        var rrPoints: [SavedSession.RRPoint] = []
        var startingRR: [RRSample] = []
        var endingRR: [RRSample] = []
        rrPoints.reserveCapacity(rrSamples.count)
        startingRR.reserveCapacity(min(rrSamples.count, 80))
        endingRR.reserveCapacity(min(rrSamples.count, 80))

        for sample in rrSamples where (300...2000).contains(sample.ms) {
            if sample.date >= start && sample.date <= end {
                rrPoints.append(SavedSession.RRPoint(t: max(0, sample.date.timeIntervalSince(start)),
                                                     ms: sample.ms,
                                                     source: sample.source))
            }
            if sample.date >= start && sample.date <= firstWindowEnd {
                startingRR.append(sample)
            }
            if sample.date >= finalWindowStart && sample.date <= end {
                endingRR.append(sample)
            }
        }

        let starting = averageHR(sum: startingSum, count: startingCount)
        let ending = averageHR(sum: endingSum, count: endingCount)
        let startingRMSSD = rmssd(inWindow: startingRR, duration: firstWindowEnd.timeIntervalSince(start))
        let endingRMSSD = rmssd(inWindow: endingRR, duration: end.timeIntervalSince(finalWindowStart))
        let rmssdDelta: Int?
        if let startingRMSSD, let endingRMSSD {
            rmssdDelta = Int((endingRMSSD - startingRMSSD).rounded())
        } else {
            rmssdDelta = nil
        }
        let result = Result(startingHR: starting, endingHR: ending, rmssdDelta: rmssdDelta)
        guard !points.isEmpty else {
            return FinishArtifacts(result: result, session: nil)
        }
        let session = SavedSession(id: UUID(),
                                   start: start,
                                   end: end,
                                   label: "Breathwork",
                                   points: points,
                                   rrPoints: rrPoints.isEmpty ? nil : rrPoints,
                                   kind: "breathwork")
        return FinishArtifacts(result: result, session: session)
    }

    private static func averageHR(sum: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        return Int((Double(sum) / Double(count)).rounded())
    }

    private func appendNewRRSamples(_ values: [RRSample]) {
        guard startedAt != nil, result == nil, pausedAt == nil, !values.isEmpty else { return }
        let newestExisting = rrSamples.last?.date ?? .distantPast
        var fresh: [RRSample] = []
        for sample in values.reversed() {
            guard sample.date > newestExisting else { break }
            guard (300...2000).contains(sample.ms) else { continue }
            fresh.append(sample)
        }
        guard !fresh.isEmpty else { return }
        fresh.reverse()
        rrSamples.append(contentsOf: fresh)
    }

    private static func rmssd(in samples: [RRSample], start: Date, end: Date) -> Double? {
        let window = samples
            .filter { $0.date >= start && $0.date <= end && (300...2000).contains($0.ms) }
        return rmssd(inWindow: window, duration: end.timeIntervalSince(start))
    }

    private static func rmssd(inWindow samples: [RRSample], duration: TimeInterval) -> Double? {
        AtriaShortWindowRMSSD.value(
            samples: samples.map { (date: $0.date, ms: Double($0.ms)) },
            minimumCoverageSeconds: duration * 0.8
        )
    }

    #if DEBUG
    private static func debugShowsResultFixture(arguments: [String]) -> Bool {
        guard let fixtureIndex = arguments.firstIndex(of: "--atria-ui-fixture") else { return false }
        let valueIndex = arguments.index(after: fixtureIndex)
        return arguments.indices.contains(valueIndex)
            && arguments[valueIndex] == "breathwork-result-rr"
    }

    private func seedDebugResultFixture() {
        let end = Date()
        let start = end.addingTimeInterval(-180)
        let seededSamples = [
            HeartSample(date: start.addingTimeInterval(5), bpm: 76),
            HeartSample(date: start.addingTimeInterval(55), bpm: 74),
            HeartSample(date: start.addingTimeInterval(125), bpm: 66),
            HeartSample(date: start.addingTimeInterval(175), bpm: 64)
        ]
        let seededRR = Self.debugRRSamples(start: start, end: end)
        startedAt = start
        samples = seededSamples
        rrSamples = seededRR
        result = Self.summarize(samples: seededSamples, rrSamples: seededRR, start: start, end: end)
    }

    private static func debugRRSamples(start: Date, end: Date) -> [RRSample] {
        var output: [RRSample] = []
        var date = start
        var index = 0
        while date <= end {
            let inFinalMinute = date >= end.addingTimeInterval(-60)
            let base = inFinalMinute ? 930 : 800
            let wave = (index % 6) * (inFinalMinute ? 9 : 4)
            let ms = base + wave
            output.append(RRSample(date: date, ms: ms))
            date = date.addingTimeInterval(Double(ms) / 1000.0)
            index += 1
        }
        return output
    }
    #endif
}
