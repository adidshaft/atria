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
            // ~1% white wash is invisible on the dark UI; drop the extra layer.
            EmptyView()
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
                                         : Color.black.opacity(emphasis == .strong ? 0.12 : 0.08),
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
            EmptyView()
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
                                         : Color.black.opacity(emphasis == .strong ? 0.10 : 0.07),
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
                    .stroke(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.09), lineWidth: 1)
            )
    }

    private var baseFill: some ShapeStyle {
        AnyShapeStyle(AtriaDesignTokens.Surface.inset(isDark: colorScheme == .dark))
    }

    @ViewBuilder
    private var tintWash: some View {
        if colorScheme == .dark {
            // ~3% tint is invisible on the dark UI; skip the extra rounded-rect
            // layer so scrolling cards have less overdraw.
            EmptyView()
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
                    .stroke(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.10), lineWidth: 1)
            }
    }

    private var baseFill: some ShapeStyle {
        AnyShapeStyle(AtriaDesignTokens.Surface.inset(isDark: colorScheme == .dark))
    }

    @ViewBuilder
    private var tintWash: some View {
        if colorScheme == .dark {
            EmptyView()
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
        // Decorative chrome that appears on every card header — use a cheap
        // translucent fill, NOT .glassEffect. Liquid Glass is GPU-expensive and
        // belongs on floating navigation/controls (the system tab bar and live
        // accessory already use it); a dozen live glass passes inside a scroll
        // is the main cause of scroll jank, including in the Simulator.
        Capsule(style: .continuous)
            .fill(fillColor)
            .overlay(stroke)
    }

    private var fillColor: Color {
        colorScheme == .dark
            ? effectiveTint.opacity(0.16)
            : tint.opacity(0.14)
    }

    private var stroke: some View {
        Capsule(style: .continuous)
            .stroke(colorScheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.12), lineWidth: 1)
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
        // Cheap translucent fill instead of a per-icon glass pass (see capsule note).
        Circle()
            .fill(colorScheme == .dark ? Color.white.opacity(0.07) : Color.white.opacity(0.55))
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
            .stroke(colorScheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.12), lineWidth: 1)
    }
}
