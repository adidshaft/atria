import SwiftUI
import UIKit

/// Renders the tri-ring hero -- exactly as the user has it configured on
/// Today -- as a shareable picture. Follows the same `ImageRenderer`
/// story-card pattern as `AtriaFaceOff.renderStoryImage()`: a fixed-size
/// off-screen SwiftUI view rendered at 2x into a `UIImage`, so it can be
/// handed straight to a `ShareLink`.
///
/// No identifying data beyond the three metrics already visible on the
/// Today screen -- no name, no device/strap identifiers, no location.
enum AtriaRingShare {
    /// 540x675pt canvas @2x = 1080x1350px -- a standard portrait story
    /// aspect ratio (4:5).
    static let canvasSize = CGSize(width: 540, height: 675)

    struct Content {
        /// Resolved ring content -- whichever metrics the user has assigned
        /// to each ring position (ring-metric-picker migration), rendered
        /// exactly as configured on Today.
        let slots: [AtriaTriRingSlotContent]
        let centerValue: String
        let centerState: String
        let dateText: String
    }

    @MainActor
    static func renderImage(_ content: Content) -> UIImage? {
        let renderer = ImageRenderer(content: ShareCard(content: content))
        renderer.scale = 2
        return renderer.uiImage
    }
}

/// Dark, Liquid-Glass-look story card: a soft dark gradient (the same family
/// of near-black tones `AtriaDesignTokens.Surface.appBackground` uses for
/// this app's dark theme) standing in for a glass backdrop, since a real
/// blurred/refractive material has nothing to sit on top of in an
/// off-screen render.
private struct ShareCard: View {
    let content: AtriaRingShare.Content

    var body: some View {
        VStack(spacing: 22) {
            Text(content.dateText.uppercased())
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .tracking(2)
                .foregroundStyle(.white.opacity(0.55))
                .padding(.top, 44)

            Spacer(minLength: 0)

            AtriaTriRing(slots: content.slots,
                         centerValue: content.centerValue,
                         centerState: content.centerState,
                         accessibilitySummary: "",
                         actions: [:])
                .scaleEffect(1.3)

            Spacer(minLength: 0)

            Text("Atria")
                .font(.system(size: 22, weight: .heavy, design: .rounded))
                .tracking(3)
                .foregroundStyle(.white.opacity(0.85))
                .padding(.bottom, 40)
        }
        .frame(width: AtriaRingShare.canvasSize.width, height: AtriaRingShare.canvasSize.height)
        .background(
            LinearGradient(colors: [Color(red: 0.05, green: 0.07, blue: 0.14),
                                    Color(red: 0.015, green: 0.02, blue: 0.045)],
                           startPoint: .top,
                           endPoint: .bottom)
        )
        .environment(\.colorScheme, .dark)
    }
}
