import Foundation

// Handoff-8 CP3: persistence + planning for the experimental relative skin
// signal. The pure computation lives in `AtriaRelativeSkinSignal`; this file
// adds the compact versioned per-night summary store and the pure producer
// plan the recovered-data pipeline executes off-main. Nothing here reads the
// forbidden absolute-decoder Celsius deviation path — that remains a separate,
// unvalidated authority — and nothing here creates a second raw archive; only
// qualified night summaries with their completeness receipts are persisted.

/// One confirmed-sleep window as the planner sees it. Deliberately slim so the
/// planner stays pure and unit-testable without `UserConfirmedSleep`.
struct AtriaRelativeSkinSleepWindow: Equatable, Sendable {
    let id: String
    let start: Date
    let end: Date
    let isNap: Bool
    /// Changes whenever the user edits, reclassifies, or re-times this sleep.
    /// A stored night whose token no longer matches is invalid and rebuilt
    /// from scratch (or dropped when it can no longer be proven).
    let revisionToken: String

    static func revisionToken(start: Date, end: Date, source: String) -> String {
        "\(Int(start.timeIntervalSince1970))|\(Int(end.timeIntervalSince1970))|\(source)"
    }
}

extension AtriaRelativeSkinSleepWindow {
    /// Matches the nap convention used elsewhere in SessionStore: nap-typed
    /// confirmed sleeps carry "nap" in their source string.
    init(confirmedSleep sleep: UserConfirmedSleep) {
        self.init(
            id: sleep.id,
            start: sleep.start,
            end: sleep.end,
            isNap: sleep.source.lowercased().contains("nap"),
            revisionToken: Self.revisionToken(
                start: sleep.start, end: sleep.end, source: sleep.source
            )
        )
    }
}

/// A persisted qualified night: the pure summary plus the exact proof that
/// authorized persisting it. `receiptDrainedThroughUnix >= sleepEnd` under a
/// complete snapshot channel is what "the raw channel is not truncated inside
/// this window" means on this transport — history drains oldest-first, so a
/// frontier past the window end proves the window's rows were all offloaded.
struct AtriaRelativeSkinStoredNight: Codable, Equatable, Sendable {
    let summary: AtriaRelativeSkinNightSummary
    let sleepRevisionToken: String
    let receiptSnapshotComplete: Bool
    let receiptDrainedThroughUnix: Double
}

/// Compact atomic file store for qualified night summaries. Keyed by
/// confirmed sleep ID + authority + algorithm version (all carried inside the
/// stored summary). One JSON file, atomic replace, fail-closed load.
final class AtriaRelativeSkinNightStore {
    static let storeVersion = 1

    private struct Envelope: Codable {
        let version: Int
        let nights: [AtriaRelativeSkinStoredNight]
    }

    private let fileURL: URL
    private let lock = NSLock()

    init(directoryURL: URL) {
        fileURL = directoryURL.appendingPathComponent(
            "night-summaries-v\(Self.storeVersion).json"
        )
    }

    static var production: AtriaRelativeSkinNightStore {
        let documents = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        )[0]
        return .init(directoryURL: documents.appendingPathComponent(
            "atria-relative-skin-v1", isDirectory: true
        ))
    }

    /// Missing, unreadable, or wrong-version stores load as empty — the
    /// producer then re-proves nights it still can and never guesses.
    func load() -> [AtriaRelativeSkinStoredNight] {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.version == Self.storeVersion else {
            return []
        }
        return envelope.nights
    }

    @discardableResult
    func replaceAll(_ nights: [AtriaRelativeSkinStoredNight]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let envelope = Envelope(version: Self.storeVersion, nights: nights)
        guard let data = try? JSONEncoder().encode(envelope) else { return false }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}

/// Pure planner: given the live confirmed sleeps, the recovered raw skin rows,
/// the previously persisted nights, and the completeness environment, decide
/// which compact night summaries may be persisted and what the UI result is.
/// No I/O — the caller persists `nightsToPersist` and installs `uiSummary`.
enum AtriaRelativeSkinProducer {
    /// Exact validated frame contract the v24 raw-skin decoder gates on
    /// (`whoop4SkinTemperatureRaw`): type 0x2f generation-24 frames, little-
    /// endian raw at offset 68, minimum proven payload of offset + 2 bytes.
    static var frameAuthority: (layoutVersion: String, payloadLength: Int, rawOffset: Int) {
        (HistoricalArchive.layoutVersion,
         AtriaResearchProbe.whoop4SkinTemperatureRawOffset + 2,
         AtriaResearchProbe.whoop4SkinTemperatureRawOffset)
    }

