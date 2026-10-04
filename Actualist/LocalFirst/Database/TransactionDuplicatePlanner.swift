import Foundation

struct TransactionDuplicateSelectionResolution: Codable, Equatable, Sendable {
    let selectedTransactionID: String
    let familyRootTransactionID: String
    let duplicateGroupID: String
}

struct TransactionDuplicateGraphClone: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let selectedTransactionIDs: [String]
    let sourceTransactionIDs: [String]
    let duplicateTransactionIDs: [String]
    let sourceRootTransactionIDs: [String]
    let duplicateRootTransactionIDs: [String]
}

struct TransactionDuplicateRowChange: Equatable, Sendable {
    let before: TransactionBatchTransactionSnapshot
    let duplicate: TransactionBatchTransactionSnapshot
}

/// Canonically ordered complete state used by a later review fingerprint.
/// A caller can encode this value with sorted JSON keys or compare it directly;
/// it deliberately does not depend on Swift's randomized `Hasher` output.
struct TransactionDuplicateFingerprintMaterial: Codable, Equatable, Sendable {
    let selections: [TransactionDuplicateSelectionResolution]
    let groups: [TransactionDuplicateGraphClone]
    let allocations: [TransactionDuplicateAllocation]
    let beforeSnapshots: [TransactionBatchTransactionSnapshot]
    let afterSnapshots: [TransactionBatchTransactionSnapshot]
}

struct TransactionDuplicatePlan: Equatable, Sendable {
    let selections: [TransactionDuplicateSelectionResolution]
    let groups: [TransactionDuplicateGraphClone]
    let allocations: [TransactionDuplicateAllocation]
    let beforeSnapshots: [TransactionBatchTransactionSnapshot]
    let afterSnapshots: [TransactionBatchTransactionSnapshot]
    let rowChanges: [TransactionDuplicateRowChange]
    let affectedResources: ChangedResources

    var requestsCategoryLearning: Bool { false }

    var fingerprintMaterial: TransactionDuplicateFingerprintMaterial {
        TransactionDuplicateFingerprintMaterial(
            selections: selections,
            groups: groups,
            allocations: allocations,
            beforeSnapshots: beforeSnapshots,
            afterSnapshots: afterSnapshots
        )
    }
}

enum TransactionDuplicatePlannerError: Error, Equatable, Sendable {
    case emptySelection
    case emptySourceSnapshots
    case invalidSourceID(String)
    case duplicateSourceSnapshot(String)
    case missingSelection(String)
    case unselectedSourceSnapshot(String)
    case unavailableSource(String)
    case missingRequiredField(String)
    case unsupportedSourceSchema(String)
    case incompatibleSourceSchemas
    case malformedSplit(String)
    case zeroChildSplit(String)
    case sourceSplitError(String)
    case malformedTransfer(String)
    case duplicateAllocation(String)
    case missingAllocation(String)
    case extraAllocation(String)
    case invalidDuplicateID(String)
    case duplicateDuplicateID(String)
    case duplicateIDAliasesSource(String)
    case invalidSortOrder(String)
    case staleSortOrder(String)
    case duplicateSortOrder
}

