import SwiftUI

struct AtriaGlassCapsuleButtonStyle: ButtonStyle {
    let tint: Color
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(foregroundColor.opacity(configuration.isPressed ? 0.92 : 1))
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .atriaGlassCapsule(tint: tint)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }

    private var foregroundColor: Color {
        colorScheme == .dark ? .white : .primary
    }
}

struct AtriaGlassIconButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(foregroundColor.opacity(configuration.isPressed ? 0.92 : 1))
            .atraGlassIconChrome()
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }

    private var foregroundColor: Color {
        colorScheme == .dark ? .white : .primary
    }
}

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

struct AtriaGlassIconSegmentStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline.weight(.semibold))
            .padding(.vertical, 10)
            .foregroundStyle(Color.primary.opacity(configuration.isPressed ? 0.88 : 1))
            .background {
                AtriaInsetTileBackground(cornerRadius: 14, tint: .white)
            }
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

enum AtriaPanelEmphasis {
    case soft
    case strong
}

private struct AtriaQuietPanelBackground: View {
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
        if colorScheme == .dark {
            return AnyShapeStyle(
                Color(red: 0.060, green: 0.071, blue: 0.092)
                    .opacity(emphasis == .strong ? 0.985 : 0.965)
            )
        }
        return AnyShapeStyle(
            LinearGradient(colors: [
                Color.white.opacity(emphasis == .strong ? 0.96 : 0.92),
                Color(red: 0.948, green: 0.958, blue: 0.982).opacity(emphasis == .strong ? 0.94 : 0.90)
            ], startPoint: .topLeading, endPoint: .bottomTrailing)
        )
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

private struct AtriaGlassPanelBackground: View {
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
        if colorScheme == .dark {
            return AnyShapeStyle(
                Color(red: 0.074, green: 0.088, blue: 0.116)
                    .opacity(emphasis == .strong ? 0.975 : 0.95)
            )
        }
        return AnyShapeStyle(
            emphasis == .strong ? .regularMaterial : .thinMaterial
        )
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

private struct AtriaInsetTileBackground: View {
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
        if colorScheme == .dark {
            return AnyShapeStyle(
                Color(red: 0.085, green: 0.097, blue: 0.126).opacity(0.955)
            )
        }
        return AnyShapeStyle(.ultraThinMaterial)
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
        if colorScheme == .dark {
            return AnyShapeStyle(
                Color(red: 0.092, green: 0.104, blue: 0.132).opacity(0.97)
            )
        }
        return AnyShapeStyle(.ultraThinMaterial)
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

struct AtriaSheetFooterBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Rectangle()
            .fill(
                colorScheme == .dark
                    ? AnyShapeStyle(Color(red: 0.040, green: 0.048, blue: 0.066).opacity(0.98))
                    : AnyShapeStyle(.thinMaterial)
            )
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color.white.opacity(colorScheme == .dark ? 0.10 : 0.14))
                    .frame(height: 1)
            }
    }
}

extension View {
    @ViewBuilder
    func atriaGlassPanel(cornerRadius: CGFloat = 28,
                         emphasis: AtriaPanelEmphasis = .soft) -> some View {
        self
            .background {
                AtriaGlassPanelBackground(cornerRadius: cornerRadius, emphasis: emphasis)
            }
    }

    @ViewBuilder
    func atriaQuietPanel(cornerRadius: CGFloat = 28,
                         emphasis: AtriaPanelEmphasis = .soft) -> some View {
        self
            .background {
                AtriaQuietPanelBackground(cornerRadius: cornerRadius, emphasis: emphasis)
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

    func atriaInsetTile(cornerRadius: CGFloat = 18, tint: Color) -> some View {
        self
            .background {
                AtriaInsetTileBackground(cornerRadius: cornerRadius, tint: tint)
            }
    }
}

private struct AtriaCapsuleChromeBackground: View {
    let tint: Color

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if #available(iOS 26, *) {
                Capsule(style: .continuous)
                    .fill(baseFill)
                    .glassEffect(.regular.tint(glassTint).interactive(), in: .capsule)
                    .overlay(stroke)
            } else {
                Capsule(style: .continuous)
                    .fill(baseFill)
                    .overlay(stroke)
            }
        }
    }

    private var baseFill: some ShapeStyle {
        if colorScheme == .dark {
            return AnyShapeStyle(
                Color(red: 0.084, green: 0.095, blue: 0.124).opacity(0.96)
            )
        }
        return AnyShapeStyle(.ultraThinMaterial)
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
        Group {
            if #available(iOS 26, *) {
                Circle()
                    .fill(baseFill)
                    .glassEffect(.regular.tint(colorScheme == .dark ? Color.white.opacity(0.06) : Color.white.opacity(0.16)).interactive(), in: .circle)
                    .overlay(stroke)
            } else {
                Circle()
                    .fill(baseFill)
                    .overlay(tintWash)
                    .overlay(stroke)
            }
        }
    }

    private var baseFill: some ShapeStyle {
        if colorScheme == .dark {
            return AnyShapeStyle(
                Color(red: 0.086, green: 0.098, blue: 0.126).opacity(0.97)
            )
        }
        return AnyShapeStyle(.ultraThinMaterial)
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
