import Foundation

/// Read-only diagnostic for the production all-day WHOOP 4 cadence model.
///
/// Usage:
///   replay_whoop4_day_steps <raw-v2.jsonl> <wall-start-unix> <wall-end-unix>
///
/// The output is model evidence only. It never edits the archive or imports
/// phone motion.
@main
private enum ReplayWhoop4DaySteps {
    private struct StoredPoint {
        let point: AtriaWhoop4GravityCadenceStepModel.Point
        let observedAt: TimeInterval
    }

    static func main() throws {
        guard CommandLine.arguments.count == 4,
              let start = TimeInterval(CommandLine.arguments[2]),
              let end = TimeInterval(CommandLine.arguments[3]),
              end > start else {
            throw NSError(
                domain: "ReplayWhoop4DaySteps",
                code: 64,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "usage: replay_whoop4_day_steps <raw.jsonl> <start> <end>",
                ]
            )
        }

        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let resource = try url.resourceValues(forKeys: [.isDirectoryKey])
        let files: [URL]
        if resource.isDirectory == true {
            guard let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                throw NSError(
                    domain: "ReplayWhoop4DaySteps",
                    code: 66,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "could not enumerate \(url.path)",
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
            files = [url]
        }
        var byPayload: [String: StoredPoint] = [:]
        for file in files {
            let data = try Data(contentsOf: file, options: .mappedIfSafe)
            data.enumerateLines { line in
                guard let lineData = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData)
                    as? [String: Any],
                  (object["sequence"] as? NSNumber)?.intValue == 24,
                  object["clockCorrectionStatus"] as? String
                    == "clock_ref_present",
                  let payloadHex = object["rawPayloadHex"] as? String,
                  let corrected = (object["clockCorrectedUnix7"]
                    as? NSNumber)?.doubleValue,
                  let subsecond = (object["subsec11"]
                    as? NSNumber)?.doubleValue,
                  let flash = (object["flash13"]
                    as? NSNumber)?.uint32Value,
                  let tick = ((object["motionTickCounter88"] as? NSNumber)
                    ?? (object["nativeStepCounter88"] as? NSNumber))?.intValue,
                  let gravityX = (object["gravityX36"]
                    as? NSNumber)?.doubleValue,
                  let gravityY = (object["gravityY40"]
                    as? NSNumber)?.doubleValue,
                  let gravityZ = (object["gravityZ44"]
                    as? NSNumber)?.doubleValue,
                  let scalar = littleEndianFloat(
                    payloadHex: payloadHex,
                    offset: 32
                  ) else {
                return
            }
                let timestamp = corrected + subsecond / 32_768
                guard timestamp >= start, timestamp <= end else { return }
                let observedAt = (object[
                    "_atriaHistoryObservedAtUnix"
                ] as? NSNumber)?.doubleValue ?? .infinity
                let stored = StoredPoint(
                    point: .init(
                        timestamp: timestamp,
                        flash: flash,
                        tick: tick,
                        gravityX: gravityX,
                        gravityY: gravityY,
                        gravityZ: gravityZ,
                        unknownMotionScalar32: scalar,
                        identity: payloadHex
                    ),
                    observedAt: observedAt
                )
                if let existing = byPayload[payloadHex],
                   existing.observedAt <= observedAt {
                    return
                }
                byPayload[payloadHex] = stored
            }
        }

        let points = byPayload.values.map(\.point)
        let autonomousBouts = AtriaWhoop4GravityCadenceStepModel
            .autonomousGaitBoutEstimates(points: points)
        let estimate = AtriaWhoop4GravityCadenceStepModel
            .estimateCoveredActivityFragments([points])
        let output: [String: Any] = [
            "algorithmVersion":
                AtriaWhoop4GravityCadenceStepModel.algorithmVersion,
            "decodedRows": points.count,
            "phoneMotionUsed": false,
            "autonomousBoutCount": autonomousBouts.count,
            "autonomousBoutSteps": autonomousBouts.reduce(0) {
                $0 + $1.steps
            },
            "steps": estimate?.steps as Any,
            "classifiedMotionTicks": estimate?.motionTicks as Any,
            "classifiedDurationSeconds": estimate?.durationSeconds as Any,
            "unresolvedMotionSeconds":
                estimate?.unresolvedMotionSeconds as Any,
        ]
        let encoded = try JSONSerialization.data(
            withJSONObject: output,
            options: [.prettyPrinted, .sortedKeys]
        )
        FileHandle.standardOutput.write(encoded)
        FileHandle.standardOutput.write(Data([0x0A]))
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
        let littleEndian = value.byteSwapped
        let float = Float(bitPattern: littleEndian)
        return float.isFinite ? Double(float) : nil
    }
}

private extension Data {
    func enumerateLines(_ body: (String) -> Void) {
        var startIndex = startIndex
        while startIndex < endIndex {
            let newline = self[startIndex...].firstIndex(of: 0x0A) ?? endIndex
            if newline > startIndex,
               let line = String(
                   data: self[startIndex..<newline],
                   encoding: .utf8
               ) {
                body(line)
            }
            startIndex = newline < endIndex
                ? index(after: newline) : endIndex
        }
    }
}