/// Pure duplicate planner. The database graph loader remains authoritative for
/// live-row membership, schema discovery, and incoming links outside this
/// snapshot set. This planner checks that its supplied complete closure is
/// self-consistent, then validates the newly linked clone graph. The caller
/// still checks allocated IDs against rows outside this source closure. Split-
/// family membership and balance validation use `SplitTransactionFamilyOps`;
/// this planner does not reimplement grouping, split arithmetic, or diffing.
enum TransactionDuplicatePlanner {
    static func plan(
        selections selectedIDs: [String],
        sourceSnapshots: [TransactionBatchTransactionSnapshot],
        allocations: [TransactionDuplicateAllocation]
    ) throws -> TransactionDuplicatePlan {
        guard !selectedIDs.isEmpty else { throw TransactionDuplicatePlannerError.emptySelection }
        guard !sourceSnapshots.isEmpty else { throw TransactionDuplicatePlannerError.emptySourceSnapshots }

        let snapshotsByID = try indexedSnapshots(sourceSnapshots)
        let canonicalColumns = Set(sourceSnapshots[0].columns)
        guard sourceSnapshots.allSatisfy({ Set($0.columns) == canonicalColumns }) else {
            throw TransactionDuplicatePlannerError.incompatibleSourceSchemas
        }
        try validateSourceRows(sourceSnapshots, columns: canonicalColumns)

        let splitUnits = try makeSplitUnits(sourceSnapshots, snapshotsByID: snapshotsByID)
        try validateTransferLinks(sourceSnapshots, snapshotsByID: snapshotsByID, unitByTransactionID: splitUnits.unitByTransactionID)

        var uniqueSelections: [String] = []
        var seenSelections = Set<String>()
        for id in selectedIDs {
            guard !id.isEmpty else { throw TransactionDuplicatePlannerError.invalidSourceID(id) }
            guard snapshotsByID[id] != nil else { throw TransactionDuplicatePlannerError.missingSelection(id) }
            if seenSelections.insert(id).inserted {
                uniqueSelections.append(id)
            }
        }

        var sourceGroupsByID: [String: Set<String>] = [:]
        var groupIDByTransactionID: [String: String] = [:]
        for selectedID in uniqueSelections {
            let sourceGroup = try completeDuplicateGroup(
                selectedID: selectedID,
                snapshotsByID: snapshotsByID,
                unitByTransactionID: splitUnits.unitByTransactionID,
                membersByUnitID: splitUnits.membersByUnitID
            )
            let rootIDs = sourceGroup.filter { splitUnits.unitByTransactionID[$0] == $0 }
            guard let groupID = rootIDs.min() ?? sourceGroup.min() else {
                throw TransactionDuplicatePlannerError.missingSelection(selectedID)
            }
            sourceGroupsByID[groupID] = sourceGroup
            for memberID in sourceGroup {
                if let previousGroup = groupIDByTransactionID[memberID], previousGroup != groupID {
                    throw TransactionDuplicatePlannerError.malformedTransfer(memberID)
                }
                groupIDByTransactionID[memberID] = groupID
            }
        }

        let selectedSourceIDs = Set(groupIDByTransactionID.keys)
        if let unselected = Set(snapshotsByID.keys).subtracting(selectedSourceIDs).sorted().first {
            throw TransactionDuplicatePlannerError.unselectedSourceSnapshot(unselected)
        }

        let canonicalAllocations = try validateAllocations(
            allocations,
            sourceIDs: selectedSourceIDs,
            snapshotsByID: snapshotsByID
        )
        let allocationBySourceID = Dictionary(
            uniqueKeysWithValues: canonicalAllocations.map { ($0.sourceTransactionID, $0) }
        )
        let beforeSnapshots = sourceSnapshots.sorted { $0.id < $1.id }
        let afterSnapshots = try beforeSnapshots.map { source in
            guard let allocation = allocationBySourceID[source.id] else {
                throw TransactionDuplicatePlannerError.missingAllocation(source.id)
            }
            return try duplicateSnapshot(
                from: source,
                allocation: allocation,
                allocationsBySourceID: allocationBySourceID
            )
        }.sorted { $0.id < $1.id }

        try validateProposedLinks(afterSnapshots)

        let groupPlans = try sourceGroupsByID.keys.sorted().map { groupID -> TransactionDuplicateGraphClone in
            guard let sourceGroup = sourceGroupsByID[groupID] else {
                throw TransactionDuplicatePlannerError.unselectedSourceSnapshot(groupID)
            }
            let sourceIDs = sourceGroup.sorted()
            let groupSelections = uniqueSelections.filter { groupIDByTransactionID[$0] == groupID }
            let rootIDs = sourceIDs.filter { splitUnits.unitByTransactionID[$0] == $0 }
            let duplicateIDs = try sourceIDs.map {
                try duplicateID(for: $0, allocationsBySourceID: allocationBySourceID)
            }
            let duplicateRoots = try rootIDs.map {
                try duplicateID(for: $0, allocationsBySourceID: allocationBySourceID)
            }
            return TransactionDuplicateGraphClone(
                id: groupID,
                selectedTransactionIDs: groupSelections,
                sourceTransactionIDs: sourceIDs,
                duplicateTransactionIDs: duplicateIDs.sorted(),
                sourceRootTransactionIDs: rootIDs.sorted(),
                duplicateRootTransactionIDs: duplicateRoots.sorted()
            )
        }
        let selectionResolutions = try uniqueSelections.map { selectedID in
            guard let familyRootID = splitUnits.unitByTransactionID[selectedID],
                  let duplicateGroupID = groupIDByTransactionID[selectedID] else {
                throw TransactionDuplicatePlannerError.missingSelection(selectedID)
            }
            return TransactionDuplicateSelectionResolution(
                selectedTransactionID: selectedID,
                familyRootTransactionID: familyRootID,
                duplicateGroupID: duplicateGroupID
            )
        }
        let afterByID = Dictionary(uniqueKeysWithValues: afterSnapshots.map { ($0.id, $0) })
        let rowChanges = try canonicalAllocations.map { allocation -> TransactionDuplicateRowChange in
            guard let before = snapshotsByID[allocation.sourceTransactionID] else {
                throw TransactionDuplicatePlannerError.missingRequiredField(allocation.sourceTransactionID)
            }
            guard let duplicate = afterByID[allocation.duplicateTransactionID] else {
                throw TransactionDuplicatePlannerError.missingAllocation(allocation.sourceTransactionID)
            }
            return TransactionDuplicateRowChange(before: before, duplicate: duplicate)
        }
        let affectedResources = try affectedResources(
            sourceSnapshots: beforeSnapshots,
            duplicateSnapshots: afterSnapshots
        )

        return TransactionDuplicatePlan(
            selections: selectionResolutions,
            groups: groupPlans,
            allocations: canonicalAllocations,
            beforeSnapshots: beforeSnapshots,
            afterSnapshots: afterSnapshots,
            rowChanges: rowChanges,
            affectedResources: affectedResources
        )
    }

