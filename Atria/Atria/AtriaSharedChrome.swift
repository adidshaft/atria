import SwiftUI

struct AtriaSegmentButtonStyle: ButtonStyle {
    let selected: Bool
    var tint: Color = .blue
    @Environment(\.colorScheme) private var colorScheme

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 18, style: .continuous) }

    func makeBody(configuration: Configuration) -> some View {
        Group {
            if selected {
                // Selected: a real tinted Liquid Glass capsule, not an opaque fill.
                configuration.label
                    .foregroundStyle(Color.primary.opacity(colorScheme == .dark ? 0.98 : 0.96))
                    .glassEffect(.regular.tint(tint.opacity(colorScheme == .dark ? 0.42 : 0.26)).interactive(),
                                 in: shape)
                    .overlay {
                        shape.stroke(tint.opacity(colorScheme == .dark ? 0.55 : 0.45), lineWidth: 1)
                    }
            } else {
                // Unselected: a calm, clearly-tappable chip — distinct from selected.
                configuration.label
                    .foregroundStyle(Color.secondary.opacity(colorScheme == .dark ? 0.88 : 0.92))
                    .background(
                        (colorScheme == .dark ? Color.white.opacity(0.05) : Color.black.opacity(0.035)),
                        in: shape
                    )
                    .overlay {
                        shape.stroke(colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.10),
                                     lineWidth: 1)
                    }
            }
        }
        .scaleEffect(configuration.isPressed ? 0.97 : 1)
        .animation(.snappy(duration: 0.14), value: selected)
        // Haptics deliberately NOT here: a feedback modifier inside a reusable
        // ButtonStyle registers an engine observer per rendered segment. Owners
        // fire .selection once at their segment-change handler instead.
    }
}

struct AtriaGlassIconButtonStyle: ButtonStyle {
    var tint: Color = .blue
    // HIG-compliant default (2026-07-05): 44pt is the minimum tap target. Every
    // current call site passes an explicit size, so this only governs future
    // buttons — the existing sub-44 sizes are intentional in tight rows and need
    // per-screen visual review before changing, not a blind global bump.
    var size: CGFloat = 44

    func makeBody(configuration: Configuration) -> some View {
        // Native Liquid Glass: a real translucent glass circle with a clearly
        // legible icon. No opaque white fill underneath — that turned the glass into
        // a flat white disc and hid the icon entirely.
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(foreground)
            .frame(width: size, height: size)
            .glassEffect(.regular.interactive(), in: .circle)
            .contentShape(Circle())
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.snappy(duration: 0.12), value: configuration.isPressed)
    }

    private var foreground: Color {
        // `.secondary` icons vanish on glass — fall back to a fully legible primary.
        tint == .secondary ? .primary : tint
    }
}

private struct AtriaCardBackground: View {
    let cornerRadius: CGFloat
    let emphasis: AtriaPanelEmphasis

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(baseFill)
            .overlay(strokeShape)
            // Light-mode cards are opaque white on a near-white canvas — without a
            // soft drop shadow they read as washed-out. A subtle elevation lifts them
            // off the background. Dark mode separates by value, so no shadow there.
            .shadow(color: colorScheme == .dark ? .clear : .black.opacity(0.06),
                    radius: 10, x: 0, y: 4)
    }

    private var baseFill: AnyShapeStyle {
        AtriaDesignTokens.Surface.card(isDark: colorScheme == .dark, emphasis: emphasis)
    }

    private var strokeShape: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .stroke(colorScheme == .dark ? Color.white.opacity(emphasis == .strong ? 0.06 : 0.045)
                                         : Color.black.opacity(emphasis == .strong ? 0.12 : 0.08),
                    lineWidth: 1)
    }
}

/// Real iOS 26 Liquid Glass surface for CONTENT cards. Opt-in on purpose: it is
/// meant to be applied hero/prominent-first, NOT flipped onto every scrolling
/// tile, because dense glass in a scroll view is GPU-costly — the reason large
/// content cards deliberately shipped static fills (see the capsule-chrome note
/// below). Honors Reduce Transparency by falling back to the opaque card so the
/// surface is never unreadable. Nothing consumes this yet; apply + verify scroll
/// performance and legibility on-device before any broad rollout.
private struct AtriaGlassCardBackground: View {
    let cornerRadius: CGFloat
    let emphasis: AtriaPanelEmphasis

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if reduceTransparency {
            AtriaCardBackground(cornerRadius: cornerRadius, emphasis: emphasis)
        } else {
            shape
                .fill(Color.clear)
                .glassEffect(.regular, in: shape)
                .overlay {
                    shape.stroke(colorScheme == .dark
                                 ? Color.white.opacity(emphasis == .strong ? 0.10 : 0.07)
                                 : Color.black.opacity(emphasis == .strong ? 0.12 : 0.08),
                                 lineWidth: 1)
                }
        }
    }
}

