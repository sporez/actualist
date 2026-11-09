import SwiftUI

/// Hosts a review sheet offered at `.medium` and `.large`, and grows it to
/// `.large` when its scroll content does not fit at `.medium`. A row-count
/// guess cannot do this: the medium detent is half the screen, so the same
/// rows fit on one iPhone and overflow on a shorter one (iPhone Duo's front
/// screen, iPhone SE) or at a larger text size.
///
/// The selected detent lives here rather than in the sheet's own view: a
/// sheet ignores a programmatic detent change when a child `.sheet` closure
/// captures the view that applies `presentationDetents` (observed on iOS 26.3
/// and 27.2), and review sheets present pickers from their own body.
struct OverflowExpandingReviewSheet<Content: View>: View {
    @State private var detent: PresentationDetent = .medium
    @State private var expansion = SheetOverflowExpansion()
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .onScrollGeometryChange(for: SheetOverflowExpansion.Fit.self) { geometry in
                SheetOverflowExpansion.Fit(geometry)
            } action: { _, fit in
                expansion.record(fit, at: detent)
            }
            .reviewSheetDetents([.medium, .large], selection: $detent)
            .onChange(of: detent) { _, detent in
                expansion.detentDidChange(to: detent)
            }
            .task(id: expansion.isGrowing) {
                if expansion.isGrowing {
                    await growToLarge()
                }
            }
    }

    /// SwiftUI drops a detent change sent in the first moments of the sheet's
    /// presentation (up to about 120 ms on the simulator) and reports neither
    /// the drop nor the end of the presentation. The scroll container growing
    /// is the only confirmation, so the request repeats until it arrives. The
    /// task is cancelled as soon as growing ends.
    private func growToLarge() async {
        for _ in 0..<SheetOverflowExpansion.growAttempts {
            detent = .large
            // A request that takes reports the taller container within a few
            // milliseconds, well inside this wait.
            guard await pause(for: SheetOverflowExpansion.growConfirmationWait), expansion.isGrowing else {
                return
            }
            // The request was dropped. Step back so the next one is a change.
            detent = .medium
            guard await pause(for: SheetOverflowExpansion.growRearmWait) else { return }
        }
        expansion.stopGrowing()
    }

    private func pause(for duration: Duration) async -> Bool {
        do {
            try await Task.sleep(for: duration)
            return true
        } catch {
            return false
        }
    }
}

/// Decides when a `[.medium, .large]` sheet grows to `.large`. It grows at
/// most once, and never after it has been at `.large`, so a user who drags it
/// back down keeps the height they chose.
struct SheetOverflowExpansion: Equatable {
    static let growAttempts = 12
    static let growConfirmationWait = Duration.milliseconds(120)
    static let growRearmWait = Duration.milliseconds(40)

    /// Scroll content height and the height it can use without scrolling,
    /// in points.
    struct Fit: Equatable {
        var contentHeight: CGFloat
        var containerHeight: CGFloat

        /// `ScrollGeometry.containerSize` already leaves out the safe-area
        /// insets, including the review sheet's bottom action bar.
        init(_ geometry: ScrollGeometry) {
            contentHeight = geometry.contentSize.height
            containerHeight = geometry.containerSize.height
        }

        init(contentHeight: CGFloat, containerHeight: CGFloat) {
            self.contentHeight = contentHeight
            self.containerHeight = containerHeight
        }

        var overflows: Bool {
            // Half a point absorbs layout rounding between content and container.
            containerHeight > 0 && contentHeight > containerHeight + 0.5
        }
    }

    private enum Phase: Equatable {
        case watching
        /// Asked for `.large` while the container was this tall.
        case growing(from: CGFloat)
        case settled
    }

    private var phase = Phase.watching

    var isGrowing: Bool {
        if case .growing = phase { true } else { false }
    }

    mutating func record(_ fit: Fit, at detent: PresentationDetent) {
        switch phase {
        case .watching:
            if detent == .medium, fit.overflows {
                phase = .growing(from: fit.containerHeight)
            }
        case .growing(let mediumHeight):
            if fit.containerHeight > mediumHeight + 0.5 {
                phase = .settled
            }
        case .settled:
            break
        }
    }

    /// While growing, detent changes are this type's own requests.
    mutating func detentDidChange(to detent: PresentationDetent) {
        if phase == .watching, detent == .large {
            phase = .settled
        }
    }

    mutating func stopGrowing() {
        phase = .settled
    }
}
