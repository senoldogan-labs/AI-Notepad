import CoreGraphics
import Foundation

/// Height of a growing question field: the laid-out text's height, at least one line and at most `maxLines` lines,
/// rounded up to whole points. Pure function.
public func askInputHeight(usedHeight: CGFloat, lineHeight: CGFloat, maxLines: Int) -> CGFloat {
    ceil(min(max(usedHeight, lineHeight), lineHeight * CGFloat(maxLines)))
}
