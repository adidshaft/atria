import Charts
import SwiftUI

/// Immutable, display-ready input for ``AtriaHealthspanDetailView``.
///
/// The model intentionally owns no store or service. Its `summary` must be the
/// persisted weekly `BiologicalAgeSummary` supplied by the caller; pace,
/// contributors, trend points, and confidence are also prepared before the
/// screen opens. This keeps presentation from accidentally turning a detail
/// view into another fitness-age calculation trigger.
struct AtriaHealthspanDetailModel: Equatable {
    enum ContributorTone: Equatable, Sendable {
        case positive
        case neutral
        case attention
    }

    struct Contributor: Identifiable, Equatable, Sendable {
        let id: String
        let label: String
        let valueText: String
        let progress: Double?
        let tone: ContributorTone

        init(id: String,
             label: String,
             valueText: String,
             progress: Double? = nil,
             tone: ContributorTone = .neutral) {
            self.id = id
            self.label = label
            self.valueText = valueText
            self.progress = progress
            self.tone = tone
        }
    }

    struct TrendPoint: Identifiable, Equatable, Sendable {
        let day: Date
        let value: Double

        var id: Date { day }

        init(day: Date, value: Double) {
            self.day = day
            self.value = value
        }
    }

    struct Confidence: Equatable, Sendable {
        let level: String
        let detail: String

        init(level: String, detail: String) {
            self.level = level
            self.detail = detail
        }
    }

    let summary: BiologicalAgeSummary
    let paceOfAging: AtriaFitnessAge.PaceOfAging?
    let contributors: [Contributor]
    let trendPoints: [TrendPoint]
    let trendTitle: String
    let trendChangeText: String?
    let confidence: Confidence?
    let cachedAt: Date?

    init(summary: BiologicalAgeSummary,
         paceOfAging: AtriaFitnessAge.PaceOfAging? = nil,
         contributors: [Contributor] = [],
         trendPoints: [TrendPoint] = [],
         trendTitle: String = "Fitness age trend",
         trendChangeText: String? = nil,
         confidence: Confidence? = nil,
         cachedAt: Date? = nil) {
        self.summary = summary
        self.paceOfAging = paceOfAging
        self.contributors = contributors
        self.trendPoints = trendPoints.sorted { $0.day < $1.day }
        self.trendTitle = trendTitle
        self.trendChangeText = trendChangeText
        self.confidence = confidence
        self.cachedAt = cachedAt
    }

    /// Prepared pace only. No fallback is inferred when the caller has not
    /// supplied enough persisted observations.
    var displayPace: Double? {
        guard let paceOfAging,
              paceOfAging.isReady,
              let value = paceOfAging.yearsPerCalendarYear,
              value.isFinite else { return nil }
        return value
    }

    /// Position in the fixed 0.5x...1.5x visual lane. The displayed number is
    /// never clamped; only the marker is kept inside its gauge.
    var paceGaugePosition: Double? {
        displayPace.map { min(max(($0 - 0.5) / 1.0, 0), 1) }
    }
}

/// Compact, read-only Healthspan detail backed entirely by cached inputs.
struct AtriaHealthspanDetailView: View {
    let model: AtriaHealthspanDetailModel
    var onViewPlan: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var orbExpanded = false
    @ScaledMetric(relativeTo: .largeTitle) private var orbSize: CGFloat = 190

    init(model: AtriaHealthspanDetailModel,
         onViewPlan: (() -> Void)? = nil) {
        self.model = model
        self.onViewPlan = onViewPlan
    }

