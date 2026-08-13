import Foundation
import CoreGraphics

/// Handoff-12 CP3: one pure, deterministic placement policy for plot-local
/// chart inspection cards. Swift Charts' wide top annotation could cover the
/// axes or escape the plot at the edges; this policy keeps a compact card
/// fully inside the plot frame, beside the selection when a side fits,
/// above/below it when neither side does, and never lets it leave the plot.
/// Portrait and landscape share the same math, so a fixture test can pin
/// every edge case without rendering.
struct AtriaChartPointerPlacement: Equatable {
    /// Top-left corner of the card in the same coordinate space as `plot`.
    let origin: CGPoint
    /// True when the card had to move above/below the anchor because neither
    /// horizontal side had room.
    let usedVerticalFallback: Bool

    /// Compact three-line inspection card metrics (time, score · zone, HR).
    static let defaultCardSize = CGSize(width: 132, height: 54)
    static let defaultInset: CGFloat = 8
    static let defaultGap: CGFloat = 10

    static func place(anchor: CGPoint,
                      plot: CGRect,
                      cardSize: CGSize = defaultCardSize,
                      inset: CGFloat = defaultInset,
                      gap: CGFloat = defaultGap) -> AtriaChartPointerPlacement {
        let minX = plot.minX + inset
        let maxX = plot.maxX - inset - cardSize.width
        let minY = plot.minY + inset
        let maxY = plot.maxY - inset - cardSize.height
        var usedVerticalFallback = false
        var origin = CGPoint(x: anchor.x + gap,
                             y: anchor.y - cardSize.height / 2)
        if origin.x > maxX {
            // Right side clips: try the left side.
            origin.x = anchor.x - gap - cardSize.width
        }
        if origin.x < minX {
            // Neither side fits (narrow plot or extreme edge): center on the
            // anchor horizontally, clamped, and move above — or below when
            // the top band has no room — so the card never covers the point.
            usedVerticalFallback = true
            origin.x = min(max(anchor.x - cardSize.width / 2, minX),
                           max(minX, maxX))
            origin.y = anchor.y - gap - cardSize.height
            if origin.y < minY {
                origin.y = anchor.y + gap
            }
        }
        origin.x = min(max(origin.x, minX), max(minX, maxX))
        origin.y = min(max(origin.y, minY), max(minY, maxY))
        return AtriaChartPointerPlacement(origin: origin,
                                          usedVerticalFallback: usedVerticalFallback)
    }

    /// Convenience for asserting containment in tests.
    static func frame(anchor: CGPoint,
                      plot: CGRect,
                      cardSize: CGSize = defaultCardSize,
                      inset: CGFloat = defaultInset,
                      gap: CGFloat = defaultGap) -> CGRect {
        let placement = place(anchor: anchor,
                              plot: plot,
                              cardSize: cardSize,
                              inset: inset,
                              gap: gap)
        return CGRect(origin: placement.origin, size: cardSize)
    }
}
