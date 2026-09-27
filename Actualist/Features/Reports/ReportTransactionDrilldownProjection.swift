import Foundation

enum ReportTransactionDrilldownRowRole: Hashable, Sendable {
    case contributor
    case context
}

enum ReportTransactionDrilldownRelationship: Hashable, Sendable {
    case root
    case splitChild(parentID: String?)
}

struct ReportTransactionDrilldownRowPresentation: Identifiable, Hashable, Sendable {
    let transaction: ActualTransaction
    let semantics: TransactionRowSemantics
    let accountName: String?
    let role: ReportTransactionDrilldownRowRole
    let relationship: ReportTransactionDrilldownRelationship

    var id: String { transaction.rowID }
}

struct ReportTransactionDrilldownDateGroupPresentation: Identifiable, Hashable, Sendable {
    let date: String
    let title: String
    let rows: [ReportTransactionDrilldownRowPresentation]

    var id: String { date }
}

struct ReportTransactionDrilldownDisplayState: Hashable, Sendable {
    let groups: [ReportTransactionDrilldownDateGroupPresentation]
    let contributingCount: Int
}

struct ReportTransactionDrilldownProjection {
    let snapshot: ReportTransactionDrilldownSnapshot
    let privacyModeEnabled: Bool

    var displayState: ReportTransactionDrilldownDisplayState {
        var seenIDs = Set<String>()
        let groups = TransactionGrouping.grouped(snapshot.loaded.transactions).map { group in
            var rows: [ReportTransactionDrilldownRowPresentation] = []
            for transaction in group.transactions {
                append(
                    transaction,
                    relationship: transaction.isChild
                        ? .splitChild(parentID: transaction.parentID)
                        : .root,
                    seenIDs: &seenIDs,
                    rows: &rows
                )
                for child in transaction.subtransactions {
                    append(
                        child,
                        relationship: .splitChild(parentID: transaction.id),
                        seenIDs: &seenIDs,
                        rows: &rows
                    )
                }
            }
            return ReportTransactionDrilldownDateGroupPresentation(
                date: group.date,
                title: group.title,
                rows: rows
            )
        }
        return ReportTransactionDrilldownDisplayState(
            groups: groups.filter { !$0.rows.isEmpty },
            contributingCount: snapshot.contributingTransactionIDs.count
        )
    }

    private func append(
        _ transaction: ActualTransaction,
        relationship: ReportTransactionDrilldownRelationship,
        seenIDs: inout Set<String>,
        rows: inout [ReportTransactionDrilldownRowPresentation]
    ) {
        guard seenIDs.insert(transaction.rowID).inserted else { return }
        rows.append(ReportTransactionDrilldownRowPresentation(
            transaction: transaction,
            semantics: TransactionRowSemantics.project(
                transaction,
                lookup: lookup,
                privacyEnabled: privacyModeEnabled
            ),
            accountName: accountName(for: transaction),
            role: transaction.id.map(snapshot.contributingTransactionIDs.contains) == true
                ? .contributor
                : .context,
            relationship: relationship
        ))
    }

    private var lookup: TransactionRowLookup {
        TransactionRowLookup(
            payeeNames: snapshot.loaded.payeeNames,
            categoryNames: snapshot.loaded.categoryNames,
            transferPayeeIDs: snapshot.loaded.transferPayeeIDs,
            transferAccountIDsByPayeeID: snapshot.loaded.transferAccountIDsByPayeeID,
            offBudgetAccountIDs: snapshot.loaded.offBudgetAccountIDs
        )
    }

    private func accountName(for transaction: ActualTransaction) -> String {
        if privacyModeEnabled {
            return PrivacyDisplay.name(for: .account, seed: transaction.account)
        }
        let name = snapshot.loaded.accountNames[transaction.account]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.flatMap { $0.isEmpty ? nil : $0 } ?? "Unknown Account"
    }
}