    private struct SplitUnits {
        let unitByTransactionID: [String: String]
        let membersByUnitID: [String: Set<String>]
    }

    private static func indexedSnapshots(
        _ snapshots: [TransactionBatchTransactionSnapshot]
    ) throws -> [String: TransactionBatchTransactionSnapshot] {
        var result: [String: TransactionBatchTransactionSnapshot] = [:]
        for snapshot in snapshots {
            guard !snapshot.id.isEmpty else { throw TransactionDuplicatePlannerError.invalidSourceID(snapshot.id) }
            guard result[snapshot.id] == nil else {
                throw TransactionDuplicatePlannerError.duplicateSourceSnapshot(snapshot.id)
            }
            result[snapshot.id] = snapshot
        }
        return result
    }

    private static func validateSourceRows(
        _ snapshots: [TransactionBatchTransactionSnapshot],
        columns: Set<String>
    ) throws {
        let requiredColumns: Set<String> = ["id", "date", "amount", "category", "sort_order", "cleared", "reconciled"]
        guard requiredColumns.isSubset(of: columns),
              columns.contains("acct") || columns.contains("account"),
              columns.contains("description") || columns.contains("payee") else {
            throw TransactionDuplicatePlannerError.unsupportedSourceSchema(snapshots[0].id)
        }

        for snapshot in snapshots {
            guard snapshot.tombstone != true else {
                throw TransactionDuplicatePlannerError.unavailableSource(snapshot.id)
            }
            guard let accountID = snapshot.accountID, !accountID.isEmpty,
                  let dateValue = snapshot.dateValue, YearMonth(validatingPackedDate: dateValue) != nil,
                  snapshot.amount != nil else {
                throw TransactionDuplicatePlannerError.missingRequiredField(snapshot.id)
            }
            if let sortOrder = snapshot.sortOrder, !sortOrder.isFinite {
                throw TransactionDuplicatePlannerError.invalidSortOrder(snapshot.id)
            }
            if snapshot.splitError.map(hasSplitError) == true {
                throw TransactionDuplicatePlannerError.sourceSplitError(snapshot.id)
            }
            if snapshot.isParent == true || snapshot.isChild == true || snapshot.parentID != nil {
                guard columns.contains("parent_id"),
                      columns.contains("isParent") || columns.contains("is_parent") else {
                    throw TransactionDuplicatePlannerError.unsupportedSourceSchema(snapshot.id)
                }
            }
            if snapshot.transferID != nil,
               !columns.contains("transferred_id"), !columns.contains("transfer_id") {
                throw TransactionDuplicatePlannerError.unsupportedSourceSchema(snapshot.id)
            }
        }
    }

