import Foundation
import SwiftUI

/// Central in-app evidence catalog. Every cited health definition, threshold,
/// calculation, or recommendation maps to one of these records.
struct AtriaEvidenceSource: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let authorsPublisher: String
    let year: Int
    let locator: String
    let lastReviewed: Date
    let supports: [String]
    let metricIDs: [String]

    var locatorURL: URL? { URL(string: locator) }
}

enum AtriaEvidenceCatalog {
    static let lastReviewed: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(year: 2026, month: 9, day: 15))!
    }()

    static let sources: [AtriaEvidenceSource] = [
        AtriaEvidenceSource(
            id: "task-force-hrv-1996",
            title: "Heart rate variability: standards of measurement, physiological interpretation, and clinical use",
            authorsPublisher: "Task Force of the European Society of Cardiology and the North American Society of Pacing and Electrophysiology",
            year: 1996,
            locator: "https://doi.org/10.1161/01.CIR.93.5.1043",
            lastReviewed: lastReviewed,
            supports: [
                "HRV is the variation in time between consecutive heartbeats.",
                "RMSSD is an accepted time-domain measure of short-term HRV.",
                "Overnight recordings are a standard context for short-term HRV.",
                "Atria Stress is a 0–3 display mapping of cardiac autonomic load from heart-rate evidence (Calm 0–1, Moderate 1–2, High 2–3), not a cortisol test or a psychological diagnosis."
            ],
            metricIDs: ["hrv", "recovery", "stress"]
        ),
        AtriaEvidenceSource(
            id: "uth-sorensen-2004",
            title: "Estimation of VO2max from the ratio between HRmax and HRrest — the Heart Rate Ratio Method",
            authorsPublisher: "Uth N, Sørensen H, Overgaard K, Pedersen PK. European Journal of Applied Physiology",
            year: 2004,
            locator: "https://doi.org/10.1007/s00421-003-0988-y",
            lastReviewed: lastReviewed,
            supports: [
                "VO₂max can be estimated as about 15.3 × HRmax / HRrest.",
                "This is a fitness estimate, not a laboratory measurement.",
                "Fitness age in Atria is a display mapping of that VO₂max estimate against chronological age, not a clinical biological age."
            ],
            metricIDs: ["vo2max", "fitnessAge"]
        ),
        AtriaEvidenceSource(
            id: "banister-trimp-1991",
            title: "Modeling elite athletic performance",
            authorsPublisher: "Banister EW. In: Physiological Testing of the High-Performance Athlete",
            year: 1991,
            locator: "https://doi.org/10.1249/00005768-199105000-00013",
            lastReviewed: lastReviewed,
            supports: [
                "Training impulse (TRIMP) is a heart-rate-derived training-load calculation.",
                "Strain in Atria is a display mapping of daily TRIMP, not a direct strap quantity."
            ],
            metricIDs: ["strain", "recovery"]
        ),
        AtriaEvidenceSource(
            id: "aasm-sleep-2017",
            title: "AASM Scoring Manual Updates for 2017 (Version 2.4)",
            authorsPublisher: "Berry RB et al. American Academy of Sleep Medicine",
            year: 2017,
            locator: "https://doi.org/10.5664/jcsm.6576",
            lastReviewed: lastReviewed,
            supports: [
                "Sleep staging (wake, light, REM, deep) is a clinical scoring construct.",
                "Wearable stage estimates are not a clinical sleep study."
            ],
            metricIDs: ["sleep", "sleepPerformance", "sleepEfficiency"]
        ),
        AtriaEvidenceSource(
            id: "rsa-hirsch-1973",
            title: "Respiratory sinus arrhythmia in humans: how breathing pattern modulates heart rate",
            authorsPublisher: "Hirsch JA, Bishop B. American Journal of Physiology",
            year: 1981,
            locator: "https://doi.org/10.1152/ajpheart.1981.241.4.H620",
            lastReviewed: lastReviewed,
            supports: [
                "Breathing modulates beat-to-beat interval timing (respiratory sinus arrhythmia).",
                "A respiratory-rate estimate can be derived from RR timing when a clear peak exists."
            ],
            metricIDs: ["respiration", "respiratoryRate"]
        ),
        AtriaEvidenceSource(
            id: "rhr-fox-1968",
            title: "Physical activity and the prevention of coronary heart disease",
            authorsPublisher: "Fox SM, Naughton JP, Haskell WL. Annals of Clinical Research",
            year: 1971,
            locator: "https://pubmed.ncbi.nlm.nih.gov/4945367/",
            lastReviewed: lastReviewed,
            supports: [
                "Resting heart rate is a cardiovascular fitness and strain marker.",
                "Overnight or true-rest values are the intended measurement context."
            ],
            metricIDs: ["restingHeartRate", "recovery"]
        ),
        AtriaEvidenceSource(
            id: "susi-motion-2013",
            title: "Motion Mode Recognition and Step Detection Algorithms Implemented in Real-Time on Mobile Devices",
            authorsPublisher: "Susi M, Renaudin V, Lachapelle G. Sensors",
            year: 2013,
            locator: "https://doi.org/10.3390/s130201539",
            lastReviewed: lastReviewed,
            supports: [
                "Step detection can be derived from body-worn inertial sensors, including gyroscope cadence.",
                "Atria counts steps from strap IMU evidence, not the iPhone pedometer."
            ],
            metricIDs: ["steps"]
        ),
        AtriaEvidenceSource(
            id: "keytel-energy-2005",
            title: "Prediction of energy expenditure from heart rate monitoring during submaximal exercise",
            authorsPublisher: "Keytel LR et al. Journal of Sports Sciences",
            year: 2005,
            locator: "https://doi.org/10.1080/02640410400011870",
            lastReviewed: lastReviewed,
            supports: [
                "Active energy can be estimated from heart-rate recordings during activity.",
                "Calorie values in Atria are derived estimates, not a strap-reported quantity."
            ],
            metricIDs: ["calories", "activeEnergy"]
        ),
        AtriaEvidenceSource(
            id: "hirshkowitz-nsf-2015",
            title: "National Sleep Foundation's sleep time duration recommendations: methodology and results summary",
            authorsPublisher: "Hirshkowitz M et al. Sleep Health",
            year: 2015,
            locator: "https://doi.org/10.1016/j.sleh.2014.12.010",
            lastReviewed: lastReviewed,
            supports: [
                "Adults typically need 7–9 hours of sleep per night.",
                "Atria sleep-need is a personal duration target from overnight wear, not a clinical sleep prescription."
            ],
            metricIDs: ["sleep", "sleepNeed", "sleepPerformance"]
        ),
        AtriaEvidenceSource(
            id: "atria-unverified-optical-signals-2026",
            title: "Unverified WHOOP 4 accessory optical signals in this Atria build",
            authorsPublisher: "Atria",
            year: 2026,
            locator: "https://www.whoop.com",
            lastReviewed: lastReviewed,
            supports: [
                "WHOOP 4 hardware includes skin-temperature and blood-oxygen sensors.",
                "Atria has not verified those Bluetooth decoders, so it does not publish a temperature deviation or an SpO₂ percentage."
            ],
            metricIDs: ["skinTemperature", "bloodOxygen"]
        )
    ]

    static func sources(for metricID: String) -> [AtriaEvidenceSource] {
        sources.filter { $0.metricIDs.contains(metricID) }
    }

    static func sources(supportingClaimNeedle needle: String) -> [AtriaEvidenceSource] {
        sources.filter { source in
            source.supports.contains { $0.localizedCaseInsensitiveContains(needle) }
        }
    }
}

