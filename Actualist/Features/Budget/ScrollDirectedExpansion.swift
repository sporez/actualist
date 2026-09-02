import CoreGraphics

/// Expands on scroll-up / top, and collapses on scroll-down.
///
/// iOS does not publish whether the system tab bar is minimized. This follows
/// the same public scroll direction the tab bar uses for `.onScrollDown`.
///
/// `onScrollGeometryChange` reports per-frame deltas of a few points. A large
/// per-callback threshold only trips on rubber-band jumps at the ends.
struct ScrollDirectedExpansion: Equatable {
    var isExpanded: Bool = true

    static let defaultThreshold: CGFloat = 1

    mutating func update(
        previousOffset: CGFloat,
        offset: CGFloat,
        maxOffset: CGFloat,
        threshold: CGFloat = Self.defaultThreshold
    ) {
        if maxOffset <= 0 || offset <= 0 {
            isExpanded = true
            return
        }

        let delta = offset - previousOffset
        guard abs(delta) >= threshold else {
            return
        }

        // Bottom rubber-band overshoots maxOffset, then springs back. That
        // spring-back is an upward delta but is not a user scroll-up.
        if max(previousOffset, offset) > maxOffset {
            isExpanded = false
            return
        }

        isExpanded = delta < 0
    }
}

struct ScrollDirectedExpansionSample: Equatable {
    var offset: CGFloat
    var maxOffset: CGFloat
}