    private static func makeSplitUnits(
        _ snapshots: [TransactionBatchTransactionSnapshot],
        snapshotsByID: [String: TransactionBatchTransactionSnapshot]
    ) throws -> SplitUnits {
        for snapshot in snapshots {
            if snapshot.isParent == true && snapshot.isChild == true {
                throw TransactionDuplicatePlannerError.malformedSplit(snapshot.id)
            }
            if let parentID = snapshot.parentID {
                guard !parentID.isEmpty, parentID != snapshot.id, snapshot.isChild == true,
                      let parent = snapshotsByID[parentID], parent.isParent == true,
                      parent.isChild != true else {
                    throw TransactionDuplicatePlannerError.malformedSplit(snapshot.id)
                }
            } else if snapshot.isChild == true {
                throw TransactionDuplicatePlannerError.malformedSplit(snapshot.id)
            }
        }

        let records = try snapshots.map { try splitRecord(from: $0) }
        var membersByUnitID: [String: Set<String>] = [:]
        var unitByTransactionID: [String: String] = [:]
        for parent in snapshots where parent.isParent == true {
            guard let family = SplitTransactionFamilyOps.family(from: records, parentID: parent.id).family else {
                throw TransactionDuplicatePlannerError.malformedSplit(parent.id)
            }
            guard !family.children.isEmpty else {
                throw TransactionDuplicatePlannerError.zeroChildSplit(parent.id)
            }
            guard family.children.allSatisfy({
                $0.isChild && $0.parentID == parent.id
                    && $0.account == family.parent.account && $0.date == family.parent.date
            }) else {
                throw TransactionDuplicatePlannerError.malformedSplit(parent.id)
            }
            guard SplitTransactionFamilyOps.recalculateSplit(family.grouped).error == nil else {
                throw TransactionDuplicatePlannerError.malformedSplit(parent.id)
            }
            let members = Set(SplitTransactionFamilyOps.ungroupTransaction(family.grouped).map(\.id))
            guard members.count == family.children.count + 1 else {
                throw TransactionDuplicatePlannerError.malformedSplit(parent.id)
            }
            membersByUnitID[parent.id] = members
            for memberID in members {
                unitByTransactionID[memberID] = parent.id
            }
        }
        for snapshot in snapshots where unitByTransactionID[snapshot.id] == nil {
            unitByTransactionID[snapshot.id] = snapshot.id
            membersByUnitID[snapshot.id] = [snapshot.id]
        }
        return SplitUnits(unitByTransactionID: unitByTransactionID, membersByUnitID: membersByUnitID)
    }

    private static func splitRecord(from snapshot: TransactionBatchTransactionSnapshot) throws -> SplitTransactionRecord {
        guard let dateValue = snapshot.dateValue,
              let dateID = actualDateID(for: dateValue),
              let amount = snapshot.amount else {
            throw TransactionDuplicatePlannerError.missingRequiredField(snapshot.id)
        }
        return SplitTransactionRecord(
            id: snapshot.id,
            amount: amount,
            account: snapshot.accountID,
            date: dateID,
            category: snapshot.categoryID,
            payee: snapshot.payeeID,
            notes: snapshot.notes,
            cleared: snapshot.cleared,
            reconciled: snapshot.reconciled,
            startingBalance: snapshot.startingBalance,
            sortOrder: snapshot.sortOrder,
            isParent: snapshot.isParent == true,
            isChild: snapshot.isChild == true,
            parentID: snapshot.parentID,
            transferID: snapshot.transferID,
            error: nil,
            deleted: snapshot.tombstone == true
        )
    }

    private static func validateTransferLinks(
        _ snapshots: [TransactionBatchTransactionSnapshot],
        snapshotsByID: [String: TransactionBatchTransactionSnapshot],
        unitByTransactionID: [String: String]
    ) throws {
        var incomingIDs: [String: Set<String>] = [:]
        for snapshot in snapshots {
            guard let transferID = snapshot.transferID else { continue }
            guard !transferID.isEmpty, transferID != snapshot.id,
                  let paired = snapshotsByID[transferID], paired.transferID == snapshot.id,
                  paired.tombstone != true,
                  let sourceAccountID = snapshot.accountID,
                  let pairedAccountID = paired.accountID,
                  sourceAccountID != pairedAccountID,
                  let amount = snapshot.amount, amount != Int.min,
                  paired.amount == -amount,
                  unitByTransactionID[transferID] != nil else {
                throw TransactionDuplicatePlannerError.malformedTransfer(snapshot.id)
            }
            incomingIDs[transferID, default: []].insert(snapshot.id)
        }
        for snapshot in snapshots {
            let expected = snapshot.transferID.map { Set([$0]) } ?? []
            if incomingIDs[snapshot.id, default: []] != expected {
                throw TransactionDuplicatePlannerError.malformedTransfer(snapshot.id)
            }
        }
    }

