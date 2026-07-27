import Foundation

/// Pure fail-closed reducer for clock-corrected WHOOP 4 v24 motion counters.
///
/// It deliberately operates on sequential points rather than subtracting two
/// distant endpoints. That prevents duplicate rows, resets, impossible flash
/// movement, and an unobservable full UInt16 revolution from becoming steps.
enum AtriaWhoop4MotionTickSequenceReducer {
    struct Point: Hashable, Sendable {
        let timestamp: TimeInterval
        let tick: Int
        let flash: UInt32
        let identity: String
    }

    struct Result: Equatable, Sendable {
        let ticks: Int
        let knownDuration: TimeInterval
        let admittedRows: Int
        let capturedThrough: Date
    }

    static func reduce(
        points: [Point],
        intervals: [DateInterval],
        boundaryTolerance: TimeInterval = 3
    ) -> Result? {
        guard boundaryTolerance >= 0,
              points.allSatisfy({
                  $0.timestamp.isFinite
                      && (0...65_535).contains($0.tick)
              }) else { return nil }
        let sortedPoints = points.sorted {
            if $0.timestamp != $1.timestamp {
                return $0.timestamp < $1.timestamp
            }
            return $0.identity < $1.identity
        }
        var ticks = 0
        var knownDuration: TimeInterval = 0
        var admittedRows = 0
        var capturedThrough: Date?

        for interval in intervals where interval.end > interval.start {
            let requestedStart = interval.start.timeIntervalSince1970
            let requestedEnd = interval.end.timeIntervalSince1970
            let candidates = sortedPoints.filter {
                $0.timestamp >= requestedStart - boundaryTolerance
                    && $0.timestamp <= requestedEnd + boundaryTolerance
            }
            guard let first = candidates.min(by: {
                abs($0.timestamp - requestedStart)
                    < abs($1.timestamp - requestedStart)
            }),
            let last = candidates.min(by: {
                abs($0.timestamp - requestedEnd)
                    < abs($1.timestamp - requestedEnd)
            }),
            abs(first.timestamp - requestedStart) <= boundaryTolerance,
            abs(last.timestamp - requestedEnd) <= boundaryTolerance,
            last.timestamp > first.timestamp else {
                continue
            }

            let ordered = candidates.filter {
                $0.timestamp >= first.timestamp && $0.timestamp <= last.timestamp
            }
            var unique: [Point] = []
            var conflict = false
            for point in ordered {
                if let prior = unique.last,
                   abs(prior.timestamp - point.timestamp) < 0.000_001 {
                    if prior.tick != point.tick || prior.flash != point.flash {
                        conflict = true
                        break
                    }
                    continue
                }
                unique.append(point)
            }
            guard !conflict, unique.count >= 2 else { continue }

            var intervalTicks = 0
            var intervalKnownDuration: TimeInterval = 0
            var intervalAdmittedRows = 0
            for (before, after) in zip(unique, unique.dropFirst()) {
                let duration = after.timestamp - before.timestamp
                // At 12 ticks/s, 5,462 seconds can hide a complete UInt16
                // revolution. Once that is possible, modulo subtraction is
                // no longer unique.
                guard duration > 0,
                      duration * 12 < 65_536 else {
                    continue
                }
                let flashDelta = after.flash >= before.flash
                    ? UInt64(after.flash - before.flash)
                    : UInt64(after.flash)
                        + UInt64(UInt32.max) + 1
                        - UInt64(before.flash)
                let maximumFlashAdvance = UInt64(
                    max(4, Int((duration * 4).rounded(.up)) + 4)
                )
                guard flashDelta > 0,
                      flashDelta <= maximumFlashAdvance else {
                    continue
                }
                let tickDelta = after.tick >= before.tick
                    ? after.tick - before.tick
                    : after.tick + 65_536 - before.tick
                guard Double(tickDelta) <= max(12, duration * 12) else {
                    continue
                }
                intervalTicks += tickDelta
                intervalKnownDuration += duration
                intervalAdmittedRows += intervalAdmittedRows == 0 ? 2 : 1
            }
            guard intervalKnownDuration > 0 else { continue }
            ticks += intervalTicks
            knownDuration += intervalKnownDuration
            admittedRows += intervalAdmittedRows
            let captured = Date(timeIntervalSince1970: last.timestamp)
            capturedThrough = max(capturedThrough ?? captured, captured)
        }

        guard knownDuration > 0, admittedRows >= 2, let capturedThrough else {
            return nil
        }
        return .init(
            ticks: ticks,
            knownDuration: knownDuration,
            admittedRows: admittedRows,
            capturedThrough: capturedThrough
        )
    }
}