private struct AtriaRaisedCardBackground: View {
    let cornerRadius: CGFloat
    let emphasis: AtriaPanelEmphasis

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(baseFill)
            .overlay(strokeShape)
            // Light-mode cards are opaque white on a near-white canvas — without a
            // soft drop shadow they read as washed-out. A subtle elevation lifts them
            // off the background. Dark mode separates by value, so no shadow there.
            .shadow(color: colorScheme == .dark ? .clear : .black.opacity(0.06),
                    radius: 10, x: 0, y: 4)
    }

    private var baseFill: AnyShapeStyle {
        AtriaDesignTokens.Surface.raisedCard(isDark: colorScheme == .dark, emphasis: emphasis)
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
    /// Opt-in identity-forward chip surface. When true, the card carries a
    /// visible wash + border in its metric hue (design-handoff "metric chip"
    /// look — one identity hue per metric, on the surface itself, not just the
    /// icon). Off by default so the ~100 existing neutral inset cards keep the
    /// deliberately-subtle gray surface. Kept restrained (well under the
    /// handoff's 0.12/0.25) to honor Atria's "Liquid Glass stays quiet" rule.
    var hueTinted: Bool = false

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(baseFill)
            .overlay(tintWash)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(strokeColor, lineWidth: 1)
            )
    }

    private var baseFill: AnyShapeStyle {
        AtriaDesignTokens.Surface.inset(isDark: colorScheme == .dark)
    }

    private var strokeColor: Color {
        if hueTinted {
            // Identity-hue hairline, matching the handoff's tinted-border chips.
            return colorScheme == .dark ? tint.opacity(0.22) : tint.opacity(0.28)
        }
        return colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.09)
    }

    @ViewBuilder
    private var tintWash: some View {
        if hueTinted {
            // A gentle top-lit hue wash so the chip reads as its metric's color
            // at a glance, without the flat saturated block the raw handoff uses.
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(colors: [
                        tint.opacity(colorScheme == .dark ? 0.14 : 0.10),
                        tint.opacity(colorScheme == .dark ? 0.05 : 0.03)
                    ], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
        } else if colorScheme == .dark {
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

    private var baseFill: AnyShapeStyle {
        AtriaDesignTokens.Surface.inset(isDark: colorScheme == .dark)
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

    /// Opt-in Liquid Glass content-card surface (see AtriaGlassCardBackground).
    /// Use for hero/prominent cards; verify scroll performance before applying to
    /// dense scrolling tiles.
    @ViewBuilder
    func atriaGlassCard(cornerRadius: CGFloat = AtriaDesignTokens.Radius.card,
                        emphasis: AtriaPanelEmphasis = .soft) -> some View {
        self
            .background {
                AtriaGlassCardBackground(cornerRadius: cornerRadius, emphasis: emphasis)
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

    /// `hueTinted` opts a card into the identity-forward "metric chip" surface
    /// (visible hue wash + hue hairline border, from the design handoff). Leave
    /// it false — the default — for every neutral inset card; turn it on only
    /// for small single-metric tiles whose whole job is to signal one hue.
    func atriaInsetCard(cornerRadius: CGFloat = AtriaDesignTokens.Radius.inset,
                        tint: Color,
                        hueTinted: Bool = false) -> some View {
        self
            .background {
                AtriaInsetCardBackground(cornerRadius: cornerRadius, tint: tint, hueTinted: hueTinted)
            }
    }

    @ViewBuilder
    func atriaCardAction(prominent: Bool = true, tint: Color = .blue) -> some View {
        // Standard native iOS 26 Liquid Glass: .glassProminent for the one primary
        // action, .glass for secondary actions. The system handles translucency,
        // press highlight, and shape — no hand-rolled fill-under-glass.
        if prominent {
            self.tint(tint).buttonStyle(.glassProminent)
        } else {
            self.tint(tint).buttonStyle(.glass)
        }
    }

    func atriaGlassIconAction(tint: Color = .blue, size: CGFloat = 44) -> some View {
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
