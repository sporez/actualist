import SwiftUI

struct TransactionScheduleConversionResolvedNames: Hashable, Sendable {
    let account: String
    let payee: String
    let category: String
}

struct TransactionScheduleConversionEntryPoint: Hashable, Sendable {
    let transactionID: String
    let asOfDayID: String
    let source: ActualTransaction
    let names: TransactionScheduleConversionResolvedNames

    static func project(
        transaction: ActualTransaction,
        lookup: TransactionRowLookup,
        asOfDayID: String,
        accountName: String?
    ) -> TransactionScheduleConversionEntryPoint? {
        guard let transactionID = transaction.id,
              !transactionID.isEmpty,
              !transaction.isChild,
              ActualScheduleRecurrence.date(from: transaction.date) != nil,
              transaction.date > asOfDayID else { return nil }

        let family = [transaction] + transaction.subtransactions
        guard family.allSatisfy({ member in
            !member.reconciled
                && TransactionRowSemantics.project(member, lookup: lookup).transferDirection == nil
        }) else { return nil }

        let semantics = TransactionRowSemantics.project(transaction, lookup: lookup)
        return TransactionScheduleConversionEntryPoint(
            transactionID: transactionID,
            asOfDayID: asOfDayID,
            source: transaction,
            names: TransactionScheduleConversionResolvedNames(
                account: accountName ?? "Unknown Account",
                payee: semantics.payeeText,
                category: semantics.categoryText
            )
        )
    }
}

struct TransactionScheduleConversionPresentationHost: ViewModifier {
    @Environment(AppState.self) private var appState
    @Bindable var coordinator: TransactionScheduleConversionCoordinator
    let onCurrentSessionCommitted: @MainActor () -> Void

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: sheetBinding) {
                TransactionScheduleConversionReviewView(
                    coordinator: coordinator,
                    repository: appState.localFirstStore,
                    onCommitted: conversionCommitted
                )
                .appSwitcherPrivacyProtected(using: appState)
            }
            .onChange(of: appState.settings.selectedBudgetID) {
                _ = coordinator.cancel()
            }
            .onChange(of: appState.localFirstStore.budgetSessionGeneration) {
                _ = coordinator.cancel()
            }
    }

    private func conversionCommitted(_ outcome: TransactionScheduleConversionOutcome) {
        guard outcome.belongsToSession(
            budgetID: appState.settings.selectedBudgetID,
            generation: appState.localFirstStore.budgetSessionGeneration
        ) else { return }
        onCurrentSessionCommitted()
    }

    private var sheetBinding: Binding<Bool> {
        Binding(
            get: { coordinator.isPresented },
            set: { isPresented in
                if !isPresented {
                    _ = coordinator.cancel()
                }
            }
        )
    }
}