    var body: some View {
        ZStack {
            background
                .ignoresSafeArea()

            ScrollView {
                LazyVStack(spacing: AtriaDesignTokens.Spacing.md) {
                    header
                    ageHero

                    if model.displayPace != nil {
                        paceCard
                    }
                    if !model.contributors.isEmpty {
                        contributorsCard
                    }
                    if !model.trendPoints.isEmpty {
                        trendCard
                    }
                    if let confidence = model.confidence {
                        confidenceRow(confidence)
                    } else {
                        estimateNoteRow
                    }
                    if let onViewPlan {
                        Button("View your plan", action: onViewPlan)
                            .font(.headline.weight(.bold))
                            .frame(maxWidth: .infinity)
                            .controlSize(.large)
                            .atriaCardAction(tint: Metrics.electricStrain)
                            .padding(.top, AtriaDesignTokens.Spacing.xs)
                    }
                }
                .padding(.horizontal, AtriaDesignTokens.Spacing.lg)
                .padding(.top, AtriaDesignTokens.Spacing.sm)
                .padding(.bottom, AtriaDesignTokens.Spacing.xxl)
            }
            .scrollIndicators(.hidden)
        }
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: startOrbAnimation)
        .onChange(of: reduceMotion) { _, _ in
            startOrbAnimation()
        }
        .onChange(of: scenePhase) { _, _ in
            startOrbAnimation()
        }
    }

    private var background: some View {
        ZStack {
            LinearGradient(colors: AtriaDesignTokens.Surface.appBackground(isDark: colorScheme == .dark),
                           startPoint: .top,
                           endPoint: .bottom)
            RadialGradient(colors: [
                Metrics.electricStrain.opacity(colorScheme == .dark ? 0.22 : 0.12),
                .clear
            ], center: UnitPoint(x: 0.5, y: 0.08), startRadius: 0, endRadius: 260)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: AtriaDesignTokens.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Healthspan")
                    .font(.title3.weight(.bold))
                Text(updateText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "heart.text.clipboard")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Metrics.electricStrain)
                .frame(width: 34, height: 34)
                .background(AtriaIconTileBackground(cornerRadius: 11, tint: Metrics.electricStrain))
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 2)
    }

    private var updateText: String {
        guard let cachedAt = model.cachedAt else { return "Recalculated weekly" }
        return "Updated \(cachedAt.formatted(.dateTime.month(.abbreviated).day()))"
    }

    private var ageHero: some View {
        ZStack {
            orb

            VStack(spacing: 1) {
                Text("BODY AGE")
                    .font(.caption2.weight(.bold))
                    .tracking(1.2)
                    .foregroundStyle(.secondary)
                Text(model.summary.valueText)
                    .font(.system(size: 52, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .contentTransition(reduceMotion ? .identity : .numericText())
                Text(ageComparisonText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Metrics.electricStrain)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                if let qualifier = model.summary.earlyEstimateQualifierText {
                    // 14–27 days of history: the estimate is real but not yet
                    // confident. The qualifier stays visibly attached to the
                    // hero so an early value never reads as a confident one.
                    Text(qualifier)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.orange)
                        .padding(.top, 2)
                }
            }
            .padding(.horizontal, AtriaDesignTokens.Spacing.xl)
        }
        .frame(maxWidth: .infinity)
        .frame(height: max(210, orbSize + 20))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ageAccessibilityLabel)
    }

    private var orb: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(colors: [
                        Metrics.electricStrain.opacity(colorScheme == .dark ? 0.38 : 0.20),
                        Metrics.electricStrain.opacity(colorScheme == .dark ? 0.14 : 0.08),
                        .clear
                    ], center: UnitPoint(x: 0.42, y: 0.38), startRadius: 0, endRadius: orbSize * 0.62)
                )
                .frame(width: orbSize * 1.12, height: orbSize * 1.12)
                .scaleEffect(reduceMotion ? 1 :
                    (orbMotionEnabled ? (orbExpanded ? 1.06 : 0.96) : 1))
                .opacity(orbMotionEnabled ? (orbExpanded ? 1 : 0.55) : 0.82)
                .animation(orbMotionEnabled ? .easeInOut(duration: 3).repeatForever(autoreverses: true) : nil,
                           value: orbExpanded)

            ZStack {
                Circle()
                    .fill(
                        RadialGradient(colors: [
                            Metrics.electricStrain.opacity(colorScheme == .dark ? 0.48 : 0.28),
                            Metrics.electricStrain.opacity(colorScheme == .dark ? 0.16 : 0.10),
                            .clear
                        ], center: .center, startRadius: 0, endRadius: orbSize / 2)
                    )
                    .frame(width: orbSize * 0.82, height: orbSize * 0.82)
                    .shadow(color: Metrics.electricStrain.opacity(0.38), radius: 30)

                Circle()
                    .stroke(Metrics.electricStrain.opacity(0.22), lineWidth: 1)
                    .frame(width: orbSize * 0.72, height: orbSize * 0.72)
            }
            // Archive: translateY(4px) scale(.98) -> translateY(-6px)
            // scale(1.03), returning over one six-second cycle.
            .scaleEffect(orbMotionEnabled ? (orbExpanded ? 1.03 : 0.98) : 1)
            .offset(y: orbMotionEnabled ? (orbExpanded ? -6 : 4) : 0)
            .animation(orbMotionEnabled ? .easeInOut(duration: 3).repeatForever(autoreverses: true) : nil,
                       value: orbExpanded)

            healthspanParticle(size: 4,
                               restingOffset: CGSize(width: -orbSize * 0.28, height: -orbSize * 0.22),
                               cycleDuration: 5,
                               delay: 0)
            healthspanParticle(size: 3,
                               restingOffset: CGSize(width: orbSize * 0.30, height: -orbSize * 0.08),
                               cycleDuration: 6.5,
                               delay: 0.6)
            healthspanParticle(size: 3,
                               restingOffset: CGSize(width: orbSize * 0.10, height: orbSize * 0.28),
                               cycleDuration: 5.8,
                               delay: 1.2)
        }
        // Only compositor-friendly properties animate. The gradient and shape
        // remain static, avoiding a per-frame Chart/Canvas redraw.
        .compositingGroup()
        .accessibilityHidden(true)
    }

    private func healthspanParticle(size: CGFloat,
                                    restingOffset: CGSize,
                                    cycleDuration: TimeInterval,
                                    delay: TimeInterval) -> some View {
        Circle()
            .fill(.white.opacity(0.78))
            .frame(width: size, height: size)
            .offset(x: restingOffset.width + (!orbMotionEnabled || !orbExpanded ? 0 : 6),
                    y: restingOffset.height + (!orbMotionEnabled || !orbExpanded ? 0 : -8))
            .opacity(orbMotionEnabled ? (orbExpanded ? 1 : 0.4) : 0.55)
            .animation(orbMotionEnabled ? .easeInOut(duration: cycleDuration / 2)
                .repeatForever(autoreverses: true)
                .delay(delay) : nil,
                       value: orbExpanded)
    }

    private var ageComparisonText: String {
        guard let delta = model.summary.ageDelta else {
            // Calibration progress (2026-07-31 device review): show the real
            // blocker ("Building resting HR baseline", "3 sleep nights
            // required") instead of a generic "Building your baseline".
            return model.summary.isRefreshing ? "Updating weekly estimate" : model.summary.compactStatusText
        }
        guard delta != 0 else { return "Matches age \(model.summary.chronologicalAge)" }
        return "\(abs(delta)) yr\(abs(delta) == 1 ? "" : "s") \(delta < 0 ? "younger" : "older") than \(model.summary.chronologicalAge)"
    }

    private var ageAccessibilityLabel: String {
        if model.summary.isReady {
            let qualifier = model.summary.earlyEstimateQualifierText.map { " \($0)." } ?? ""
            return "Body age \(model.summary.valueText). \(ageComparisonText).\(qualifier)"
        }
        return "Body age unavailable. \(ageComparisonText)."
    }

    private var paceCard: some View {
        VStack(alignment: .leading, spacing: AtriaDesignTokens.Spacing.md) {
            HStack(alignment: .firstTextBaseline) {
                sectionLabel("PACE OF AGING")
                Spacer()
                if let pace = model.displayPace {
                    Text(pace.formatted(.number.precision(.fractionLength(1))) + "×")
                        .font(.title3.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(paceTint(pace))
                }
            }

            GeometryReader { proxy in
                let position = model.paceGaugePosition ?? 0.5
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(colors: [Metrics.electricGreen,
                                                    Metrics.electricYellow,
                                                    Metrics.electricRed],
                                           startPoint: .leading,
                                           endPoint: .trailing)
                        )
                        .frame(height: 10)
                    Capsule(style: .continuous)
                        .fill(Color.primary)
                        .frame(width: 4, height: 22)
                        .shadow(color: .black.opacity(0.24), radius: 3, y: 1)
                        .offset(x: max(0, min(proxy.size.width - 4, proxy.size.width * position - 2)))
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 22)
            .accessibilityHidden(true)

            HStack {
                Text("Slower · 0.5×")
                Spacer()
                Text("Clock · 1×")
                Spacer()
                Text("Faster · 1.5×")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            if let copy = model.paceOfAging?.copyText {
                Text(copy)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(AtriaDesignTokens.Spacing.lg)
        .atriaCard(cornerRadius: AtriaDesignTokens.Radius.tile)
        .accessibilityElement(children: .combine)
    }

    private var contributorsCard: some View {
        VStack(alignment: .leading, spacing: AtriaDesignTokens.Spacing.md) {
            sectionLabel("WHAT'S DRIVING IT")

            ForEach(model.contributors) { contributor in
                contributorRow(contributor)
            }
        }
        .padding(AtriaDesignTokens.Spacing.lg)
        .atriaCard(cornerRadius: AtriaDesignTokens.Radius.tile)
    }

    private func contributorRow(_ contributor: AtriaHealthspanDetailModel.Contributor) -> some View {
        let tint = contributorTint(contributor.tone)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: AtriaDesignTokens.Spacing.sm) {
                Text(contributor.label)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: AtriaDesignTokens.Spacing.sm)
                Text(contributor.valueText)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            if let progress = contributor.progress, progress.isFinite {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule(style: .continuous)
                            .fill(Color.secondary.opacity(0.16))
                        Capsule(style: .continuous)
                            .fill(tint)
                            .frame(width: proxy.size.width * min(max(progress, 0), 1))
                    }
                }
                .frame(height: 5)
                .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var trendCard: some View {
        VStack(alignment: .leading, spacing: AtriaDesignTokens.Spacing.md) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.trendTitle)
                    .font(.subheadline.weight(.bold))
                Spacer()
                if let change = model.trendChangeText {
                    Text(change)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Metrics.electricStrain)
                }
            }

            Chart(model.trendPoints) { point in
                LineMark(x: .value("Date", point.day),
                         y: .value("Fitness age", point.value))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .foregroundStyle(Metrics.electricStrain)

                PointMark(x: .value("Date", point.day),
                          y: .value("Fitness age", point.value))
                    .symbolSize(point.id == model.trendPoints.last?.id ? 22 : 0)
                    .foregroundStyle(Metrics.electricStrain)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 82)
            .accessibilityLabel(trendAccessibilityLabel)
            .atriaInspectableGraph(
                AtriaInspectableGraph(
                    title: model.trendTitle,
                    subtitle: "Recorded fitness-age estimates",
                    content: .timeSeries([
                        .init(title: "Fitness age",
                              unit: " yr",
                              tint: Metrics.electricStrain,
                              points: model.trendPoints.map {
                                  .init(date: $0.day, value: $0.value)
                              })
                    ])
                )
            )
        }
        .padding(AtriaDesignTokens.Spacing.lg)
        .atriaCard(cornerRadius: AtriaDesignTokens.Radius.tile)
    }

    private var trendAccessibilityLabel: String {
        guard let first = model.trendPoints.first,
              let last = model.trendPoints.last else { return model.trendTitle }
        return "\(model.trendTitle), from \(first.value.formatted()) to \(last.value.formatted())."
    }

    private func confidenceRow(_ confidence: AtriaHealthspanDetailModel.Confidence) -> some View {
        HStack(alignment: .top, spacing: AtriaDesignTokens.Spacing.md) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Confidence: **\(confidence.level)**. \(confidence.detail)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AtriaDesignTokens.Spacing.lg)
        .atriaInsetCard(tint: Metrics.electricStrain)
        .accessibilityElement(children: .combine)
    }

    private var estimateNoteRow: some View {
        HStack(alignment: .top, spacing: AtriaDesignTokens.Spacing.md) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(model.summary.footnote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AtriaDesignTokens.Spacing.lg)
        .atriaInsetCard(tint: Metrics.electricStrain)
        .accessibilityElement(children: .combine)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .tracking(1.1)
            .foregroundStyle(.secondary)
    }

    private func contributorTint(_ tone: AtriaHealthspanDetailModel.ContributorTone) -> Color {
        switch tone {
        case .positive: Metrics.electricGreen
        case .neutral: Metrics.electricStrain
        case .attention: Metrics.electricYellow
        }
    }

    private func paceTint(_ pace: Double) -> Color {
        if pace < 0.95 { return Metrics.electricGreen }
        if pace > 1.05 { return Metrics.electricRed }
        return Metrics.electricYellow
    }

    private func startOrbAnimation() {
        orbExpanded = false
        guard orbMotionEnabled else { return }
        orbExpanded = true
    }

    private var orbMotionEnabled: Bool {
        !reduceMotion && scenePhase == .active
    }
}
