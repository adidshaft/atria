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
            return Color(red: 0.965, green: 0.972, blue: 0.988)
                .opacity(emphasis == .strong ? 0.98 : 0.94)
        }

        static func raisedCard(isDark: Bool, emphasis: AtriaPanelEmphasis) -> Color {
            if isDark {
                return Color(red: 0.074, green: 0.088, blue: 0.116)
                    .opacity(emphasis == .strong ? 0.975 : 0.95)
            }
            return Color(red: 0.985, green: 0.989, blue: 0.996)
                .opacity(emphasis == .strong ? 0.98 : 0.95)
        }

        static func inset(isDark: Bool) -> Color {
            isDark
                ? Color(red: 0.085, green: 0.097, blue: 0.126).opacity(0.955)
                : Color(red: 0.940, green: 0.950, blue: 0.970).opacity(0.96)
        }
    }
}
