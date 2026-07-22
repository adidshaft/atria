import CryptoKit
import Darwin
import Foundation

/// Durable catalog for immutable, content-addressed daily cold-session chunks.
/// Chunks are zlib-compressed JSON; readers always verify both compressed and
/// decoded digests before exposing facts.
struct AtriaColdSessionCatalog: Codable, Equatable, Sendable {
    static let currentSchema = 1

    struct Source: Codable, Equatable, Sendable {
        let filename: String
        let sha256: String
        let byteCount: UInt64
        let decodedSessionCount: Int
        let compactEligibleSessionCount: Int
    }

    struct Entry: Codable, Equatable, Sendable {
        let civilUTCDate: String
        let filename: String
        let compressedSHA256: String
        let decodedSHA256: String
        let compressedByteCount: UInt64
        let decodedByteCount: UInt64
        let sessionCount: Int
        let firstSessionStart: Date
        let lastSessionEnd: Date
    }

    struct ConsumerReadiness: Codable, Equatable, Sendable {
        let timeline: AtriaColdSessionAvailability<String>
        let dailyLoad: AtriaColdSessionAvailability<String>
        let sleepReferences: AtriaColdSessionAvailability<String>
        let workoutReferences: AtriaColdSessionAvailability<String>
        let activityReferences: AtriaColdSessionAvailability<String>
        let rrLookback: AtriaColdSessionAvailability<String>

        static let shadowOnly = ConsumerReadiness(
            timeline: .unsupported("SessionStore timeline does not read the compact tier yet"),
            dailyLoad: .unsupported("SessionStore daily load does not read the compact tier yet"),
            sleepReferences: .unsupported("sleep consumers do not read the compact tier yet"),
            workoutReferences: .unsupported("workout consumers do not read the compact tier yet"),
            activityReferences: .unsupported("durable activity identity and readers are not complete"),
            rrLookback: .unsupported("HRV and RR consumers do not read the compact tier yet")
        )

        /// Every retained fact family has a production reader. Individual
        /// measurements can still be explicitly missing/known-empty inside a
        /// fact; this receipt means the consumer understands and preserves that
        /// state instead of silently substituting zero or an empty array.
        static let productionReadable = ConsumerReadiness(
            timeline: .available("bounded History timeline reader"),
            dailyLoad: .available("minute distribution load reader"),
            sleepReferences: .available("confirmed sleep reference reader"),
            workoutReferences: .available("confirmed workout reference reader"),
            activityReferences: .available("durable detection reference reader"),
            rrLookback: .available("five-minute RR epoch reader")
        )

        var authorizesRawRetirement: Bool {
            [timeline, dailyLoad, sleepReferences, workoutReferences, activityReferences, rrLookback]
                .allSatisfy { $0.state == .available }
        }
    }

    let schema: Int
    let generatedAt: Date
    let fullFidelityHotDays: Int
    let fullFidelityDecodedColdDays: Int
    let source: Source
    let entries: [Entry]
    let consumerReadiness: ConsumerReadiness
    /// This is intentionally false in production until all SessionStore query
    /// paths consume compact facts and have independent parity receipts.
    let productionRawRetirementEnabled: Bool

    var authorizesRawRetirement: Bool {
        productionRawRetirementEnabled && consumerReadiness.authorizesRawRetirement
    }
}

struct AtriaColdSessionChunk: Codable, Equatable, Sendable {
    static let currentSchema = 1

    let schema: Int
    let civilUTCDate: String
    let createdAt: Date
    let facts: [AtriaColdSessionFact]

    enum ValidationError: Error, Equatable {
        case unsupportedSchema
        case invalidDay
        case empty
        case duplicateSession
        case factOutsideDay
        case invalidFact
    }

    func validate() throws {
        guard schema == Self.currentSchema else { throw ValidationError.unsupportedSchema }
        guard Self.validDay(civilUTCDate) else { throw ValidationError.invalidDay }
        guard !facts.isEmpty else { throw ValidationError.empty }
        guard Set(facts.map(\.source.sessionID)).count == facts.count else {
            throw ValidationError.duplicateSession
        }
        for fact in facts {
            do { try fact.validate() } catch { throw ValidationError.invalidFact }
            guard Self.utcDay(fact.source.start) == civilUTCDate else {
                throw ValidationError.factOutsideDay
            }
        }
    }

    static func utcDay(_ date: Date) -> String {
        let seconds = Int64(floor(date.timeIntervalSince1970))
        let day = seconds >= 0 ? seconds / 86_400 : (seconds - 86_399) / 86_400
        let start = Date(timeIntervalSince1970: Double(day * 86_400))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents([.year, .month, .day], from: start)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private static func validDay(_ value: String) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        return parts.count == 3 && parts[0].count == 4 && parts[1].count == 2 && parts[2].count == 2
            && Int(parts[0]) != nil && Int(parts[1]) != nil && Int(parts[2]) != nil
    }
}