    private static func completeDuplicateGroup(
        selectedID: String,
        snapshotsByID: [String: TransactionBatchTransactionSnapshot],
        unitByTransactionID: [String: String],
        membersByUnitID: [String: Set<String>]
    ) throws -> Set<String> {
        guard let firstUnitID = unitByTransactionID[selectedID] else {
            throw TransactionDuplicatePlannerError.missingSelection(selectedID)
        }
        var pendingUnitIDs = [firstUnitID]
        var visitedUnitIDs = Set<String>()
        var members = Set<String>()
        while let unitID = pendingUnitIDs.popLast() {
            guard visitedUnitIDs.insert(unitID).inserted else { continue }
            guard let unitMembers = membersByUnitID[unitID], !unitMembers.isEmpty else {
                throw TransactionDuplicatePlannerError.malformedSplit(unitID)
            }
            members.formUnion(unitMembers)
            for memberID in unitMembers {
                guard let snapshot = snapshotsByID[memberID] else {
                    throw TransactionDuplicatePlannerError.unselectedSourceSnapshot(memberID)
                }
                if let transferID = snapshot.transferID {
                    guard let pairedUnitID = unitByTransactionID[transferID] else {
                        throw TransactionDuplicatePlannerError.malformedTransfer(memberID)
                    }
                    pendingUnitIDs.append(pairedUnitID)
                }
            }
        }
        return members
    }

    private static func validateAllocations(
        _ allocations: [TransactionDuplicateAllocation],
        sourceIDs: Set<String>,
        snapshotsByID: [String: TransactionBatchTransactionSnapshot]
    ) throws -> [TransactionDuplicateAllocation] {
        var bySourceID: [String: TransactionDuplicateAllocation] = [:]
        var duplicateIDs = Set<String>()
        var allocatedOrders = Set<Double>()
        let sourceOrders = Set(snapshotsByID.values.compactMap(\.sortOrder))
        for allocation in allocations {
            guard bySourceID[allocation.sourceTransactionID] == nil else {
                throw TransactionDuplicatePlannerError.duplicateAllocation(allocation.sourceTransactionID)
            }
            guard sourceIDs.contains(allocation.sourceTransactionID) else {
                throw TransactionDuplicatePlannerError.extraAllocation(allocation.sourceTransactionID)
            }
            guard !allocation.duplicateTransactionID.isEmpty else {
                throw TransactionDuplicatePlannerError.invalidDuplicateID(allocation.sourceTransactionID)
            }
            guard duplicateIDs.insert(allocation.duplicateTransactionID).inserted else {
                throw TransactionDuplicatePlannerError.duplicateDuplicateID(allocation.duplicateTransactionID)
            }
            guard !snapshotsByID.keys.contains(allocation.duplicateTransactionID) else {
                throw TransactionDuplicatePlannerError.duplicateIDAliasesSource(allocation.duplicateTransactionID)
            }
            guard allocation.sortOrder.isFinite else {
                throw TransactionDuplicatePlannerError.invalidSortOrder(allocation.sourceTransactionID)
            }
            guard !sourceOrders.contains(allocation.sortOrder) else {
                throw TransactionDuplicatePlannerError.staleSortOrder(allocation.sourceTransactionID)
            }
            guard allocatedOrders.insert(allocation.sortOrder).inserted else {
                throw TransactionDuplicatePlannerError.duplicateSortOrder
            }
            bySourceID[allocation.sourceTransactionID] = allocation
        }
        if let missing = sourceIDs.subtracting(Set(bySourceID.keys)).sorted().first {
            throw TransactionDuplicatePlannerError.missingAllocation(missing)
        }
        return bySourceID.values.sorted { $0.sourceTransactionID < $1.sourceTransactionID }
    }

    private static func duplicateID(
        for sourceID: String,
        allocationsBySourceID: [String: TransactionDuplicateAllocation]
    ) throws -> String {
        guard let allocation = allocationsBySourceID[sourceID] else {
            throw TransactionDuplicatePlannerError.missingAllocation(sourceID)
        }
        return allocation.duplicateTransactionID
    }

