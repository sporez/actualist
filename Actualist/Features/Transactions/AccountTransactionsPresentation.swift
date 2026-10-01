import SwiftUI

enum AccountTransactionsPresentation {
    case navigation
    case categoryInspector(onClose: @MainActor () -> Void)

    var isCategoryInspector: Bool {
        if case .categoryInspector = self { true } else { false }
    }

    @MainActor
    func closeInspector() {
        if case .categoryInspector(let onClose) = self {
            onClose()
        }
    }
}

struct TransactionNavigationTitleModifier: ViewModifier {
    let title: String
    let isVisible: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isVisible {
            content
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
        } else {
            content
        }
    }
}
