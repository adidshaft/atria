import SwiftUI

enum AtriaPanelEmphasis {
    case soft
    case strong
}

enum AtriaDesignTokens {
    enum Radius {
        static let card: CGFloat = 28
        static let inset: CGFloat = 18
    }

    enum Surface {
        static func card(isDark: Bool, emphasis: AtriaPanelEmphasis) -> Color {
            if isDark {
                return Color(red: 0.060, green: 0.071, blue: 0.092)
                    .opacity(emphasis == .strong ? 0.985 : 0.965)
            }
            // Light mode: opaque near-white cards that float above the gray-blue
            // field (native grouped style). The previous translucent off-white
            // blended into the backdrop and read washed-out.
            return Color(red: 1.0, green: 1.0, blue: 1.0)
        }

        static func raisedCard(isDark: Bool, emphasis: AtriaPanelEmphasis) -> Color {
            if isDark {
                return Color(red: 0.074, green: 0.088, blue: 0.116)
                    .opacity(emphasis == .strong ? 0.975 : 0.95)
            }
            return Color(red: 1.0, green: 1.0, blue: 1.0)
        }

        static func inset(isDark: Bool) -> Color {
            isDark
                ? Color(red: 0.085, green: 0.097, blue: 0.126).opacity(0.955)
                // Recessed within a white card: a soft cool gray reads as inset.
                : Color(red: 0.926, green: 0.938, blue: 0.960)
        }
    }
}
