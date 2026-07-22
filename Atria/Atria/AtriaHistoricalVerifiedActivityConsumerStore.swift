import CryptoKit
import Darwin
import Foundation

/// Crash-safe shadow evidence for the first downstream typed-history consumer.
///
/// This store is deliberately not an Activity/Workout store. It records only
/// how one verified typed Activity artifact compares with the existing raw
/// session detector. No value here is read by UI, strain, recovery, or workout
/// persistence.
struct AtriaHistoricalVerifiedActivityConsumerApplicationStore {
    typealias ArtifactKind = AtriaHistoricalConsumerReceiptLedger.ProjectionKind
    typealias VerificationIdentity = AtriaHistoricalVerifiedConsumerReader.VerificationIdentity

    enum CandidateOrigin: String, Codable, Equatable, Sendable {
        case typedVerifiedArtifact
        case rawSessionDetector
    }

    enum ArtifactOutcome: String, Codable, Equatable, Sendable {
        case available
        case knownEmpty
    }

    struct Candidate: Codable, Equatable, Sendable {
        let identifier: String
        let start: Date
        let end: Date
        let fingerprintSHA256: String
        let origin: CandidateOrigin

        init(identifier: String,
             start: Date,
             end: Date,
             origin: CandidateOrigin) throws {
            guard !identifier.isEmpty,
                  start.timeIntervalSince1970.isFinite,
                  end.timeIntervalSince1970.isFinite,
                  end > start else { throw StoreError.invalidCandidate }
            let canonicalStart = Self.millisecondDate(start)
            let canonicalEnd = Self.millisecondDate(end)
            guard canonicalEnd > canonicalStart else { throw StoreError.invalidCandidate }
            self.identifier = identifier
            self.start = canonicalStart
            self.end = canonicalEnd
            self.origin = origin
            self.fingerprintSHA256 = try Self.fingerprint(identifier: identifier,
                                                          start: canonicalStart,
                                                          end: canonicalEnd,
                                                          origin: origin)
        }

        private struct FingerprintInput: Codable {
            let identifier: String
            let start: Date
            let end: Date
            let origin: CandidateOrigin
        }

        private static func fingerprint(identifier: String,
                                        start: Date,
                                        end: Date,
                                        origin: CandidateOrigin) throws -> String {
            try AtriaHistoricalVerifiedActivityConsumerApplicationStore.sha256(
                AtriaHistoricalVerifiedActivityConsumerApplicationStore.canonicalData(
                    FingerprintInput(identifier: identifier,
                                     start: start,
                                     end: end,
                                     origin: origin)
                )
            )
        }

        private static func millisecondDate(_ value: Date) -> Date {
            Date(timeIntervalSince1970:
                    (value.timeIntervalSince1970 * 1_000).rounded() / 1_000)
        }

        fileprivate func isValid() -> Bool {
            guard let expected = try? Self.fingerprint(identifier: identifier,
                                                       start: start,
                                                       end: end,
                                                       origin: origin) else { return false }
            return end > start && expected == fingerprintSHA256
        }
    }

    struct OverlapPair: Codable, Equatable, Sendable {
        let typedIdentifier: String
        let rawIdentifier: String
    }

    struct Parity: Codable, Equatable, Sendable {
        let exactIdentifiers: [String]
        let overlapOnly: [OverlapPair]
        let typedOnlyIdentifiers: [String]
        let rawOnlyIdentifiers: [String]

        var isExact: Bool {
            overlapOnly.isEmpty
                && typedOnlyIdentifiers.isEmpty
                && rawOnlyIdentifiers.isEmpty
        }
    }

    struct Input: Equatable, Sendable {
        let verificationIdentity: VerificationIdentity
        let artifactKind: ArtifactKind
        let outcome: ArtifactOutcome
        let typedCandidates: [Candidate]
        let rawCandidates: [Candidate]
        let appliedAt: Date

        init(verificationIdentity: VerificationIdentity,
             artifactKind: ArtifactKind = .activity,
             outcome: ArtifactOutcome,
             typedCandidates: [Candidate],
             rawCandidates: [Candidate],
             appliedAt: Date = Date()) {
            self.verificationIdentity = verificationIdentity
            self.artifactKind = artifactKind
            self.outcome = outcome
            self.typedCandidates = typedCandidates
            self.rawCandidates = rawCandidates
            self.appliedAt = appliedAt
        }
    }

