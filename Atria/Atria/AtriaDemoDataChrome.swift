import SwiftUI

/// Persistent, consistent marking for every demo-derived surface.
struct AtriaSampleDataBadge: View {
    var compact: Bool = false

    var body: some View {
        Label(
            compact ? AtriaAppReviewDemo.bannerTitle : AtriaAppReviewDemo.bannerDetail,
            systemImage: "checkmark.shield.fill"
        )
        .font(compact ? .caption2.weight(.semibold) : .footnote.weight(.semibold))
        .padding(.horizontal, compact ? 8 : 12)
        .padding(.vertical, compact ? 4 : 8)
        .background(.ultraThinMaterial, in: Capsule())
        .accessibilityIdentifier("atria.demo.sample-data-badge")
        .accessibilityLabel(AtriaAppReviewDemo.bannerDetail)
    }
}

extension View {
    /// Sample-data mark that stays visible when a sheet covers the top banner.
    @ViewBuilder
    func atriaDemoSampleBadge() -> some View {
        if AtriaAppReviewDemo.isActive {
            self.safeAreaInset(edge: .top, spacing: 0) {
                AtriaSampleDataBadge(compact: true)
                    .padding(.top, 6)
                    .frame(maxWidth: .infinity)
            }
        } else {
            self
        }
    }
}

struct AtriaDemoDataBanner: View {
    var onErase: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            AtriaSampleDataBadge()
            Spacer(minLength: 8)
            Button(AtriaAppReviewDemo.eraseAndReturnTitle, action: onErase)
                .font(.footnote.weight(.bold))
                .accessibilityIdentifier("atria.demo.erase-and-return")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .accessibilityElement(children: .contain)
    }
}
