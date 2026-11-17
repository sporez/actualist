import Foundation
import GRDB

enum ActionLogSQL {
    /// Gesture facts captured from live cells before the forward messages are
    /// applied.
    struct ActionLogFacts {
        var kind: BudgetActionKind
        var month: String
        var summary: BudgetActionSummary
        var inverse: BudgetActionInverse
        var affectedCategoryIDs: [String]
        var modeIdentity: BudgetModeIdentity? = nil
        var transactionCommandCapture: TransactionCommandActionCapture? = nil

        func record(
            id: String,
            createdAt: Date,
            source: BudgetActionSource,
            forwardTimestampStart: String?,
            forwardTimestampEnd: String?
        ) -> BudgetActionRecord {
            BudgetActionRecord(
                id: id,
                createdAt: createdAt,
                kind: kind,
                status: .applied,
                month: month.isEmpty ? nil : month,
                summary: summary,
                inverse: inverse,
                affectedCategoryIDs: affectedCategoryIDs,
                forwardTimestampStart: forwardTimestampStart,
                forwardTimestampEnd: forwardTimestampEnd,
                source: source,
                modeIdentity: modeIdentity
            )
        }

        func appending(learning: BudgetActionLearningSideEffect) -> ActionLogFacts {
            var copy = self
            copy.inverse = inverse.appending(learning: learning)
            return copy
        }
    }

