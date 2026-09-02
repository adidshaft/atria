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

    /// One type scale for data surfaces.
    ///
    /// MEASURED 2026-08-26: the app renders `.caption` 1,191 times and
    /// `.caption2` 524 times, against `.body` 64 and `.largeTitle` once. Almost
    /// every string is caption-sized, so nothing leads and nothing recedes and
    /// a tile of three near-identical lines has to be read word by word. The
    /// owner's report was "too much literature across the app which makes app
    /// very congested to digest data" — the volume is a symptom; the missing
    /// hierarchy is the cause.
    ///
    /// Three roles, in the order the eye should hit them:
    ///   value   -- the number. Large, heavy, TABULAR so digits do not jitter
    ///              between refreshes, and tracked tight because large digits
    ///              set loose read as separate glyphs.
    ///   label   -- what the number is. Medium weight carries hierarchy without
    ///              a second size step.
    ///   caption -- provenance/qualifier ONLY. If a caption merely restates the
    ///              label, delete it rather than restyle it; that is what
    ///              actually reduces the literature.
    enum Typography {
        static let metricValue = Font.system(
            .title2, design: .rounded, weight: .semibold
        ).monospacedDigit()
        static let metricValueCompact = Font.system(
            .title3, design: .rounded, weight: .semibold
        ).monospacedDigit()
        static let metricLabel = Font.subheadline.weight(.medium)
        static let metricCaption = Font.caption2

        /// Large digits set at default tracking read as loose, separate
        /// glyphs; pair this with `metricValue` on hero numbers.
        static let valueTracking: CGFloat = -0.5

        /// Eyebrow: the small uppercase label that heads a card section
        /// ("LOGGED CONTEXT", "TONIGHT'S WINDOW"). Uppercase set at default
        /// tracking clumps; a little positive tracking is what makes small
        /// caps read as a quiet label rather than a shout. MEASURED 2026-09-02:
        /// 13 sites hand-set caption/caption2 x semibold/bold with no tracking
        /// while the chart-grammar eyebrows next to them were tracked, so the
        /// same element read two ways on one screen. Apply via `.atriaEyebrow()`.
        static let eyebrow = Font.caption2.weight(.semibold)
        static let eyebrowTracking: CGFloat = 0.8

        /// Smallest fixed-size text the app sets. Below 11pt SwiftUI's
        /// `.caption2` no longer has a Dynamic Type peer, and 8-9pt labels
        /// neither scale for larger-text users nor stay legible on a wrist-
        /// sized tile. Chart-internal axis labels are the one exception (they
        /// are geometry-constrained); everything else should use `.caption2`.
        static let minimumLabel = Font.caption2
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
            // MEASURED 2026-09-02 (light Vitals screenshot): this gradient used
            // to end in secondarySystemGroupedBackground — pure white — so every
            // white card in the lower half of a screen sat on a white field:
            // tile interior 255, gap between tiles 255, field 255. Cards only
            // exist if the field is not their color. The field now stays a cool
            // off-white end to end (the same navy family as the dark backdrop
            // and the elevation shadow), so the white cards read as cards on
            // every screen, not just near the top-left.
            return [
                Color(uiColor: .systemGroupedBackground),
                Color(red: 0.925, green: 0.930, blue: 0.955)
            ]
        }

        static func reducedTransparencyBackground(isDark: Bool) -> Color {
            isDark
                ? Color(red: 0.018, green: 0.023, blue: 0.032)
                : Color(uiColor: .systemGroupedBackground)
        }

        /// Light-mode card elevation. A pure-black shadow on a cool near-white
        /// canvas reads as a gray smudge; tinting it toward the same deep navy
        /// the dark backdrop is built from keeps the shadow inside the palette
        /// and makes the lift read as ambient light, not dirt. Dark mode
        /// separates surfaces by value, so it casts nothing.
        static func elevationShadow(isDark: Bool) -> Color {
            isDark ? .clear : Color(red: 0.07, green: 0.11, blue: 0.20).opacity(0.08)
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
