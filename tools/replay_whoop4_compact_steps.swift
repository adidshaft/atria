import Foundation

/// Read-only replay of the production WHOOP 4 cadence model from one compact
/// v24 shard.
///
/// Usage:
///   replay_whoop4_compact_steps <compact.bin> <start-unix> <end-unix>
///
/// The compact derivative contains only strap motion. This tool does not read
/// phone motion, GPS, distance, or heart rate and never modifies its input.
@main
private enum ReplayWhoop4CompactSteps {
    private static let recordMagic: UInt32 = 0x3154_4D41
    private static let recordSize = 52

    static func main() throws {
        guard CommandLine.arguments.count == 4,
              let start = TimeInterval(CommandLine.arguments[2]),
              let end = TimeInterval(CommandLine.arguments[3]),
              end > start else {
            throw NSError(
                domain: "ReplayWhoop4CompactSteps",
                code: 64,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "usage: replay_whoop4_compact_steps "
                        + "<compact.bin> <start-unix> <end-unix>",
                ]
            )
        }

        let data = try Data(
            contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]),
            options: .mappedIfSafe
        )
        var points: [AtriaWhoop4GravityCadenceStepModel.Point] = []
        for offset in stride(
            from: 0,
            to: data.count - (data.count % recordSize),
            by: recordSize
        ) {
            guard uint32(data, at: offset) == recordMagic else { continue }
            let timestamp = Double(bitPattern: uint64(data, at: offset + 4))
            guard timestamp >= start, timestamp <= end else { continue }
            let flash = uint32(data, at: offset + 12)
            let tick = Int(Int32(bitPattern: uint32(data, at: offset + 16)))
            let gravityX = Double(
                Float(bitPattern: uint32(data, at: offset + 20))
            )
            let gravityY = Double(
                Float(bitPattern: uint32(data, at: offset + 24))
            )
            let gravityZ = Double(
                Float(bitPattern: uint32(data, at: offset + 28))
            )
            let scalar = Float(bitPattern: uint32(data, at: offset + 32))
            let digest = data[(offset + 36)..<(offset + 52)].map {
                String(format: "%02x", $0)
            }.joined()
            guard timestamp.isFinite,
                  (0...65_535).contains(tick),
                  gravityX.isFinite,
                  gravityY.isFinite,
                  gravityZ.isFinite else {
                continue
            }
            points.append(.init(
                timestamp: timestamp,
                flash: flash,
                tick: tick,
                gravityX: gravityX,
                gravityY: gravityY,
                gravityZ: gravityZ,
                unknownMotionScalar32:
                    scalar.isFinite ? Double(scalar) : nil,
                identity: digest
            ))
        }

        let bouts = AtriaWhoop4GravityCadenceStepModel
            .autonomousGaitBoutEstimates(points: points)
        let estimate = AtriaWhoop4GravityCadenceStepModel
            .estimateCoveredActivityFragments([points])
        let output: [String: Any] = [
            "algorithmVersion":
                AtriaWhoop4GravityCadenceStepModel.algorithmVersion,
            "decodedRows": points.count,
            "firstTimestamp": points.map(\.timestamp).min() as Any,
            "lastTimestamp": points.map(\.timestamp).max() as Any,
            "phoneMotionUsed": false,
            "autonomousBoutCount": bouts.count,
            "autonomousBoutSteps": bouts.reduce(0) { $0 + $1.steps },
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

    private static func uint32(_ data: Data, at offset: Int) -> UInt32 {
        data[offset..<(offset + 4)].enumerated().reduce(0) {
            $0 | UInt32($1.element) << UInt32($1.offset * 8)
        }
    }

    private static func uint64(_ data: Data, at offset: Int) -> UInt64 {
        data[offset..<(offset + 8)].enumerated().reduce(0) {
            $0 | UInt64($1.element) << UInt64($1.offset * 8)
        }
    }
}
