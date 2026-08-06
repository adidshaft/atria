import Darwin
import Foundation

/// Durable authority for one exact missing-data request and its current BLE
/// transport attempt. It is deliberately separate from the history reducer:
/// reducer generations are process-local, while this generation survives app
/// termination and monotonically invalidates stale callbacks.
final class AtriaBLEHistoryRequestAuthorityStore: @unchecked Sendable {
    struct ExactRequest: Codable, Equatable, Sendable {
        let sourceIdentifier: String
        let requestedStartUnix: TimeInterval
        let requestedEndUnix: TimeInterval

        var requestedStart: Date { Date(timeIntervalSince1970: requestedStartUnix) }
        var requestedEnd: Date { Date(timeIntervalSince1970: requestedEndUnix) }
    }

    struct Authority: Codable, Equatable, Sendable {
        enum Status: String, Codable, Equatable, Sendable {
            case armed
            case consumed
        }

        let generation: UInt64
        let requestIdentifier: String
        let peripheralIdentifier: String
        let strapIdentity: String
        let exactRequest: ExactRequest
        let createdAtUnix: TimeInterval
        var status: Status
        var attempt: UInt64
        var transportNonce: String?
        var transportGeneration: UInt64?
        var boundAtUnix: TimeInterval?
        var consumedAtUnix: TimeInterval?
    }

    struct Binding: Codable, Equatable, Sendable {
        let authorityGeneration: UInt64
        let requestIdentifier: String
        let peripheralIdentifier: String
        let strapIdentity: String
        let exactRequest: ExactRequest
        let attempt: UInt64
        let transportNonce: String
        let transportGeneration: UInt64
    }

    enum StoreError: Error, Equatable {
        case invalidExactRequest
        case invalidIdentity
        case stateCorrupt
        case generationExhausted
        case attemptExhausted
        case authorityMissing
        case authorityConsumed
        case staleAuthority
        case staleTransportAttempt
        case peripheralMismatch
        case strapMismatch
        case invalidCompletionTime
    }

    private struct State: Codable, Equatable {
        static let currentVersion = 1
        let version: Int
        var lastGeneration: UInt64
        var authority: Authority?
    }

    private let directoryURL: URL
    private let stateURL: URL
    private let fileManager: FileManager
    private let makeIdentifier: () -> String
    private let lock = NSLock()

    init(directoryURL: URL,
         fileManager: FileManager = .default,
         makeIdentifier: @escaping () -> String = { UUID().uuidString.lowercased() }) {
        self.directoryURL = directoryURL.standardizedFileURL
        self.stateURL = directoryURL.appendingPathComponent("ble-history-request-authority-v1.json")
        self.fileManager = fileManager
        self.makeIdentifier = makeIdentifier
    }

    /// Reuses only the same still-armed exact request. A consumed request or a
    /// changed interval receives a newer durable generation.
    func arm(exactRequest: ExactRequest,
             peripheralIdentifier: String,
             strapIdentity: String,
             now: Date) throws -> Authority {
        try Self.validate(exactRequest)
        guard !peripheralIdentifier.isEmpty, !strapIdentity.isEmpty else {
            throw StoreError.invalidIdentity
        }
        guard now.timeIntervalSince1970.isFinite,
              now.timeIntervalSince1970 >= exactRequest.requestedEndUnix else {
            throw StoreError.invalidExactRequest
        }
        lock.lock()
        defer { lock.unlock() }
        var state = try loadStateLocked()
        if let existing = state.authority,
           existing.status == .armed,
           existing.exactRequest == exactRequest,
           existing.peripheralIdentifier == peripheralIdentifier,
           existing.strapIdentity == strapIdentity {
            return existing
        }
        guard state.lastGeneration < UInt64.max else { throw StoreError.generationExhausted }
        let authority = Authority(
            generation: state.lastGeneration + 1,
            requestIdentifier: makeIdentifier(),
            peripheralIdentifier: peripheralIdentifier,
            strapIdentity: strapIdentity,
            exactRequest: exactRequest,
            createdAtUnix: now.timeIntervalSince1970,
            status: .armed,
            attempt: 0,
            transportNonce: nil,
            transportGeneration: nil,
            boundAtUnix: nil,
            consumedAtUnix: nil
        )
        guard !authority.requestIdentifier.isEmpty else { throw StoreError.invalidIdentity }
        state.lastGeneration = authority.generation
        state.authority = authority
        try persistLocked(state)
        return try loadStateLocked().authority ?? authority
    }

