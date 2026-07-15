import Foundation

/// Crash authority for a restore that spans files and UserDefaults. The marker
/// contains both complete images before any destination is touched. A process
/// death while `phase == .forward` deterministically finishes the restore on
/// the next launch; an ordinary write failure first durably flips the marker to
/// `.rollback`, then restores every previous value. A failed rollback keeps the
/// marker for another launch rather than pretending the store is coherent.
struct AtriaRestoreTransaction: Codable, Equatable {
    static let schema = 1

    enum Phase: String, Codable {
        case forward
        case rollback
    }

    enum DefaultsValue: Codable, Equatable {
        case data(Data)
        case integer(Int)
        case boolean(Bool)
    }

    enum Destination: Codable, Equatable {
        case file(path: String, previous: Data?, next: Data?)
        case defaults(key: String, previous: DefaultsValue?, next: DefaultsValue?)
    }

    let schemaVersion: Int
    let id: UUID
    let createdAt: Date
    var phase: Phase
    let destinations: [Destination]

    init(id: UUID = UUID(),
         createdAt: Date = Date(),
         phase: Phase = .forward,
         destinations: [Destination]) {
        schemaVersion = Self.schema
        self.id = id
        self.createdAt = createdAt
        self.phase = phase
        self.destinations = destinations
    }
}

enum AtriaRestoreTransactionError: Error, Equatable {
    case invalidMarker
    case destinationWriteFailed(Int)
    case destinationReadbackFailed(Int)
    case rollbackFailed(Int)
    case simulatedCrash(Int)
}

enum AtriaRestoreTransactionCoordinator {
    struct FailureInjection: Equatable {
        var failForwardAfterDestination: Int?
        var crashForwardAfterDestination: Int?
        var failRollbackAtDestination: Int?

        static let none = FailureInjection()
    }

    enum RecoveryResult: Equatable {
        case noMarker
        case completedForward
        case completedRollback
        case retainedMarker
    }

    static let markerFileName = "atria-restore-transaction-v1.json"

    static func markerURL(nextTo sessionFileURL: URL) -> URL {
        sessionFileURL.deletingLastPathComponent().appendingPathComponent(markerFileName)
    }