    private static func duplicateSnapshot(
        from source: TransactionBatchTransactionSnapshot,
        allocation: TransactionDuplicateAllocation,
        allocationsBySourceID: [String: TransactionDuplicateAllocation]
    ) throws -> TransactionBatchTransactionSnapshot {
        let parentID: String?
        if let sourceParentID = source.parentID {
            parentID = try duplicateID(for: sourceParentID, allocationsBySourceID: allocationsBySourceID)
        } else {
            parentID = nil
        }
        let transferID: String?
        if let sourceTransferID = source.transferID {
            transferID = try duplicateID(for: sourceTransferID, allocationsBySourceID: allocationsBySourceID)
        } else {
            transferID = nil
        }
        return TransactionBatchTransactionSnapshot(
            id: allocation.duplicateTransactionID,
            columns: source.columns,
            accountID: source.accountID,
            dateValue: source.dateValue,
            amount: source.amount,
            payeeID: source.payeeID,
            categoryID: source.categoryID,
            notes: source.notes,
            cleared: false,
            reconciled: false,
            tombstone: source.columns.contains("tombstone") ? false : nil,
            isParent: source.isParent,
            isChild: source.isChild,
            parentID: parentID,
            transferID: transferID,
            sortOrder: allocation.sortOrder,
            splitError: source.splitError,
            startingBalance: source.startingBalance,
            scheduleID: source.scheduleID,
            importedID: source.importedID,
            importedPayee: source.importedPayee,
            importedDescription: source.importedDescription
        )
    }

    private static func validateProposedLinks(
        _ snapshots: [TransactionBatchTransactionSnapshot]
    ) throws {
        let byID = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0) })
        for snapshot in snapshots {
            guard snapshot.cleared == false, snapshot.reconciled == false else {
                throw TransactionDuplicatePlannerError.missingRequiredField(snapshot.id)
            }
            if let parentID = snapshot.parentID {
                guard parentID != snapshot.id,
                      let parent = byID[parentID], parent.isParent == true,
                      snapshot.isChild == true else {
                    throw TransactionDuplicatePlannerError.malformedSplit(snapshot.id)
                }
            }
            if snapshot.isParent == true {
                guard snapshots.contains(where: { $0.parentID == snapshot.id && $0.isChild == true }) else {
                    throw TransactionDuplicatePlannerError.zeroChildSplit(snapshot.id)
                }
            }
            if let transferID = snapshot.transferID {
                guard transferID != snapshot.id,
                      let paired = byID[transferID], paired.transferID == snapshot.id else {
                    throw TransactionDuplicatePlannerError.malformedTransfer(snapshot.id)
                }
            }
        }
    }

    private static func affectedResources(
        sourceSnapshots: [TransactionBatchTransactionSnapshot],
        duplicateSnapshots: [TransactionBatchTransactionSnapshot]
    ) throws -> ChangedResources {
        let allSnapshots = sourceSnapshots + duplicateSnapshots
        var months = Set<String>()
        for snapshot in allSnapshots {
            guard let dateValue = snapshot.dateValue, let monthID = YearMonth(validatingPackedDate: dateValue)?.rawValue else {
                throw TransactionDuplicatePlannerError.missingRequiredField(snapshot.id)
            }
            months.insert(monthID)
        }
        let accounts = try allSnapshots.map { snapshot in
            guard let accountID = snapshot.accountID, !accountID.isEmpty else {
                throw TransactionDuplicatePlannerError.missingRequiredField(snapshot.id)
            }
            return accountID
        }
        return ChangedResources(
            accounts: Set(accounts).sorted(),
            months: months.sorted(),
            transactions: Set(allSnapshots.map(\.id)).sorted()
        )
    }

    private static func actualDateID(for packedDate: Int) -> String? {
        guard packedDate > 0 else { return nil }
        let year = packedDate / 10_000
        let month = (packedDate / 100) % 100
        let day = packedDate % 100
        guard (1...9_999).contains(year) else { return nil }
        let dateID = String(format: "%04d-%02d-%02d", year, month, day)
        guard ActualDateOnly.date(from: dateID, timeZone: .gmt) != nil else { return nil }
        return dateID
    }

    private static func hasSplitError(_ error: String) -> Bool {
        !error.isEmpty && error != "null"
    }
}