    /// Binds a process-local reducer generation to a fresh durable nonce. A
    /// reconnect/restart creates a newer attempt and invalidates old callbacks.
    func bind(authorityGeneration: UInt64,
              requestIdentifier: String,
              transportGeneration: UInt64,
              peripheralIdentifier: String,
              strapIdentity: String,
              now: Date) throws -> Binding {
        guard transportGeneration > 0 else { throw StoreError.staleTransportAttempt }
        guard now.timeIntervalSince1970.isFinite else { throw StoreError.staleTransportAttempt }
        lock.lock()
        defer { lock.unlock() }
        var state = try loadStateLocked()
        guard var authority = state.authority else { throw StoreError.authorityMissing }
        try Self.match(authority,
                       generation: authorityGeneration,
                       requestIdentifier: requestIdentifier,
                       peripheralIdentifier: peripheralIdentifier,
                       strapIdentity: strapIdentity)
        guard authority.status == .armed else { throw StoreError.authorityConsumed }
        guard authority.attempt < UInt64.max else { throw StoreError.attemptExhausted }
        authority.attempt += 1
        authority.transportNonce = makeIdentifier()
        authority.transportGeneration = transportGeneration
        authority.boundAtUnix = now.timeIntervalSince1970
        guard let nonce = authority.transportNonce, !nonce.isEmpty else {
            throw StoreError.invalidIdentity
        }
        state.authority = authority
        try persistLocked(state)
        return Self.binding(authority, nonce: nonce, transportGeneration: transportGeneration)
    }

    /// Validates the current attempt without consuming it. Materialization is
    /// retriable after a crash; only a verified successful commit calls
    /// `markConsumed`.
    func validateTerminal(binding: Binding,
                          peripheralIdentifier: String,
                          strapIdentity: String) throws -> Authority {
        lock.lock()
        defer { lock.unlock() }
        let state = try loadStateLocked()
        guard let authority = state.authority else { throw StoreError.authorityMissing }
        try Self.match(authority,
                       generation: binding.authorityGeneration,
                       requestIdentifier: binding.requestIdentifier,
                       peripheralIdentifier: peripheralIdentifier,
                       strapIdentity: strapIdentity)
        guard authority.status == .armed else { throw StoreError.authorityConsumed }
        guard authority.exactRequest == binding.exactRequest,
              authority.attempt == binding.attempt,
              authority.transportNonce == binding.transportNonce,
              authority.transportGeneration == binding.transportGeneration else {
            throw StoreError.staleTransportAttempt
        }
        return authority
    }

