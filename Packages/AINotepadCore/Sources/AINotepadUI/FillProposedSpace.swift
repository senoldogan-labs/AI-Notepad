import SwiftUI

/// Size of a view that takes exactly the space it is offered: a concrete proposed dimension (0 and infinity too) is the
/// size; an unspecified one comes from the content's own size (`contentSize`, measured only then). Pure function.
func fillingSize(proposal: ProposedViewSize, contentSize: CGSize?) -> CGSize {
    guard let width = proposal.width, let height = proposal.height else {
        guard let contentSize else {
            preconditionFailure("fillingSize: proposal \(proposal) has an unspecified dimension but no content size was measured")
        }
        return CGSize(width: proposal.width ?? contentSize.width, height: proposal.height ?? contentSize.height)
    }
    return CGSize(width: width, height: height)
}

/// Layout of `fillsProposedSpace()`: answers size queries with the proposal and places the content once with the final
/// size. SwiftUI stacks and `safeAreaInset` ask each child for its smallest and largest size (proposals of 0 and
/// infinity) before placing it; for a page that scrolls, that measures every text of the page at those widths on every
/// change (hundreds of milliseconds for a meeting page with a long note). A page that fills its column never needs
/// those answers.
private struct FillProposedSpaceLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let needsContent: Bool = proposal.width == nil || proposal.height == nil
        return fillingSize(proposal: proposal, contentSize: needsContent ? subviews.first?.sizeThatFits(proposal) ?? .zero : nil)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

public extension View {
    /// The view takes all the space its container offers without measuring its content for it (see
    /// `FillProposedSpaceLayout`). For page columns and scroll views that fill their place anyway
    /// (`.frame(maxWidth: .infinity, maxHeight: .infinity)`): their content is laid out once, at the final size.
    func fillsProposedSpace() -> some View {
        FillProposedSpaceLayout { self }
    }
}
