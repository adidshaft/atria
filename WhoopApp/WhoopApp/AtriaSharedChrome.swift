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
    func atriaChromeCapsule(tint: Color) -> some View {
        self.background(AtriaCapsuleChromeBackground(tint: tint))
    }

    func atriaChromeIcon() -> some View {
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
        // Static chrome — no .interactive(): these chips are decorative and
        // appear on every card header, so live touch-refraction would resample
        // the moving backdrop on every scrolled frame and cause jank.
        Capsule(style: .continuous)
            .glassEffect(.regular.tint(glassTint), in: .capsule)
            .overlay(stroke)
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
            .glassEffect(.regular.tint(colorScheme == .dark ? Color.white.opacity(0.06) : Color.white.opacity(0.16)), in: .circle)
            .overlay(stroke)
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
