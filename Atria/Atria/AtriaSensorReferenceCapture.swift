import Foundation
import SwiftUI

/// An independently observed instrument reading captured against the phone's
/// clock. These rows are research inputs only: recording one never changes a
/// decoder gate, creates a health metric, or writes to HealthKit.
struct AtriaSensorReferenceEntry: Codable, Equatable, Identifiable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case oxygenReference = "oxygen_reference"
        case skinTemperature = "skin_temperature_reference"
        case clockMarker = "clock_marker"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .oxygenReference: return "Oxygen reference"
            case .skinTemperature: return "Skin-temperature reference"
            case .clockMarker: return "Clock marker"
            }
        }

        var systemImage: String {
            switch self {
            case .oxygenReference: return "waveform.path.ecg"
            case .skinTemperature: return "thermometer.medium"
            case .clockMarker: return "clock.badge.checkmark"
            }
        }
    }

    enum TemperatureUnit: String, Codable, CaseIterable, Identifiable {
        case celsius = "degC"
        case fahrenheit = "degF"

        var id: String { rawValue }
        var symbol: String { self == .celsius ? "°C" : "°F" }
    }

    let id: UUID
    let capturedAt: Date
    let kind: Kind
    let referenceSpO2Percent: Double?
    let referenceSkinTemperatureC: Double?
    let inputValue: Double?
    let inputUnit: String?
    let label: String
    let referenceDevice: String
    let measurementSite: String
    let contactState: String
    let notes: String

    init(id: UUID = UUID(),
         capturedAt: Date,
         kind: Kind,
         value: Double?,
         temperatureUnit: TemperatureUnit = .celsius,
         label: String,
         referenceDevice: String,
         measurementSite: String,
         contactState: String,
         notes: String) throws {
        let cleanedDevice = Self.cleaned(referenceDevice, maximumLength: 80)
        let cleanedSite = Self.cleaned(measurementSite, maximumLength: 80)
        if kind != .clockMarker {
            guard !cleanedDevice.isEmpty else { throw ValidationError.referenceDeviceRequired }
            guard !cleanedSite.isEmpty else { throw ValidationError.measurementSiteRequired }
        }
        switch kind {
        case .oxygenReference:
            guard let value, value.isFinite, (50...100).contains(value) else {
                throw ValidationError.oxygenOutOfRange
            }
            referenceSpO2Percent = value
            referenceSkinTemperatureC = nil
            inputValue = value
            inputUnit = "percent"
        case .skinTemperature:
            guard let value, value.isFinite else {
                throw ValidationError.temperatureOutOfRange
            }
            let celsius = temperatureUnit == .celsius ? value : (value - 32) * 5 / 9
            guard (15...45).contains(celsius) else {
                throw ValidationError.temperatureOutOfRange
            }
            referenceSpO2Percent = nil
            referenceSkinTemperatureC = celsius
            inputValue = value
            inputUnit = temperatureUnit.rawValue
        case .clockMarker:
            referenceSpO2Percent = nil
            referenceSkinTemperatureC = nil
            inputValue = nil
            inputUnit = nil
        }

        self.id = id
        self.capturedAt = capturedAt
        self.kind = kind
        self.label = Self.cleaned(label, maximumLength: 80)
        self.referenceDevice = cleanedDevice
        self.measurementSite = cleanedSite
        self.contactState = Self.cleaned(contactState, maximumLength: 80)
        self.notes = Self.cleaned(notes, maximumLength: 240)
    }

    enum ValidationError: LocalizedError, Equatable {
        case oxygenOutOfRange
        case temperatureOutOfRange
        case referenceDeviceRequired
        case measurementSiteRequired

        var errorDescription: String? {
            switch self {
            case .oxygenOutOfRange:
                return "Enter the independent monitor reading from 50 to 100%."
            case .temperatureOutOfRange:
                return "Enter a contact skin reading from 15 to 45 °C (59 to 113 °F)."
            case .referenceDeviceRequired:
                return "Enter the independent reference-device model."
            case .measurementSiteRequired:
                return "Enter where the independent reading was measured."
            }
        }
    }

    private static func cleaned(_ value: String, maximumLength: Int) -> String {
        String(value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .prefix(maximumLength))
    }
}

@MainActor
final class AtriaSensorReferenceStore: ObservableObject {
    static let defaultsKey = "atria.sensorReferenceEntries.v1"
    static let maximumEntries = 2_000

