import Foundation
import SwiftUI

/// Subjective morning evidence. This is intentionally a separate domain from
/// `Metrics.RecoveryEstimate`: saving or editing it cannot mutate a recovery
/// score, a baseline, or a sleep record.
struct AtriaMorningCheckIn: Codable, Equatable, Identifiable {
    static let schema = 1
    static let maximumNoteCharacters = 280
    static let maximumInterruptions = 20

    enum InterruptionTag: String, Codable, CaseIterable, Identifiable {
        case bathroom
        case restless
        case noise
        case temperature
        case pain
        case stress

        var id: String { rawValue }

        var label: String {
            switch self {
            case .bathroom: return "Bathroom"
            case .restless: return "Restless"
            case .noise: return "Noise"
            case .temperature: return "Temperature"
            case .pain: return "Pain"
            case .stress: return "Stress"
            }
        }
    }

    let schemaVersion: Int
    /// Stable civil-day identity in the timezone in which the check-in began.
    let dayKey: String
    let timeZoneIdentifier: String
    let createdAt: Date
    var updatedAt: Date
    var perceivedRecovery: Int
    var sleepQuality: Int
    var energyReadiness: Int
    var soreness: Int
    var interruptionCount: Int
    var interruptionTags: [InterruptionTag]
    var note: String
    /// Frozen context for later comparison only. Never read by recovery math.
    let objectiveRecoveryAtCheckIn: Int?
    let objectiveRecoveryConfidence: String?

    var id: String { dayKey }

    init(dayKey: String,
         timeZoneIdentifier: String,
         createdAt: Date,
         updatedAt: Date,
         perceivedRecovery: Int,
         sleepQuality: Int,
         energyReadiness: Int,
         soreness: Int,
         interruptionCount: Int,
         interruptionTags: [InterruptionTag],
         note: String,
         objectiveRecoveryAtCheckIn: Int?,
         objectiveRecoveryConfidence: String?) {
        schemaVersion = Self.schema
        self.dayKey = dayKey
        self.timeZoneIdentifier = timeZoneIdentifier
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.perceivedRecovery = Self.rating(perceivedRecovery)
        self.sleepQuality = Self.rating(sleepQuality)
        self.energyReadiness = Self.rating(energyReadiness)
        self.soreness = Self.rating(soreness)
        self.interruptionCount = min(max(interruptionCount, 0), Self.maximumInterruptions)
        self.interruptionTags = Array(Set(interruptionTags)).sorted { $0.rawValue < $1.rawValue }
        self.note = Self.sanitizedNote(note)
        self.objectiveRecoveryAtCheckIn = objectiveRecoveryAtCheckIn.flatMap {
            (0...100).contains($0) ? $0 : nil
        }
        self.objectiveRecoveryConfidence = Self.sanitizedConfidence(objectiveRecoveryConfidence)
    }

    static func rating(_ value: Int) -> Int { min(max(value, 1), 5) }

    static func sanitizedNote(_ value: String) -> String {
        String(value.trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(maximumNoteCharacters))
    }

    static func sanitizedConfidence(_ value: String?) -> String? {
        guard let value else { return nil }
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        return String(clean.prefix(80))
    }

    var isValid: Bool {
        schemaVersion == Self.schema
            && Self.isDayKey(dayKey)
            && TimeZone(identifier: timeZoneIdentifier) != nil
            && (1...5).contains(perceivedRecovery)
            && (1...5).contains(sleepQuality)
            && (1...5).contains(energyReadiness)
            && (1...5).contains(soreness)
            && (0...Self.maximumInterruptions).contains(interruptionCount)
            && interruptionTags.count == Set(interruptionTags).count
            && note.count <= Self.maximumNoteCharacters
            && (objectiveRecoveryAtCheckIn.map { (0...100).contains($0) } ?? true)
    }

    private static func isDayKey(_ value: String) -> Bool {
        value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
    }
}

struct AtriaMorningCheckInDraft: Equatable {
    var perceivedRecovery = 3
    var sleepQuality = 3
    var energyReadiness = 3
    var soreness = 3
    var interruptionCount = 0
    var interruptionTags: Set<AtriaMorningCheckIn.InterruptionTag> = []
    var note = ""

    init() {}

