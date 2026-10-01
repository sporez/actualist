import Foundation

/// Pure display projection for the exact rows pinned by a batch review.
struct TransactionBatchReviewDisplay: Equatable {
    enum Tone: Equatable {
        case normal
        case positive
        case warning
        case danger
        case secondary
    }

    struct Effect: Equatable, Identifiable {
        let title: String
        let before: String
        let after: String

        var id: String { "\(title)|\(before)|\(after)" }
    }

    struct Member: Equatable, Identifiable {
        let id: String
        let payee: String
        let context: String
        let note: String?
        let amount: String
        let relation: String?
        let effects: [Effect]
    }

    struct Row: Equatable, Identifiable {
        let id: String
        let member: Member?
        let status: String
        let tone: Tone
        let explanation: String?
        let linkedMembers: [Member]
    }

    let title: String
    let confirmationTitle: String
    let selectedCountText: String
    let changedCountText: String
    let skippedCountText: String?
    let blockedCountText: String?
    let rows: [Row]
    let authorizationMessage: String?
    let canSubmit: Bool

    init(
        review: TransactionBatchReview,
        locale: Locale = .current,
        isPrivacyModeEnabled: Bool = false
    ) {
        let changes = Dictionary(uniqueKeysWithValues: review.rowChanges.map { ($0.id, $0) })
        let selectedIDs = Set(review.selections.map(\.transactionID))
        let factory = MemberFactory(
            review: review,
            locale: locale,
            isPrivacyModeEnabled: isPrivacyModeEnabled
        )

        title = review.reviewTitle
        confirmationTitle = review.confirmationTitle
        selectedCountText = review.selections.count.formatted()
        changedCountText = review.rowChanges.filter(\.changed).count.formatted()
        skippedCountText = review.skippedCount > 0 ? review.skippedCount.formatted() : nil
        blockedCountText = review.blockedCount > 0 ? review.blockedCount.formatted() : nil
        canSubmit = review.canSubmit
        if let authorization = review.authorization {
            let count = Set(
                authorization.reconciledTransactionIDs
                    + authorization.pairedReconciledTransactionIDs
            ).count
            authorizationMessage = "\(count.formatted()) reconciled transaction\(count == 1 ? " is" : "s are") connected to these changes."
        } else {
            authorizationMessage = nil
        }

        rows = review.dispositions.map { disposition in
            let change = changes[disposition.selection.transactionID]
            let effect: TransactionBatchEffectSummary?
            let status: String
            let tone: Tone
            let explanation: String?
            switch disposition {
            case .eligible(let summary):
                effect = summary
                status = change?.changed == true ? "Will change" : "No change"
                tone = change?.changed == true ? .positive : .secondary
                explanation = nil
            case .requiresAuthorization(let requirement):
                effect = requirement.effect
                status = "Needs confirmation"
                tone = .warning
                explanation = "This change includes reconciled transaction data."
            case .skipped(let reason):
                effect = nil
                status = "Skipped"
                tone = .secondary
                explanation = reason.explanation
            case .blocked(let reason):
                effect = nil
                status = "Blocked"
                tone = .danger
                explanation = reason.explanation
            }
            guard let change else {
                return Row(
                    id: disposition.id,
                    member: nil,
                    status: "Blocked",
                    tone: .danger,
                    explanation: explanation ?? "The selected transaction is unavailable.",
                    linkedMembers: []
                )
            }
            let linked = effect?.affectedTransactionIDs.compactMap { id -> Member? in
                guard !selectedIDs.contains(id), let linkedChange = changes[id] else { return nil }
                return factory.member(for: linkedChange, relativeTo: change.before)
            } ?? []
            return Row(
                id: disposition.id,
                member: factory.member(for: change, relativeTo: nil),
                status: status,
                tone: tone,
                explanation: explanation,
                linkedMembers: linked
            )
        }
    }
}

private struct MemberFactory {
    let review: TransactionBatchReview
    let locale: Locale
    let isPrivacyModeEnabled: Bool

    func member(
        for change: TransactionBatchRowChange,
        relativeTo selected: TransactionBatchRowSnapshot?
    ) -> TransactionBatchReviewDisplay.Member {
        let row = change.before
        return TransactionBatchReviewDisplay.Member(
            id: row.id,
            payee: payeeName(row.payeeID, imported: row.importedPayee),
            context: "\(dateText(row.dateValue)) · \(accountName(row.accountID))",
            note: isPrivacyModeEnabled ? nil : nonempty(row.notes),
            amount: amountText(row.amount, rowID: row.id, role: "identity"),
            relation: selected.map { relation(of: row, to: $0) },
            effects: effects(for: change)
        )
    }

