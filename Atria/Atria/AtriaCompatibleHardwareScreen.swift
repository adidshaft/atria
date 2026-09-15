import SwiftUI

/// Review-accurate hardware and signal disclosure. Only WHOOP 4.0 is stated as
/// validated for this build. Atria is independent and not affiliated with WHOOP.
struct AtriaCompatibleHardwareScreen: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Compatible hardware & signals")
                    .font(AtriaDesignTokens.Typography.pageTitle)
                    .fixedSize(horizontal: false, vertical: true)

                Text("This review build is validated with WHOOP 4.0. Other WHOOP generations are not claimed as equally validated here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                disclosureCard(
                    title: "Validated hardware",
                    rows: [
                        ("WHOOP 4.0", "The model used for this review build.")
                    ]
                )

                disclosureCard(
                    title: "Read from the strap",
                    rows: [
                        ("Bluetooth connection state", "Connected, scanning, or disconnected."),
                        ("Battery", "On-strap charge when the device reports it."),
                        ("Heart rate", "Live beats per minute from the optical sensor."),
                        ("Beat-to-beat / RR timing", "Shown when the strap provides usable intervals."),
                        ("Motion / step evidence", "Validated IMU evidence from the strap, not the iPhone pedometer.")
                    ]
                )

                disclosureCard(
                    title: "Derived by Atria",
                    rows: [
                        ("HRV", "Overnight variation of accepted beat-to-beat intervals."),
                        ("Resting heart rate", "Low-percentile overnight heart rate."),
                        ("Respiratory-rate estimate", "From respiratory sinus arrhythmia in beat timing."),
                        ("Recovery", "Readiness blend of overnight signals against your baseline."),
                        ("Strain", "Display skin over daily training impulse from heart rate."),
                        ("Sleep", "Duration and timing from overnight heart-rate evidence."),
                        ("Training load", "Rolling strain across recent days."),
                        ("Calories", "Active energy estimated from heart-rate sessions.")
                    ]
                )

                disclosureCard(
                    title: "Not available",
                    rows: [
                        ("ECG", "Atria does not record or display an electrocardiogram."),
                        ("Blood pressure", "Not measured or estimated."),
                        ("SpO₂", "The decoder is not verified; no percentage is shown."),
                        ("Skin temperature", "The decoder is not verified; no deviation is shown.")
                    ]
                )

                Text("Atria is independent and is not affiliated with, endorsed by, or sponsored by WHOOP.")
                    .font(.footnote.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)

                NavigationLink {
                    AtriaEvidenceCatalogScreen()
                } label: {
                    Label("Sources", systemImage: "doc.text.magnifyingglass")
                        .font(.body.weight(.semibold))
                }
                .frame(minHeight: 44)
            }
            .padding(20)
        }
        .navigationTitle("Hardware & signals")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("atria.hardware.signals")
    }

    private func disclosureCard(title: String, rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.caption.weight(.bold))
                .tracking(0.5)
                .foregroundStyle(.secondary)
            ForEach(rows, id: \.0) { row in
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.0)
                        .font(.subheadline.weight(.semibold))
                    Text(row.1)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(16)
        .atriaCard(emphasis: .soft)
    }
}
