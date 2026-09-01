import Foundation

/// Actual 26.8.1 `SplitTransactionError`: parent amount minus child total.
struct SplitTransactionError: Equatable, Sendable, Codable, Hashable {
    var type: String
    var version: Int
    var difference: Int

    init(type: String = "SplitTransactionError", version: Int = 1, difference: Int) {
        self.type = type
        self.version = version
        self.difference = difference
    }

    init(total: Int, parentAmount: Int) {
        self.init(difference: parentAmount - total)
    }
}

/// Distinguishes omitted JSON keys from explicit null, matching JavaScript
/// `'field' in data` in Actual `makeChild`.
enum SplitOptionalField<Value: Equatable>: Equatable, Sendable where Value: Sendable {
    case omitted
    case value(Value?)
}

/// Patch for `makeChild` / conversion inputs. Omitted category/payee inherit
/// from the parent; explicit nulls override.
struct SplitTransactionPatch: Equatable, Sendable {
    var id: String? = nil
    var amount: Int? = nil
    var category: SplitOptionalField<String> = .omitted
    var payee: SplitOptionalField<String> = .omitted
    var notes: SplitOptionalField<String> = .omitted
    var sortOrder: SplitOptionalField<Double> = .omitted

    static func fromRecord(_ record: SplitTransactionRecord, includePayee: Bool = true) -> SplitTransactionPatch {
        SplitTransactionPatch(
            id: record.id,
            amount: record.amount,
            category: .value(record.category),
            payee: includePayee ? .value(record.payee) : .omitted,
            notes: .value(record.notes),
            sortOrder: .value(record.sortOrder)
        )
    }
}

/// Canonical split-family row. Field names match the pinned
/// `family-transformations.json` `selected()` shape.
struct SplitTransactionRecord: Equatable, Sendable, Codable {
    var id: String
    var amount: Int
    var account: String?
    var date: String?
    var category: String?
    var payee: String?
    var notes: String?
    var cleared: Bool?
    var reconciled: Bool?
    var startingBalance: Bool?
    var sortOrder: Double?
    var isParent: Bool
    var isChild: Bool
    var parentID: String?
    var error: SplitTransactionError?
    var deleted: Bool
    var subtransactions: [SplitTransactionRecord]

    init(
        id: String,
        amount: Int = 0,
        account: String? = nil,
        date: String? = nil,
        category: String? = nil,
        payee: String? = nil,
        notes: String? = nil,
        cleared: Bool? = nil,
        reconciled: Bool? = nil,
        startingBalance: Bool? = nil,
        sortOrder: Double? = nil,
        isParent: Bool = false,
        isChild: Bool = false,
        parentID: String? = nil,
        error: SplitTransactionError? = nil,
        deleted: Bool = false,
        subtransactions: [SplitTransactionRecord] = []
    ) {
        self.id = id
        self.amount = amount
        self.account = account
        self.date = date
        self.category = category
        self.payee = payee
        self.notes = notes
        self.cleared = cleared
        self.reconciled = reconciled
        self.startingBalance = startingBalance
        self.sortOrder = sortOrder
        self.isParent = isParent
        self.isChild = isChild
        self.parentID = parentID
        self.error = error
        self.deleted = deleted
        self.subtransactions = subtransactions
    }