    init(record: AtriaMorningCheckIn) {
        perceivedRecovery = record.perceivedRecovery
        sleepQuality = record.sleepQuality
        energyReadiness = record.energyReadiness
        soreness = record.soreness
        interruptionCount = record.interruptionCount
        interruptionTags = Set(record.interruptionTags)
        note = record.note
    }
}

struct AtriaMorningCheckInEligibility: Equatable {
    let dayKey: String
    let isEligible: Bool
    let reason: String

    static func resolve(now: Date,
                        mainSleepEnd: Date?,
                        calendar: Calendar = .current) -> Self {
        if let mainSleepEnd,
           mainSleepEnd <= now.addingTimeInterval(5 * 60),
           now.timeIntervalSince(mainSleepEnd) <= 18 * 3600 {
            return .init(dayKey: dayKey(for: mainSleepEnd, calendar: calendar),
                         isEligible: true,
                         reason: "main_sleep")
        }

        let hour = calendar.component(.hour, from: now)
        return .init(dayKey: dayKey(for: now, calendar: calendar),
                     isEligible: (4..<15).contains(hour),
                     reason: (4..<15).contains(hour) ? "local_morning_wear" : "outside_morning")
    }

    static func dayKey(for date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

struct AtriaMorningCalibrationSummary: Equatable {
    static let minimumPairedDays = 7
    let pairedDays: Int
    let meanObjectiveRecovery: Double?
    let meanPerceivedRecovery: Double?
    let meanPerceivedMinusObjective: Double?

    var isReady: Bool { pairedDays >= Self.minimumPairedDays }

    static func make(records: [AtriaMorningCheckIn]) -> Self {
        let pairs = records.compactMap { record -> (Double, Double)? in
            guard record.isValid, let objective = record.objectiveRecoveryAtCheckIn else { return nil }
            // Put the 1...5 answer on an intuitive 0...100 comparison scale.
            return (Double(objective), Double(record.perceivedRecovery - 1) * 25)
        }
        guard pairs.count >= minimumPairedDays else {
            return .init(pairedDays: pairs.count,
                         meanObjectiveRecovery: nil,
                         meanPerceivedRecovery: nil,
                         meanPerceivedMinusObjective: nil)
        }
        let count = Double(pairs.count)
        let objective = pairs.reduce(0) { $0 + $1.0 } / count
        let perceived = pairs.reduce(0) { $0 + $1.1 } / count
        return .init(pairedDays: pairs.count,
                     meanObjectiveRecovery: objective,
                     meanPerceivedRecovery: perceived,
                     meanPerceivedMinusObjective: perceived - objective)
    }
}

final class AtriaMorningCheckInStore {
    static let fileName = "atria-morning-check-ins-v1.json"
    static let maximumRecords = 400

    private struct Envelope: Codable {
        let schemaVersion: Int
        var records: [AtriaMorningCheckIn]
    }

    private(set) var records: [AtriaMorningCheckIn] = []
    private let fileURL: URL

    init(directory: URL? = nil) {
        let base = directory
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        fileURL = base.appendingPathComponent(Self.fileName)
        load()
    }

    func record(for dayKey: String) -> AtriaMorningCheckIn? {
        records.first { $0.dayKey == dayKey }
    }

    var calibrationSummary: AtriaMorningCalibrationSummary {
        .make(records: records)
    }

    @discardableResult
    func save(dayKey: String,
              timeZone: TimeZone,
              draft: AtriaMorningCheckInDraft,
              objectiveRecovery: Int?,
              objectiveConfidence: String?,
              now: Date = Date()) throws -> AtriaMorningCheckIn {
        let existing = record(for: dayKey)
        let value = AtriaMorningCheckIn(
            dayKey: dayKey,
            timeZoneIdentifier: existing?.timeZoneIdentifier ?? timeZone.identifier,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now,
            perceivedRecovery: draft.perceivedRecovery,
            sleepQuality: draft.sleepQuality,
            energyReadiness: draft.energyReadiness,
            soreness: draft.soreness,
            interruptionCount: draft.interruptionCount,
            interruptionTags: Array(draft.interruptionTags),
            note: draft.note,
            // Editing never rewrites the paired objective context.
            objectiveRecoveryAtCheckIn: existing?.objectiveRecoveryAtCheckIn ?? objectiveRecovery,
            objectiveRecoveryConfidence: existing?.objectiveRecoveryConfidence ?? objectiveConfidence
        )
        guard value.isValid else { throw CocoaError(.validationMissingMandatoryProperty) }
        var next = records.filter { $0.dayKey != dayKey }
        next.append(value)
        next.sort { $0.dayKey > $1.dayKey }
        next = Array(next.prefix(Self.maximumRecords))
        try persist(next)
        records = next
        return value
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let envelope = try? JSONDecoder.atriaJournal.decode(Envelope.self, from: data),
              envelope.schemaVersion == AtriaMorningCheckIn.schema else { return }
        var seen = Set<String>()
        records = envelope.records
            .filter { $0.isValid && seen.insert($0.dayKey).inserted }
            .sorted { $0.dayKey > $1.dayKey }
        records = Array(records.prefix(Self.maximumRecords))
    }

    private func persist(_ records: [AtriaMorningCheckIn]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let envelope = Envelope(schemaVersion: AtriaMorningCheckIn.schema, records: records)
        let data = try JSONEncoder.atriaJournal.encode(envelope)
        try data.write(to: fileURL,
                       options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        // `.atomic` supplies same-directory rename; synchronizing the resulting
        // inode makes a successful save a durable UI acknowledgement boundary.
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.synchronize()
        try handle.close()
    }
}

@MainActor
private final class AtriaMorningCheckInViewModel: ObservableObject {
    @Published private(set) var record: AtriaMorningCheckIn?
    @Published var saveError: String?
    @Published private(set) var eligibility: AtriaMorningCheckInEligibility
    private let store: AtriaMorningCheckInStore

    init(mainSleepEnd: Date?, now: Date = Date(), calendar: Calendar = .current) {
        eligibility = .resolve(now: now, mainSleepEnd: mainSleepEnd, calendar: calendar)
        store = AtriaMorningCheckInStore()
        record = store.record(for: eligibility.dayKey)
    }

    func refresh(mainSleepEnd: Date?, now: Date = Date(), calendar: Calendar = .current) {
        let next = AtriaMorningCheckInEligibility.resolve(now: now,
                                                          mainSleepEnd: mainSleepEnd,
                                                          calendar: calendar)
        guard next != eligibility else { return }
        eligibility = next
        record = store.record(for: next.dayKey)
        saveError = nil
    }

    func save(_ draft: AtriaMorningCheckInDraft,
              objectiveRecovery: Int?,
              objectiveConfidence: String?) -> Bool {
        do {
            record = try store.save(dayKey: eligibility.dayKey,
                                    timeZone: .current,
                                    draft: draft,
                                    objectiveRecovery: objectiveRecovery,
                                    objectiveConfidence: objectiveConfidence)
            saveError = nil
            return true
        } catch {
            saveError = "Couldn’t save yet. Your answers are still here—try again."
            return false
        }
    }
}

struct AtriaMorningCheckInCard: View {
    let mainSleepEnd: Date?
    let objectiveRecovery: () -> Metrics.RecoveryEstimate
    @StateObject private var model: AtriaMorningCheckInViewModel
    @State private var showsSheet = false

    init(mainSleepEnd: Date?, objectiveRecovery: @escaping () -> Metrics.RecoveryEstimate) {
        self.mainSleepEnd = mainSleepEnd
        self.objectiveRecovery = objectiveRecovery
        _model = StateObject(wrappedValue: AtriaMorningCheckInViewModel(mainSleepEnd: mainSleepEnd))
    }

    var body: some View {
        if model.eligibility.isEligible || model.record != nil {
            HStack(spacing: 12) {
                Image(systemName: "heart.text.square.fill")
                    .foregroundStyle(.pink)
                    .frame(width: 34, height: 34)
                    .background(Color.pink.opacity(0.11), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text("How you feel")
                        .font(.subheadline.weight(.semibold))
                    Text(model.record.map { "Perceived recovery \($0.perceivedRecovery)/5 · separate from your objective score" }
                         ?? "Add a 30-second morning check-in")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Button(model.record == nil ? "Check in" : "Edit") { showsSheet = true }
                    .buttonStyle(.bordered)
                    .tint(.pink)
            }
            .padding(12)
            .atriaInsetCard(tint: .pink)
            .sheet(isPresented: $showsSheet) {
                AtriaMorningCheckInSheet(existing: model.record,
                                         objectiveRecovery: objectiveRecovery()) { draft, objective in
                    let saved = model.save(draft,
                                           objectiveRecovery: objective.percent,
                                           objectiveConfidence: objective.confidence.rawValue)
                    if saved { showsSheet = false }
                    return saved
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
            .onAppear {
                model.refresh(mainSleepEnd: mainSleepEnd)
            }
            .onChange(of: mainSleepEnd) { _, end in
                model.refresh(mainSleepEnd: end)
            }
        }
    }
}

private struct AtriaMorningCheckInSheet: View {
    let existing: AtriaMorningCheckIn?
    let objectiveRecovery: Metrics.RecoveryEstimate
    let onSave: (AtriaMorningCheckInDraft, Metrics.RecoveryEstimate) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var draft: AtriaMorningCheckInDraft
    @State private var saveFailed = false

    init(existing: AtriaMorningCheckIn?,
         objectiveRecovery: Metrics.RecoveryEstimate,
         onSave: @escaping (AtriaMorningCheckInDraft, Metrics.RecoveryEstimate) -> Bool) {
        self.existing = existing
        self.objectiveRecovery = objectiveRecovery
        self.onSave = onSave
        _draft = State(initialValue: existing.map(AtriaMorningCheckInDraft.init(record:)) ?? .init())
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Objective recovery")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(objectiveRecovery.percent.map { "\($0)%" } ?? "Learning")
                            .font(.title2.weight(.bold).monospacedDigit())
                        Text("Atria keeps this physiological estimate separate. Your answers add context; they never rewrite today’s score.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(14)
                    .atriaInsetCard(tint: .green)

                    Text("How you feel")
                        .font(.title3.weight(.bold))

                    rating("Perceived recovery", value: $draft.perceivedRecovery,
                           low: "Drained", high: "Excellent")
                    rating("Sleep quality", value: $draft.sleepQuality,
                           low: "Poor", high: "Restorative")
                    rating("Energy / readiness", value: $draft.energyReadiness,
                           low: "Low", high: "Ready")
                    rating("Soreness", value: $draft.soreness,
                           low: "None", high: "Very sore")

                    Stepper("Sleep interruptions: \(draft.interruptionCount)",
                            value: $draft.interruptionCount,
                            in: 0...AtriaMorningCheckIn.maximumInterruptions)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)], spacing: 8) {
                        ForEach(AtriaMorningCheckIn.InterruptionTag.allCases) { tag in
                            Button {
                                if draft.interruptionTags.contains(tag) {
                                    draft.interruptionTags.remove(tag)
                                } else {
                                    draft.interruptionTags.insert(tag)
                                }
                            } label: {
                                Label(tag.label,
                                      systemImage: draft.interruptionTags.contains(tag) ? "checkmark.circle.fill" : "circle")
                                    .font(.caption.weight(.semibold))
                            }
                            .buttonStyle(.bordered)
                            .tint(draft.interruptionTags.contains(tag) ? .pink : .secondary)
                        }
                    }

                    TextField("Optional note (280 characters)", text: $draft.note, axis: .vertical)
                        .lineLimit(2...5)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: draft.note) { _, value in
                            if value.count > AtriaMorningCheckIn.maximumNoteCharacters {
                                draft.note = String(value.prefix(AtriaMorningCheckIn.maximumNoteCharacters))
                            }
                        }

                    if saveFailed {
                        Label("Couldn’t save yet. Your answers are still here—try again.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                }
                .padding(18)
            }
            .navigationTitle(existing == nil ? "Morning check-in" : "Edit check-in")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveFailed = !onSave(draft, objectiveRecovery) }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    private func rating(_ title: String,
                        value: Binding<Int>,
                        low: String,
                        high: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(value.wrappedValue)/5").font(.subheadline.weight(.bold).monospacedDigit())
            }
            HStack(spacing: 7) {
                ForEach(1...5, id: \.self) { level in
                    Button { value.wrappedValue = level } label: {
                        Text("\(level)")
                            .font(.caption.weight(.bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                    }
                    .buttonStyle(.bordered)
                    .tint(value.wrappedValue == level ? .pink : .secondary)
                    .accessibilityLabel("\(title), \(level) of 5")
                }
            }
            HStack {
                Text(low)
                Spacer()
                Text(high)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }
}