    @Published private(set) var entries: [AtriaSensorReferenceEntry]

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
           let decoded = try? JSONDecoder().decode([AtriaSensorReferenceEntry].self, from: data) {
            entries = Array(decoded.sorted { $0.capturedAt > $1.capturedAt }.prefix(Self.maximumEntries))
        } else {
            entries = []
        }
    }

    @discardableResult
    func capture(kind: AtriaSensorReferenceEntry.Kind,
                 value: Double?,
                 temperatureUnit: AtriaSensorReferenceEntry.TemperatureUnit = .celsius,
                 label: String,
                 referenceDevice: String,
                 measurementSite: String,
                 contactState: String,
                 notes: String) throws -> AtriaSensorReferenceEntry {
        let entry = try AtriaSensorReferenceEntry(capturedAt: now(),
                                                  kind: kind,
                                                  value: value,
                                                  temperatureUnit: temperatureUnit,
                                                  label: label,
                                                  referenceDevice: referenceDevice,
                                                  measurementSite: measurementSite,
                                                  contactState: contactState,
                                                  notes: notes)
        entries = Array(([entry] + entries).prefix(Self.maximumEntries))
        persist()
        AtriaDebugLog("ATRIADBG sensor_reference status=captured kind=%@ timestamp_ms=%lld local_only=1 research_only=1 decoder_validated=0 metric_promotions=0 healthkit_write=0",
                      kind.rawValue,
                      Int64((entry.capturedAt.timeIntervalSince1970 * 1_000).rounded()))
        return entry
    }

    func remove(_ entry: AtriaSensorReferenceEntry) {
        entries.removeAll { $0.id == entry.id }
        persist()
    }

    func clear() {
        entries = []
        defaults.removeObject(forKey: Self.defaultsKey)
    }

    func writeCSV() throws -> URL {
        guard !entries.isEmpty else { throw ExportError.noEntries }
        let timestampMS = Int64((now().timeIntervalSince1970 * 1_000).rounded())
        let url = fileManager.temporaryDirectory
            .appendingPathComponent("atria-sensor-reference-\(timestampMS).csv")
        try Self.csv(entries: entries.sorted { $0.capturedAt < $1.capturedAt })
            .write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func csv(entries: [AtriaSensorReferenceEntry]) -> String {
        let header = [
            "timestamp", "reference_spo2_percent", "reference_skin_temp_c", "label",
            "event_kind", "reference_device", "input_value", "input_unit",
            "measurement_site", "contact_state", "notes", "local_only",
            "research_only", "decoder_validated", "metric_promotions",
        ]
        var rows = [header.map(csvField).joined(separator: ",")]
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for entry in entries {
            rows.append([
                formatter.string(from: entry.capturedAt),
                decimal(entry.referenceSpO2Percent),
                decimal(entry.referenceSkinTemperatureC),
                entry.label,
                entry.kind.rawValue,
                entry.referenceDevice,
                decimal(entry.inputValue),
                entry.inputUnit ?? "",
                entry.measurementSite,
                entry.contactState,
                entry.notes,
                "1", "1", "0", "0",
            ].map(csvField).joined(separator: ","))
        }
        return rows.joined(separator: "\n") + "\n"
    }

    enum ExportError: LocalizedError {
        case noEntries

        var errorDescription: String? { "Capture at least one reference row before sharing." }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    private static func decimal(_ value: Double?) -> String {
        guard let value else { return "" }
        return String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
            .replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
    }

    private static func csvField(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}

/// Developer-only entry point for synchronized external instrument readings.
/// The capture timestamp is assigned when the operator taps Capture now, not
/// when this form opens, so it can be aligned to the instrument display.
struct AtriaSensorReferenceCaptureCard: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @StateObject private var store = AtriaSensorReferenceStore()
    @State private var draft: Draft?
    @State private var exportURL: URL?
    @State private var showsClearConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            Text("Record an external reading when it appears. Data stays on this iPhone until exported.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 8) {
                referenceButton(.oxygenReference)
                referenceButton(.skinTemperature)
                referenceButton(.clockMarker)
            }

            if let latest = store.entries.first {
                HStack(spacing: 10) {
                    Image(systemName: latest.kind.systemImage)
                        .foregroundStyle(.teal)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(latest.kind.title)
                            .font(.caption.weight(.semibold))
                        Text(latest.capturedAt.formatted(date: .omitted, time: .standard))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Text(Self.valueText(latest))
                        .font(.caption.monospacedDigit().weight(.semibold))
                }
                .padding(.vertical, 2)
                .accessibilityElement(children: .combine)
            }

            exportActions

            Label("Research only · Decoders locked · No HealthKit writes", systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .atriaCard(emphasis: .soft)
        .sheet(item: $draft) { draft in
            AtriaSensorReferenceCaptureSheet(draft: draft) { completed in
                try store.capture(kind: completed.kind,
                                  value: completed.numericValue,
                                  temperatureUnit: completed.temperatureUnit,
                                  label: completed.label,
                                  referenceDevice: completed.referenceDevice,
                                  measurementSite: completed.measurementSite,
                                  contactState: completed.contactState,
                                  notes: completed.notes)
                exportURL = nil
            }
        }
        .confirmationDialog("Clear sensor references?",
                            isPresented: $showsClearConfirmation,
                            titleVisibility: .visible) {
            Button("Clear all", role: .destructive) {
                store.clear()
                exportURL = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes the local reference rows. It does not delete strap captures already exported elsewhere.")
        }
    }

    @ViewBuilder
    private var header: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 6) {
                AtriaPanelSectionHeader(title: "Sensor references", subtitle: "Developer research")
                entryCount
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                AtriaPanelSectionHeader(title: "Sensor references", subtitle: "Developer research")
                Spacer(minLength: 8)
                entryCount
            }
        }
    }

    private var entryCount: some View {
        Text("\(store.entries.count) \(store.entries.count == 1 ? "record" : "records")")
            .font(.caption.monospacedDigit().weight(.semibold))
            .foregroundStyle(store.entries.isEmpty ? Color.secondary : Color.teal)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("\(store.entries.count) sensor reference records")
    }

    @ViewBuilder
    private var exportActions: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 8) {
                exportButton
                clearButton
            }
        } else {
            HStack(spacing: 8) {
                exportButton
                clearButton
            }
        }
    }

    @ViewBuilder
    private var exportButton: some View {
        if let exportURL {
            ShareLink(item: exportURL) {
                compactActionLabel("Share CSV", systemImage: "square.and.arrow.up")
            }
            .tint(.teal)
            .buttonStyle(.glass)
            .buttonBorderShape(.roundedRectangle(radius: 14))
        } else {
            Button {
                exportURL = try? store.writeCSV()
            } label: {
                compactActionLabel("Prepare CSV", systemImage: "doc.badge.gearshape")
            }
            .tint(.teal)
            .buttonStyle(.glass)
            .buttonBorderShape(.roundedRectangle(radius: 14))
            .disabled(store.entries.isEmpty)
        }
    }

    private var clearButton: some View {
        Button(role: .destructive) {
            showsClearConfirmation = true
        } label: {
            compactActionLabel("Clear", systemImage: "trash")
        }
        .tint(.red)
        .buttonStyle(.glass)
        .buttonBorderShape(.roundedRectangle(radius: 14))
        .disabled(store.entries.isEmpty)
    }

    private func compactActionLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: 44)
    }

    private func referenceButton(_ kind: AtriaSensorReferenceEntry.Kind) -> some View {
        Button {
            if kind == .clockMarker {
                _ = try? store.capture(kind: kind,
                                       value: nil,
                                       label: "clock-sync",
                                       referenceDevice: "",
                                       measurementSite: "",
                                       contactState: "",
                                       notes: "")
                exportURL = nil
            } else {
                draft = Draft(kind: kind)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: kind.systemImage)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.teal)
                    .frame(width: 24)

                Text(kind == .clockMarker ? "Mark clock" : kind.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)

                Spacer(minLength: 8)

                Image(systemName: kind == .clockMarker ? "plus" : "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        }
        .tint(.teal)
        .buttonStyle(.glass)
        .buttonBorderShape(.roundedRectangle(radius: 14))
    }

    private static func valueText(_ entry: AtriaSensorReferenceEntry) -> String {
        if let value = entry.referenceSpO2Percent { return "\(value.formatted())%" }
        if let value = entry.referenceSkinTemperatureC { return "\(value.formatted()) °C" }
        return "marker"
    }

    fileprivate struct Draft: Identifiable {
        let id = UUID()
        let kind: AtriaSensorReferenceEntry.Kind
        var valueText = ""
        var temperatureUnit = AtriaSensorReferenceEntry.TemperatureUnit.celsius
        var label = "seated-baseline"
        var referenceDevice = ""
        var measurementSite: String
        var contactState = "stable-contact"
        var notes = ""

        init(kind: AtriaSensorReferenceEntry.Kind) {
            self.kind = kind
            measurementSite = kind == .oxygenReference ? "fingertip" : "adjacent-wrist"
        }

        var numericValue: Double? {
            Double(valueText.replacingOccurrences(of: ",", with: "."))
        }
    }
}

private struct AtriaSensorReferenceCaptureSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: AtriaSensorReferenceCaptureCard.Draft
    @State private var validationMessage: String?
    let onCapture: (AtriaSensorReferenceCaptureCard.Draft) throws -> Void

    init(draft: AtriaSensorReferenceCaptureCard.Draft,
         onCapture: @escaping (AtriaSensorReferenceCaptureCard.Draft) throws -> Void) {
        _draft = State(initialValue: draft)
        self.onCapture = onCapture
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Independent reading") {
                    HStack {
                        TextField("Value", text: $draft.valueText)
                            .keyboardType(.decimalPad)
                        Text(draft.kind == .oxygenReference ? "%" : draft.temperatureUnit.symbol)
                            .foregroundStyle(.secondary)
                    }
                    if draft.kind == .skinTemperature {
                        Picker("Unit", selection: $draft.temperatureUnit) {
                            ForEach(AtriaSensorReferenceEntry.TemperatureUnit.allCases) { unit in
                                Text(unit.symbol).tag(unit)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                    TextField("Reference device model", text: $draft.referenceDevice)
                    TextField("Condition label", text: $draft.label)
                }

                Section("Capture context") {
                    TextField("Measurement site", text: $draft.measurementSite)
                    TextField("Contact state", text: $draft.contactState)
                    TextField("Notes", text: $draft.notes, axis: .vertical)
                        .lineLimit(2...4)
                }

                Section {
                    Text("The phone assigns a millisecond timestamp when you tap Record now. Use a timestamped independent monitor; this does not validate or unlock a decoder.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let validationMessage {
                    Section {
                        Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle(draft.kind.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Record now") {
                        do {
                            try onCapture(draft)
                            dismiss()
                        } catch {
                            validationMessage = error.localizedDescription
                        }
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}
