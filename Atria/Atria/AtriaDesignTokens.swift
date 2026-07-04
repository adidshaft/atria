import SwiftUI
import UIKit

enum AtriaPanelEmphasis {
    case soft
    case strong
}

enum AtriaDesignTokens {
    enum Radius {
        static let card: CGFloat = 28
        static let inset: CGFloat = 18

        static func concentric(parent: CGFloat = card, inset: CGFloat) -> CGFloat {
            max(8, parent - inset)
        }
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

        static func card(isDark: Bool, emphasis: AtriaPanelEmphasis) -> AnyShapeStyle {
            if isDark {
                return AnyShapeStyle(Color(uiColor: .secondarySystemGroupedBackground))
            }
            return AnyShapeStyle(Color(uiColor: .secondarySystemGroupedBackground))
        }

        static func raisedCard(isDark: Bool, emphasis: AtriaPanelEmphasis) -> AnyShapeStyle {
            if isDark {
                return AnyShapeStyle(Color(uiColor: .secondarySystemGroupedBackground))
            }
            return AnyShapeStyle(Color(uiColor: .secondarySystemGroupedBackground))
        }

        static func inset(isDark: Bool) -> AnyShapeStyle {
            if isDark {
                return AnyShapeStyle(Color(uiColor: .tertiarySystemFill))
            }
            return AnyShapeStyle(Color(uiColor: .tertiarySystemFill))
        }
    }
}