struct AtriaSourcesLink: View {
    let metricID: String
    var compact: Bool = false
    @State private var showCatalog = false

    var body: some View {
        Button {
            showCatalog = true
        } label: {
            Label("Sources", systemImage: "doc.text.magnifyingglass")
                .font(compact ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
        }
        .accessibilityIdentifier("atria.sources.\(metricID)")
        .accessibilityHint("Opens the cited sources for this claim")
        .sheet(isPresented: $showCatalog) {
            NavigationStack {
                AtriaEvidenceCatalogScreen(focusedMetricID: metricID)
                    .atriaDemoSampleBadge()
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { showCatalog = false }
                        }
                    }
            }
        }
    }
}

struct AtriaEvidenceCatalogScreen: View {
    var focusedMetricID: String? = nil

    private var visibleSources: [AtriaEvidenceSource] {
        if let focusedMetricID {
            let focused = AtriaEvidenceCatalog.sources(for: focusedMetricID)
            return focused.isEmpty ? AtriaEvidenceCatalog.sources : focused
        }
        return AtriaEvidenceCatalog.sources
    }

    var body: some View {
        List {
            Section {
                Text("These records support Atria's definitions and calculations. They are not medical advice, and they do not endorse a specific training prescription.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(visibleSources) { source in
                Section {
                    LabeledContent("Authors / publisher") {
                        Text(source.authorsPublisher)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Year") {
                        Text("\(source.year)")
                    }
                    if let url = source.locatorURL {
                        Link(source.locator, destination: url)
                    } else {
                        LabeledContent("Locator") {
                            Text(source.locator)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                    LabeledContent("Last reviewed") {
                        Text(source.lastReviewed.formatted(date: .abbreviated, time: .omitted))
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Supports")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(source.supports, id: \.self) { claim in
                            Text("• \(claim)")
                                .font(.footnote)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } header: {
                    Text(source.title)
                }
            }
        }
        .navigationTitle("Sources")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("atria.evidence.catalog")
    }
}