    static func fileImage(at url: URL, fileManager: FileManager = .default) throws -> Data? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url, options: [.mappedIfSafe])
    }

    static func defaultsDataImage(key: String, defaults: UserDefaults = .standard)
        -> AtriaRestoreTransaction.DefaultsValue? {
        defaults.data(forKey: key).map(AtriaRestoreTransaction.DefaultsValue.data)
    }

    static func defaultsIntegerImage(key: String, defaults: UserDefaults = .standard)
        -> AtriaRestoreTransaction.DefaultsValue? {
        guard defaults.object(forKey: key) != nil else { return nil }
        return .integer(defaults.integer(forKey: key))
    }

    static func defaultsBooleanImage(key: String, defaults: UserDefaults = .standard)
        -> AtriaRestoreTransaction.DefaultsValue? {
        guard defaults.object(forKey: key) != nil else { return nil }
        return .boolean(defaults.bool(forKey: key))
    }

    static func commit(_ transaction: AtriaRestoreTransaction,
                       markerURL: URL,
                       defaults: UserDefaults = .standard,
                       fileManager: FileManager = .default,
                       injection: FailureInjection = .none) throws {
        var authority = transaction
        authority.phase = .forward
        try persistMarker(authority, at: markerURL, fileManager: fileManager)

        do {
            try apply(authority.destinations,
                      direction: .forward,
                      defaults: defaults,
                      fileManager: fileManager,
                      injection: injection)
            try fileManager.removeItem(at: markerURL)
        } catch let error as AtriaRestoreTransactionError {
            if case .simulatedCrash = error {
                // Model process death: no catch/rollback work can run. The
                // durable forward marker is deliberately left in place.
                throw error
            }
            authority.phase = .rollback
            try persistMarker(authority, at: markerURL, fileManager: fileManager)
            do {
                try apply(authority.destinations,
                          direction: .rollback,
                          defaults: defaults,
                          fileManager: fileManager,
                          injection: injection)
                try fileManager.removeItem(at: markerURL)
            } catch let rollbackError as AtriaRestoreTransactionError {
                // Never erase the only durable recovery authority.
                throw rollbackError
            }
            throw error
        }
    }

    @discardableResult
    static func recoverIfNeeded(markerURL: URL,
                                defaults: UserDefaults = .standard,
                                fileManager: FileManager = .default,
                                injection: FailureInjection = .none) -> RecoveryResult {
        guard fileManager.fileExists(atPath: markerURL.path) else { return .noMarker }
        do {
            let data = try Data(contentsOf: markerURL)
            let authority = try JSONDecoder().decode(AtriaRestoreTransaction.self, from: data)
            guard authority.schemaVersion == AtriaRestoreTransaction.schema,
                  !authority.destinations.isEmpty else {
                throw AtriaRestoreTransactionError.invalidMarker
            }
            try apply(authority.destinations,
                      direction: authority.phase,
                      defaults: defaults,
                      fileManager: fileManager,
                      injection: injection)
            try fileManager.removeItem(at: markerURL)
            return authority.phase == .forward ? .completedForward : .completedRollback
        } catch {
            return .retainedMarker
        }
    }

    private static func persistMarker(_ transaction: AtriaRestoreTransaction,
                                      at markerURL: URL,
                                      fileManager: FileManager) throws {
        try fileManager.createDirectory(at: markerURL.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(transaction)
        try data.write(to: markerURL,
                       options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        guard let readback = try? Data(contentsOf: markerURL),
              readback == data,
              let decoded = try? JSONDecoder().decode(AtriaRestoreTransaction.self, from: readback),
              decoded == transaction else {
            throw AtriaRestoreTransactionError.invalidMarker
        }
    }

    private static func apply(_ destinations: [AtriaRestoreTransaction.Destination],
                              direction: AtriaRestoreTransaction.Phase,
                              defaults: UserDefaults,
                              fileManager: FileManager,
                              injection: FailureInjection) throws {
        for (index, destination) in destinations.enumerated() {
            if direction == .rollback, injection.failRollbackAtDestination == index {
                throw AtriaRestoreTransactionError.rollbackFailed(index)
            }
            do {
                try apply(destination,
                          direction: direction,
                          defaults: defaults,
                          fileManager: fileManager)
            } catch {
                throw direction == .rollback
                    ? AtriaRestoreTransactionError.rollbackFailed(index)
                    : AtriaRestoreTransactionError.destinationWriteFailed(index)
            }

            if direction == .forward {
                if injection.crashForwardAfterDestination == index {
                    throw AtriaRestoreTransactionError.simulatedCrash(index)
                }
                if injection.failForwardAfterDestination == index {
                    throw AtriaRestoreTransactionError.destinationWriteFailed(index)
                }
            }
        }
    }

    private static func apply(_ destination: AtriaRestoreTransaction.Destination,
                              direction: AtriaRestoreTransaction.Phase,
                              defaults: UserDefaults,
                              fileManager: FileManager) throws {
        switch destination {
        case .file(let path, let previous, let next):
            let url = URL(fileURLWithPath: path)
            let value = direction == .forward ? next : previous
            if let value {
                try fileManager.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
                try value.write(to: url,
                                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                guard (try? Data(contentsOf: url)) == value else {
                    throw AtriaRestoreTransactionError.destinationReadbackFailed(0)
                }
            } else if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
                guard !fileManager.fileExists(atPath: url.path) else {
                    throw AtriaRestoreTransactionError.destinationReadbackFailed(0)
                }
            }

        case .defaults(let key, let previous, let next):
            let value = direction == .forward ? next : previous
            if let value {
                switch value {
                case .data(let data): defaults.set(data, forKey: key)
                case .integer(let integer): defaults.set(integer, forKey: key)
                case .boolean(let boolean): defaults.set(boolean, forKey: key)
                }
            } else {
                defaults.removeObject(forKey: key)
            }
            guard defaultsValue(key: key, defaults: defaults) == value else {
                throw AtriaRestoreTransactionError.destinationReadbackFailed(0)
            }
        }
    }

    private static func defaultsValue(key: String,
                                      defaults: UserDefaults) -> AtriaRestoreTransaction.DefaultsValue? {
        guard let object = defaults.object(forKey: key) else { return nil }
        if let data = object as? Data { return .data(data) }
        if let number = object as? NSNumber {
            // CFBoolean is an NSNumber subclass; preserve the destination's
            // semantic type so exact readback does not accept 1 for true.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .boolean(number.boolValue)
            }
            return .integer(number.intValue)
        }
        return nil
    }
}
