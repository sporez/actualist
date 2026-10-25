import SwiftUI

/// Moves a `List`'s horizontal safe-area insets into its content margins.
///
/// Beside a side-docked tab bar (iPhone Duo) the List's rows stop at the tab
/// column, but swipe actions still slide a row by the button width plus that
/// trailing inset, leaving an empty band beside the button. Ignoring the
/// horizontal safe area and restoring the inset as a content margin keeps the
/// rows clear of the tab column without that extra slide.
struct HorizontalSafeAreaContentMargins: ViewModifier {
    @State private var insets = EdgeInsets()

    func body(content: Content) -> some View {
        content
            .contentMargins(.leading, insets.leading)
            .contentMargins(.trailing, insets.trailing)
            .ignoresSafeArea(.container, edges: .horizontal)
            // Measured outside the ignored edges; inside, the insets read as zero.
            .background {
                Color.clear
                    .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: { insets = $0 }
            }
    }
}
