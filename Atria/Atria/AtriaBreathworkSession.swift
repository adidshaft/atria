import SwiftUI

struct AtriaBreathworkSession: View {
    struct HeartSample: Equatable {
        let date: Date
        let bpm: Int
    }

    struct RRSample: Equatable {
        let date: Date
        let ms: Int
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
    let onSave: (SavedSession) -> Void
    let onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedDuration: TimeInterval = 180
    @State private var startedAt: Date?
    @State private var samples: [HeartSample] = []
    @State private var rrSamples: [RRSample] = []
    @State private var result: Result?

    private let breathCycle: TimeInterval = 10.9

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
            guard startedAt != nil, result == nil, bpm > 0 else { return }
            samples.append(HeartSample(date: Date(), bpm: bpm))
        }
        .onChange(of: currentRRSamples) { _, values in
            appendNewRRSamples(values)
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
                Text("Breathwork")
                    .font(.title2.weight(.black))
                    .foregroundStyle(.white)
                Text("5.5 breaths/min")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.68))
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
            .buttonStyle(.borderedProminent)
            .tint(Metrics.electricStrain)
            .controlSize(.large)
        }
        .multilineTextAlignment(.center)
    }

    private func activeSession(startedAt: Date) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let elapsed = context.date.timeIntervalSince(startedAt)
            let remaining = max(0, selectedDuration - elapsed)
            VStack(spacing: 22) {
                breathCircle(elapsed: elapsed)

                Text(phaseText(elapsed: elapsed))
                    .font(.title.weight(.black))
                    .foregroundStyle(.white)
                    .contentTransition(.opacity)

                Text(timeText(remaining))
                    .font(.system(size: 42, weight: .black, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)

                Text(currentHeartRate > 0 ? "\(currentHeartRate) bpm" : "HR learning")
                    .font(.headline.weight(.bold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.72))
            }
            .onChange(of: Int(elapsed)) { _, _ in
                if elapsed >= selectedDuration, result == nil {
                    finish()
                }
            }
        }
    }

    @ViewBuilder
    private func breathCircle(elapsed: TimeInterval) -> some View {
        let progress = (elapsed.truncatingRemainder(dividingBy: breathCycle)) / breathCycle
        let inhale = progress < 0.5
        let phaseProgress = inhale ? progress * 2 : (1 - progress) * 2
        let scale = reduceMotion ? 1.0 : 0.78 + 0.28 * phaseProgress

        Circle()
            .fill(Metrics.electricStrain.opacity(0.18))
            .overlay {
                Circle()
                    .stroke(.white.opacity(0.42), lineWidth: 2)
            }
            .overlay {
                Text(inhale ? "Inhale" : "Exhale")
                    .font(.title3.weight(.black))
                    .foregroundStyle(.white)
                    .opacity(reduceMotion ? 1 : 0.92)
            }
            .frame(width: 230, height: 230)
            .scaleEffect(scale)
            .glassEffect(.regular.tint(Metrics.electricStrain.opacity(0.20)), in: Circle())
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: scale)
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
            .buttonStyle(.borderedProminent)
            .tint(.mint)
            .controlSize(.large)
        }
    }

    private func finish() {
        let start = startedAt ?? Date()
        let end = Date()
        result = Self.summarize(samples: samples, rrSamples: rrSamples, start: start, end: end)
        if let session = Self.savedSession(samples: samples, rrSamples: rrSamples, start: start, end: end) {
            onSave(session)
        }
    }

    private func phaseText(elapsed: TimeInterval) -> String {
        (elapsed.truncatingRemainder(dividingBy: breathCycle)) < breathCycle / 2 ? "Inhale" : "Exhale"
    }

    private func timeText(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func summarize(samples: [HeartSample],
                          rrSamples: [RRSample] = [],
                          start: Date,
                          end: Date) -> Result {
        let firstWindowEnd = start.addingTimeInterval(60)
        let finalWindowStart = end.addingTimeInterval(-60)
        let starting = averageHR(samples.filter { $0.date >= start && $0.date <= firstWindowEnd })
        let ending = averageHR(samples.filter { $0.date >= finalWindowStart && $0.date <= end })
        let startingRMSSD = rmssd(in: rrSamples, start: start, end: firstWindowEnd)
        let endingRMSSD = rmssd(in: rrSamples, start: finalWindowStart, end: end)
        let rmssdDelta: Int?
        if let startingRMSSD, let endingRMSSD {
            rmssdDelta = Int((endingRMSSD - startingRMSSD).rounded())
        } else {
            rmssdDelta = nil
        }
        return Result(startingHR: starting, endingHR: ending, rmssdDelta: rmssdDelta)
    }

    static func savedSession(samples: [HeartSample],
                             rrSamples: [RRSample] = [],
                             start: Date,
                             end: Date) -> SavedSession? {
        let points = samples
            .filter { $0.date >= start && $0.date <= end && $0.bpm > 0 }
            .map { SavedSession.Point(t: max(0, $0.date.timeIntervalSince(start)), bpm: $0.bpm) }
        guard !points.isEmpty else { return nil }
        let rrPoints = rrSamples
            .filter { $0.date >= start && $0.date <= end && (300...2000).contains($0.ms) }
            .map { SavedSession.RRPoint(t: max(0, $0.date.timeIntervalSince(start)), ms: $0.ms) }
        return SavedSession(id: UUID(),
                            start: start,
                            end: end,
                            label: "Breathwork",
                            points: points,
                            rrPoints: rrPoints.isEmpty ? nil : rrPoints,
                            kind: "breathwork")
    }

    private static func averageHR(_ samples: [HeartSample]) -> Int? {
        let values = samples.map(\.bpm).filter { $0 > 0 }
        guard !values.isEmpty else { return nil }
        return Int((Double(values.reduce(0, +)) / Double(values.count)).rounded())
    }

    private func appendNewRRSamples(_ values: [RRSample]) {
        guard startedAt != nil, result == nil, !values.isEmpty else { return }
        let newestExisting = rrSamples.last?.date ?? .distantPast
        let fresh = values
            .filter { $0.date > newestExisting && (300...2000).contains($0.ms) }
            .sorted { $0.date < $1.date }
        guard !fresh.isEmpty else { return }
        rrSamples.append(contentsOf: fresh)
    }

    private static func rmssd(in samples: [RRSample], start: Date, end: Date) -> Double? {
        let window = samples
            .filter { $0.date >= start && $0.date <= end && (300...2000).contains($0.ms) }
            .sorted { $0.date < $1.date }
        guard window.count >= 3 else { return nil }
        let coveredMS = window.reduce(0) { $0 + $1.ms }
        guard Double(coveredMS) >= end.timeIntervalSince(start) * 1_000 * 0.8 else { return nil }
        var squaredDiffs: [Double] = []
        squaredDiffs.reserveCapacity(window.count - 1)
        for pair in zip(window, window.dropFirst()) {
            let diff = Double(pair.1.ms - pair.0.ms)
            squaredDiffs.append(diff * diff)
        }
        guard !squaredDiffs.isEmpty else { return nil }
        return sqrt(squaredDiffs.reduce(0, +) / Double(squaredDiffs.count))
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