    /// One-shot terminal commit. Repeating the exact already-consumed binding
    /// is idempotent and returns false; all other stale attempts are rejected.
    @discardableResult
    func markConsumed(binding: Binding,
                      peripheralIdentifier: String,
                      strapIdentity: String,
                      completedAt: Date) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var state = try loadStateLocked()
        guard var authority = state.authority else { throw StoreError.authorityMissing }
        guard completedAt.timeIntervalSince1970.isFinite,
              completedAt.timeIntervalSince1970 >= authority.exactRequest.requestedEndUnix,
              completedAt.timeIntervalSince1970 >= (authority.boundAtUnix ?? 0) else {
            throw StoreError.invalidCompletionTime
        }
        try Self.match(authority,
                       generation: binding.authorityGeneration,
                       requestIdentifier: binding.requestIdentifier,
                       peripheralIdentifier: peripheralIdentifier,
                       strapIdentity: strapIdentity)
        guard authority.exactRequest == binding.exactRequest,
              authority.attempt == binding.attempt,
              authority.transportNonce == binding.transportNonce,
              authority.transportGeneration == binding.transportGeneration else {
            throw StoreError.staleTransportAttempt
        }
        if authority.status == .consumed { return false }
        authority.status = .consumed
        authority.consumedAtUnix = completedAt.timeIntervalSince1970
        state.authority = authority
        try persistLocked(state)
        return true
    }

    func loadAuthority() throws -> Authority? {
        lock.lock()
        defer { lock.unlock() }
        return try loadStateLocked().authority
    }

    /// Reconciles a crash after this store durably consumed the request but
    /// before the separate publication journal advanced to completed. This
    /// never arms or binds a new request.
    func validateConsumedAuthority(
        generation: UInt64,
        requestIdentifier: String,
        peripheralIdentifier: String,
        strapIdentity: String,
        exactRequest: ExactRequest
    ) throws -> Authority {
        lock.lock()
        defer { lock.unlock() }
        let state = try loadStateLocked()
        guard let authority = state.authority else { throw StoreError.authorityMissing }
        try Self.match(authority,
                       generation: generation,
                       requestIdentifier: requestIdentifier,
                       peripheralIdentifier: peripheralIdentifier,
                       strapIdentity: strapIdentity)
        guard authority.exactRequest == exactRequest,
              authority.status == .consumed else {
            throw StoreError.staleAuthority
        }
        return authority
    }

    private func loadStateLocked() throws -> State {
        guard fileManager.fileExists(atPath: stateURL.path) else {
            return State(version: State.currentVersion, lastGeneration: 0, authority: nil)
        }
        do {
            let data = try Data(contentsOf: stateURL)
            let state = try JSONDecoder().decode(State.self, from: data)
            guard state.version == State.currentVersion,
                  try Self.canonicalData(state) == data else {
                throw StoreError.stateCorrupt
            }
            if let authority = state.authority {
                try Self.validate(authority.exactRequest)
                guard authority.generation > 0,
                      authority.generation <= state.lastGeneration,
                      !authority.requestIdentifier.isEmpty,
                      !authority.peripheralIdentifier.isEmpty,
                      !authority.strapIdentity.isEmpty,
                      authority.createdAtUnix.isFinite,
                      (authority.attempt == 0)
                        == (authority.transportNonce == nil),
                      (authority.transportNonce == nil)
                        == (authority.transportGeneration == nil) else {
                    throw StoreError.stateCorrupt
                }
            }
            return state
        } catch let error as StoreError {
            throw error
        } catch {
            throw StoreError.stateCorrupt
        }
    }

    private func persistLocked(_ state: State) throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let data = try Self.canonicalData(state)
        let temporary = directoryURL.appendingPathComponent(
            ".\(stateURL.lastPathComponent).\(UUID().uuidString).tmp"
        )
        try data.write(to: temporary)
        let handle = try FileHandle(forWritingTo: temporary)
        try handle.synchronize()
        try handle.close()
        if fileManager.fileExists(atPath: stateURL.path) {
            _ = try fileManager.replaceItemAt(stateURL, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: stateURL)
        }
        try Self.synchronizeDirectory(directoryURL)
    }

    private static func validate(_ request: ExactRequest) throws {
        guard !request.sourceIdentifier.isEmpty,
              request.requestedStartUnix.isFinite,
              request.requestedEndUnix.isFinite,
              request.requestedStartUnix > 0,
              request.requestedEndUnix > request.requestedStartUnix else {
            throw StoreError.invalidExactRequest
        }
    }

    private static func match(_ authority: Authority,
                              generation: UInt64,
                              requestIdentifier: String,
                              peripheralIdentifier: String,
                              strapIdentity: String) throws {
        guard authority.generation == generation,
              authority.requestIdentifier == requestIdentifier else {
            throw StoreError.staleAuthority
        }
        guard authority.peripheralIdentifier == peripheralIdentifier else {
            throw StoreError.peripheralMismatch
        }
        guard authority.strapIdentity == strapIdentity else { throw StoreError.strapMismatch }
    }

    private static func binding(_ authority: Authority,
                                nonce: String,
                                transportGeneration: UInt64) -> Binding {
        .init(authorityGeneration: authority.generation,
              requestIdentifier: authority.requestIdentifier,
              peripheralIdentifier: authority.peripheralIdentifier,
              strapIdentity: authority.strapIdentity,
              exactRequest: authority.exactRequest,
              attempt: authority.attempt,
              transportNonce: nonce,
              transportGeneration: transportGeneration)
    }

    private static func canonicalData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func synchronizeDirectory(_ url: URL) throws {
        let descriptor = url.path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY) }
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw POSIXError(.EIO) }
    }
}
