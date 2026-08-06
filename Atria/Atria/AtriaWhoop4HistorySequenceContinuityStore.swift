import Foundation

/// Small, bounded durable record of replay-confirmed WHOOP flash holes. A
/// corrupt or non-canonical record is deleted and treated as no evidence, so it
/// can only make recovery more conservative.
final class AtriaWhoop4HistorySequenceContinuityStore: @unchecked Sendable {
    private struct Envelope: Codable, Equatable {
        static let currentSchemaVersion = 1
        let schemaVersion: Int
        let strapIdentifier: String
        let continuity: AtriaWhoop4HistoryDrainState.ContinuitySnapshot
    }

    private let directoryURL: URL
    private let stateURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    init(directoryURL: URL, fileManager: FileManager = .default) {
        self.directoryURL = directoryURL.standardizedFileURL
        self.stateURL = directoryURL.appendingPathComponent("sequence-continuity-v1.json")
        self.fileManager = fileManager
    }

    convenience init(fileManager: FileManager = .default) {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.init(directoryURL: documents.appendingPathComponent("atria-historical/history-drain-state-v1"),
                  fileManager: fileManager)
    }

    func load(strapIdentifier: String) -> AtriaWhoop4HistoryDrainState.ContinuitySnapshot? {
        guard Self.validatedStrapIdentifier(strapIdentifier) != nil else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard fileManager.fileExists(atPath: stateURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: stateURL, options: .mappedIfSafe)
            guard data.count <= 600_000 else { throw CocoaError(.fileReadCorruptFile) }
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            guard envelope.schemaVersion == Envelope.currentSchemaVersion,
                  envelope.strapIdentifier == Self.validatedStrapIdentifier(envelope.strapIdentifier),
                  envelope.strapIdentifier == strapIdentifier else { return nil }
            var validator = AtriaWhoop4HistoryDrainState()
            guard validator.restoreContinuitySnapshot(envelope.continuity),
                  try Self.encode(envelope) == data else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return envelope.continuity
        } catch {
            try? fileManager.removeItem(at: stateURL)
            return nil
        }
    }

    func save(_ snapshot: AtriaWhoop4HistoryDrainState.ContinuitySnapshot,
              strapIdentifier: String) throws {
        guard let canonicalStrapIdentifier = Self.validatedStrapIdentifier(strapIdentifier),
              canonicalStrapIdentifier == strapIdentifier else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        var validator = AtriaWhoop4HistoryDrainState()
        guard validator.restoreContinuitySnapshot(snapshot) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        lock.lock()
        defer { lock.unlock() }
        try fileManager.createDirectory(at: directoryURL,
                                        withIntermediateDirectories: true,
                                        attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        let envelope = Envelope(schemaVersion: Envelope.currentSchemaVersion,
                                strapIdentifier: canonicalStrapIdentifier,
                                continuity: snapshot)
        let data = try Self.encode(envelope)
        let temporary = directoryURL.appendingPathComponent(".sequence-continuity.\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporary, options: .atomic)
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: temporary.path
            )
            let handle = try FileHandle(forWritingTo: temporary)
            try handle.synchronize()
            try handle.close()
            if fileManager.fileExists(atPath: stateURL.path) {
                _ = try fileManager.replaceItemAt(stateURL, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: stateURL)
            }
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    func clear() throws {
        lock.lock()
        defer { lock.unlock() }
        guard fileManager.fileExists(atPath: stateURL.path) else { return }
        try fileManager.removeItem(at: stateURL)
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private static func validatedStrapIdentifier(_ value: String) -> String? {
        guard let uuid = UUID(uuidString: value) else { return nil }
        return uuid.uuidString
    }
}