    /// Completes inverse facts after the forward write, applies category-learning
    /// follow-up messages in the same transaction, and inserts the log row.
    static func finishActionLogCommit(
        _ commit: ActionLogCommit,
        facts: ActionLogFacts?,
        applied: BudgetDatabase.CommittedDraftsResult,
        clock: inout HybridLogicalClock,
        now: Date,
        baseTimestamp: String,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> Int {
        var actionLogFacts = facts
        var firstTimestamp = applied.firstTimestamp
        var lastTimestamp = applied.lastTimestamp
        var appliedCount = applied.appliedCount
        if let facts {
            actionLogFacts = try TransactionActionLogSQL.completeActionLogFacts(
                facts,
                descriptor: commit.descriptor,
                in: database,
                db: db
            )
        }
        if !commit.learningTransactionIDs.isEmpty {
            var learningBuilder = LocalFirstSyncMessageBuilder()
            let rulesBefore = try RuleSQL.fetchRules(in: database, db: db)
            let learning = try RuleSQL.categoryLearningRuleMessages(
                changedTransactionIDs: commit.learningTransactionIDs,
                builder: &learningBuilder,
                in: database,
                db: db
            )
            if !learning.isEmpty {
                let learningApplied = try database.applyCommittedDrafts(
                    learning,
                    clock: &clock,
                    now: now,
                    baseTimestamp: baseTimestamp,
                    db: db
                )
                appliedCount += learningApplied.appliedCount
                if firstTimestamp == nil {
                    firstTimestamp = learningApplied.firstTimestamp
                }
                lastTimestamp = learningApplied.lastTimestamp ?? lastTimestamp
                let sideEffect = TransactionActionLogSQL.learningSideEffect(beforeRules: rulesBefore, messages: learning)
                actionLogFacts = actionLogFacts?.appending(learning: sideEffect)
            }
        }
        if let actionLogFacts {
            var actionLogFacts = actionLogFacts
            // Capture the authoritative identity inside the same transaction
            // as the forward write and History row. Legacy rows remain nil.
            actionLogFacts.modeIdentity = try BudgetModeSQL.budgetModeIdentity(in: database, db: db)
            try ActionLogStorageSQL.ensureActionLog(in: database, db: db)
            try ActionLogStorageSQL.insertActionLogRecord(
                actionLogFacts.record(
                    id: commit.actionID,
                    createdAt: now,
                    source: commit.source,
                    forwardTimestampStart: firstTimestamp,
                    forwardTimestampEnd: lastTimestamp
                ),
                db: db
            )
            try ActionLogStorageSQL.pruneActionLogKeepingMoneyFlowWindow(limit: ActionLogStorageSQL.actionLogRetentionLimit, db: db)
        }
        return appliedCount
    }

    static func captureActionLogFacts(descriptor: BudgetActionDescriptor, in database: isolated BudgetDatabase, db: Database) throws -> ActionLogFacts {
        switch descriptor {
        case .assign(let month, let categoryID, let budgeted):
            let trimmedCategoryID = categoryID.trimmingCharacters(in: .whitespacesAndNewlines)
            let before = try BudgetCategoryValueSQL.categoryBudgets(month: month, in: database, db: db)[trimmedCategoryID]?.budgeted ?? 0
            let assign = AssignBudgetAction(
                month: month,
                categoryID: trimmedCategoryID,
                before: before,
                after: budgeted
            )
            return ActionLogFacts(
                kind: .assign,
                month: month,
                summary: .assign(assign),
                inverse: .assign(assign),
                affectedCategoryIDs: [trimmedCategoryID]
            )
        case .move(let month, let legs):
            let budgets = try BudgetCategoryValueSQL.categoryBudgets(month: month, in: database, db: db)
            var affectedIDs = Set<String>()
            var previousBudgeted: [String: Int] = [:]
            for categoryID in legs.flatMap({ [$0.fromCategoryID, $0.toCategoryID] }).compactMap({ $0 }) {
                let trimmed = categoryID.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                if affectedIDs.insert(trimmed).inserted {
                    previousBudgeted[trimmed] = budgets[trimmed]?.budgeted ?? 0
                }
            }
            return ActionLogFacts(
                kind: .move,
                month: month,
                summary: .move(MoveBudgetAction(month: month, legs: legs)),
                inverse: .move(MoveBudgetActionInverse(
                    month: month,
                    legs: legs,
                    previousBudgeted: previousBudgeted
                )),
                affectedCategoryIDs: affectedIDs.sorted()
            )
        case .template(let month, let mode, let assignments):
            let budgets = try BudgetCategoryValueSQL.categoryBudgets(month: month, in: database, db: db)
            var entries: [BudgetTemplateAssignmentFact] = []
            var affectedIDs: [String] = []
            for assignment in assignments.sorted(by: { $0.categoryID < $1.categoryID }) {
                let trimmed = assignment.categoryID.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                entries.append(BudgetTemplateAssignmentFact(
                    categoryID: trimmed,
                    before: budgets[trimmed]?.budgeted ?? 0,
                    after: assignment.amount
                ))
                affectedIDs.append(trimmed)
            }
            let template = TemplateBudgetAction(month: month, mode: mode, entries: entries)
            return ActionLogFacts(
                kind: .template,
                month: month,
                summary: .template(template),
                inverse: .template(template),
                affectedCategoryIDs: affectedIDs
            )
        case .createTransaction, .editTransaction, .deleteTransaction, .categorize,
                .transactionBatch, .transactionDuplicate, .transactionMerge:
            return try TransactionActionLogSQL.captureTransactionActionLogFacts(descriptor: descriptor, in: database, db: db)
        case .payee, .rule, .account, .carryover, .learningPref, .transactionMetadata:
            return try captureMetadataActionLogFacts(descriptor: descriptor)
        }
    }

    // MARK: - Undo

    /// Live budgeted amounts for every category the inverse touches. A `nil`
    /// value means the category was deleted since the gesture was recorded.
    private static func liveBudgetedForUndo(
        record: BudgetActionRecord,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> [String: Int?] {
        let budgets = try BudgetCategoryValueSQL.categoryBudgets(month: record.inverse.month, in: database, db: db)
        let categoryColumns: Set<String>
        let categoriesPresent = try database.tableExists("categories", db: db)
        if categoriesPresent {
            categoryColumns = try database.columnSet(for: "categories", db: db)
        } else {
            categoryColumns = []
        }
        var live: [String: Int?] = [:]
        for categoryID in record.affectedCategoryIDs {
            var alive = false
            if categoriesPresent {
                alive = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT id FROM categories
                        WHERE id = ? AND \(database.predicateForLiveRows(columns: categoryColumns))
                        LIMIT 1
                        """,
                    arguments: [categoryID]
                ) != nil
            }
            live[categoryID] = alive ? (budgets[categoryID]?.budgeted ?? 0) : nil
        }
        return live
    }

    /// Current → proposed amounts for the undo review, or the typed block
    /// explaining why the gesture cannot be undone.
    static func actionUndoPreview(record: BudgetActionRecord, in database: isolated BudgetDatabase) throws -> BudgetActionUndoPreview {
        try database.queue.read { db in
            switch try evaluateActionUndo(record: record, in: database, db: db) {
            case .clean(let plan):
                switch plan {
                case .assignments(let targets):
                    let live = try liveBudgetedForUndo(record: record, in: database, db: db)
                    let entries = targets.keys.sorted().compactMap { categoryID -> BudgetActionUndoPreview.Entry? in
                        guard let current = live[categoryID] ?? nil,
                              let proposed = targets[categoryID] else {
                            return nil
                        }
                        return BudgetActionUndoPreview.Entry(
                            categoryID: categoryID,
                            current: current,
                            proposed: proposed
                        )
                    }
                    return BudgetActionUndoPreview(
                        actionID: record.id,
                        month: record.inverse.month,
                        entries: entries,
                        block: nil
                    )
                case .tombstoneTransactions, .unTombstoneTransactions, .restoreSnapshots,
                        .restoreCategories, .restoreBatchTransactions,
                        .tombstoneDuplicateTransactions, .restoreMergedTransactions:
                    return BudgetActionUndoPreview(
                        actionID: record.id,
                        month: record.inverse.month,
                        entries: [],
                        transactionLines: TransactionActionLogSQL.undoPreviewLines(record: record, plan: plan),
                        block: nil
                    )
                }
            case .blocked(let block):
                return BudgetActionUndoPreview(
                    actionID: record.id,
                    month: record.inverse.month,
                    entries: [],
                    block: block
                )
            }
        }
    }

    static func evaluateActionUndo(
        record: BudgetActionRecord,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> BudgetActionUndoEvaluation {
        let liveBudgeted = try liveBudgetedForUndo(record: record, in: database, db: db)
        let liveTransactions = try TransactionActionLogSQL.liveTransactionsForUndo(
            ids: record.inverse.transactionIDs,
            in: database,
            db: db
        )
        let expectedGraphSnapshots: [TransactionBatchTransactionSnapshot]?
        switch record.inverse {
        case .transactionBatch(let batch):
            expectedGraphSnapshots = batch.afterSnapshots
        case .transactionDuplicate(let duplicate):
            guard record.kind == .transactionDuplicate,
                  case .transactionDuplicate(let summary) = record.summary,
                  TransactionCommandActionValidation.duplicate(summary: summary, inverse: duplicate) else {
                return .blocked(.transactionCommandChanged)
            }
            expectedGraphSnapshots = duplicate.afterSnapshots
        case .transactionMerge(let merge):
            guard record.kind == .transactionMerge,
                  case .transactionMerge(let summary) = record.summary,
                  TransactionCommandActionValidation.merge(summary: summary, inverse: merge) else {
                return .blocked(.transactionCommandChanged)
            }
            expectedGraphSnapshots = merge.afterSnapshots
        case .assign, .move, .template, .createTransaction, .editTransaction, .deleteTransaction,
                .categorize, .payee, .rule, .account, .carryover, .learningPref, .transactionMetadata:
            expectedGraphSnapshots = nil
        }
        let liveBatchSnapshots: [String: TransactionBatchTransactionSnapshot?]
        if let expectedGraphSnapshots {
            let snapshots = try TransactionBatchSnapshotSQL.transactionBatchSnapshots(
                ids: expectedGraphSnapshots.map(\.id),
                in: database,
                db: db
            )
            liveBatchSnapshots = Dictionary(
                uniqueKeysWithValues: snapshots.map { ($0.id, Optional($0)) }
            )
            guard snapshots.count == expectedGraphSnapshots.count,
                  snapshots.map(\.id) == expectedGraphSnapshots.map(\.id),
                  try TransactionBatchSnapshotSQL.transactionBatchGraphMembershipMatches(expectedGraphSnapshots, in: database, db: db) else {
                return .blocked(record.kind == .transactionBatch ? .batchChanged : .transactionCommandChanged)
            }
            if case .transactionDuplicate = record.inverse,
               try !TransactionCommandActionLogSQL.transactionDuplicateUndoStateMatches(expectedGraphSnapshots, in: database, db: db) {
                return .blocked(.transactionCommandChanged)
            }
        } else {
            liveBatchSnapshots = [:]
        }
        let liveRules = try TransactionActionLogSQL.liveRuleActionsForUndo(
            learning: record.inverse.learning,
            in: database,
            db: db
        )
        return BudgetActionUndo.evaluate(
            record: record,
            liveBudgeted: liveBudgeted,
            currentModeIdentity: try BudgetModeSQL.budgetModeIdentity(in: database, db: db),
            liveTransactions: liveTransactions,
            liveTransactionBatchSnapshots: liveBatchSnapshots,
            liveRuleActions: liveRules,
            liveReferences: try TransactionActionLogSQL.liveRestoredReferences(
                BudgetActionUndo.restoredReferences(inverse: record.inverse, liveTransactions: liveTransactions),
                in: database,
                db: db
            )
        )
    }

    static func undoMessages(
        for plan: BudgetActionUndoPlan,
        record: BudgetActionRecord,
        builder: inout LocalFirstSyncMessageBuilder,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> [ActualSyncDecodedMessage] {
        switch plan {
        case .assignments(let targets):
            let monthValue = try BudgetDatabase.actualMonthValue(record.inverse.month)
            let table = try database.budgetTable(db: db)
            let columns = try database.requiredColumns(
                table: table.rawValue,
                required: ["month", "category", "amount"],
                db: db
            )
            var drafts: [ActualSyncDecodedMessage] = []
            for categoryID in targets.keys.sorted() {
                guard let amount = targets[categoryID] else { continue }
                drafts += try BudgetRowSQL.assignCategoryBudgetMessages(
                    categoryID: categoryID,
                    budgeted: amount,
                    monthValue: monthValue,
                    table: table,
                    columns: columns,
                    builder: &builder,
                    in: database,
                    db: db
                )
            }
            return drafts
        case .tombstoneTransactions, .unTombstoneTransactions, .restoreSnapshots,
                .restoreCategories, .restoreBatchTransactions,
                .tombstoneDuplicateTransactions, .restoreMergedTransactions:
            return try TransactionActionLogSQL.transactionUndoMessages(plan: plan, builder: &builder, in: database, db: db)
        }
    }

    private static func captureMetadataActionLogFacts(
        descriptor: BudgetActionDescriptor
    ) throws -> ActionLogFacts {
        switch descriptor {
        case .payee(let payee):
            let payload = PayeeBudgetAction(operation: payee.operation, names: payee.names)
            return ActionLogFacts(
                kind: .payee,
                month: "",
                summary: .payee(payload),
                inverse: .payee(payload),
                affectedCategoryIDs: []
            )
        case .rule(let rule):
            let payload = RuleBudgetAction(operation: rule.operation)
            return ActionLogFacts(
                kind: .rule,
                month: "",
                summary: .rule(payload),
                inverse: .rule(payload),
                affectedCategoryIDs: []
            )
        case .account(let account):
            let payload = AccountBudgetAction(
                name: account.name, offbudget: account.offbudget, operation: account.operation
            )
            return ActionLogFacts(
                kind: .account,
                month: "",
                summary: .account(payload),
                inverse: .account(payload),
                affectedCategoryIDs: []
            )
        case .carryover(let carryover):
            let payload = CarryoverBudgetAction(
                startMonth: carryover.startMonth,
                after: carryover.after,
                categoryCount: carryover.categoryCount
            )
            return ActionLogFacts(
                kind: .carryover,
                month: carryover.startMonth,
                summary: .carryover(payload),
                inverse: .carryover(payload),
                affectedCategoryIDs: []
            )
        case .learningPref(let learning):
            let payload = LearningPrefBudgetAction(after: learning.after)
            return ActionLogFacts(
                kind: .learningPref,
                month: "",
                summary: .learningPref(payload),
                inverse: .learningPref(payload),
                affectedCategoryIDs: []
            )
        case .transactionMetadata(let metadata):
            let payload = TransactionMetadataBudgetAction(
                month: metadata.month,
                payeeName: metadata.payeeName,
                notesChanged: metadata.notesChanged,
                clearedChanged: metadata.clearedChanged
            )
            return ActionLogFacts(
                kind: .transactionMetadata,
                month: metadata.month,
                summary: .transactionMetadata(payload),
                inverse: .transactionMetadata(payload),
                affectedCategoryIDs: []
            )
        case .assign, .move, .template, .createTransaction, .editTransaction, .deleteTransaction,
                .categorize, .transactionBatch, .transactionDuplicate, .transactionMerge:
            throw LocalFirstError.invalidLocalWrite("unexpected money-flow action in metadata capture")
        }
    }
}
