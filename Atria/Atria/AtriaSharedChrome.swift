import SwiftUI

struct AtriaSegmentButtonStyle: ButtonStyle {
    let selected: Bool
    var tint: Color = .blue
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 18, style: .continuous) }

    func makeBody(configuration: Configuration) -> some View {
        Group {
            if reduceTransparency {
                configuration.label
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                    .background(
                        selected
                            ? AtriaDesignTokens.Surface.card(isDark: colorScheme == .dark, emphasis: .strong)
                            : AtriaDesignTokens.Surface.inset(isDark: colorScheme == .dark),
                        in: shape
                    )
                    .overlay {
                        shape.stroke(selected ? tint.opacity(0.58)
                                              : (colorScheme == .dark
                                                 ? Color.white.opacity(0.14)
                                                 : Color.black.opacity(0.14)),
                                     lineWidth: 1)
                    }
            } else if selected {
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
        .animation(reduceMotion ? nil : .snappy(duration: AtriaDesignTokens.Motion.quick), value: selected)
        // Haptics deliberately NOT here: a feedback modifier inside a reusable
        // ButtonStyle registers an engine observer per rendered segment. Owners
        // fire .selection once at their segment-change handler instead.
    }
}

/// Pressed feedback for tappable CARDS — glance tiles, metric tiles, and any
/// card whose whole surface is the button. `.plain` renders the label
/// untouched but gives the finger nothing back; a card that opens a sheet
/// should acknowledge the press the way the segment and icon buttons above
/// already do. Scale is gentler than theirs (a large surface at 0.94 lurches).
struct AtriaPressableCardStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(reduceMotion ? nil : .snappy(duration: AtriaDesignTokens.Motion.quick),
                       value: configuration.isPressed)
    }
}

struct AtriaGlassIconButtonStyle: ButtonStyle {
    var tint: Color = .blue
    // `size` is the visual glass diameter. The outer interaction frame remains
    // at least 44pt, so compact 28–38pt chrome does not create undersized taps.
    var size: CGFloat = 44
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let hitSize = max(size, 44)
        // Native Liquid Glass: a real translucent glass circle with a clearly
        // legible icon. No opaque white fill underneath — that turned the glass into
        // a flat white disc and hid the icon entirely.
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(foreground)
            .frame(width: size, height: size)
            .glassEffect(.regular.interactive(), in: .circle)
            .frame(width: hitSize, height: hitSize)
            .contentShape(Circle())
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(reduceMotion ? nil : .snappy(duration: AtriaDesignTokens.Motion.quick), value: configuration.isPressed)
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
            // off the background; the shadow is navy-tinted, not black, so it stays
            // in the palette. Dark mode separates by value, so no shadow there.
            .shadow(color: AtriaDesignTokens.Surface.elevationShadow(isDark: colorScheme == .dark),
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
            // off the background; the shadow is navy-tinted, not black, so it stays
            // in the palette. Dark mode separates by value, so no shadow there.
            .shadow(color: AtriaDesignTokens.Surface.elevationShadow(isDark: colorScheme == .dark),
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
    func atriaChromeCapsule(tint: Color, interactive: Bool = false) -> some View {
        self.background(AtriaCapsuleChromeBackground(tint: tint, interactive: interactive))
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

    /// The small uppercase label that heads a card section. One font, one
    /// tracking, one color, so every eyebrow in the app is the same element
    /// (see `AtriaDesignTokens.Typography.eyebrow`).
    func atriaEyebrow() -> some View {
        self
            .font(AtriaDesignTokens.Typography.eyebrow)
            .tracking(AtriaDesignTokens.Typography.eyebrowTracking)
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
    }
}

private struct AtriaCapsuleChromeBackground: View {
    let tint: Color
    let interactive: Bool

    var body: some View {
        // Native Liquid Glass supplies its own adaptive material. A custom
        // opaque fill below it flattens the refraction and adds overdraw.
        Capsule(style: .continuous)
            .fill(.clear)
            .glassEffect(.regular.tint(tint.opacity(0.10)).interactive(interactive),
                         in: Capsule(style: .continuous))
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