struct AtriaColdSessionStore {
    static let directoryName = "atria-cold-session-tier-v1"
    static let catalogFilename = "catalog.json"

    enum QueryError: Error, Equatable {
        case catalogMissing
        case unsupportedCatalogSchema
        case rawRetirementUnexpectedlyEnabled
        case invalidCatalog
        case chunkMissing(String)
        case chunkDigestMismatch(String)
        case chunkDecodeFailure(String)
        case chunkSemanticMismatch(String)
    }

    let rootURL: URL
    private let fileManager: FileManager

    init(rootURL: URL, fileManager: FileManager = .default) {
        self.rootURL = rootURL
        self.fileManager = fileManager
    }

    var chunksURL: URL { rootURL.appendingPathComponent("chunks", isDirectory: true) }
    var catalogURL: URL { rootURL.appendingPathComponent(Self.catalogFilename) }

    func loadCatalog() throws -> AtriaColdSessionCatalog {
        guard fileManager.fileExists(atPath: catalogURL.path) else { throw QueryError.catalogMissing }
        let data = try Data(contentsOf: catalogURL)
        let catalog: AtriaColdSessionCatalog
        do { catalog = try Self.decoder().decode(AtriaColdSessionCatalog.self, from: data) }
        catch { throw QueryError.invalidCatalog }
        guard catalog.schema == AtriaColdSessionCatalog.currentSchema else {
            throw QueryError.unsupportedCatalogSchema
        }
        // A file edit cannot grant retirement authority: the enabled bit is
        // accepted only with the exact production reader receipt set, and the
        // caller must still re-verify every compact fact against the current
        // full-fidelity manifest before removing a chunk.
        guard !catalog.productionRawRetirementEnabled
                || catalog.consumerReadiness == .productionReadable else {
            throw QueryError.rawRetirementUnexpectedlyEnabled
        }
        guard catalog.fullFidelityHotDays == AtriaColdSessionRetentionPolicy.hotFullFidelityDays,
              catalog.fullFidelityDecodedColdDays == AtriaColdSessionRetentionPolicy.decodedColdFullFidelityDays,
              Self.isSHA256(catalog.source.sha256),
              Set(catalog.entries.map(\.civilUTCDate)).count == catalog.entries.count,
              catalog.entries == catalog.entries.sorted(by: { $0.civilUTCDate < $1.civilUTCDate }) else {
            throw QueryError.invalidCatalog
        }
        return catalog
    }

    func loadChunk(entry: AtriaColdSessionCatalog.Entry) throws -> AtriaColdSessionChunk {
        let url = chunksURL.appendingPathComponent(entry.filename)
        guard fileManager.fileExists(atPath: url.path) else { throw QueryError.chunkMissing(entry.filename) }
        let compressed = try Data(contentsOf: url)
        guard UInt64(compressed.count) == entry.compressedByteCount,
              Self.sha256(compressed) == entry.compressedSHA256 else {
            throw QueryError.chunkDigestMismatch(entry.filename)
        }
        let decoded: Data
        do {
            decoded = try AtriaBackupCompression.archivePayloadData(from: compressed,
                                                                    fileExtension: "gz")
        } catch {
            throw QueryError.chunkDecodeFailure(entry.filename)
        }
        guard UInt64(decoded.count) == entry.decodedByteCount,
              Self.sha256(decoded) == entry.decodedSHA256 else {
            throw QueryError.chunkDigestMismatch(entry.filename)
        }
        let chunk: AtriaColdSessionChunk
        do {
            chunk = try Self.decoder().decode(AtriaColdSessionChunk.self, from: decoded)
            try chunk.validate()
        } catch {
            throw QueryError.chunkDecodeFailure("\(entry.filename): \(String(reflecting: error))")
        }
        guard chunk.civilUTCDate == entry.civilUTCDate,
              chunk.facts.count == entry.sessionCount,
              chunk.facts.map(\.source.start).min() == entry.firstSessionStart,
              chunk.facts.map(\.source.end).max() == entry.lastSessionEnd else {
            throw QueryError.chunkSemanticMismatch(entry.filename)
        }
        return chunk
    }

