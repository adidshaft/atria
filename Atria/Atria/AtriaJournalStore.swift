import Foundation

/// Typed journal answers (Journal phase 2). Layered ON TOP of the legacy
/// boolean `BehaviorJournalEntry` tags: boolean questions still write the tag
/// (so the existing impact engine keeps working), and typed detail — time of
/// day, quantity, 1-5 scale — is recorded here for the v2 insight engine.
enum AtriaJournalValue: Codable, Equatable {
    case yes
    case no
    /// Minutes after local midnight (0..<1440), e.g. last caffeine at 15:30 = 930.
    case timeOfDay(minutes: Int)
    /// Small count, e.g. drinks (clamped 0...20).
    case quantity(Int)
    /// 1...5 subjective scale (mood, stress).
    case scale(Int)

    private enum CodingKeys: String, CodingKey { case kind, minutes, count, level }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .yes:
            try container.encode("yes", forKey: .kind)
        case .no:
            try container.encode("no", forKey: .kind)
        case .timeOfDay(let minutes):
            try container.encode("time", forKey: .kind)
            try container.encode(minutes, forKey: .minutes)
        case .quantity(let count):
            try container.encode("quantity", forKey: .kind)
            try container.encode(count, forKey: .count)
        case .scale(let level):
            try container.encode("scale", forKey: .kind)
            try container.encode(level, forKey: .level)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "yes":
            self = .yes
        case "no":
            self = .no
        case "time":
            let minutes = try container.decode(Int.self, forKey: .minutes)
            self = .timeOfDay(minutes: min(max(minutes, 0), 1439))
        case "quantity":
            let count = try container.decode(Int.self, forKey: .count)
            self = .quantity(min(max(count, 0), 20))
        case "scale":
            let level = try container.decode(Int.self, forKey: .level)
            self = .scale(min(max(level, 1), 5))
        default:
            // Unknown kind (newer app version / corruption): refuse rather than
            // coercing to .no, which would poison a typed question's series.
            throw DecodingError.dataCorruptedError(forKey: .kind,
                                                   in: container,
                                                   debugDescription: "unknown journal value kind")
        }
    }

    var timeOfDayMinutes: Int? {
        if case .timeOfDay(let minutes) = self { return minutes }
        return nil
    }

    var quantityValue: Int? {
        if case .quantity(let count) = self { return count }
        return nil
    }

    var scaleValue: Int? {
        if case .scale(let level) = self { return level }
        return nil
    }

    var isAffirmative: Bool {
        switch self {
        case .yes: return true
        case .no: return false
        case .timeOfDay: return true
        case .quantity(let count): return count > 0
        case .scale: return true
        }
    }
}

struct AtriaJournalAnswer: Codable, Equatable, Identifiable {
    let questionID: String
    /// Local start-of-day this answer describes.
    let day: Date
    var value: AtriaJournalValue
    var loggedAt: Date
    /// "user" | "auto"
    var source: String

    var id: String { "\(questionID)-\(Int(day.timeIntervalSince1970))" }
}

/// One JSON file in Documents; answers are tiny (a few per day). Loads lazily,
/// saves debounced on the caller's schedule (the store saves on every mutation —
/// writes are ~1 KB and rare).
final class AtriaJournalAnswerStore {
    static let fileName = "atria-journal-answers.json"
    private(set) var answers: [AtriaJournalAnswer] = []
    private var loaded = false
    private let url: URL

    init(directory: URL? = nil) {
        let base = directory
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        url = base.appendingPathComponent(Self.fileName)
    }