    enum CodingKeys: String, CodingKey {
        case id, amount, account, date, category, payee, notes, cleared, reconciled
        case startingBalance, sortOrder, isParent, isChild, parentID, error, deleted
        case subtransactions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        amount = try container.decodeIfPresent(Int.self, forKey: .amount) ?? 0
        account = try container.decodeIfPresent(String.self, forKey: .account)
        date = try container.decodeIfPresent(String.self, forKey: .date)
        category = try container.decodeIfPresent(String.self, forKey: .category)
        payee = try container.decodeIfPresent(String.self, forKey: .payee)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        cleared = try container.decodeIfPresent(Bool.self, forKey: .cleared)
        reconciled = try container.decodeIfPresent(Bool.self, forKey: .reconciled)
        startingBalance = try container.decodeIfPresent(Bool.self, forKey: .startingBalance)
        if let sortOrder = try container.decodeIfPresent(Double.self, forKey: .sortOrder) {
            self.sortOrder = sortOrder
        } else if let sortOrder = try container.decodeIfPresent(Int.self, forKey: .sortOrder) {
            self.sortOrder = Double(sortOrder)
        } else {
            sortOrder = nil
        }
        isParent = try container.decodeIfPresent(Bool.self, forKey: .isParent) ?? false
        isChild = try container.decodeIfPresent(Bool.self, forKey: .isChild) ?? false
        parentID = try container.decodeIfPresent(String.self, forKey: .parentID)
        error = try container.decodeIfPresent(SplitTransactionError.self, forKey: .error)
        deleted = try container.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
        subtransactions = try container.decodeIfPresent([SplitTransactionRecord].self, forKey: .subtransactions) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(amount, forKey: .amount)
        try container.encodeIfPresent(account, forKey: .account)
        try container.encodeIfPresent(date, forKey: .date)
        try container.encodeIfPresent(category, forKey: .category)
        try container.encodeIfPresent(payee, forKey: .payee)
        try container.encodeIfPresent(notes, forKey: .notes)
        try container.encodeIfPresent(cleared, forKey: .cleared)
        try container.encodeIfPresent(reconciled, forKey: .reconciled)
        try container.encodeIfPresent(startingBalance, forKey: .startingBalance)
        try container.encodeIfPresent(sortOrder, forKey: .sortOrder)
        try container.encode(isParent, forKey: .isParent)
        try container.encode(isChild, forKey: .isChild)
        try container.encodeIfPresent(parentID, forKey: .parentID)
        try container.encodeIfPresent(error, forKey: .error)
        try container.encode(deleted, forKey: .deleted)
        if !subtransactions.isEmpty {
            try container.encode(subtransactions, forKey: .subtransactions)
        }
    }

    /// `selected()` shape used by the pinned oracle JSON.
    func selected() -> SplitTransactionRecord {
        var copy = self
        copy.subtransactions = []
        return copy
    }

    var isEffectiveParent: Bool { isParent }
    var isEffectiveChild: Bool { isChild }
    var effectiveParentID: String? { isChild ? parentID : nil }
}

struct SplitTransactionFamily: Equatable, Sendable {
    var parent: SplitTransactionRecord
    var children: [SplitTransactionRecord]

    var selected: SplitTransactionFamily {
        SplitTransactionFamily(
            parent: parent.selected(),
            children: children.map { $0.selected() }
        )
    }

    var grouped: SplitTransactionRecord {
        var grouped = parent
        grouped.subtransactions = children
        return grouped
    }
}

struct SplitTransactionDiff: Equatable, Sendable {
    var added: [SplitTransactionRecord]
    var updated: [SplitTransactionRecord]
    var deleted: [String]
}

struct SplitTransactionChangeSet: Equatable, Sendable {
    var data: [SplitTransactionRecord]
    var newTransaction: SplitTransactionRecord?
    var diff: SplitTransactionDiff
}

enum SplitTransactionFamilyOps {
    static func makeChild(
        parent: SplitTransactionRecord,
        data: SplitTransactionPatch = SplitTransactionPatch(),
        idGenerator: () -> String = { UUID().uuidString }
    ) -> SplitTransactionRecord {
        let prefix = parent.id == "temp" ? "temp" : ""
        let category: String?
        switch data.category {
        case .omitted: category = parent.category
        case .value(let value): category = value
        }
        let payee: String?
        switch data.payee {
        case .omitted: payee = parent.payee
        case .value(let value): payee = value
        }
        let notes: String?
        switch data.notes {
        case .omitted: notes = nil
        case .value(let value): notes = value
        }
        let sortOrder: Double?
        switch data.sortOrder {
        case .omitted: sortOrder = parent.sortOrder
        case .value(let value): sortOrder = value
        }
        return SplitTransactionRecord(
            id: data.id ?? prefix + idGenerator(),
            amount: data.amount ?? 0,
            account: parent.account,
            date: parent.date,
            category: category,
            payee: payee,
            notes: notes,
            cleared: parent.cleared,
            reconciled: parent.reconciled,
            startingBalance: parent.startingBalance,
            sortOrder: sortOrder,
            isParent: false,
            isChild: true,
            parentID: parent.id,
            error: nil,
            deleted: false
        )
    }

