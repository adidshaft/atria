import Combine
import Foundation

enum AtriaOnboardingHistoryBootstrapPolicy {
    /// The setup contract is deliberately narrower than "erase the strap".
    /// We have verified how to read and acknowledge a durable replay page, but
    /// not a command that physically erases WHOOP flash.  Treating a cursor
    /// acknowledgement as an erase would make a destructive claim we cannot
    /// prove (and could lose a user's only copy of a night).
    enum FreshStartPolicy {
        static let title = "Start a new Atria timeline"
        static let summary = "Atria reconciles any records the strap serves before starting live collection."
        static let disclosure = "Your new Atria timeline starts after setup. Records already on the strap are saved on this iPhone before their verified replay pages are acknowledged. Atria does not send a physical-erase command: the current verified strap protocol does not provide one."
        static let interruptionDisclosure = "If setup is interrupted, Atria resumes the same safe import. It never discards unseen strap data to force a fresh start."

        static func completionDetail(importedRows: Int) -> String {
            importedRows > 0
                ? "Existing strap records were saved. Your new Atria timeline has started."
                : "Strap history was verified. Your new Atria timeline has started."
        }
    }

    nonisolated static func canComplete(durableTransportAuthorityAndLiveRestored: Bool,
                                        recoveredDataPublished: Bool,
                                        requestedPeripheralIdentifier: String,
                                        currentPeripheralIdentifier: String?) -> Bool {
        durableTransportAuthorityAndLiveRestored
            && recoveredDataPublished
            && currentPeripheralIdentifier == requestedPeripheralIdentifier
    }
}

/// Crash-resumable owner for the first-run strap import.
///
/// The BLE history reducer remains the sole owner of transport, fsync and ACK
/// ordering. This coordinator only sequences its public completion fence with
/// SessionStore's recovered-data publication fence, and persists enough state
/// for onboarding to resume honestly after process death.
@MainActor
final class AtriaOnboardingHistoryBootstrap: ObservableObject {
    enum Phase: String, Codable, Equatable {
        case waitingForStrap
        case importing
        case publishing
        case complete
        case failed
    }

    struct Snapshot: Codable, Equatable {
        static let schema = 1

        var schema: Int = Self.schema
        var phase: Phase
        var peripheralIdentifier: String?
        var importedRows: Int
        var attempt: Int
        var updatedAt: Date
        var detail: String

        static func initial(now: Date = Date()) -> Snapshot {
            Snapshot(phase: .waitingForStrap,
                     peripheralIdentifier: nil,
                     importedRows: 0,
                     attempt: 0,
                     updatedAt: now,
                     detail: "Waiting for your strap")
        }
    }

    @Published private(set) var snapshot: Snapshot

    private let ble: AtriaBLEManager
    private let store: SessionStore
    private let persistenceURL: URL?
    private var bootstrapTask: Task<Void, Never>?
    private var pairingPreflightCancellable: AnyCancellable? = nil

    init(ble: AtriaBLEManager,
         store: SessionStore,
         persistenceURL: URL? = AtriaOnboardingHistoryBootstrap.defaultPersistenceURL) {
        self.ble = ble
        self.store = store
        self.persistenceURL = persistenceURL
        self.snapshot = Self.load(from: persistenceURL) ?? .initial()
        self.pairingPreflightCancellable = ble.$onboardingPairingPreflightInFlight
            .removeDuplicates()
            .dropFirst()
            .filter { !$0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.startOrResumeIfPossible()
            }
    }

    deinit {
        bootstrapTask?.cancel()
    }

    var isCompleteForCurrentStrap: Bool {
        guard snapshot.phase == .complete,
              let current = ble.currentPeripheralIdentifier else { return false }
        return snapshot.peripheralIdentifier == current
    }

    var isWorking: Bool {
        snapshot.phase == .importing || snapshot.phase == .publishing
    }