    struct Environment: Equatable, Sendable {
        /// The recovered snapshot's skin channel decoded without hitting a
        /// projection budget (`RecoveredDataCompleteness == .complete`).
        let snapshotChannelComplete: Bool
        /// `atria.offlineSync.drainedThroughUnix.v1` at plan time.
        let drainedThroughUnix: Double
        let now: Date
        var calendar: Calendar = .current
    }

    struct Plan: Equatable, Sendable {
        /// The complete replacement store contents (survivors + new nights).
        let nightsToPersist: [AtriaRelativeSkinStoredNight]
        let uiSummary: AtriaRelativeSkinSignalSummary
    }

    static func plan(
        sleeps: [AtriaRelativeSkinSleepWindow],
        rows: [HistoricalArchive.SkinTemperatureRawPoint],
        stored: [AtriaRelativeSkinStoredNight],
        environment: Environment
    ) -> Plan {
        let mains = sleeps.filter { !$0.isNap && $0.end > $0.start }
            .sorted { $0.end < $1.end }
        let liveByID = Dictionary(uniqueKeysWithValues: mains.map { ($0.id, $0) })

        // Edit/delete/reclassification invalidation: a stored night survives
        // only when its confirmed sleep still exists as a MAIN sleep with the
        // same revision token, under the current algorithm version. A stale
        // worker rebuilt from these survivors cannot restore a dropped night.
        var survivors: [String: AtriaRelativeSkinStoredNight] = [:]
        for night in stored {
            guard let live = liveByID[night.summary.confirmedSleepID],
                  live.revisionToken == night.sleepRevisionToken,
                  night.summary.authority.algorithmVersion
                      == AtriaRelativeSkinSignal.algorithmVersion,
                  night.receiptSnapshotComplete,
                  night.receiptDrainedThroughUnix
                      >= night.summary.sleepEnd.timeIntervalSince1970 else {
                continue
            }
            survivors[night.summary.confirmedSleepID] = night
        }

        guard let currentMain = mains.last else {
            return Plan(
                nightsToPersist: Array(survivors.values)
                    .sorted { $0.summary.sleepEnd < $1.summary.sleepEnd },
                uiSummary: AtriaRelativeSkinSignal.resolve(
                    currentNight: nil,
                    priorNights: [],
                    blockerIfNoCurrent: .noCurrentConfirmedMainSleep
                )
            )
        }

        var currentBlocker: AtriaRelativeSkinSignalBlocker = .noCurrentRawEvidence
        for sleep in mains where survivors[sleep.id] == nil {
            switch buildNight(sleep: sleep, rows: rows, environment: environment) {
            case .success(let night):
                survivors[sleep.id] = night
            case .failure(let blocker):
                if sleep.id == currentMain.id { currentBlocker = blocker }
            }
        }

        let persisted = Array(survivors.values)
            .sorted { $0.summary.sleepEnd < $1.summary.sleepEnd }
        let currentNight = survivors[currentMain.id]?.summary
        let priors = persisted
            .map(\.summary)
            .filter { $0.confirmedSleepID != currentMain.id }
        return Plan(
            nightsToPersist: persisted,
            uiSummary: AtriaRelativeSkinSignal.resolve(
                currentNight: currentNight,
                priorNights: priors,
                blockerIfNoCurrent: currentBlocker
            )
        )
    }

