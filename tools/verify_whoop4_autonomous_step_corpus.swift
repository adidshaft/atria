import Foundation

/// Read-only acceptance replay for the autonomous WHOOP 4 all-day step path.
///
/// Usage:
///   verify_whoop4_autonomous_step_corpus <raw-v2-directory-or-jsonl>
///
/// Every label is bound to its physical truth, exact wall-clock interval, and
/// original evidence path below. The supplied archive is read once, payloads
/// are deduplicated, and the production autonomous scorer is exercised at the
/// exact interval plus every whole-second boundary shift from -2 through +2.
/// No phone motion, distance, GPS, or user count enters the scorer.
@main
private enum VerifyWhoop4AutonomousStepCorpus {
    private struct Label {
        let name: String
        let start: TimeInterval
        let end: TimeInterval
        let expectedSteps: Int
        let provenance: String
    }

    private struct StoredPoint {
        let point: AtriaWhoop4GravityCadenceStepModel.Point
        let observedAt: TimeInterval
    }

    private static let labels: [Label] = [
        .init(
            name: "W132",
            start: 1_785_091_772,
            end: 1_785_091_863,
            expectedSteps: 132,
            provenance:
                "evidence/2026-07-27-gate4-prearmed-walk/"
                + "training-walk-drain.jsonl"
        ),
        .init(
            name: "W136",
            start: 1_785_092_820,
            end: 1_785_092_913,
            expectedSteps: 136,
            provenance:
                "evidence/2026-07-27-gate4-prearmed-walk/"
                + "heldout-walk-drain.jsonl"
        ),
        .init(
            name: "W150",
            start: 1_785_096_721,
            end: 1_785_096_819,
            expectedSteps: 150,
            provenance:
                "evidence/2026-07-27-gate4-unannounced-150/README.md"
        ),
        .init(
            name: "W129",
            start: 1_785_101_104,
            end: 1_785_101_199,
            expectedSteps: 129,
            provenance:
                "evidence/2026-07-27-gate4-untouched-129/receipt.json"
        ),
        .init(
            name: "W106",
            start: 1_785_104_940,
            end: 1_785_105_037,
            expectedSteps: 106,
            provenance:
                "evidence/2026-07-27-gate4-v6-slow-walk-failure/"
                + "receipt.json"
        ),
        .init(
            name: "W108",
            start: 1_785_105_727,
            end: 1_785_105_821,
            expectedSteps: 108,
            provenance:
                "evidence/2026-07-27-gate4-v7-high-impact-failure/"
                + "receipt.json"
        ),
        .init(
            name: "W100",
            start: 1_785_106_514,
            end: 1_785_106_608,
            expectedSteps: 100,
            provenance:
                "evidence/2026-07-27-gate4-v8-low-alias-failure/"
                + "receipt.json"
        ),
        .init(
            name: "W110",
            start: 1_785_107_793,
            end: 1_785_107_886,
            expectedSteps: 110,
            provenance:
                "evidence/2026-07-27-gate4-v9-motion-ownership-failure/"
                + "receipt.json"
        ),
        .init(
            name: "W109",
            start: 1_785_108_502,
            end: 1_785_108_595,
            expectedSteps: 109,
            provenance:
                "evidence/2026-07-27-gate4-v10-fresh-slow-walk-109/"
                + "README.md"
        ),
        .init(
            name: "W109b",
            start: 1_785_111_646,
            end: 1_785_111_737,
            expectedSteps: 109,
            provenance:
                "evidence/2026-07-27-gate4-v10-fresh-slow-walk-109/"
                + "historical-active-chunk.jsonl"
        ),
        .init(
            name: "W115",
            start: 1_785_112_541,
            end: 1_785_112_632,
            expectedSteps: 115,
            provenance:
                "evidence/2026-07-27-gate4-v11-fresh-slow-walk-115/"
                + "README.md"
        ),
        .init(
            name: "W90",
            start: 1_785_417_551,
            end: 1_785_417_641,
            expectedSteps: 90,
            provenance:
                "Atria/AtriaTests/Fixtures/"
                + "whoop4-v15-physical-gait-corpus.jsonl"
                + "#compact-e49a6a6-1785417551-1785417641"
        ),
        .init(
            name: "C1",
            start: 1_785_102_086,
            end: 1_785_102_206,
            expectedSteps: 0,
            provenance:
                "evidence/2026-07-27-gate4-arm-control-failure/"
                + "receipt.json"
        ),
        .init(
            name: "C2",
            start: 1_785_103_194,
            end: 1_785_103_300,
            expectedSteps: 0,
            provenance:
                "evidence/2026-07-27-gate4-v5-arm-control-failure/"
                + "receipt.json"
        ),
        .init(
            name: "C3",
            start: 1_785_104_226,
            end: 1_785_104_332,
            expectedSteps: 0,
            provenance:
                "evidence/2026-07-27-gate4-v6-arm-control-pass/"
                + "receipt.json"
        ),
        .init(
            name: "C4",
            start: 1_785_114_466.586_846,
            end: 1_785_114_557.847_872,
            expectedSteps: 0,
            provenance:
                "evidence/2026-07-27-gate4-v12-fresh-arm-control/"
                + "README.md"
        ),
    ]

    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw NSError(
                domain: "VerifyWhoop4AutonomousStepCorpus",
                code: 64,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "usage: verify_whoop4_autonomous_step_corpus "
                        + "<raw-v2-directory-or-jsonl>",
                ]
            )
        }
        let source = URL(fileURLWithPath: CommandLine.arguments[1])
        var points = try loadPoints(from: source)
        points.append(contentsOf: try loadPoints(
            from: URL(
                fileURLWithPath:
                    "Atria/AtriaTests/Fixtures/"
                    + "whoop4-v15-physical-gait-corpus.jsonl"
            )
        ))
        points.append(contentsOf: try loadProtectedDrainPoints(
            from: URL(
                fileURLWithPath:
                    "evidence/2026-07-27-gate4-prearmed-walk/"
                    + "training-walk-drain.jsonl"
            ),
            wallMinusDeviceSeconds: -1
        ))
        points.append(contentsOf: try loadProtectedDrainPoints(
            from: URL(
                fileURLWithPath:
                    "evidence/2026-07-27-gate4-prearmed-walk/"
                    + "heldout-walk-drain.jsonl"
            ),
            wallMinusDeviceSeconds: 0
        ))
        points = Array(
            Dictionary(
                points.map { ($0.identity, $0) },
                uniquingKeysWith: { first, _ in first }
            ).values
        )

        var rows: [[String: Any]] = []
        var passed = 0
        var failed = 0
        for label in labels {
            for shift in -2...2 {
                let start = label.start + Double(shift)
                let end = label.end + Double(shift)
                let bounded = points.filter {
                    $0.timestamp >= start && $0.timestamp <= end
                }
                let estimate =
                    AtriaWhoop4GravityCadenceStepModel
                        .estimateCoveredActivityFragments([bounded])
                let autonomousDiagnostics =
                    AtriaWhoop4GravityCadenceStepModel
                        .autonomousGaitBoutDiagnostics(points: bounded)
                let autonomousEstimates = autonomousDiagnostics.map(\.estimate)
                let autonomousSteps = autonomousEstimates.reduce(0) {
                    $0 + $1.steps
                }
                let observed = estimate?.steps
                let relativeError: Double?
                let accepted: Bool
                if label.expectedSteps == 0 {
                    relativeError = nil
                    accepted = (observed ?? 0) == 0
                } else {
                    relativeError = observed.map {
                        abs(Double($0 - label.expectedSteps))
                            / Double(label.expectedSteps)
                    }
                    accepted = relativeError.map { $0 <= 0.05 } == true
                }
                if accepted {
                    passed += 1
                } else {
                    failed += 1
                }
                rows.append([
                    "label": label.name,
                    "boundaryShiftSeconds": shift,
                    "expectedSteps": label.expectedSteps,
                    "observedSteps": observed as Any,
                    "relativeError": relativeError as Any,
                    "decodedRows": bounded.count,
                    "classifiedDurationSeconds":
                        estimate?.durationSeconds as Any,
                    "motionTicks": estimate?.motionTicks as Any,
                    "cadenceSteps":
                        estimate?.cadenceOnlySteps as Any,
                    "motionVolumeSteps":
                        estimate?.motionVolumeSteps as Any,
                    "aliasFrequencyHz":
                        estimate?.aliasFrequencyHz as Any,
                    "autonomousBoutCount": autonomousEstimates.count,
                    "autonomousSteps": autonomousSteps,
                    "autonomousDurationsSeconds":
                        autonomousEstimates.map(\.durationSeconds),
                    "autonomousRanges": autonomousDiagnostics.map {
                        [
                            "start": $0.startTimestamp,
                            "end": $0.endTimestamp,
                        ]
                    },
                    "passed": accepted,
                    "provenance": label.provenance,
                ])
            }
        }

        let output: [String: Any] = [
            "algorithmVersion":
                AtriaWhoop4GravityCadenceStepModel.algorithmVersion,
            "source": source.path,
            "decodedUniqueRows": points.count,
            "phoneMotionUsed": false,
            "boundaryShiftRangeSeconds": [-2, 2],
            "maximumWalkRelativeError": 0.05,
            "passedChecks": passed,
            "failedChecks": failed,
            "accepted": failed == 0,
            "checks": rows,
        ]
        let encoded = try JSONSerialization.data(
            withJSONObject: output,
            options: [.prettyPrinted, .sortedKeys]
        )
        FileHandle.standardOutput.write(encoded)
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    private static func loadPoints(
        from source: URL
    ) throws -> [AtriaWhoop4GravityCadenceStepModel.Point] {
        let values = try source.resourceValues(forKeys: [.isDirectoryKey])
        let files: [URL]
        if values.isDirectory == true {
            guard let enumerator = FileManager.default.enumerator(
                at: source,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                throw NSError(
                    domain: "VerifyWhoop4AutonomousStepCorpus",
                    code: 66,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "could not enumerate \(source.path)",
                    ]
                )
            }
            files = enumerator.compactMap { entry -> URL? in
                guard let candidate = entry as? URL,
                      candidate.pathExtension == "jsonl",
                      (try? candidate.resourceValues(
                          forKeys: [.isRegularFileKey]
                      ).isRegularFile) == true else {
                    return nil
                }
                return candidate
            }
            .sorted { $0.path < $1.path }
        } else {
            files = [source]
        }

        let lowerBound = labels.map(\.start).min()! - 2
        let upperBound = labels.map(\.end).max()! + 2
        var byPayload: [String: StoredPoint] = [:]
        for file in files {
            let data = try Data(contentsOf: file, options: .mappedIfSafe)
            data.enumerateLines { line in
                guard let lineData = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(
                          with: lineData
                      ) as? [String: Any],
                      (object["sequence"] as? NSNumber)?.intValue == 24,
                      object["clockCorrectionStatus"] as? String
                        == "clock_ref_present",
                      let identity =
                        (object["rawPayloadHex"] as? String)
                        ?? (object["compactDigest"] as? String),
                      let corrected = (object["clockCorrectedUnix7"]
                        as? NSNumber)?.doubleValue,
                      let subsecond = (object["subsec11"]
                        as? NSNumber)?.doubleValue,
                      let flash = (object["flash13"]
                        as? NSNumber)?.uint32Value,
                      let tick = ((object["motionTickCounter88"] as? NSNumber)
                        ?? (object["nativeStepCounter88"]
                            as? NSNumber))?.intValue,
                      let gravityX = (object["gravityX36"]
                        as? NSNumber)?.doubleValue,
                      let gravityY = (object["gravityY40"]
                        as? NSNumber)?.doubleValue,
                      let gravityZ = (object["gravityZ44"]
                        as? NSNumber)?.doubleValue,
                      let scalar = (
                        (object["unknownMotionScalar32"]
                            as? NSNumber)?.doubleValue
                        ?? (object["rawPayloadHex"] as? String).flatMap {
                            littleEndianFloat(payloadHex: $0, offset: 32)
                        }
                      ) else {
                    return
                }
                let timestamp = corrected + subsecond / 32_768
                guard timestamp >= lowerBound,
                      timestamp <= upperBound else {
                    return
                }
                let observedAt = (
                    object["_atriaHistoryObservedAtUnix"] as? NSNumber
                )?.doubleValue ?? .infinity
                let stored = StoredPoint(
                    point: .init(
                        timestamp: timestamp,
                        flash: flash,
                        tick: tick,
                        gravityX: gravityX,
                        gravityY: gravityY,
                        gravityZ: gravityZ,
                        unknownMotionScalar32: scalar,
                        identity: identity
                    ),
                    observedAt: observedAt
                )
                if let existing = byPayload[identity],
                   existing.observedAt <= observedAt {
                    return
                }
                byPayload[identity] = stored
            }
        }
        return byPayload.values.map(\.point)
    }

    private static func loadProtectedDrainPoints(
        from source: URL,
        wallMinusDeviceSeconds: TimeInterval
    ) throws -> [AtriaWhoop4GravityCadenceStepModel.Point] {
        let data = try Data(contentsOf: source, options: .mappedIfSafe)
        var points: [AtriaWhoop4GravityCadenceStepModel.Point] = []
        data.enumerateLines { line in
            guard let lineData = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(
                      with: lineData
                  ) as? [String: Any],
                  object["event"] as? String == "evidence_historical_frame",
                  let payloadHex = object["payload_hex"] as? String,
                  let bytes = bytes(payloadHex),
                  bytes.count >= 90,
                  bytes[0] == 0x2F,
                  bytes[1] == 24,
                  let flash = uint32(bytes, at: 3),
                  let deviceSecond = uint32(bytes, at: 7),
                  let subsecond = uint16(bytes, at: 11),
                  let scalar = float32(bytes, at: 32),
                  let gravityX = float32(bytes, at: 36),
                  let gravityY = float32(bytes, at: 40),
                  let gravityZ = float32(bytes, at: 44),
                  let tick = uint16(bytes, at: 88) else {
                return
            }
            points.append(.init(
                timestamp:
                    Double(deviceSecond)
                    + wallMinusDeviceSeconds
                    + Double(subsecond) / 32_768,
                flash: flash,
                tick: Int(tick),
                gravityX: gravityX,
                gravityY: gravityY,
                gravityZ: gravityZ,
                unknownMotionScalar32: scalar,
                identity: payloadHex
            ))
        }
        return points
    }

    private static func littleEndianFloat(
        payloadHex: String,
        offset: Int
    ) -> Double? {
        guard payloadHex.count >= (offset + 4) * 2 else { return nil }
        let start = payloadHex.index(
            payloadHex.startIndex,
            offsetBy: offset * 2
        )
        let end = payloadHex.index(start, offsetBy: 8)
        guard let value = UInt32(payloadHex[start..<end], radix: 16) else {
            return nil
        }
        let float = Float(bitPattern: value.byteSwapped)
        return float.isFinite ? Double(float) : nil
    }

    private static func bytes(_ hex: String) -> [UInt8]? {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var cursor = hex.startIndex
        while cursor < hex.endIndex {
            let end = hex.index(cursor, offsetBy: 2)
            guard let byte = UInt8(hex[cursor..<end], radix: 16) else {
                return nil
            }
            bytes.append(byte)
            cursor = end
        }
        return bytes
    }

    private static func uint16(
        _ bytes: [UInt8],
        at offset: Int
    ) -> UInt16? {
        guard offset >= 0, offset + 1 < bytes.count else { return nil }
        return UInt16(bytes[offset])
            | UInt16(bytes[offset + 1]) << 8
    }

    private static func uint32(
        _ bytes: [UInt8],
        at offset: Int
    ) -> UInt32? {
        guard offset >= 0, offset + 3 < bytes.count else { return nil }
        return UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }

    private static func float32(
        _ bytes: [UInt8],
        at offset: Int
    ) -> Double? {
        guard let bits = uint32(bytes, at: offset) else { return nil }
        let value = Float(bitPattern: bits)
        return value.isFinite ? Double(value) : nil
    }
}

private extension Data {
    func enumerateLines(_ body: (String) -> Void) {
        var cursor = startIndex
        while cursor < endIndex {
            let newline = self[cursor...].firstIndex(of: 0x0A) ?? endIndex
            if newline > cursor,
               let line = String(
                   data: self[cursor..<newline],
                   encoding: .utf8
               ) {
                body(line)
            }
            cursor = newline < endIndex ? index(after: newline) : endIndex
        }
    }
}
