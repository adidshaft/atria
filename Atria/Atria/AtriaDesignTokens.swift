import SwiftUI
import UIKit

enum AtriaPanelEmphasis {
    case soft
    case strong
}

enum AtriaDesignTokens {
    /// One radius scale for the whole app. Before this existed, the three main
    /// view files hardcoded 15 distinct corner-radius literals (8,9,10,11,12,13,
    /// 14,15,16,17,18,20,28...), so nested and adjacent surfaces never read as one
    /// system. Snap every surface to the nearest rung: chip < inset < tile < card
    /// < hero. `concentric` keeps an inset radius visually parallel to its parent.
    enum Radius {
        static let chip: CGFloat = 12
        static let inset: CGFloat = 18
        static let tile: CGFloat = 20
        static let card: CGFloat = 28
        static let hero: CGFloat = 32

        static func concentric(parent: CGFloat = card, inset: CGFloat) -> CGFloat {
            max(8, parent - inset)
        }
    }

    /// One spacing rhythm for padding and stack spacing. Before this, padding used
    /// ~20 raw values and stack spacing ~17, so vertical rhythm and inset generosity
    /// varied card-to-card. Snap to these rungs (4/8/12/16/20/28) for a consistent,
    /// generous feel. Names are size-ordered, not semantic, so any surface can pick.
    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 28
    }

    /// One motion rhythm. `.snappy` was already the house curve (56 call sites),
    /// but its duration had drifted across ten distinct values -- 0.12, 0.14,
    /// 0.18, 0.2, 0.22, 0.24, 0.25, 0.28, 0.3, 0.35 -- so comparable gestures
    /// resolved at visibly different speeds depending on which file they lived
    /// in. Nobody chose 0.24 over 0.25 on purpose; that tail is drift, not
    /// intent. Three tiers cover every real case, so pick by the SIZE of the
    /// move rather than by feel:
    ///   quick    -- press/toggle feedback on a single control
    ///   standard -- the default: reveals, selection changes, chip swaps
    ///   emphatic -- structural moves: drag reorder, section insert/remove
    /// Long ambient animations (breathing glows, ring fills) deliberately stay
    /// off this scale -- they are not interaction feedback.
    enum Motion {
        static let quick: Double = 0.14
        static let standard: Double = 0.2
        static let emphatic: Double = 0.3
    }

    enum Surface {
        static func appBackground(isDark: Bool) -> [Color] {
            if isDark {
                return [
                    Color(red: 0.018, green: 0.023, blue: 0.032),
                    Color(red: 0.024, green: 0.031, blue: 0.043),
                    Color(red: 0.016, green: 0.021, blue: 0.030)
                ]
            }
            return [
                Color(uiColor: .systemGroupedBackground),
                Color(uiColor: .secondarySystemGroupedBackground)
            ]
        }

        static func reducedTransparencyBackground(isDark: Bool) -> Color {
            isDark
                ? Color(red: 0.018, green: 0.023, blue: 0.032)
                : Color(uiColor: .systemGroupedBackground)
        }

        // The isDark/emphasis params are retained for call-site stability; the
        // underlying UIColors are already dynamic (dark/light aware), so both
        // branches resolved to the same style — collapsed to one return.
        static func card(isDark: Bool, emphasis: AtriaPanelEmphasis) -> AnyShapeStyle {
            AnyShapeStyle(Color(uiColor: .secondarySystemGroupedBackground))
        }

        static func raisedCard(isDark: Bool, emphasis: AtriaPanelEmphasis) -> AnyShapeStyle {
            AnyShapeStyle(Color(uiColor: .secondarySystemGroupedBackground))
        }

        static func inset(isDark: Bool) -> AnyShapeStyle {
            AnyShapeStyle(Color(uiColor: .tertiarySystemFill))
        }
    }
}
