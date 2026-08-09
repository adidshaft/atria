import Darwin
import Foundation

/// Reachability collection for immutable generations used while historical
/// consumers are published. Necessary typed history is retained indefinitely;
/// only generations unreachable from a durable current pointer are removed.
/// Any malformed pointer or missing target fails the whole pass closed.
struct AtriaHistoricalGeneratedArtifactGC {
    static let productionMaximumAvoidableBytes: UInt64 = 64 * 1_024 * 1_024
    /// A durable generation that is not yet reachable can still belong to a
    /// publication between its immutable-file and current-pointer commits.
    /// Quarantining it for a day makes collection safe across processes too,
    /// not just across the locks in this process.
    static let unreachableGenerationQuarantine: TimeInterval = 24 * 60 * 60
    /// Transaction temporaries are never restart inputs. One hour is far
    /// beyond a normal fsync/verify/publish transaction while still reclaiming
    /// crash-left aggregate copies before they grow into gigabytes.
    static let abandonedTemporaryQuarantine: TimeInterval = 60 * 60

    struct Result: Equatable, Sendable {
        let removedFiles: Int
        let removedBytes: UInt64
        let avoidableBytesBefore: UInt64
        let avoidableBytesAfter: UInt64
        let limitSatisfied: Bool
    }

    enum GCError: Error, Equatable {
        case unsafeDirectory
        case corruptPointer(String)
        case missingReachableTarget(String)
        case byteCountOverflow
        case maintenanceAuthorityRevoked
    }

    let archiveRoot: URL
    var fileManager: FileManager = .default
    var now: Date = Date()

    func prune(shouldContinue: () -> Bool = { true }) throws -> Result {
        guard shouldContinue() else {
            throw GCError.maintenanceAuthorityRevoked
        }
        let root = archiveRoot.standardizedFileURL
        guard !root.path.isEmpty else { throw GCError.unsafeDirectory }
        let receiptDirectory = root.appendingPathComponent(
            "consumer-receipts-v1", isDirectory: true
        )
        let canonicalRoot = root.appendingPathComponent(
            "canonical-consumers-v1", isDirectory: true
        )
        let destinationDirectory = canonicalRoot.appendingPathComponent(
            "destinations", isDirectory: true
        )
        let proofDirectory = canonicalRoot.appendingPathComponent(
            "application-proofs", isDirectory: true
        )

        let receiptPlan = try planReceiptDirectory(receiptDirectory)
        guard shouldContinue() else {
            throw GCError.maintenanceAuthorityRevoked
        }
        let destinationPlan = try planPointerDirectory(
            destinationDirectory,
            pointerPattern: #"^canonical-(sleep|workoutAndActivity|dailyStrainAndRecovery|steps|replayIdentity)-current-[0-9a-f]{64}\.json$"#,
            targetField: "snapshotFilename",
            targetPattern: #"^canonical-(sleep|workoutAndActivity|dailyStrainAndRecovery|steps|replayIdentity)-[0-9a-f]{20}-[0-9a-f]{64}\.json$"#
        )
        let proofPlan = try planPointerDirectory(
            proofDirectory,
            pointerPattern: #"^canonical-consumer-current-[0-9a-f]{64}\.json$"#,
            targetField: "setFilename",
            targetPattern: #"^canonical-consumer-set-[0-9a-f]{64}-[0-9a-f]{64}\.json$"#
        )
        let aggregateTemporaryPlan = try planTemporaryDirectory(
            root.appendingPathComponent("aggregates-v2", isDirectory: true),
            recognizedBasePattern: #"^aggregate-[A-Za-z0-9._-]+\.json$"#
        )
        let manifestTemporaryPlan = try planTemporaryDirectory(
            root.appendingPathComponent("retention-manifests-v2", isDirectory: true),
            recognizedBasePattern: #"^manifest-[A-Za-z0-9._-]+\.json$"#
        )
        let plans = [
            aggregateTemporaryPlan,
            manifestTemporaryPlan,
            receiptPlan,
            destinationPlan,
            proofPlan,
        ]
        var before: UInt64 = 0
        for plan in plans {
            for candidate in plan.candidates {
                guard shouldContinue() else {
                    throw GCError.maintenanceAuthorityRevoked
                }
                let value = (try? candidate.resourceValues(forKeys: [.fileSizeKey]))?
                    .fileSize ?? 0
                before = try adding(before, UInt64(max(0, value)))
            }
        }

        var removedFiles = 0
        var removedBytes: UInt64 = 0
        for plan in plans {
            var directoryChanged = false
            for url in plan.candidates {
                guard shouldContinue() else {
                    throw GCError.maintenanceAuthorityRevoked
                }
                let values = try url.resourceValues(forKeys: [
                    .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
                ])
                guard values.isRegularFile == true, values.isSymbolicLink != true,
                      url.deletingLastPathComponent().standardizedFileURL
                        == plan.directory.standardizedFileURL else { continue }
                let bytes = UInt64(max(0, values.fileSize ?? 0))
                guard shouldContinue() else {
                    throw GCError.maintenanceAuthorityRevoked
                }
                try fileManager.removeItem(at: url)
                removedFiles += 1
                removedBytes = try adding(removedBytes, bytes)
                directoryChanged = true
            }
            if directoryChanged {
                guard shouldContinue() else {
                    throw GCError.maintenanceAuthorityRevoked
                }
                try synchronizeDirectory(plan.directory)
            }
        }
        let after = before >= removedBytes ? before - removedBytes : 0
        return .init(removedFiles: removedFiles,
                     removedBytes: removedBytes,
                     avoidableBytesBefore: before,
                     avoidableBytesAfter: after,
                     limitSatisfied: after <= Self.productionMaximumAvoidableBytes)
    }