    struct AppliedGeneration: Codable, Equatable, Sendable {
        static let currentSchema = 1

        let schema: Int
        let verificationIdentity: VerificationIdentity
        let verificationIdentitySHA256: String
        let artifactKind: ArtifactKind
        let outcome: ArtifactOutcome
        let typedCandidates: [Candidate]
        let rawCandidates: [Candidate]
        let parity: Parity
        /// Candidate IDs from earlier applied generations suppressed because a
        /// newer verified candidate covers the same interval with a new ID.
        let tombstonedCandidateIdentifiers: [String]
        let appliedAt: Date
    }

    enum Checkpoint: Equatable, Sendable {
        case generationTemporaryDurable
        case generationPublished
        case pointerTemporaryDurable
        case pointerPublished
    }

    enum StoreError: Error, Equatable {
        case invalidIdentity
        case invalidArtifactKind
        case invalidOutcome
        case invalidCandidate
        case duplicateCandidateIdentifier
        case staleCurrentGeneration
        case pointerInvalid
        case generationInvalid
        case generationConflict
    }

    private struct Pointer: Codable, Equatable {
        static let currentVersion = 1
        let version: Int
        let sourceChunkID: String
        let generationFilename: String
        let generationSHA256: String
        let verificationIdentitySHA256: String
    }

    private let directoryURL: URL
    private let fileManager: FileManager
    private let checkpoint: (Checkpoint) throws -> Void
    private static let mutationLock = NSLock()