    static func makeChild(
        parent: SplitTransactionRecord,
        record: SplitTransactionRecord,
        includePayee: Bool = true,
        idGenerator: () -> String = { UUID().uuidString }
    ) -> SplitTransactionRecord {
        makeChild(
            parent: parent,
            data: .fromRecord(record, includePayee: includePayee),
            idGenerator: idGenerator
        )
    }

    static func recalculateSplit(_ transaction: SplitTransactionRecord) -> SplitTransactionRecord {
        let total = (transaction.subtransactions).reduce(0) { $0 + $1.amount }
        var result = transaction
        result.error = total == transaction.amount
            ? nil
            : SplitTransactionError(total: total, parentAmount: transaction.amount)
        return result
    }

    static func groupTransaction(_ split: [SplitTransactionRecord]) -> SplitTransactionRecord {
        guard let parent = split.first else {
            return SplitTransactionRecord(id: "")
        }
        var grouped = parent
        grouped.subtransactions = Array(split.dropFirst())
        return grouped
    }

    static func ungroupTransaction(_ split: SplitTransactionRecord?) -> [SplitTransactionRecord] {
        guard let split else { return [] }
        return ungroupTransactions([split])
    }

    static func ungroupTransactions(_ transactions: [SplitTransactionRecord]) -> [SplitTransactionRecord] {
        transactions.reduce(into: []) { list, parent in
            var trans = parent
            let children = trans.subtransactions
            trans.subtransactions = []
            list.append(trans)
            list.append(contentsOf: children)
        }
    }

    static func splitTransaction(
        _ transactions: [SplitTransactionRecord],
        id: String,
        createSubtransactions: ((SplitTransactionRecord) -> [SplitTransactionRecord])? = nil,
        idGenerator: () -> String = { UUID().uuidString }
    ) -> SplitTransactionChangeSet {
        replaceTransactions(transactions, id: id) { trans in
            if trans.isParent || trans.isChild {
                return trans
            }
            let subtransactions = createSubtransactions?(trans) ?? [
                makeChild(parent: trans, idGenerator: idGenerator)
            ]
            var parent = trans
            parent.error = nil
            parent.isParent = true
            parent.payee = nil
            parent.error = parent.amount == 0
                ? nil
                : SplitTransactionError(total: 0, parentAmount: parent.amount)
            parent.subtransactions = subtransactions.map { child in
                var copy = child
                copy.sortOrder = child.sortOrder ?? -1
                return copy
            }
            return parent
        }
    }

    static func updateTransaction(
        _ transactions: [SplitTransactionRecord],
        transaction: SplitTransactionRecord,
        idGenerator: () -> String = { UUID().uuidString }
    ) -> SplitTransactionChangeSet {
        replaceTransactions(transactions, id: transaction.id) { trans in
            if trans.isParent {
                var parent = trans.id == transaction.id ? merged(trans, transaction) : trans
                let originalSubtransactions = parent.subtransactions.isEmpty
                    ? trans.subtransactions
                    : parent.subtransactions
                let sub = originalSubtransactions.map { child -> SplitTransactionRecord in
                    var next = child
                    if trans.id == transaction.id {
                        let childPayee = child.payee
                        let newPayee = childPayee == trans.payee ? transaction.payee : childPayee
                        if newPayee == nil {
                            return makeChild(
                                parent: parent,
                                record: child,
                                includePayee: false,
                                idGenerator: idGenerator
                            )
                        }
                        next.payee = newPayee
                    } else if child.id == transaction.id {
                        next = transaction
                    }
                    return makeChild(parent: parent, record: next, idGenerator: idGenerator)
                }
                parent.subtransactions = sub
                return recalculateSplit(parent)
            } else if !transaction.subtransactions.isEmpty {
                var parent = merged(trans, transaction)
                parent.isParent = true
                parent.isChild = false
                parent.parentID = nil
                parent.subtransactions = transaction.subtransactions.enumerated().map { index, sub in
                    var child = sub
                    if child.sortOrder == nil {
                        child.sortOrder = Double(-(index + 1))
                    }
                    return makeChild(parent: parent, record: child, idGenerator: idGenerator)
                }
                return recalculateSplit(parent)
            } else {
                return transaction
            }
        }
    }