    private struct Plan {
        let directory: URL
        let candidates: [URL]
    }

    private func planReceiptDirectory(_ directory: URL) throws -> Plan {
        guard fileManager.fileExists(atPath: directory.path) else {
            return .init(directory: directory, candidates: [])
        }
        let files = try regularFiles(in: directory)
        let pointers = files.filter {
            matches($0.lastPathComponent,
                    #"^consumer-set-current-[0-9a-f]{64}\.json$"#)
        }
        var liveSets = Set<String>()
        for pointer in pointers {
            let object = try jsonObject(pointer)
            guard let filename = object["setFilename"] as? String,
                  matches(filename,
                          #"^consumer-set-[0-9a-f]{64}-[0-9a-f]{64}\.json$"#) else {
                throw GCError.corruptPointer(pointer.lastPathComponent)
            }
            try requireTarget(filename, in: directory)
            liveSets.insert(filename)
        }

        var liveReceipts = Set<String>()
        for filename in liveSets {
            let object = try jsonObject(directory.appendingPathComponent(filename))
            guard let entries = object["entries"] as? [[String: Any]] else {
                throw GCError.corruptPointer(filename)
            }
            for entry in entries {
                guard let receipt = entry["receiptFilename"] as? String,
                      matches(receipt,
                              #"^consumer-receipt-(activity|dailyMetrics|steps|sleep|workout)-[0-9a-f]{64}-[0-9a-f]{64}\.json$"#) else {
                    throw GCError.corruptPointer(filename)
                }
                try requireTarget(receipt, in: directory)
                liveReceipts.insert(receipt)
            }
        }

        // Replay staging is intentionally outside the app-facing current set.
        // Its exact compactor owns retirement, so retain every replay receipt and
        // artifact here while collecting superseded typed generations.
        var liveArtifacts = Set<String>()
        for filename in liveReceipts {
            let object = try jsonObject(directory.appendingPathComponent(filename))
            guard let artifact = object["artifactFilename"] as? String,
                  matches(artifact,
                          #"^consumer-artifact-(activity|dailyMetrics|steps|sleep|workout)-[0-9a-f]{64}\.bin$"#) else {
                throw GCError.corruptPointer(filename)
            }
            try requireTarget(artifact, in: directory)
            liveArtifacts.insert(artifact)
        }

        var candidates: [URL] = []
        for url in files {
            let name = url.lastPathComponent
            if matches(name, #"^consumer-set-[0-9a-f]{64}-[0-9a-f]{64}\.json$"#),
               !liveSets.contains(name), oldEnoughForCollection(url) {
                candidates.append(url)
            } else if matches(name,
                              #"^consumer-receipt-(activity|dailyMetrics|steps|sleep|workout)-[0-9a-f]{64}-[0-9a-f]{64}\.json$"#),
                      !liveReceipts.contains(name), oldEnoughForCollection(url) {
                candidates.append(url)
            } else if matches(name,
                              #"^consumer-artifact-(activity|dailyMetrics|steps|sleep|workout)-[0-9a-f]{64}\.bin$"#),
                      !liveArtifacts.contains(name), oldEnoughForCollection(url) {
                candidates.append(url)
            } else if abandonedTemporary(name, modifiedAt: modificationDate(url),
                                         recognizedBase: recognizedReceiptBase) {
                candidates.append(url)
            }
        }
        return .init(directory: directory, candidates: candidates)
    }

    private func planPointerDirectory(
        _ directory: URL,
        pointerPattern: String,
        targetField: String,
        targetPattern: String
    ) throws -> Plan {
        guard fileManager.fileExists(atPath: directory.path) else {
            return .init(directory: directory, candidates: [])
        }
        let files = try regularFiles(in: directory)
        var liveTargets = Set<String>()
        for pointer in files where matches(pointer.lastPathComponent, pointerPattern) {
            let object = try jsonObject(pointer)
            guard let target = object[targetField] as? String,
                  matches(target, targetPattern) else {
                throw GCError.corruptPointer(pointer.lastPathComponent)
            }
            try requireTarget(target, in: directory)
            liveTargets.insert(target)
        }
        let candidates = files.filter { url in
            let name = url.lastPathComponent
            if matches(name, targetPattern) {
                return !liveTargets.contains(name) && oldEnoughForCollection(url)
            }
            return abandonedTemporary(name, modifiedAt: modificationDate(url)) {
                matches($0, pointerPattern) || matches($0, targetPattern)
            }
        }
        return .init(directory: directory, candidates: candidates)
    }

    private func planTemporaryDirectory(
        _ directory: URL,
        recognizedBasePattern: String
    ) throws -> Plan {
        guard fileManager.fileExists(atPath: directory.path) else {
            return .init(directory: directory, candidates: [])
        }
        let candidates = try regularFiles(in: directory).filter { url in
            abandonedTemporary(
                url.lastPathComponent,
                modifiedAt: modificationDate(url),
                quarantine: Self.abandonedTemporaryQuarantine
            ) {
                matches($0, recognizedBasePattern)
            }
        }
        return .init(directory: directory, candidates: candidates)
    }

    private func regularFiles(in directory: URL) throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey,
                                         .fileSizeKey, .contentModificationDateKey],
            options: []
        ).filter {
            let values = try? $0.resourceValues(forKeys: [.isRegularFileKey,
                                                           .isSymbolicLinkKey])
            return values?.isRegularFile == true && values?.isSymbolicLink != true
        }
    }

    private func jsonObject(_ url: URL) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
                as? [String: Any] else {
            throw GCError.corruptPointer(url.lastPathComponent)
        }
        return object
    }