    func verifyCatalog(_ catalog: AtriaColdSessionCatalog,
                       expectedFactsByID: [UUID: String]? = nil) throws {
        var seen: [UUID: String] = [:]
        for entry in catalog.entries {
            let chunk = try loadChunk(entry: entry)
            for fact in chunk.facts {
                guard seen.updateValue(fact.source.canonicalSHA256,
                                       forKey: fact.source.sessionID) == nil else {
                    throw QueryError.chunkSemanticMismatch(entry.filename)
                }
            }
        }
        guard seen.count == catalog.source.compactEligibleSessionCount else {
            throw QueryError.invalidCatalog
        }
        if let expectedFactsByID, seen != expectedFactsByID {
            throw QueryError.invalidCatalog
        }
    }

    func facts(overlapping interval: DateInterval) throws -> [AtriaColdSessionFact] {
        let catalog = try loadCatalog()
        return try catalog.entries
            .filter { $0.lastSessionEnd > interval.start && $0.firstSessionStart < interval.end }
            .flatMap { try loadChunk(entry: $0).facts }
            .filter { $0.source.end > interval.start && $0.source.start < interval.end }
            .sorted { $0.source.start < $1.source.start }
    }

    /// ID-targeted verified reader used by retirement. It never materializes
    /// unrelated lifetime facts and fails closed when any requested identity is
    /// absent or duplicated.
    func facts(sessionIDs requestedIDs: Set<UUID>) throws -> [UUID: AtriaColdSessionFact] {
        guard !requestedIDs.isEmpty else { return [:] }
        let catalog = try loadCatalog()
        var result: [UUID: AtriaColdSessionFact] = [:]
        for entry in catalog.entries where result.count < requestedIDs.count {
            for fact in try loadChunk(entry: entry).facts
                where requestedIDs.contains(fact.source.sessionID) {
                guard result.updateValue(fact, forKey: fact.source.sessionID) == nil else {
                    throw QueryError.chunkSemanticMismatch(entry.filename)
                }
            }
        }
        guard result.count == requestedIDs.count else { throw QueryError.invalidCatalog }
        return result
    }

    /// Bounded newest-first page for History. Chunk metadata is filtered before
    /// decompression and the decoded-byte budget is enforced across complete
    /// daily chunks, so a lifetime compact catalog is never loaded at once.
    func factsPage(before upperBound: Date,
                   maximumFactCount: Int,
                   maximumDecodedBytes: UInt64) throws -> [AtriaColdSessionFact] {
        guard maximumFactCount > 0, maximumDecodedBytes > 0 else { return [] }
        let catalog = try loadCatalog()
        var decodedBytes: UInt64 = 0
        var result: [AtriaColdSessionFact] = []
        for entry in catalog.entries.reversed()
            where entry.firstSessionStart < upperBound {
            let next = decodedBytes.addingReportingOverflow(entry.decodedByteCount)
            guard !next.overflow, next.partialValue <= maximumDecodedBytes else { continue }
            let chunk = try loadChunk(entry: entry)
            decodedBytes = next.partialValue
            result.append(contentsOf: chunk.facts.filter { $0.source.start < upperBound })
            result.sort {
                if $0.source.start != $1.source.start { return $0.source.start > $1.source.start }
                return $0.source.sessionID.uuidString < $1.source.sessionID.uuidString
            }
            if result.count >= maximumFactCount {
                return Array(result.prefix(maximumFactCount))
            }
        }
        return result
    }

    func heartRateTimeline(overlapping interval: DateInterval)
        -> AtriaColdSessionAvailability<[AtriaColdSessionFact.HeartRateMinute]> {
        do {
            let rows = try facts(overlapping: interval).flatMap { $0.heartRate.value?.minutes ?? [] }
                .filter { $0.minuteStart >= interval.start && $0.minuteStart < interval.end }
                .sorted { $0.minuteStart < $1.minuteStart }
            return rows.isEmpty
                ? .knownEmpty("verified compact chunks contain no heart-rate facts in this interval")
                : .available(rows)
        } catch QueryError.catalogMissing {
            return .missing("cold-session catalog has not been generated")
        } catch QueryError.unsupportedCatalogSchema {
            return .unsupported("cold-session catalog schema is newer than this reader")
        } catch {
            return .missing("cold-session catalog or chunk verification failed: \(error)")
        }
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func writeDurable(_ data: Data, temporaryURL: URL) throws {
        let flags = O_WRONLY | O_CREAT | O_EXCL
        let descriptor = open(temporaryURL.path, flags, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        do {
            try data.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.baseAddress else { return }
                var written = 0
                while written < rawBuffer.count {
                    let result = Darwin.write(descriptor,
                                              base.advanced(by: written),
                                              rawBuffer.count - written)
                    guard result > 0 else {
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    written += result
                }
            }
            guard fsync(descriptor) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard close(descriptor) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            _ = close(descriptor)
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    static func synchronizeDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { _ = close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy(
            CharacterSet(charactersIn: "0123456789abcdef").contains
        )
    }
}
