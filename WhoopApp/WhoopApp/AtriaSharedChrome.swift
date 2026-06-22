import SwiftUI

struct AtriaSegmentButtonStyle: ButtonStyle {
    let selected: Bool
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(selected ? Color.primary.opacity(colorScheme == .dark ? 0.98 : 0.96) : Color.secondary.opacity(colorScheme == .dark ? 0.88 : 0.92))
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(selectedFill)
                        .overlay {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(colorScheme == .dark ? Color.white.opacity(0.12) : Color.white.opacity(0.48), lineWidth: 1)
                        }
                }
            }
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
    }

    private var selectedFill: AnyShapeStyle {
        if colorScheme == .dark {
            return AnyShapeStyle(
                Color(red: 0.112, green: 0.126, blue: 0.158).opacity(0.98)
            )
        }
        return AnyShapeStyle(
            LinearGradient(colors: [
                Color.white.opacity(0.70),
                Color.white.opacity(0.42)
            ], startPoint: .topLeading, endPoint: .bottomTrailing)
        )
    }
}

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

private struct AtriaCardBackground: View {
    let cornerRadius: CGFloat
    let emphasis: AtriaPanelEmphasis

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(baseFill)
            .overlay(tintWash)
            .overlay(strokeShape)
    }

    private var baseFill: some ShapeStyle {
        AnyShapeStyle(AtriaDesignTokens.Surface.card(isDark: colorScheme == .dark, emphasis: emphasis))
    }

    @ViewBuilder
    private var tintWash: some View {
        if colorScheme == .dark {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.white.opacity(emphasis == .strong ? 0.018 : 0.010))
        } else {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(colors: [
                        Color.white.opacity(emphasis == .strong ? 0.22 : 0.14),
                        Color.blue.opacity(0.018),
                        Color.clear
                    ], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
        }
    }

    private var strokeShape: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .stroke(colorScheme == .dark ? Color.white.opacity(emphasis == .strong ? 0.06 : 0.045)
                                         : Color.white.opacity(emphasis == .strong ? 0.52 : 0.34),
                    lineWidth: 1)
    }
}

private struct AtriaRaisedCardBackground: View {
    let cornerRadius: CGFloat
    let emphasis: AtriaPanelEmphasis

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(baseFill)
            .overlay(tintWash)
            .overlay(strokeShape)
    }

    private var baseFill: some ShapeStyle {
        AnyShapeStyle(AtriaDesignTokens.Surface.raisedCard(isDark: colorScheme == .dark, emphasis: emphasis))
    }

    @ViewBuilder
    private var tintWash: some View {
        if colorScheme == .dark {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(colors: [
                        Color.white.opacity(emphasis == .strong ? 0.028 : 0.018),
                        Color.cyan.opacity(emphasis == .strong ? 0.016 : 0.008),
                        Color.clear
                    ], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
        } else {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(colors: [
                        Color.white.opacity(emphasis == .strong ? 0.16 : 0.10),
                        Color.blue.opacity(0.025),
                        Color.clear
                    ], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
        }
    }

    @ViewBuilder
    private var strokeShape: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .stroke(colorScheme == .dark ? Color.white.opacity(emphasis == .strong ? 0.08 : 0.055)
                                         : Color.white.opacity(emphasis == .strong ? 0.28 : 0.18),
                    lineWidth: 1)
    }
}

private struct AtriaInsetCardBackground: View {
    let cornerRadius: CGFloat
    let tint: Color

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(baseFill)
            .overlay(tintWash)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.10), lineWidth: 1)
            )
    }

    private var baseFill: some ShapeStyle {
        AnyShapeStyle(AtriaDesignTokens.Surface.inset(isDark: colorScheme == .dark))
    }

    @ViewBuilder
    private var tintWash: some View {
        if colorScheme == .dark {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(accentTint.opacity(0.028))
        } else {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(colors: [
                        tint.opacity(0.045),
                        Color.white.opacity(0.02)
                    ], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
        }
    }

    private var accentTint: Color {
        if tint == .white {
            return Color(red: 0.52, green: 0.76, blue: 0.98)
        }
        return tint
    }
}

