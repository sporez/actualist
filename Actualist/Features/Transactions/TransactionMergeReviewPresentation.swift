import Foundation

/// Display projection for a merge review. Input position follows the prepared
/// tap order; kept and dropped labels follow the review, not the input index.
struct TransactionMergeReviewDisplay: Equatable {
    struct Input: Equatable, Identifiable {
        let id: String
        let position: Int
        let positionLabel: String
        let outcomeLabel: String?
        let isKept: Bool
        let role: String?
        let context: String?
        let amount: String?
        let note: String?
        let detail: String
    }

    struct Effect: Equatable, Identifiable {
        let id: String
        let title: String
        let value: String
    }

    let title = "Review Merge Transactions"
    let confirmationTitle = "Merge"
    let subtitle = "Input 1 is the first transaction you selected. Input 2 is the second."
    let inputCountText: String
    let keptLabel: String?
    let droppedLabel: String?
    let blockedMessage: String?
    let authorizationMessage: String?
    let inputs: [Input]
    let keptEffects: [Effect]
    let canSubmit: Bool

    init(
        review: TransactionMergeReview,
        locale: Locale = .current,
        currency: BudgetCurrency = .usd,
        isPrivacyModeEnabled: Bool = false
    ) {
        inputCountText = review.orderedTransactionIDs.count.formatted(.number.locale(locale))
        blockedMessage = review.blockedReason.map(Self.blockedMessage(for:))
        canSubmit = review.canSubmit && review.blockedReason == nil
        if canSubmit {
            let reconciledCount = Set(review.reconciledTransactionIDs).count
            authorizationMessage = reconciledCount == 0
                ? nil
                : TransactionCommandReviewFormatting.reconciledConfirmationMessage(
                    count: reconciledCount,
                    locale: locale
                )
        } else {
            authorizationMessage = nil
        }

        // The merged rows describe the result; the current input rows keep a
        // blocked review readable. Kept and dropped take precedence.
        let rowsByID = (review.inputRows + [review.keptRow, review.droppedRow].compactMap { $0 })
            .reduce(into: [String: TransactionMergeReviewRow]()) { rows, row in
                rows[row.transactionID] = row
            }
        inputs = review.orderedTransactionIDs.enumerated().map { offset, transactionID in
            let position = offset + 1
            let row = rowsByID[transactionID]
            let isKept = review.keptRow?.transactionID == transactionID
            let isDropped = review.droppedRow?.transactionID == transactionID
            let outcome = isKept ? "Kept" : (isDropped ? "Dropped" : nil)
            return Input(
                id: transactionID,
                position: position,
                positionLabel: "Input \(position)",
                outcomeLabel: outcome,
                isKept: isKept,
                role: row.map {
                    TransactionCommandReviewFormatting.role(
                        isParent: $0.isParent,
                        isChild: $0.isChild,
                        isTransfer: $0.isTransfer
                    )
                },
                context: row.map {
                    TransactionCommandReviewFormatting.dateText($0.date, locale: locale)
                },
                amount: row.map {
                    TransactionCommandReviewFormatting.amountText(
                        $0.amountMinorUnits,
                        seed: "merge-review-\(transactionID)-\($0.amountMinorUnits)",
                        currency: currency,
                        isPrivacyModeEnabled: isPrivacyModeEnabled
                    )
                },
                note: TransactionCommandReviewFormatting.note(
                    row?.notes,
                    isPrivacyModeEnabled: isPrivacyModeEnabled
                ),
                detail: isKept
                    ? "This transaction is kept."
                    : (isDropped
                        ? "This transaction will be removed."
                        : (row == nil ? "This transaction is unavailable." : "This transaction will not be changed."))
            )
        }
        keptLabel = inputs.first { $0.isKept }?.positionLabel
        droppedLabel = inputs.first { $0.outcomeLabel == "Dropped" }?.positionLabel
        keptEffects = canSubmit
            ? Self.effects(
                review.fieldEffects,
                currency: currency,
                locale: locale,
                isPrivacyModeEnabled: isPrivacyModeEnabled
            )
            : []
    }

