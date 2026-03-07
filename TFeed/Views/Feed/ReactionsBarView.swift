import SwiftUI

struct ReactionsBarView: View {
    let reactions: [FeedItem.Reaction]
    private let chipSpacing: CGFloat = 6

    var body: some View {
        if !reactions.isEmpty {
            WrappingFlowLayout(spacing: chipSpacing, rowSpacing: chipSpacing) {
                ForEach(reactions, id: \.emoji) { reaction in
                    HStack(spacing: 4) {
                        Text(reaction.emoji)
                        Text("\(reaction.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .glassEffect(.regular, in: .capsule)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct WrappingFlowLayout: Layout {
    let spacing: CGFloat
    let rowSpacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var currentRowWidth: CGFloat = 0
        var currentRowHeight: CGFloat = 0
        var measuredWidth: CGFloat = 0
        var measuredHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let spacingBefore = currentRowWidth == 0 ? 0 : spacing

            if currentRowWidth > 0, currentRowWidth + spacingBefore + size.width > maxWidth {
                measuredWidth = max(measuredWidth, currentRowWidth)
                measuredHeight += currentRowHeight + rowSpacing
                currentRowWidth = 0
                currentRowHeight = 0
            }

            let appliedSpacing = currentRowWidth == 0 ? 0 : spacing
            currentRowWidth += appliedSpacing + size.width
            currentRowHeight = max(currentRowHeight, size.height)
        }

        if currentRowHeight > 0 {
            measuredWidth = max(measuredWidth, currentRowWidth)
            measuredHeight += currentRowHeight
        }

        return CGSize(
            width: proposal.width ?? measuredWidth,
            height: measuredHeight
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var currentRowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)

            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += currentRowHeight + rowSpacing
                currentRowHeight = 0
            }

            subview.place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )

            x += size.width + spacing
            currentRowHeight = max(currentRowHeight, size.height)
        }
    }
}