struct AtriaIconTileBackground: View {
    let cornerRadius: CGFloat
    let tint: Color

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(baseFill)
            .overlay(tintWash)
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.14), lineWidth: 1)
            }
    }

    private var baseFill: some ShapeStyle {
        AnyShapeStyle(AtriaDesignTokens.Surface.inset(isDark: colorScheme == .dark))
    }

    @ViewBuilder
    private var tintWash: some View {
        if colorScheme == .dark {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(accentTint.opacity(0.035))
        } else {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(tint.opacity(0.06))
        }
    }

    private var accentTint: Color {
        if tint == .white {
            return Color(red: 0.55, green: 0.78, blue: 0.98)
        }
        return tint
    }
}

struct AtriaChecklistBadgeBackground: View {
    let tint: Color

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Circle()
            .fill(
                LinearGradient(colors: [
                    colorScheme == .dark ? Color.white.opacity(0.08) : Color.white.opacity(0.80),
                    colorScheme == .dark ? tint.opacity(0.16) : tint.opacity(0.10)
                ], startPoint: .topLeading, endPoint: .bottomTrailing)
            )
    }
}

extension View {
    @ViewBuilder
    func atriaRaisedCard(cornerRadius: CGFloat = AtriaDesignTokens.Radius.card,
                         emphasis: AtriaPanelEmphasis = .soft) -> some View {
        self
            .background {
                AtriaRaisedCardBackground(cornerRadius: cornerRadius, emphasis: emphasis)
            }
    }

    @ViewBuilder
    func atriaCard(cornerRadius: CGFloat = AtriaDesignTokens.Radius.card,
                   emphasis: AtriaPanelEmphasis = .soft) -> some View {
        self
            .background {
                AtriaCardBackground(cornerRadius: cornerRadius, emphasis: emphasis)
            }
    }

    @ViewBuilder
    func atriaGlassCapsule(tint: Color) -> some View {
        self.background(AtriaCapsuleChromeBackground(tint: tint))
    }

    func atraGlassIconChrome() -> some View {
        self
            .frame(width: 46, height: 46)
            .background(AtriaIconChromeBackground())
    }

    func atriaInsetCard(cornerRadius: CGFloat = AtriaDesignTokens.Radius.inset, tint: Color) -> some View {
        self
            .background {
                AtriaInsetCardBackground(cornerRadius: cornerRadius, tint: tint)
            }
    }
}

private struct AtriaCapsuleChromeBackground: View {
    let tint: Color

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Capsule(style: .continuous)
            .fill(baseFill)
            .glassEffect(.regular.tint(glassTint).interactive(), in: .capsule)
            .overlay(stroke)
    }

    private var baseFill: some ShapeStyle {
        if colorScheme == .dark {
            return AnyShapeStyle(
                Color(red: 0.084, green: 0.095, blue: 0.124).opacity(0.96)
            )
        }
        return AnyShapeStyle(Color.white.opacity(0.42))
    }

    private var glassTint: Color {
        colorScheme == .dark ? effectiveTint.opacity(0.025) : tint.opacity(0.12)
    }

    private var stroke: some View {
        Capsule(style: .continuous)
            .stroke(Color.white.opacity(colorScheme == .dark ? 0.07 : 0.16), lineWidth: 1)
    }

    private var effectiveTint: Color {
        if tint == .gray {
            return Color.white
        }
        return tint
    }
}

private struct AtriaIconChromeBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Circle()
            .fill(baseFill)
            .glassEffect(.regular.tint(colorScheme == .dark ? Color.white.opacity(0.06) : Color.white.opacity(0.16)).interactive(), in: .circle)
            .overlay(stroke)
    }

    private var baseFill: some ShapeStyle {
        if colorScheme == .dark {
            return AnyShapeStyle(
                Color(red: 0.086, green: 0.098, blue: 0.126).opacity(0.97)
            )
        }
        return AnyShapeStyle(Color.white.opacity(0.42))
    }

    @ViewBuilder
    private var tintWash: some View {
        if colorScheme == .dark {
            Circle()
                .fill(Color.white.opacity(0.016))
        }
    }

    private var stroke: some View {
        Circle()
            .stroke(Color.white.opacity(colorScheme == .dark ? 0.07 : 0.18), lineWidth: 1)
    }
}