    private func requireTarget(_ filename: String, in directory: URL) throws {
        let url = directory.appendingPathComponent(filename)
        guard url.deletingLastPathComponent().standardizedFileURL
                == directory.standardizedFileURL,
              fileManager.fileExists(atPath: url.path) else {
            throw GCError.missingReachableTarget(filename)
        }
    }

    private func recognizedReceiptBase(_ name: String) -> Bool {
        matches(name, #"^consumer-set-[0-9a-f]{64}-[0-9a-f]{64}\.json$"#)
            || matches(name, #"^consumer-set-current-[0-9a-f]{64}\.json$"#)
            || matches(name, #"^consumer-receipt-(activity|dailyMetrics|steps|sleep|workout|replayIdentity)-[0-9a-f]{64}-[0-9a-f]{64}\.json$"#)
            || matches(name, #"^consumer-artifact-(activity|dailyMetrics|steps|sleep|workout|replayIdentity)-[0-9a-f]{64}\.bin$"#)
    }

    private func abandonedTemporary(
        _ filename: String,
        modifiedAt: Date?,
        quarantine: TimeInterval = unreachableGenerationQuarantine,
        recognizedBase: (String) -> Bool
    ) -> Bool {
        guard let modifiedAt, now.timeIntervalSince(modifiedAt) >= quarantine,
              filename.hasPrefix("."), filename.hasSuffix(".tmp") else { return false }
        let body = String(filename.dropFirst().dropLast(4))
        guard let separator = body.lastIndex(of: "."),
              UUID(uuidString: String(body[body.index(after: separator)...])) != nil else {
            return false
        }
        return recognizedBase(String(body[..<separator]))
    }

    private func modificationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
    }

    private func oldEnoughForCollection(_ url: URL) -> Bool {
        guard let modifiedAt = modificationDate(url) else { return false }
        return now.timeIntervalSince(modifiedAt) >= Self.unreachableGenerationQuarantine
    }

    private func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }

    private func adding(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
        let result = lhs.addingReportingOverflow(rhs)
        guard !result.overflow else { throw GCError.byteCountOverflow }
        return result.partialValue
    }

    private func synchronizeDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw POSIXError(.EIO) }
    }
}