    /// One night's proof chain: completeness receipt → in-window rows → one
    /// exact sensor authority → pure `nightSummary` qualification.
    private static func buildNight(
        sleep: AtriaRelativeSkinSleepWindow,
        rows: [HistoricalArchive.SkinTemperatureRawPoint],
        environment: Environment
    ) -> Result<AtriaRelativeSkinStoredNight, AtriaRelativeSkinSignalBlocker> {
        guard environment.snapshotChannelComplete,
              environment.drainedThroughUnix >= sleep.end.timeIntervalSince1970 else {
            return .failure(.incompleteArchive)
        }
        let inWindow = rows.filter { $0.t >= sleep.start && $0.t <= sleep.end }
        guard !inWindow.isEmpty else { return .failure(.noCurrentRawEvidence) }

        var strapKeys = Set<String>()
        var sawUnknown = false
        for row in inWindow {
            let normalized = row.strapIdentifier?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() ?? ""
            if normalized.isEmpty { sawUnknown = true } else { strapKeys.insert(normalized) }
        }
        guard !sawUnknown, let strapKey = strapKeys.first else {
            return .failure(.unknownSensorAuthority)
        }
        guard strapKeys.count == 1 else { return .failure(.mixedSensorAuthority) }

        let frame = frameAuthority
        let authority = AtriaRelativeSkinSignalAuthority(
            pseudonymousStrapKey: strapKey,
            layoutVersion: frame.layoutVersion,
            payloadLength: frame.payloadLength,
            rawOffset: frame.rawOffset,
            algorithmVersion: AtriaRelativeSkinSignal.algorithmVersion
        )
        let samples = inWindow.map {
            AtriaRelativeSkinSignal.RawSkinSample(
                t: $0.t, raw: $0.raw, strapIdentifier: $0.strapIdentifier
            )
        }
        // motionQualified stays false on this transport: no validated motion
        // minute exclusion exists, so a night never claims stillness.
        let result = AtriaRelativeSkinSignal.nightSummary(
            samples: samples,
            sleepStart: sleep.start,
            sleepEnd: sleep.end,
            confirmedSleepID: sleep.id,
            cycleDay: environment.calendar.startOfDay(for: sleep.end),
            authority: authority,
            motionQualified: false,
            calculatedAt: environment.now,
            calendar: environment.calendar
        )
        switch result {
        case .success(let summary):
            return .success(.init(
                summary: summary,
                sleepRevisionToken: sleep.revisionToken,
                receiptSnapshotComplete: environment.snapshotChannelComplete,
                receiptDrainedThroughUnix: environment.drainedThroughUnix
            ))
        case .failure(let blocker):
            return .failure(blocker)
        }
    }
}

/// Pure copy policy for the experimental Vitals row. Only two states render:
/// baseline-building progress and a fully qualified raw-unit delta. Every
/// other blocker renders nothing — the validated temperature row already
/// carries the "Decoder not verified" truth, and no numeric raw delta may
/// appear while any blocker stands. Directional wording (higher/lower/within)
/// is reserved for motion-qualified nights; HR-only nights show the signed
/// raw delta without claiming the movement is meaningful.
enum AtriaRelativeSkinSignalPresentation {
    struct Content: Equatable, Sendable {
        let headline: String
        let detail: String
    }

    static func content(
        for summary: AtriaRelativeSkinSignalSummary
    ) -> Content? {
        if summary.blocker == .buildingBaseline {
            let count = max(0, min(summary.baselineNightCount,
                                   AtriaRelativeSkinSignal.minimumPriorNights))
            return .init(
                headline: "Building personal baseline · \(count) of "
                    + "\(AtriaRelativeSkinSignal.minimumPriorNights) nights",
                detail: "Experimental · uncalibrated"
            )
        }
        guard summary.blocker == nil,
              let rawDelta = summary.rawDelta else { return nil }
        let deltaText = String(format: "%+.0f raw sensor units", rawDelta)
        if summary.motionQualified, let index = summary.normalizedIndex {
            let direction: String
            if index > 1 {
                direction = "Higher than your usual raw baseline"
            } else if index < -1 {
                direction = "Lower than your usual raw baseline"
            } else {
                direction = "Within your usual raw baseline"
            }
            return .init(
                headline: direction,
                detail: "\(deltaText) · Experimental · uncalibrated"
            )
        }
        return .init(
            headline: "\(deltaText) vs your usual baseline",
            detail: "Experimental · uncalibrated · stillness unverified"
        )
    }
}

/// MainActor holder the Vitals experimental row observes. Installed only via
/// the bounded value swap in the recovered pipeline (after ticket/authority/
/// confirmed-sleeps rechecks) or the launch reseed from the persisted store.
@MainActor
final class AtriaRelativeSkinSignalCenter: ObservableObject {
    static let shared = AtriaRelativeSkinSignalCenter()
    @Published private(set) var summary: AtriaRelativeSkinSignalSummary = .empty

    func install(_ summary: AtriaRelativeSkinSignalSummary) {
        self.summary = summary
    }
}