    init(directoryURL: URL,
         fileManager: FileManager = .default,
         checkpoint: @escaping (Checkpoint) throws -> Void = { _ in }) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
        self.checkpoint = checkpoint
    }

    /// Compare-and-swap application. The caller must pass the identity it read;
    /// nil means it observed no current generation. Identical replay leaves the
    /// current generation unchanged.
    @discardableResult
    func apply(_ input: Input,
               expectedCurrentIdentitySHA256: String?) throws -> AppliedGeneration {
        Self.mutationLock.lock()
        defer { Self.mutationLock.unlock() }
        return try applyLocked(input,
                               expectedCurrentIdentitySHA256: expectedCurrentIdentitySHA256)
    }

    private func applyLocked(
        _ input: Input,
        expectedCurrentIdentitySHA256: String?
    ) throws -> AppliedGeneration {
        try fileManager.createDirectory(at: directoryURL,
                                        withIntermediateDirectories: true)
        let current = try loadCurrent(sourceChunkID: input.verificationIdentity.source.chunkID)
        guard current?.verificationIdentitySHA256 == expectedCurrentIdentitySHA256 else {
            throw StoreError.staleCurrentGeneration
        }

        let normalizedTyped = try normalized(input.typedCandidates,
                                             expectedOrigin: .typedVerifiedArtifact)
        let normalizedRaw = try normalized(input.rawCandidates,
                                           expectedOrigin: .rawSessionDetector)
        let identityDigest = try Self.sha256(Self.canonicalData(input.verificationIdentity))
        try validateIdentity(input.verificationIdentity,
                             digest: identityDigest,
                             artifactKind: input.artifactKind)
        guard input.artifactKind == .activity else { throw StoreError.invalidArtifactKind }
        guard (input.outcome == .knownEmpty) == normalizedTyped.isEmpty else {
            throw StoreError.invalidOutcome
        }

        let parity = Self.parity(typed: normalizedTyped, raw: normalizedRaw)
        let priorTombstones = Set(current?.tombstonedCandidateIdentifiers ?? [])
        let newlyTombstoned = Self.overlapTombstones(previous: current?.typedCandidates ?? [],
                                                     replacement: normalizedTyped)
        let tombstones = Array(priorTombstones.union(newlyTombstoned)).sorted()
        let generation = AppliedGeneration(
            schema: AppliedGeneration.currentSchema,
            verificationIdentity: input.verificationIdentity,
            verificationIdentitySHA256: identityDigest,
            artifactKind: input.artifactKind,
            outcome: input.outcome,
            typedCandidates: normalizedTyped,
            rawCandidates: normalizedRaw,
            parity: parity,
            tombstonedCandidateIdentifiers: tombstones,
            appliedAt: input.appliedAt
        )

        if let current, current.verificationIdentitySHA256 == identityDigest {
            var replay = generation
            replay = .init(schema: replay.schema,
                           verificationIdentity: replay.verificationIdentity,
                           verificationIdentitySHA256: replay.verificationIdentitySHA256,
                           artifactKind: replay.artifactKind,
                           outcome: replay.outcome,
                           typedCandidates: replay.typedCandidates,
                           rawCandidates: replay.rawCandidates,
                           parity: replay.parity,
                           tombstonedCandidateIdentifiers: replay.tombstonedCandidateIdentifiers,
                           appliedAt: current.appliedAt)
            guard replay == current else { throw StoreError.generationConflict }
            return current
        }

        let bytes = try Self.canonicalData(generation)
        let generationDigest = Self.sha256(bytes)
        let filename = "activity-consumer-generation-\(generationDigest).json"
        let destination = directoryURL.appendingPathComponent(filename)
        if fileManager.fileExists(atPath: destination.path) {
            guard try Self.sha256(Data(contentsOf: destination)) == generationDigest else {
                throw StoreError.generationConflict
            }
        } else {
            let temporary = temporaryURL(filename)
            try Self.writeDurably(bytes, to: temporary)
            try checkpoint(.generationTemporaryDurable)
            try fileManager.moveItem(at: temporary, to: destination)
            try Self.synchronizeDirectory(directoryURL)
            try checkpoint(.generationPublished)
        }

        let pointer = Pointer(version: Pointer.currentVersion,
                              sourceChunkID: input.verificationIdentity.source.chunkID,
                              generationFilename: filename,
                              generationSHA256: generationDigest,
                              verificationIdentitySHA256: identityDigest)
        let pointerURL = self.pointerURL(sourceChunkID: pointer.sourceChunkID)
        let temporaryPointer = temporaryURL(pointerURL.lastPathComponent)
        try Self.writeDurably(Self.canonicalData(pointer), to: temporaryPointer)
        try checkpoint(.pointerTemporaryDurable)
        if fileManager.fileExists(atPath: pointerURL.path) {
            _ = try fileManager.replaceItemAt(pointerURL, withItemAt: temporaryPointer)
        } else {
            try fileManager.moveItem(at: temporaryPointer, to: pointerURL)
        }
        try Self.synchronizeDirectory(directoryURL)
        try checkpoint(.pointerPublished)
        return try loadCurrent(sourceChunkID: pointer.sourceChunkID) ?? {
            throw StoreError.pointerInvalid
        }()
    }

    func loadCurrent(sourceChunkID: String) throws -> AppliedGeneration? {
        guard !sourceChunkID.isEmpty else { throw StoreError.pointerInvalid }
        let pointerURL = pointerURL(sourceChunkID: sourceChunkID)
        guard fileManager.fileExists(atPath: pointerURL.path) else { return nil }
        let pointerBytes = try Data(contentsOf: pointerURL)
        let pointer: Pointer
        do { pointer = try Self.decoder().decode(Pointer.self, from: pointerBytes) }
        catch { throw StoreError.pointerInvalid }
        guard pointer.version == Pointer.currentVersion,
              pointer.sourceChunkID == sourceChunkID,
              Self.safeFilename(pointer.generationFilename),
              Self.isSHA256(pointer.generationSHA256),
              Self.isSHA256(pointer.verificationIdentitySHA256),
              try Self.canonicalData(pointer) == pointerBytes else {
            throw StoreError.pointerInvalid
        }
        let generationURL = directoryURL.appendingPathComponent(pointer.generationFilename)
        guard fileManager.fileExists(atPath: generationURL.path) else {
            throw StoreError.generationInvalid
        }
        let bytes = try Data(contentsOf: generationURL)
        guard Self.sha256(bytes) == pointer.generationSHA256 else {
            throw StoreError.generationInvalid
        }
        let generation: AppliedGeneration
        do { generation = try Self.decoder().decode(AppliedGeneration.self, from: bytes) }
        catch { throw StoreError.generationInvalid }
        guard try Self.canonicalData(generation) == bytes,
              try validates(generation),
              generation.verificationIdentity.source.chunkID == sourceChunkID,
              generation.verificationIdentitySHA256 == pointer.verificationIdentitySHA256 else {
            throw StoreError.generationInvalid
        }
        return generation
    }

    private func validates(_ generation: AppliedGeneration) throws -> Bool {
        let typed = try normalized(generation.typedCandidates,
                                   expectedOrigin: .typedVerifiedArtifact)
        let raw = try normalized(generation.rawCandidates,
                                 expectedOrigin: .rawSessionDetector)
        let identityDigest = Self.sha256(try Self.canonicalData(generation.verificationIdentity))
        return generation.schema == AppliedGeneration.currentSchema
            && generation.artifactKind == .activity
            && generation.verificationIdentitySHA256 == identityDigest
            && (generation.outcome == .knownEmpty) == typed.isEmpty
            && typed == generation.typedCandidates
            && raw == generation.rawCandidates
            && generation.parity == Self.parity(typed: typed, raw: raw)
            && generation.tombstonedCandidateIdentifiers
                == Array(Set(generation.tombstonedCandidateIdentifiers)).sorted()
    }

    private func validateIdentity(_ identity: VerificationIdentity,
                                  digest: String,
                                  artifactKind: ArtifactKind) throws {
        guard !identity.generationIdentifier.isEmpty,
              identity.completionGeneration > 0,
              !identity.source.chunkID.isEmpty,
              Self.isSHA256(identity.source.rawSHA256),
              Self.isSHA256(identity.catalogSnapshotSHA256),
              Self.isSHA256(digest),
              identity.receipts.count == 5,
              identity.receipts == identity.receipts.sorted(by: {
                  $0.kind.rawValue < $1.kind.rawValue
              }),
              Set(identity.receipts.map(\.kind)).count == identity.receipts.count,
              identity.receipts.allSatisfy({ $0.source == identity.source }),
              identity.receipts.contains(where: { $0.kind == artifactKind }) else {
            throw StoreError.invalidIdentity
        }
    }

    private func normalized(_ candidates: [Candidate],
                            expectedOrigin: CandidateOrigin) throws -> [Candidate] {
        let sorted = candidates.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.end != $1.end { return $0.end < $1.end }
            return $0.identifier < $1.identifier
        }
        var byIdentifier: [String: Candidate] = [:]
        for candidate in sorted {
            guard candidate.origin == expectedOrigin, candidate.isValid() else {
                throw StoreError.invalidCandidate
            }
            if let existing = byIdentifier[candidate.identifier] {
                guard existing == candidate else { throw StoreError.duplicateCandidateIdentifier }
                continue
            }
            byIdentifier[candidate.identifier] = candidate
        }
        return byIdentifier.values.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.end != $1.end { return $0.end < $1.end }
            return $0.identifier < $1.identifier
        }
    }

    private static func parity(typed: [Candidate], raw: [Candidate]) -> Parity {
        let rawIDs = Set(raw.map(\.identifier))
        // Stable detector identity is authoritative inside one comparison
        // snapshot; fingerprints remain origin-specific audit evidence.
        let exact = typed.compactMap { rawIDs.contains($0.identifier) ? $0.identifier : nil }.sorted()
        let exactSet = Set(exact)
        var unmatchedRaw = raw.filter { !exactSet.contains($0.identifier) }
        var overlaps: [OverlapPair] = []
        var typedOnly: [String] = []
        for candidate in typed where !exactSet.contains(candidate.identifier) {
            if let index = unmatchedRaw.indices
                .filter({ intervalsOverlap(candidate, unmatchedRaw[$0]) })
                .max(by: {
                    overlapDuration(candidate, unmatchedRaw[$0])
                        < overlapDuration(candidate, unmatchedRaw[$1])
                }) {
                let match = unmatchedRaw.remove(at: index)
                overlaps.append(.init(typedIdentifier: candidate.identifier,
                                      rawIdentifier: match.identifier))
            } else {
                typedOnly.append(candidate.identifier)
            }
        }
        return .init(exactIdentifiers: exact,
                     overlapOnly: overlaps.sorted {
                         if $0.typedIdentifier != $1.typedIdentifier {
                             return $0.typedIdentifier < $1.typedIdentifier
                         }
                         return $0.rawIdentifier < $1.rawIdentifier
                     },
                     typedOnlyIdentifiers: typedOnly.sorted(),
                     rawOnlyIdentifiers: unmatchedRaw.map(\.identifier).sorted())
    }

    private static func overlapTombstones(previous: [Candidate],
                                          replacement: [Candidate]) -> Set<String> {
        let replacementIDs = Set(replacement.map(\.identifier))
        return Set(previous.compactMap { old in
            guard !replacementIDs.contains(old.identifier),
                  replacement.contains(where: { intervalsOverlap(old, $0) }) else { return nil }
            return old.identifier
        })
    }

    private static func intervalsOverlap(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        min(lhs.end, rhs.end) > max(lhs.start, rhs.start)
    }

    private static func overlapDuration(_ lhs: Candidate, _ rhs: Candidate) -> TimeInterval {
        max(0, min(lhs.end, rhs.end).timeIntervalSince(max(lhs.start, rhs.start)))
    }

    private func pointerURL(sourceChunkID: String) -> URL {
        let key = Self.sha256(Data(sourceChunkID.utf8))
        return directoryURL.appendingPathComponent("activity-consumer-current-\(key).json")
    }

    private func temporaryURL(_ filename: String) -> URL {
        directoryURL.appendingPathComponent(".\(filename).\(UUID().uuidString).tmp")
    }

    fileprivate static func canonicalData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    fileprivate static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit }
    }

    private static func safeFilename(_ value: String) -> Bool {
        !value.isEmpty && value == URL(fileURLWithPath: value).lastPathComponent
    }

    private static func writeDurably(_ data: Data, to url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    private static func synchronizeDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}