    static func deleteTransaction(
        _ transactions: [SplitTransactionRecord],
        id: String
    ) -> SplitTransactionChangeSet {
        replaceTransactions(transactions, id: id) { trans in
            if trans.isParent {
                if trans.id == id {
                    return nil
                } else if trans.subtransactions.count == 1 {
                    var rest = trans
                    rest.subtransactions = []
                    rest.isParent = false
                    rest.error = nil
                    return rest
                } else {
                    var next = trans
                    next.subtransactions = trans.subtransactions.filter { $0.id != id }
                    return recalculateSplit(next)
                }
            } else {
                return nil
            }
        }
    }

    static func makeAsNonChildTransactions(
        childTransactionsToUpdate: [SplitTransactionRecord],
        transactions: [SplitTransactionRecord]
    ) -> (updated: [SplitTransactionRecord], deleted: [SplitTransactionRecord]) {
        guard let parentTransaction = transactions.first else {
            return (updated: [], deleted: [])
        }
        let childTransactions = Array(transactions.dropFirst())
        let newNonChildTransactions = childTransactionsToUpdate.map {
            makeNonChild(parent: parentTransaction, data: $0)
        }
        let remainingChildTransactions = childTransactions.filter { child in
            !newNonChildTransactions.contains { $0.id == child.id }
        }
        if childTransactions.count == 1,
           childTransactionsToUpdate.count == 1,
           childTransactionsToUpdate.first?.id == childTransactions.first?.id {
            return (
                updated: [makeTransactionWithChildCategory(parent: parentTransaction, data: childTransactionsToUpdate[0])],
                deleted: childTransactionsToUpdate
            )
        }

        let nonChildTransactionsToUpdate = remainingChildTransactions.count == 1
            ? newNonChildTransactions + remainingChildTransactions.map {
                makeNonChild(parent: parentTransaction, data: $0)
            }
            : newNonChildTransactions
        let deleteParentTransaction = remainingChildTransactions.count <= 1
        var updatedParentTransaction = parentTransaction
        if !deleteParentTransaction {
            updatedParentTransaction.amount = remainingChildTransactions.reduce(0) { $0 + $1.amount }
        }
        return (
            updated: (deleteParentTransaction ? [] : [updatedParentTransaction]) + nonChildTransactionsToUpdate,
            deleted: deleteParentTransaction ? [updatedParentTransaction] : []
        )
    }

    static func family(
        from rows: [SplitTransactionRecord],
        parentID: String = "parent-1"
    ) -> (rows: [SplitTransactionRecord], family: SplitTransactionFamily?) {
        let selectedRows = rows.map { $0.selected() }
        guard let parent = rows.first(where: { $0.id == parentID }) else {
            return (rows: selectedRows, family: nil)
        }
        return (
            rows: selectedRows,
            family: SplitTransactionFamily(
                parent: parent.selected(),
                children: rows.filter { $0.parentID == parentID }.map { $0.selected() }
            ).selected
        )
    }

    static func diffItems(
        _ items: [SplitTransactionRecord],
        _ newItems: [SplitTransactionRecord]
    ) -> SplitTransactionDiff {
        let grouped = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let newGrouped = Dictionary(uniqueKeysWithValues: newItems.map { ($0.id, $0) })
        let deleted = items.filter { newGrouped[$0.id] == nil }.map(\.id)
        var added: [SplitTransactionRecord] = []
        var updated: [SplitTransactionRecord] = []
        for newItem in newItems {
            guard let item = grouped[newItem.id] else {
                added.append(newItem)
                continue
            }
            if let changes = changedValues(from: item, to: newItem) {
                updated.append(changes)
            }
        }
        return SplitTransactionDiff(added: added, updated: updated, deleted: deleted)
    }
}

private extension SplitTransactionFamilyOps {
    static func makeNonChild(
        parent: SplitTransactionRecord,
        data: SplitTransactionRecord
    ) -> SplitTransactionRecord {
        var result = data
        result.cleared = parent.cleared
        result.reconciled = parent.reconciled
        result.sortOrder = parent.sortOrder
        result.startingBalance = nil
        result.isChild = false
        result.parentID = nil
        return result
    }

    static func makeTransactionWithChildCategory(
        parent: SplitTransactionRecord,
        data: SplitTransactionRecord
    ) -> SplitTransactionRecord {
        var result = parent
        result.isParent = false
        result.category = data.category
        return result
    }

