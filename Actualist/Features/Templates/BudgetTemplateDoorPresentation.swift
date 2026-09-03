import Foundation

/// Cut A types the editor can add. Titles are tester-facing.
enum BudgetTemplateCutAKind: String, CaseIterable, Identifiable, Sendable {
    case monthlyFixed
    case copy
    case average
    case schedule
    case remainder
    case goal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .monthlyFixed: "Fixed Amount"
        case .copy: "Copy Previous Month"
        case .average: "Average"
        case .schedule: "Cover Schedule"
        case .remainder: "Remainder"
        case .goal: "Goal"
        }
    }

    var isSingleton: Bool {
        switch self {
        case .remainder, .goal:
            true
        case .monthlyFixed, .copy, .average, .schedule:
            false
        }
    }

    func makeDraft(now: Date) -> BudgetTemplateDraft {
        switch self {
        case .monthlyFixed: .monthlyFixed(now: now)
        case .copy: .copy()
        case .average: .average()
        case .schedule: .schedule()
        case .remainder: .remainder()
        case .goal: .goal()
        }
    }
}

/// Add / Edit / View labels for the Budget long-press and category-details row.
enum BudgetTemplateDoorKind: Equatable, Sendable {
    case add
    case edit
    case view

    static func kind(hasDefinition: Bool, lock: BudgetTemplateCategoryLock) -> Self {
        if !lock.isEditable {
            return .view
        }
        return hasDefinition ? .edit : .add
    }

    /// Long-press without a loaded lock: Add vs Edit from stored definition.
    static func kind(hasDefinition: Bool) -> Self {
        hasDefinition ? .edit : .add
    }

    var menuTitle: String {
        switch self {
        case .add: "Add Templates"
        case .edit: "Edit Templates"
        case .view: "View Templates"
        }
    }

    var detailsTitle: String {
        switch self {
        case .add: "Add Template"
        case .edit: "Edit Templates"
        case .view: "View Templates"
        }
    }

    var editorTitle: String {
        detailsTitle
    }
}

/// Prepared category-details row. Views render this; they do not load or summarize.
struct BudgetTemplateDoorRow: Equatable, Sendable {
    var kind: BudgetTemplateDoorKind
    var summary: String
    var lockReason: String?

    static func placeholder(hasDefinition: Bool) -> BudgetTemplateDoorRow {
        BudgetTemplateDoorRow(
            kind: .kind(hasDefinition: hasDefinition),
            summary: "",
            lockReason: nil
        )
    }

    static func make(
        snapshot: BudgetTemplateEditorSnapshot,
        currency: BudgetCurrency,
        randomized: Bool
    ) -> BudgetTemplateDoorRow {
        BudgetTemplateDoorRow(
            kind: .kind(hasDefinition: snapshot.hasDefinition, lock: snapshot.lock),
            summary: BudgetTemplateSummary.line(
                drafts: snapshot.drafts,
                currency: currency,
                randomized: randomized,
                seed: snapshot.categoryID
            ),
            lockReason: snapshot.lock.testerFacingReason
        )
    }
}

struct BudgetTemplateEditorTarget: Identifiable, Hashable, Sendable {
    var categoryID: String
    var categoryName: String
    var month: String

    var id: String { "\(month)|\(categoryID)" }
}