    /// Called from the narrow onboarding connection observer. Repeated calls
    /// are harmless; one retained task owns the complete import transaction.
    func startOrResumeIfPossible() {
        guard bootstrapTask == nil else { return }
        guard snapshot.phase != .failed else { return }
        guard let peripheralIdentifier = ble.currentPeripheralIdentifier else {
            if snapshot.phase != .complete && snapshot.phase != .failed {
                transition(to: .waitingForStrap,
                           peripheralIdentifier: snapshot.peripheralIdentifier,
                           detail: "Waiting for a fresh strap signal")
            }
            return
        }
        if snapshot.phase == .complete,
           snapshot.peripheralIdentifier == peripheralIdentifier {
            return
        }
        // Standard 2A37 HR does not prove access to WHOOP's protected command
        // channel. Always give the exact read-only 22/00 preflight its one
        // connection-scoped opportunity before the history owner starts.
        ble.requestOnboardingPairingPreflightIfNeeded()
        if ble.onboardingPairingPreflightInFlight {
            if snapshot.phase != .complete && snapshot.phase != .failed {
                transition(
                    to: .waitingForStrap,
                    peripheralIdentifier: peripheralIdentifier,
                    detail: "Verifying secure strap access — accept Pair if iPhone asks"
                )
            }
            return
        }
        guard ble.currentConnectionHasFreshHeartRate else {
            if snapshot.phase != .complete && snapshot.phase != .failed {
                transition(
                    to: .waitingForStrap,
                    peripheralIdentifier: peripheralIdentifier,
                    detail: "Connected — waiting for a fresh strap signal"
                )
            }
            return
        }
        if snapshot.peripheralIdentifier != nil,
           snapshot.peripheralIdentifier != peripheralIdentifier {
            snapshot = .initial()
            persist()
        }

        let nextAttempt = snapshot.attempt + 1
        guard transition(to: .importing,
                         peripheralIdentifier: peripheralIdentifier,
                         importedRows: 0,
                         attempt: nextAttempt,
                         detail: nextAttempt == 1
                            ? "Securely importing existing strap history"
                            : "Resuming the secure strap import") else {
            snapshot.phase = .failed
            snapshot.detail = "Atria could not save setup progress. Free storage space, then retry; no strap history was changed."
            return
        }

        bootstrapTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let rowsBefore = await Task.detached(priority: .utility) {
                HistoricalArchive.diagnostics().rows
            }.value

            // This public BLE fence returns true only after every exact retirement
            // ACK has followed its raw+identity fsync and either the genuine
            // HISTORY_COMPLETE terminal has durable authority or a matched 22/00
            // cursor proves the strap is empty. Both paths require fresh live HR;
            // generations with typed receipt work also wait for all five receipts.
            let durableTransportAuthorityAndLiveRestored = await self.ble
                .requestOfflineHistoricalSyncAwaitingCompletion(
                    reason: "onboarding_initial_import",
                    force: true
                )
            guard !Task.isCancelled else {
                self.bootstrapTask = nil
                return
            }
            guard durableTransportAuthorityAndLiveRestored else {
                self.fail(
                    peripheralIdentifier: peripheralIdentifier,
                    detail: "The strap import did not finish. Keep the strap nearby, put it in pairing mode, accept Pair if iPhone asks, then retry. Your saved data was not discarded."
                )
                return
            }

            guard self.transition(
                to: .publishing,
                peripheralIdentifier: peripheralIdentifier,
                importedRows: max(0, HistoricalArchive.diagnostics().rows - rowsBefore),
                detail: "History complete. Preparing sleep, activity, steps, and your baseline"
            ) else {
                self.fail(
                    peripheralIdentifier: peripheralIdentifier,
                    detail: "Your strap history is safely stored, but Atria could not save setup progress. Free storage space, then retry."
                )
                return
            }
            let publicationComplete = await self.store
                .requestAndAwaitRecoveredDataPublication(
                    reason: "onboarding_initial_import",
                    timeout: .seconds(180)
                )
            guard !Task.isCancelled else {
                self.bootstrapTask = nil
                return
            }
            guard AtriaOnboardingHistoryBootstrapPolicy.canComplete(
                durableTransportAuthorityAndLiveRestored:
                    durableTransportAuthorityAndLiveRestored,
                recoveredDataPublished: publicationComplete,
                requestedPeripheralIdentifier: peripheralIdentifier,
                currentPeripheralIdentifier: self.ble.currentPeripheralIdentifier
            ) else {
                self.fail(
                    peripheralIdentifier: peripheralIdentifier,
                    detail: publicationComplete
                        ? "The strap changed before setup finished. Reconnect the strap you want to use and retry."
                        : "Your strap history is safely stored, but Atria could not finish preparing it. Retry to resume; the strap data will not be imported twice."
                )
                return
            }

            let rowsAfter = await Task.detached(priority: .utility) {
                HistoricalArchive.diagnostics().rows
            }.value
            guard self.transition(
                to: .complete,
                peripheralIdentifier: peripheralIdentifier,
                importedRows: max(0, rowsAfter - rowsBefore),
                detail: FreshStartPolicy.completionDetail(
                    importedRows: max(0, rowsAfter - rowsBefore)
                )
            ) else {
                self.snapshot.phase = .failed
                self.snapshot.detail = "Setup finished safely, but its completion record could not be saved. Free storage space, then retry."
                self.bootstrapTask = nil
                return
            }
            self.bootstrapTask = nil
            AtriaDebugLog("ATRIADBG onboarding_history status=complete peripheral=%@ imported_rows=%d attempt=%d",
                          peripheralIdentifier,
                          self.snapshot.importedRows,
                          self.snapshot.attempt)
        }
    }

    func retry() {
        bootstrapTask?.cancel()
        bootstrapTask = nil
        transition(to: .waitingForStrap,
                   peripheralIdentifier: snapshot.peripheralIdentifier,
                   importedRows: snapshot.importedRows,
                   detail: "Waiting for a fresh strap signal")
        if ble.status != .connected {
            ble.startScan(reason: "onboarding_primary_connect")
        }
        startOrResumeIfPossible()
    }

    private func fail(peripheralIdentifier: String, detail: String) {
        transition(to: .failed,
                   peripheralIdentifier: peripheralIdentifier,
                   importedRows: snapshot.importedRows,
                   detail: detail)
        bootstrapTask = nil
        AtriaDebugLog("ATRIADBG onboarding_history status=failed peripheral=%@ attempt=%d detail=%@",
                      peripheralIdentifier,
                      snapshot.attempt,
                      detail)
    }

    @discardableResult
    private func transition(to phase: Phase,
                            peripheralIdentifier: String?,
                            importedRows: Int? = nil,
                            attempt: Int? = nil,
                            detail: String) -> Bool {
        snapshot.phase = phase
        snapshot.peripheralIdentifier = peripheralIdentifier
        if let importedRows { snapshot.importedRows = max(0, importedRows) }
        if let attempt { snapshot.attempt = max(0, attempt) }
        snapshot.updatedAt = Date()
        snapshot.detail = detail
        return persist()
    }

    @discardableResult
    private func persist() -> Bool {
        guard let persistenceURL else { return true }
        do {
            try FileManager.default.createDirectory(
                at: persistenceURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970
            encoder.outputFormatting = [.sortedKeys]
            let encoded = try encoder.encode(snapshot)
            try encoded.write(
                to: persistenceURL,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
            let handle = try FileHandle(forWritingTo: persistenceURL)
            defer { try? handle.close() }
            try handle.synchronize()
            return true
        } catch {
            AtriaDebugLog("ATRIADBG onboarding_history status=persist_failed phase=%@ error=%@",
                          snapshot.phase.rawValue,
                          String(describing: error))
            return false
        }
    }

    nonisolated static var defaultPersistenceURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory,
                                 in: .userDomainMask).first?
            .appendingPathComponent("Onboarding", isDirectory: true)
            .appendingPathComponent("strap-history-bootstrap-v1.json")
    }

    nonisolated static func load(from url: URL?) -> Snapshot? {
        guard let url,
              let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        guard let decoded = try? decoder.decode(Snapshot.self, from: data),
              decoded.schema == Snapshot.schema,
              decoded.importedRows >= 0,
              decoded.attempt >= 0 else { return nil }
        return decoded
    }
}
