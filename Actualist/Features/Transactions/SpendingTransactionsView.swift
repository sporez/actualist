import SwiftUI

struct SpendingTransactionsView: View {
    var body: some View {
        NavigationStack {
            AccountTransactionsView(scope: .spending)
        }
    }
}