    private func effects(for change: TransactionBatchRowChange) -> [TransactionBatchReviewDisplay.Effect] {
        let before = change.before
        let after = change.after
        if before.tombstone != true, after.tombstone == true {
            return [effect("Status", "Present", "Deleted")]
        }
        var output: [TransactionBatchReviewDisplay.Effect] = []
        if before.dateValue != after.dateValue {
            output.append(effect("Date", dateText(before.dateValue), dateText(after.dateValue)))
        }
        if before.accountID != after.accountID {
            output.append(effect("Account", accountName(before.accountID), accountName(after.accountID)))
        }
        if before.amount != after.amount {
            output.append(effect(
                "Amount",
                amountText(before.amount, rowID: before.id, role: "before"),
                amountText(after.amount, rowID: after.id, role: "after")
            ))
        }
        if before.payeeID != after.payeeID || before.importedPayee != after.importedPayee {
            output.append(effect(
                "Payee",
                payeeName(before.payeeID, imported: before.importedPayee),
                payeeName(after.payeeID, imported: after.importedPayee)
            ))
        }
        if before.categoryID != after.categoryID {
            output.append(effect(
                "Category",
                categoryName(before.categoryID),
                categoryName(after.categoryID)
            ))
        }
        append(&output, "Cleared", clearedText(before.cleared), clearedText(after.cleared))
        append(&output, "Reconciled", booleanText(before.reconciled), booleanText(after.reconciled))
        if before.transferID != after.transferID {
            output.append(effect("Transfer", linkText(before.transferID), linkText(after.transferID)))
        }
        if before.parentID != after.parentID {
            output.append(effect("Split family", linkText(before.parentID), linkText(after.parentID)))
        }
        if before.isParent != after.isParent || before.isChild != after.isChild {
            append(&output, "Split role", splitRole(before), splitRole(after))
        }
        return output
    }

    private func append(
        _ effects: inout [TransactionBatchReviewDisplay.Effect],
        _ title: String,
        _ before: String,
        _ after: String
    ) {
        guard before != after else { return }
        effects.append(effect(title, before, after))
    }

    private func effect(_ title: String, _ before: String, _ after: String) -> TransactionBatchReviewDisplay.Effect {
        .init(title: title, before: before, after: after)
    }

    private func accountName(_ id: String?) -> String {
        guard let id else { return "Account unavailable" }
        if isPrivacyModeEnabled { return PrivacyDisplay.name(for: .account, seed: "batch-account-\(id)") }
        return nonempty(review.metadata.accountNames[id]) ?? "Account unavailable"
    }

    private func payeeName(_ id: String?, imported: String?) -> String {
        if isPrivacyModeEnabled {
            return PrivacyDisplay.name(for: .payee, seed: "batch-payee-\(id ?? imported ?? "unavailable")")
        }
        return nonempty(id.flatMap { review.metadata.payeeNames[$0] })
            ?? nonempty(imported)
            ?? "Payee unavailable"
    }

    private func categoryName(_ id: String?) -> String {
        guard let id else { return isPrivacyModeEnabled ? "Category hidden" : "Uncategorized" }
        if isPrivacyModeEnabled { return PrivacyDisplay.name(for: .category, seed: "batch-category-\(id)") }
        return nonempty(review.metadata.categoryNames[id]) ?? "Category unavailable"
    }

    private func amountText(_ amount: Int?, rowID: String, role: String) -> String {
        guard let amount else { return "Amount unavailable" }
        if isPrivacyModeEnabled {
            return PrivacyDisplay.money(
                amount,
                seed: "batch-review-\(rowID)-\(role)-\(amount)",
                currency: review.metadata.currency
            )
        }
        return review.metadata.currency.formatted(amount)
    }

    private func dateText(_ packed: Int?) -> String {
        guard let packed else { return "Date unavailable" }
        let compact = String(format: "%08d", packed)
        guard compact.count == 8 else { return compact }
        let dayID = "\(compact.prefix(4))-\(compact.dropFirst(4).prefix(2))-\(compact.suffix(2))"
        guard let date = ActualDateOnly.date(from: dayID, timeZone: ActualDateOnly.utc) else { return dayID }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = locale
        formatter.timeZone = ActualDateOnly.utc
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    private func clearedText(_ value: Bool?) -> String {
        switch value {
        case true: "Cleared"
        case false: "Uncleared"
        case nil: "Unavailable"
        }
    }

    private func booleanText(_ value: Bool?) -> String {
        switch value {
        case true: "Yes"
        case false: "No"
        case nil: "Unavailable"
        }
    }

    private func linkText(_ id: String?) -> String { id == nil ? "Not linked" : "Linked" }

    private func splitRole(_ row: TransactionBatchRowSnapshot) -> String {
        if row.isParent == true { return "Split transaction" }
        if row.isChild == true { return "Split entry" }
        return "Transaction"
    }

    private func relation(
        of row: TransactionBatchRowSnapshot,
        to selected: TransactionBatchRowSnapshot
    ) -> String {
        if row.id == selected.transferID || row.transferID == selected.id { return "Affected transfer member" }
        if row.parentID == selected.id || selected.parentID == row.id { return "Affected split member" }
        if let parentID = row.parentID, parentID == selected.parentID { return "Affected split member" }
        return "Affected linked member"
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }
}

extension TransactionBatchReview {
    var reviewTitle: String {
        switch intent {
        case .clear: clearTarget == false ? "Review Unclear Transactions" : "Review Clear Transactions"
        case .categorize: "Review Categorize Transactions"
        case .delete: "Review Delete Transactions"
        }
    }

    var confirmationTitle: String {
        switch intent {
        case .clear: clearTarget == false ? "Unclear" : "Clear"
        case .categorize: "Categorize"
        case .delete: "Delete"
        }
    }
}