    /// Tolerant per-element decoding: one unrecognized record (e.g. written by a
    /// newer app version) must not discard the whole answer file.
    private struct LossyAnswer: Decodable {
        let value: AtriaJournalAnswer?
        init(from decoder: Decoder) {
            value = try? AtriaJournalAnswer(from: decoder)
        }
    }

    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder.atriaJournal.decode([LossyAnswer].self, from: data) else {
            return
        }
        answers = decoded.compactMap(\.value)
    }

    func answer(questionID: String, day: Date, calendar: Calendar = .current) -> AtriaJournalAnswer? {
        loadIfNeeded()
        let target = calendar.startOfDay(for: day)
        return answers.first { $0.questionID == questionID && calendar.startOfDay(for: $0.day) == target }
    }

    func answersByQuestion(for day: Date, calendar: Calendar = .current) -> [String: AtriaJournalAnswer] {
        loadIfNeeded()
        let target = calendar.startOfDay(for: day)
        var result: [String: AtriaJournalAnswer] = [:]
        for answer in answers where calendar.startOfDay(for: answer.day) == target {
            if result[answer.questionID] == nil {
                result[answer.questionID] = answer
            }
        }
        return result
    }

    func answerHistory(questionID: String) -> [AtriaJournalAnswer] {
        loadIfNeeded()
        return answers.filter { $0.questionID == questionID }.sorted { $0.day < $1.day }
    }

    @discardableResult
    func record(questionID: String,
                day: Date = Date(),
                value: AtriaJournalValue,
                source: String = "user",
                now: Date = Date(),
                calendar: Calendar = .current) -> AtriaJournalAnswer {
        loadIfNeeded()
        let target = calendar.startOfDay(for: day)
        let answer = AtriaJournalAnswer(questionID: questionID,
                                        day: target,
                                        value: value,
                                        loggedAt: now,
                                        source: source)
        answers.removeAll { $0.questionID == questionID && calendar.startOfDay(for: $0.day) == target }
        answers.append(answer)
        prune(now: now, calendar: calendar)
        persist()
        AtriaDebugLog("ATRIADBG journal_typed_answer status=saved question=%@ kind=%@ answers=%d",
                      questionID,
                      Self.kindLabel(value),
                      answers.count)
        return answer
    }

    /// Most recent day with any typed answer — the journal-activity signal.
    func latestActivityDay() -> Date? {
        loadIfNeeded()
        return answers.map(\.day).max()
    }

    func removeAnswer(questionID: String, day: Date, calendar: Calendar = .current) {
        loadIfNeeded()
        let target = calendar.startOfDay(for: day)
        let before = answers.count
        answers.removeAll { $0.questionID == questionID && calendar.startOfDay(for: $0.day) == target }
        guard answers.count != before else { return }
        persist()
    }

    private func prune(now: Date, calendar: Calendar, keepDays: Int = 400) {
        guard let cutoff = calendar.date(byAdding: .day, value: -keepDays, to: now) else { return }
        answers.removeAll { $0.day < cutoff }
    }

    private func persist() {
        guard let data = try? JSONEncoder.atriaJournal.encode(answers.sorted { $0.day < $1.day }) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func kindLabel(_ value: AtriaJournalValue) -> String {
        switch value {
        case .yes: return "yes"
        case .no: return "no"
        case .timeOfDay: return "time"
        case .quantity: return "quantity"
        case .scale: return "scale"
        }
    }
}

extension JSONEncoder {
    static var atriaJournal: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var atriaJournal: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// The typed follow-up attached to a boolean tag card, plus standalone scale
/// questions. IDs are stable — they key the persisted answers.
enum AtriaJournalTypedQuestion: String, CaseIterable, Identifiable {
    case caffeineLastTime = "caffeine.lastTime"
    case alcoholDrinks = "alcohol.drinks"
    case moodScale = "mood.scale"
    case stressScale = "stress.scale"
    // Subjective outcomes (2026-07-08): daily energy + focus. Both scale 1→5 =
    // depleted→energized / scattered→sharp, matching the emoji scale, so the
    // insight engine can correlate them with recovery/sleep/strain over time.
    case energyScale = "energy.scale"
    case focusScale = "focus.scale"
    // Habit behavior (2026-07-08): evening wind-down / sleep hygiene, scale 1→5 =
    // wired→relaxed. A daily behavior the user can build a habit around, and the
    // insight engine can correlate with sleep + recovery ("you sleep better on
    // well-wound-down nights") — water/nutrition/caffeine are already tracked, so
    // this fills a genuine gap rather than duplicating.
    case windDownScale = "winddown.scale"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .caffeineLastTime: return "Last caffeine at…"
        case .alcoholDrinks: return "How many drinks?"
        case .moodScale: return "How's your mood today?"
        case .stressScale: return "How stressed do you feel?"
        case .energyScale: return "How's your energy today?"
        case .focusScale: return "How sharp is your focus?"
        case .windDownScale: return "How well did you wind down?"
        }
    }

    var symbolName: String {
        switch self {
        case .caffeineLastTime: return "clock"
        case .alcoholDrinks: return "wineglass"
        case .moodScale: return "face.smiling"
        case .stressScale: return "bolt.heart"
        case .energyScale: return "bolt.fill"
        case .focusScale: return "target"
        case .windDownScale: return "moon.zzz"
        }
    }

    /// Short noun used in generated insight sentences.
    var insightLabel: String {
        switch self {
        case .caffeineLastTime: return "Caffeine"
        case .alcoholDrinks: return "drinks"
        case .moodScale: return "mood"
        case .stressScale: return "stress"
        case .energyScale: return "energy"
        case .focusScale: return "focus"
        case .windDownScale: return "wind-down"
        }
    }

    /// The legacy boolean tag this follow-up refines, when there is one.
    var linkedTag: BehaviorJournalEntry.Tag? {
        switch self {
        case .caffeineLastTime: return .caffeine
        case .alcoholDrinks: return .alcohol
        case .moodScale, .stressScale, .energyScale, .focusScale, .windDownScale: return nil
        }
    }
}
