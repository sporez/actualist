import SwiftUI

struct RootTransactionEditorContent: View {
    let presentation: TransactionEditorSession

    var body: some View {
        TransactionEditorView(session: presentation)
            .environment(\.budgetCurrency, presentation.model.currency)
    }
}