enum AtriaHistoricalVerifiedActivityShadowPlanner {
    enum RetainReason: String, Equatable, Sendable {
        case missingIdentity
        case missingArtifact
        case deferredArtifact
        case invalidIdentity
    }

    enum Decision: Equatable, Sendable {
        case apply(AtriaHistoricalVerifiedActivityConsumerApplicationStore.Input)
        case retainPrevious(RetainReason)
    }

    static func prepare(
        source: AtriaHistoricalVerifiedConsumerReader.SourceArtifacts,
        rawCandidates: [AtriaHistoricalVerifiedActivityConsumerApplicationStore.Candidate],
        appliedAt: Date = Date()
    ) -> Decision {
        guard let identity = source.verificationIdentity else {
            switch source.activity {
            case .missing: return .retainPrevious(.missingArtifact)
            case .deferred: return .retainPrevious(.deferredArtifact)
            case .available, .knownEmpty: return .retainPrevious(.missingIdentity)
            }
        }
        guard identity.source.chunkID == source.sourceChunkID,
              identity.receipts.contains(where: { $0.kind == .activity }) else {
            return .retainPrevious(.invalidIdentity)
        }
        switch source.activity {
        case .missing:
            return .retainPrevious(.missingArtifact)
        case .deferred:
            return .retainPrevious(.deferredArtifact)
        case .knownEmpty:
            return .apply(.init(verificationIdentity: identity,
                                outcome: .knownEmpty,
                                typedCandidates: [],
                                rawCandidates: rawCandidates,
                                appliedAt: appliedAt))
        case .available(let projection):
            do {
                let candidates = try projection.candidates.map {
                    try AtriaHistoricalVerifiedActivityConsumerApplicationStore.Candidate(
                        identifier: $0.identifier,
                        start: $0.start,
                        end: $0.end,
                        origin: .typedVerifiedArtifact
                    )
                }
                return .apply(.init(verificationIdentity: identity,
                                    outcome: .available,
                                    typedCandidates: candidates,
                                    rawCandidates: rawCandidates,
                                    appliedAt: appliedAt))
            } catch {
                return .retainPrevious(.invalidIdentity)
            }
        }
    }
}
