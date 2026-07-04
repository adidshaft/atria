import Foundation

struct DailyRollupVitals: Codable, Equatable {
    struct Stat: Codable, Equatable {
        let mean: Double
        let sd: Double
        let n: Int
    }

    let rhr: Stat?
    let hrv: Stat?
    let resp: Stat?
}

struct DailyRollupStoreEntry: Codable, Equatable, Identifiable {
    let day: Date
    let tzOffsetMinutes: Int
    var recovery: Int?
    var lnRMSSD: Double?
    var rhr: Int?
    var sleepSeconds: TimeInterval?
    var sleepPerformance: Int?
    var bedtimeMinutes: Int?
    var strain: Double?
    var respiratoryRate: Double?
    var vitals: DailyRollupVitals?
    var nutrition: AtriaNutritionSummary?

    var id: Date { day }

    private enum CodingKeys: String, CodingKey {
        case day
        case tzOffsetMinutes
        case recovery
        case lnRMSSD
        case rhr
        case sleepSeconds
        case sleepPerformance
        case bedtimeMinutes
        case strain
        case respiratoryRate
        case vitals
        case nutrition
    }

    init(day: Date,
         tzOffsetMinutes: Int? = nil,
         recovery: Int? = nil,
         lnRMSSD: Double? = nil,
         rhr: Int? = nil,
         sleepSeconds: TimeInterval? = nil,
         sleepPerformance: Int? = nil,
         bedtimeMinutes: Int? = nil,
         strain: Double? = nil,
         respiratoryRate: Double? = nil,
         vitals: DailyRollupVitals? = nil,
         nutrition: AtriaNutritionSummary? = nil,
         calendar: Calendar = .current) {
        self.day = calendar.startOfDay(for: day)
        self.tzOffsetMinutes = tzOffsetMinutes ?? TimeZone.current.secondsFromGMT(for: day) / 60
        self.recovery = recovery
        self.lnRMSSD = lnRMSSD
        self.rhr = rhr
        self.sleepSeconds = sleepSeconds
        self.sleepPerformance = sleepPerformance
        self.bedtimeMinutes = bedtimeMinutes
        self.strain = strain
        self.respiratoryRate = respiratoryRate
        self.vitals = vitals
        self.nutrition = nutrition
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let dayText = try container.decode(String.self, forKey: .day)
        guard let day = Self.dayFormatter.date(from: dayText) else {
            throw DecodingError.dataCorruptedError(forKey: .day,
                                                   in: container,
                                                   debugDescription: "Expected yyyy-MM-dd local date.")
        }
        self.day = day
        tzOffsetMinutes = try container.decode(Int.self, forKey: .tzOffsetMinutes)
        recovery = try container.decodeIfPresent(Int.self, forKey: .recovery)
        lnRMSSD = try container.decodeIfPresent(Double.self, forKey: .lnRMSSD)
        rhr = try container.decodeIfPresent(Int.self, forKey: .rhr)
        sleepSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .sleepSeconds)
        sleepPerformance = try container.decodeIfPresent(Int.self, forKey: .sleepPerformance)
        bedtimeMinutes = try container.decodeIfPresent(Int.self, forKey: .bedtimeMinutes)
        strain = try container.decodeIfPresent(Double.self, forKey: .strain)
        respiratoryRate = try container.decodeIfPresent(Double.self, forKey: .respiratoryRate)
        vitals = try container.decodeIfPresent(DailyRollupVitals.self, forKey: .vitals)
        nutrition = try container.decodeIfPresent(AtriaNutritionSummary.self, forKey: .nutrition)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.dayFormatter.string(from: day), forKey: .day)
        try container.encode(tzOffsetMinutes, forKey: .tzOffsetMinutes)
        try container.encodeIfPresent(recovery, forKey: .recovery)
        try container.encodeIfPresent(lnRMSSD, forKey: .lnRMSSD)
        try container.encodeIfPresent(rhr, forKey: .rhr)
        try container.encodeIfPresent(sleepSeconds, forKey: .sleepSeconds)
        try container.encodeIfPresent(sleepPerformance, forKey: .sleepPerformance)
        try container.encodeIfPresent(bedtimeMinutes, forKey: .bedtimeMinutes)
        try container.encodeIfPresent(strain, forKey: .strain)
        try container.encodeIfPresent(respiratoryRate, forKey: .respiratoryRate)
        try container.encodeIfPresent(vitals, forKey: .vitals)
        try container.encodeIfPresent(nutrition, forKey: .nutrition)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

final class DailyRollupStore {
    private let url: URL
    private let calendar: Calendar
    private let queue = DispatchQueue(label: "com.adidshaft.atria.daily-rollups", qos: .utility)
    private var cache: [DailyRollupStoreEntry]

    init(url: URL? = nil,
         calendar: Calendar = .current,
         fileManager: FileManager = .default) {
        self.calendar = calendar
        if let url {
            self.url = url
        } else {
            let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
                ?? fileManager.temporaryDirectory
            self.url = documents.appendingPathComponent("daily-rollups.json")
        }
        cache = Self.load(from: self.url)
    }

    func rollup(for day: Date) -> DailyRollupStoreEntry? {
        let normalized = calendar.startOfDay(for: day)
        return cache.first { calendar.isDate($0.day, inSameDayAs: normalized) }
    }

    func rollups(last count: Int) -> [DailyRollupStoreEntry] {
        Array(cache.sorted { $0.day > $1.day }.prefix(max(0, count)))
    }

    func upsert(_ rollup: DailyRollupStoreEntry) {
        let normalized = DailyRollupStoreEntry(day: rollup.day,
                                               tzOffsetMinutes: TimeZone.current.secondsFromGMT(for: rollup.day) / 60,
                                               recovery: rollup.recovery,
                                               lnRMSSD: rollup.lnRMSSD,
                                               rhr: rollup.rhr,
                                               sleepSeconds: rollup.sleepSeconds,
                                               sleepPerformance: rollup.sleepPerformance,
                                               bedtimeMinutes: rollup.bedtimeMinutes,
                                               strain: rollup.strain,
                                               respiratoryRate: rollup.respiratoryRate,
                                               vitals: rollup.vitals,
                                               nutrition: rollup.nutrition,
                                               calendar: calendar)
        cache.removeAll { calendar.isDate($0.day, inSameDayAs: normalized.day) }
        cache.append(normalized)
        cache.sort { $0.day > $1.day }

        let snapshot = cache
        let targetURL = url
        queue.async {
            Self.persist(snapshot, to: targetURL)
        }
    }

    private static func load(from url: URL) -> [DailyRollupStoreEntry] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([DailyRollupStoreEntry].self, from: data) else {
            return []
        }
        return decoded.sorted { $0.day > $1.day }
    }

    private static func persist(_ rollups: [DailyRollupStoreEntry], to url: URL) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(rollups)
            try data.write(to: url, options: .atomic)
            AtriaDebugLog("ATRIADBG daily_rollup_store_save status=ok rows=%d bytes=%d path=%@",
                          rollups.count,
                          data.count,
                          url.lastPathComponent)
        } catch {
            AtriaDebugLog("ATRIADBG daily_rollup_store_save status=failed error=%@",
                          error.localizedDescription)
        }
    }

    func replaceAll(_ rollups: [DailyRollupStoreEntry]) {
        cache = rollups.sorted { $0.day > $1.day }
        let snapshot = cache
        let targetURL = url
        queue.async {
            Self.persist(snapshot, to: targetURL)
        }
    }
}