    static func blockedMessage(for reason: TransactionMergeBlockedReason) -> String {
        switch reason {
        case .requiresExactlyTwoIDs:
            "Select exactly two transactions to merge."
        case .emptyTransactionID:
            "One of the selected transactions is missing."
        case .duplicateTransactionID:
            "Select two different transactions to merge."
        case .missingRootSnapshot:
            "One of the selected transactions is no longer available."
        case .selectedChild:
            "A split entry cannot be merged by itself. Select the whole transaction."
        case .overlappingGraphs:
            "These transactions are already linked, so they cannot be merged."
        case .malformedRow:
            "This transaction cannot be merged because one of its stored values is incomplete."
        case .missingAccountMetadata, .invalidReferenceMetadata:
            "This transaction cannot be merged because its account is unavailable."
        case .zeroChildSplit:
            "An empty split cannot be merged."
        case .splitHasError:
            "A split with an error cannot be merged."
        case .malformedSplit:
            "This split cannot be merged because its entries are incomplete."
        case .malformedTransfer:
            "This transfer cannot be merged because its other side is incomplete."
        case .extraIncomingTransfer:
            "This transfer cannot be merged because it has an extra linked transaction."
        case .missingTransferDestination:
            "This transfer cannot be merged because its destination account is missing."
        case .accountMismatch:
            "These transactions are in different accounts, so they cannot be merged."
        case .amountMismatch:
            "These transactions have different amounts, so they cannot be merged."
        case .differentTransferDestinations:
            "These transfers go to different accounts, so they cannot be merged."
        case .invalidProposedParentFields:
            "This split cannot be merged because the combined transaction would be invalid."
        }
    }

    private static func effects(
        _ effects: [TransactionMergeFieldEffect],
        currency: BudgetCurrency,
        locale: Locale,
        isPrivacyModeEnabled: Bool
    ) -> [Effect] {
        effects.compactMap { effect in
            guard effect.beforeValue != effect.afterValue else { return nil }
            if isPrivacyModeEnabled, effect.field == .notes { return nil }
            guard let title = title(for: effect.field) else { return nil }
            return Effect(
                id: "\(effect.transactionID)|\(effect.field.rawValue)",
                title: title,
                value: valueText(
                    effect.afterValue,
                    field: effect.field,
                    currency: currency,
                    locale: locale,
                    isPrivacyModeEnabled: isPrivacyModeEnabled,
                    seed: "merge-effect-\(effect.transactionID)-\(effect.field.rawValue)"
                )
            )
        }
    }

    private static func title(for field: TransactionMergeField) -> String? {
        switch field {
        case .notes: "Notes"
        case .cleared: "Cleared"
        case .reconciled: "Reconciled"
        case .dateValue, .amount, .accountID, .payeeID, .categoryID,
             .scheduleID, .importedID, .importedPayee, .importedDescription,
             .startingBalance, .sortOrder:
            nil
        }
    }

    private static func valueText(
        _ value: TransactionMergeFieldValue,
        field: TransactionMergeField,
        currency: BudgetCurrency,
        locale: Locale,
        isPrivacyModeEnabled: Bool,
        seed: String
    ) -> String {
        switch value {
        case .text(let text):
            if field == .notes, isPrivacyModeEnabled { return "Hidden" }
            return text?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "None"
        case .boolean(let flag):
            switch flag {
            case true: return "Yes"
            case false: return "No"
            case nil: return "Unavailable"
            }
        case .integer(let number):
            guard let number else { return "Unavailable" }
            if field == .amount {
                return TransactionCommandReviewFormatting.amountText(
                    number,
                    seed: seed,
                    currency: currency,
                    isPrivacyModeEnabled: isPrivacyModeEnabled
                )
            }
            return number.formatted(.number.locale(locale))
        case .decimal(let number):
            guard let number else { return "Unavailable" }
            return number.formatted(.number.locale(locale))
        }
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
