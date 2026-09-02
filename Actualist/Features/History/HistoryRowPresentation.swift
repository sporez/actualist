import Foundation

/// One row on the History screen. Built by `HistoryRowPresentation` from a
/// persisted `BudgetActionRecord`; the view only binds it.
struct HistoryRowModel: Identifiable, Equatable, Sendable {
    enum Visual: Equatable, Sendable {
        case assign
        case move
        case template
    }

    enum AmountTone: Equatable, Sendable {
        case positive
        case negative
        case neutral
    }

    let id: String
    let title: String
    let detail: String
    let amountText: String?
    let amountTone: AmountTone
    let visual: Visual
    let isUndone: Bool
    /// LIFO: only the newest applied row offers Undo (Q2). Undone rows stay
    /// visible and never re-offer it (Q15).
    let canUndo: Bool
}

/// What the nested undo review shows. `blockReason` replaces the entries when
/// the conflict check refused the undo.
struct HistoryUndoReviewPresentation: Identifiable, Equatable, Sendable {
    struct Entry: Identifiable, Equatable, Sendable {
        let categoryID: String
        let name: String
        let currentText: String
        let proposedText: String

        var id: String { categoryID }
    }

    let actionID: String
    /// Lead of the row being undone, e.g. "Assigned $600.00 to Groceries".
    let gestureSummary: String
    let entries: [Entry]
    let blockReason: String?

    var id: String { actionID }
    var isUndoable: Bool { blockReason == nil && !entries.isEmpty }
}

/// Pure projection from records to display rows. Amounts and names honor the
/// randomized-display privacy setting.
enum HistoryRowPresentation {
    static func rows(
        from records: [BudgetActionRecord],
        categoryNames: [String: String],
        undoableActionID: String?,
        currency: BudgetCurrency,
        privacyEnabled: Bool,
        now: Date = Date()
    ) -> [HistoryRowModel] {
        records.map { record in
            row(
                for: record,
                categoryNames: categoryNames,
                canUndo: record.id == undoableActionID && record.status == .applied,
                currency: currency,
                privacyEnabled: privacyEnabled,
                now: now
            )
        }
    }

    /// Display name for a History category reference. To Budget legs use nil.
    static func displayName(
        for categoryID: String?,
        categoryNames: [String: String],
        privacyEnabled: Bool
    ) -> String {
        guard let categoryID else {
            return "To Budget"
        }
        guard !privacyEnabled else {
            return PrivacyDisplay.name(for: .category, seed: categoryID)
        }
        let name = categoryNames[categoryID]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return name?.isEmpty == false ? name! : "Deleted category"
    }

    static func moneyText(
        _ minorUnits: Int,
        seed: String,
        currency: BudgetCurrency,
        privacyEnabled: Bool
    ) -> String {
        guard !privacyEnabled else {
            return PrivacyDisplay.money(minorUnits, seed: seed, currency: currency)
        }
        return Money(minorUnits: minorUnits).formatted(using: currency)
    }

    /// One-line description of the gesture, reused by the undo review header.
    static func gestureSummary(
        for record: BudgetActionRecord,
        categoryNames: [String: String],
        currency: BudgetCurrency,
        privacyEnabled: Bool
    ) -> String {
        switch record.summary {
        case .assign(let assign):
            let amount = moneyText(
                assign.after,
                seed: "\(record.id)-assign",
                currency: currency,
                privacyEnabled: privacyEnabled
            )
            return "Assigned \(amount) to \(displayName(for: assign.categoryID, categoryNames: categoryNames, privacyEnabled: privacyEnabled))"
        case .move(let move):
            let amount = moneyText(
                move.legs.reduce(0) { $0 + $1.amount },
                seed: "\(record.id)-move",
                currency: currency,
                privacyEnabled: privacyEnabled
            )
            return "Moved \(amount)"
        case .template(let template):
            let noun = template.entries.count == 1 ? "category" : "categories"
            let action = template.mode == .overwrite ? "overwrite" : "fill"
            return "Applied Templates (\(action)) across \(template.entries.count) \(noun)"
        }
    }

    private static func row(
        for record: BudgetActionRecord,
        categoryNames: [String: String],
        canUndo: Bool,
        currency: BudgetCurrency,
        privacyEnabled: Bool,
        now: Date
    ) -> HistoryRowModel {
        let monthTitle = record.month.map { BudgetMonthNavigationPresentation.title(for: $0) } ?? ""
        let timeText = timeText(for: record.createdAt, now: now)
        let occurrence = [monthTitle, timeText].filter { !$0.isEmpty }.joined(separator: " · ")
        let isUndone = record.status == .undone

        let title: String
        let actionDetail: String
        var amountText: String?
        var amountTone: HistoryRowModel.AmountTone = .neutral
        let visual: HistoryRowModel.Visual

        switch record.summary {
        case .assign(let assign):
            let name = displayName(for: assign.categoryID, categoryNames: categoryNames, privacyEnabled: privacyEnabled)
            let afterText = moneyText(assign.after, seed: "\(record.id)-assign-after", currency: currency, privacyEnabled: privacyEnabled)
            let beforeText = moneyText(assign.before, seed: "\(record.id)-assign-before", currency: currency, privacyEnabled: privacyEnabled)
            title = "Assigned \(afterText) to \(name)"
            actionDetail = "was \(beforeText)"
            let delta = assign.after - assign.before
            let deltaText = moneyText(abs(delta), seed: "\(record.id)-assign-delta", currency: currency, privacyEnabled: privacyEnabled)
            if delta > 0 {
                amountText = "+\(deltaText)"
                amountTone = .positive
            } else if delta < 0 {
                amountText = "-\(deltaText)"
                amountTone = .negative
            } else {
                amountText = nil
            }
            visual = .assign

        case .move(let move):
            if move.legs.count == 1, let leg = move.legs.first {
                let amount = moneyText(leg.amount, seed: "\(record.id)-move", currency: currency, privacyEnabled: privacyEnabled)
                let from = displayName(for: leg.fromCategoryID, categoryNames: categoryNames, privacyEnabled: privacyEnabled)
                let to = displayName(for: leg.toCategoryID, categoryNames: categoryNames, privacyEnabled: privacyEnabled)
                title = "Moved \(amount)"
                actionDetail = "\(from) → \(to)"
            } else {
                let total = move.legs.reduce(0) { $0 + $1.amount }
                title = "Moved \(moneyText(total, seed: "\(record.id)-move", currency: currency, privacyEnabled: privacyEnabled))"
                actionDetail = "\(move.legs.count) transfers"
            }
            visual = .move

        case .template(let template):
            title = template.mode == .overwrite ? "Applied Templates Overwrite" : "Applied Templates"
            let noun = template.entries.count == 1 ? "category" : "categories"
            actionDetail = "\(template.entries.count) \(noun)"
            visual = .template
        }

        let detail = ([isUndone ? "Undone" : nil, actionDetail, occurrence].compactMap { $0 })
            .filter { !$0.isEmpty }
            .joined(separator: " · ")

        return HistoryRowModel(
            id: record.id,
            title: title,
            detail: detail,
            amountText: isUndone ? nil : amountText,
            amountTone: isUndone ? .neutral : amountTone,
            visual: visual,
            isUndone: isUndone,
            canUndo: canUndo
        )
    }

    private static func timeText(for date: Date, now: Date) -> String {
        if Calendar.current.isDate(date, inSameDayAs: now) {
            return date.formatted(.dateTime.hour().minute())
        }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}
