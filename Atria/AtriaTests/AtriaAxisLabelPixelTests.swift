import XCTest
import SwiftUI
import Charts
@testable import Atria

/// Measures, in rendered pixels, where a day-bar's axis label actually lands.
///
/// Every other test about this is a source scan — it asserts which modifier is
/// written, never where the glyph ends up. That is exactly how the defect
/// shipped: `AtriaDayBarAxisAlignmentTests` pinned `centered: true` as correct
/// for charts whose marks are NOT one day apart, and stayed green while the
/// label sat days away from its bar.
///
/// So this renders the chart with `ImageRenderer` and finds two centroids: the
/// red bar in the plot, and the leftmost text blob in the axis strip. If the
/// label belongs to that bar, the two x-centroids coincide.
@MainActor
final class AtriaAxisLabelPixelTests: XCTestCase {

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }()

    private lazy var day0: Date = calendar.startOfDay(
        for: Date(timeIntervalSince1970: 1_756_000_000)
    )

    private func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset, to: day0)!
    }

    private static let size = CGSize(width: 420, height: 220)
    private static let markStrideDays = 7

    /// One tall bar on day 0, nothing else, so the plot has exactly one red
    /// region to locate. Marks are `markStrideDays` apart, which is the shape
    /// `.automatic(desiredCount:)` produces on a wide window.
    private func chart<Axis: AxisContent>(
        @AxisContentBuilder axis: @escaping () -> Axis
    ) -> some View {
        Chart {
            BarMark(x: .value("Day", day(Self.markStrideDays), unit: .day),
                    y: .value("Value", 1.0))
                .foregroundStyle(.red)
        }
        .chartXScale(domain: day0...day(21))
        .chartYScale(domain: 0...1)
        .chartYAxis(.hidden)
        .chartXAxis { axis() }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Color.white)
        .environment(\.colorScheme, .light)
    }

    private func render(_ view: some View) throws -> CGImage {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        return try XCTUnwrap(renderer.cgImage, "ImageRenderer produced no image")
    }

    private struct Pixels {
        let width: Int
        let height: Int
        let rgba: [UInt8]

        func at(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
            let i = (y * width + x) * 4
            return (Int(rgba[i]), Int(rgba[i + 1]), Int(rgba[i + 2]))
        }
    }

    private func pixels(_ image: CGImage) throws -> Pixels {
        let width = image.width
        let height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &buffer,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return Pixels(width: width, height: height, rgba: buffer)
    }

    /// Mean x of the red bar.
    private func barCentreX(_ p: Pixels) -> Double? {
        var xs: [Int] = []
        for y in 0..<p.height {
            for x in 0..<p.width {
                let c = p.at(x, y)
                if c.r > 140, c.g < 110, c.b < 110 { xs.append(x) }
            }
        }
        guard !xs.isEmpty else { return nil }
        return Double(xs.reduce(0, +)) / Double(xs.count)
    }

    /// Mean x of every separated text blob in the axis strip, left to right.
    /// Blobs rather than one centroid because the chart shows several labels
    /// and only one of them belongs to the bar.
    private func labelCentresX(_ p: Pixels) -> [Double] {
        let stripTop = Int(Double(p.height) * 0.86)
        var inked: [Int] = []
        for x in 0..<p.width {
            var hit = false
            for y in stripTop..<p.height where !hit {
                let c = p.at(x, y)
                if c.r < 190 && c.g < 190 && c.b < 190 { hit = true }
            }
            if hit { inked.append(x) }
        }
        guard !inked.isEmpty else { return [] }

        var blobs: [[Int]] = [[inked[0]]]
        for x in inked.dropFirst() {
            if x - blobs[blobs.count - 1].last! > 6 {
                blobs.append([x])
            } else {
                blobs[blobs.count - 1].append(x)
            }
        }
        return blobs.map { Double($0.reduce(0, +)) / Double($0.count) }
    }

    /// The bar's centre, and the centre of the label for the bar's OWN day.
    ///
    /// The bar deliberately sits on the middle mark, not the first: Charts
    /// nudges an edge label inward so it will not clip, and a bar at the plot
    /// edge therefore measures the nudge instead of the centring rule. An
    /// earlier version of this test put the bar on day 0 and produced a result
    /// that contradicted the shipped behaviour for exactly that reason.
    private func measure<Axis: AxisContent>(
        @AxisContentBuilder axis: @escaping () -> Axis
    ) throws -> (bar: Double, label: Double) {
        let image = try render(chart(axis: axis))
        let p = try pixels(image)
        let bar = try XCTUnwrap(barCentreX(p), "no red bar found in the render")
        let labels = labelCentresX(p)
        XCTAssertGreaterThanOrEqual(labels.count, 2,
                                    "expected several day labels, found \(labels.count)")
        // Index 1: the middle mark, which is the bar's own day.
        let label = try XCTUnwrap(labels.indices.contains(1) ? labels[1] : nil)
        return (bar, label)
    }

    // MARK: - The claim under test

    func testCentredLabelsDriftOffTheBarWhenMarksAreNotOneDayApart() throws {
        // The shipped-this-morning shape: marks a week apart, label centred.
        let marks = [day(0), day(Self.markStrideDays), day(Self.markStrideDays * 2)]
        let measured = try measure {
            AxisMarks(values: marks) { _ in
                AxisValueLabel(format: .dateTime.day(), centered: true)
                    .foregroundStyle(.black)
            }
        }

        let drift = measured.label - measured.bar
        // 21-day domain over ~420pt of plot is ~20pt/day, so half a 7-day step
        // is roughly 70pt to the RIGHT. Asserting only the direction and that
        // it is large, so the test does not encode plot insets.
        XCTAssertGreaterThan(drift, 30,
                             "centred label should sit well right of its bar "
                                 + "(measured drift \(drift)pt)")
    }

    func testMarkingTheDayCentrePutsTheLabelOnItsOwnBar() throws {
        let marks = AtriaChartVisualGrammar.dayCentreMarks(
            in: day0...day(21),
            targetCount: 3,
            calendar: calendar
        )
        let measured = try measure {
            AxisMarks(values: marks) { _ in
                AxisValueLabel(format: .dateTime.day())
                    .foregroundStyle(.black)
            }
        }

        let drift = abs(measured.label - measured.bar)
        XCTAssertLessThan(drift, 12,
                          "a noon mark should place the label on the bar it "
                              + "names (measured drift \(drift)pt)")
    }

    func testTheUncentredMidnightMarkSitsAtTheBarsLeadingEdge() throws {
        // The behaviour BEFORE this morning: bounded, but half a bar off.
        let marks = [day(0), day(Self.markStrideDays), day(Self.markStrideDays * 2)]
        let measured = try measure {
            AxisMarks(values: marks) { _ in
                AxisValueLabel(format: .dateTime.day())
                    .foregroundStyle(.black)
            }
        }

        let drift = measured.bar - measured.label
        XCTAssertGreaterThan(drift, 0,
                             "a midnight mark sits left of the bar's centre")
        XCTAssertLessThan(drift, 30,
                          "but only by about half a bar — the error this "
                              + "morning's change replaced with a much larger one")
    }
}