    static func merged(_ base: SplitTransactionRecord, _ overlay: SplitTransactionRecord) -> SplitTransactionRecord {
        var result = overlay
        if result.subtransactions.isEmpty {
            result.subtransactions = base.subtransactions
        }
        return result
    }

    static func findParentIndex(_ transactions: [SplitTransactionRecord], idx: Int) -> Int? {
        var index = idx
        while index >= 0 {
            if transactions[index].isParent {
                return index
            }
            index -= 1
        }
        return nil
    }

    static func getSplit(_ transactions: [SplitTransactionRecord], parentIndex: Int) -> [SplitTransactionRecord] {
        var split = [transactions[parentIndex]]
        var current = parentIndex + 1
        while current < transactions.count && transactions[current].isChild {
            split.append(transactions[current])
            current += 1
        }
        return split
    }

    static func replaceTransactions(
        _ transactions: [SplitTransactionRecord],
        id: String,
        transform: (SplitTransactionRecord) -> SplitTransactionRecord?
    ) -> SplitTransactionChangeSet {
        guard let idx = transactions.firstIndex(where: { $0.id == id }) else {
            return SplitTransactionChangeSet(
                data: [],
                newTransaction: nil,
                diff: SplitTransactionDiff(added: [], updated: [], deleted: [])
            )
        }
        let trans = transactions[idx]
        var copy = transactions
        if trans.isParent || trans.isChild {
            guard let parentIndex = findParentIndex(transactions, idx: idx) else {
                return SplitTransactionChangeSet(
                    data: [],
                    newTransaction: nil,
                    diff: SplitTransactionDiff(added: [], updated: [], deleted: [])
                )
            }
            let split = getSplit(transactions, parentIndex: parentIndex)
            let grouped = transform(groupTransaction(split))
            let newSplit = ungroupTransaction(grouped)
            let diff: SplitTransactionDiff
            let newTransaction: SplitTransactionRecord?
            if newSplit.isEmpty {
                diff = SplitTransactionDiff(added: [], updated: [], deleted: [split[0].id])
                var deletedParent = split[0]
                deletedParent.deleted = true
                newTransaction = deletedParent
                copy.removeSubrange(parentIndex..<(parentIndex + split.count))
            } else {
                diff = diffItems(split, newSplit)
                copy.replaceSubrange(parentIndex..<(parentIndex + split.count), with: newSplit)
                newTransaction = grouped
            }
            return SplitTransactionChangeSet(data: copy, newTransaction: newTransaction, diff: diff)
        } else {
            let grouped = transform(trans)
            let newTrans = ungroupTransaction(grouped)
            copy.replaceSubrange(idx...idx, with: newTrans)
            let newTransaction = grouped ?? {
                var deleted = trans
                deleted.deleted = true
                return deleted
            }()
            return SplitTransactionChangeSet(
                data: copy,
                newTransaction: newTransaction,
                diff: diffItems([trans], newTrans)
            )
        }
    }

    static func changedValues(
        from old: SplitTransactionRecord,
        to new: SplitTransactionRecord
    ) -> SplitTransactionRecord? {
        var diff = SplitTransactionRecord(id: old.id)
        var changed = false
        func assign<T: Equatable>(_ keyPath: WritableKeyPath<SplitTransactionRecord, T>, _ value: T, _ oldValue: T) {
            if value != oldValue {
                diff[keyPath: keyPath] = value
                changed = true
            }
        }
        assign(\.amount, new.amount, old.amount)
        assign(\.account, new.account, old.account)
        assign(\.date, new.date, old.date)
        assign(\.category, new.category, old.category)
        assign(\.payee, new.payee, old.payee)
        assign(\.notes, new.notes, old.notes)
        assign(\.cleared, new.cleared, old.cleared)
        assign(\.reconciled, new.reconciled, old.reconciled)
        assign(\.startingBalance, new.startingBalance, old.startingBalance)
        assign(\.sortOrder, new.sortOrder, old.sortOrder)
        assign(\.isParent, new.isParent, old.isParent)
        assign(\.isChild, new.isChild, old.isChild)
        assign(\.parentID, new.parentID, old.parentID)
        assign(\.error, new.error, old.error)
        assign(\.deleted, new.deleted, old.deleted)
        return changed ? diff : nil
    }
}
