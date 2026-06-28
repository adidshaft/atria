import SwiftUI

struct AtriaSegmentButtonStyle: ButtonStyle {
    let selected: Bool
    var tint: Color = .blue
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
                tint.opacity(0.10)
            ], startPoint: .topLeading, endPoint: .bottomTrailing)
        )
    }
}

struct AtriaCardActionButtonStyle: ButtonStyle {
    var prominent = true
    var tint: Color = .blue
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(fill)
                    .glassEffect(.regular.tint(tint.opacity(prominent ? 0.16 : 0.08)).interactive(),
                                 in: .rect(cornerRadius: 13))
                    .overlay {
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .stroke(stroke, lineWidth: 1)
                    }
            }
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.snappy(duration: 0.12), value: configuration.isPressed)
    }

    private var foreground: Color {
        if prominent { return colorScheme == .dark ? .white : .primary }
        return colorScheme == .dark ? Color.white.opacity(0.86) : .secondary
    }

    private var fill: AnyShapeStyle {
        if prominent {
            return AnyShapeStyle(
                LinearGradient(colors: [
                    colorScheme == .dark ? tint.opacity(0.30) : tint.opacity(0.16),
                    colorScheme == .dark ? Color.white.opacity(0.07) : Color.white.opacity(0.62)
                ], startPoint: .topLeading, endPoint: .bottomTrailing)
            )
        }
        return AnyShapeStyle(colorScheme == .dark ? Color.white.opacity(0.055) : Color.white.opacity(0.54))
    }

    private var stroke: Color {
        colorScheme == .dark ? Color.white.opacity(prominent ? 0.10 : 0.07)
                             : Color.black.opacity(prominent ? 0.12 : 0.09)
    }
}

struct AtriaGlassIconButtonStyle: ButtonStyle {
    var tint: Color = .blue
    var size: CGFloat = 38
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(foreground)
            .frame(width: size, height: size)
            .background {
                Circle()
                    .fill(fill)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .overlay {
                        Circle()
                            .stroke(stroke, lineWidth: 1)
                    }
            }
            .contentShape(Circle())
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.snappy(duration: 0.12), value: configuration.isPressed)
    }

    private var foreground: Color {
        tint == .secondary ? .secondary : tint
    }

    private var fill: AnyShapeStyle {
        AnyShapeStyle(
            LinearGradient(colors: [
                colorScheme == .dark ? Color.white.opacity(0.075) : Color.white.opacity(0.72),
                colorScheme == .dark ? tint.opacity(0.18) : tint.opacity(0.10)
            ], startPoint: .topLeading, endPoint: .bottomTrailing)
        )
    }

    private var stroke: Color {
        colorScheme == .dark ? Color.white.opacity(0.09) : Color.black.opacity(0.10)
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

    func atriaCardAction(prominent: Bool = true, tint: Color = .blue) -> some View {
        self.buttonStyle(AtriaCardActionButtonStyle(prominent: prominent, tint: tint))
    }

    func atriaGlassIconAction(tint: Color = .blue, size: CGFloat = 38) -> some View {
        self.buttonStyle(AtriaGlassIconButtonStyle(tint: tint, size: size))
    }
}

private struct AtriaCapsuleChromeBackground: View {
    let tint: Color

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // Keep this to compact chrome only. Large content cards still use static
        // material fills so scrolling stays smooth while controls feel native.
        Capsule(style: .continuous)
            .fill(fillColor)
            .glassEffect(.regular.tint(tint.opacity(0.10)), in: Capsule(style: .continuous))
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
