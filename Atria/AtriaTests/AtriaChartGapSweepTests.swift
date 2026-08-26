import XCTest

/// Every line and area mark in the app, swept for gap-splitting.
///
/// Three separate surfaces were found bridging gaps by reading code one at a
/// time — the Vitals sparkline, the metric chart's min-max band, and then its
/// gradient area fill, all within two days. Finding the fourth by eye was not a
/// plan, so this checks all of them at once.
///
/// A mark that plots a DAILY series must carry `series:` so Swift Charts can
/// break the run. Dense intra-day traces (a beat-level tachogram, a session HR
/// line) and categorical axes are exempt and named individually below, because
/// "exempt" should be a decision on the record rather than an omission.
final class AtriaChartGapSweepTests: XCTestCase {

    private func sources() throws -> [(name: String, text: String)] {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".swift") }
            .sorted()
        return try names.map {
            ($0, try String(contentsOf: dir.appendingPathComponent($0), encoding: .utf8))
        }
    }

    /// Marks whose x value is a DAY — these are the ones a gap can falsify.
    func testEveryDailyLineOrAreaMarkCanBreakAtAGap() throws {
        var offenders: [String] = []
        for (name, text) in try sources() {
            let lines = text.components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                guard line.contains("LineMark(") || line.contains("AreaMark(") else { continue }
                let window = lines[index..<min(index + 9, lines.count)].joined(separator: "\n")
                // Only daily series: an x value carrying a "Day" label.
                guard window.contains("\"Day\"") else { continue }
                if !window.contains("series:") {
                    offenders.append("\(name):\(index + 1)")
                }
            }
        }
        XCTAssertEqual(offenders, [],
                       "a daily line/area without `series:` draws through days "
                           + "that were never measured: \(offenders)")
    }

    /// The exemptions, stated rather than implied.
    func testTheOnlyUnsplitMarksAreDenseOrCategorical() throws {
        var unsplit: [String] = []
        for (name, text) in try sources() {
            let lines = text.components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                guard line.contains("LineMark(") || line.contains("AreaMark(") else { continue }
                let window = lines[index..<min(index + 9, lines.count)].joined(separator: "\n")
                if !window.contains("series:") { unsplit.append("\(name):\(index + 1)") }
            }
        }
        // HRV.swift — the RR tachogram, beat-level, where the scatter IS the
        // measurement (see AtriaChartInterpolationGrammarTests).
        // Sessions.swift — a categorical x ("Window" labels, no time gaps) and
        // a dense beat-level session HR trace.
        let expected = ["HRV.swift", "Sessions.swift"]
        for entry in unsplit {
            let file = entry.components(separatedBy: ":")[0]
            XCTAssertTrue(expected.contains(file),
                          "\(entry) is an unsplit mark in a file with no "
                              + "recorded exemption — classify it deliberately")
        }
        XCTAssertLessThanOrEqual(unsplit.count, 3,
                                 "the exemption list is meant to shrink, not "
                                     + "grow: \(unsplit)")
    }
}
