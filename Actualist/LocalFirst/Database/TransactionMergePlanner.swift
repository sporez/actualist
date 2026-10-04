import Foundation

/// Pure C5 projection. Database callers must first load each closure with
/// `transactionBatchGraph` and reject its SQL-backed `invalidReason`; this
/// planner validates the supplied rows and proposed in-memory after-graph, but
/// deliberately does not rediscover SQL membership or external backlinks.
enum TransactionMergePlanner {
    private struct ValidatedGraph {
        let rows: [String: TransactionBatchTransactionSnapshot]
        let childrenByParentID: [String: [String]]
    }

    private struct PairMerge {
        let keptID: String
        let droppedID: String
    }

    private enum Check<Value> {
        case valid(Value)
        case blocked(TransactionMergeBlockedReason)
    }

    static func plan(_ input: TransactionMergePlannerInput) -> TransactionMergePlanningResult {
        guard input.orderedTransactionIDs.count == 2 else {
            return .blocked(.requiresExactlyTwoIDs)
        }
        let orderedIDs = input.orderedTransactionIDs
        guard orderedIDs.allSatisfy({ !$0.isEmpty }) else { return .blocked(.emptyTransactionID) }
        guard orderedIDs[0] != orderedIDs[1] else { return .blocked(.duplicateTransactionID) }

        let overlaps = Set(input.firstGraph.map(\.id))
            .intersection(Set(input.secondGraph.map(\.id)))
            .sorted()
        guard overlaps.isEmpty else { return .blocked(.overlappingGraphs(overlaps)) }

        guard let reference = validatedReference(input.referenceMetadata) else {
            return .blocked(.invalidReferenceMetadata)
        }
        let first: ValidatedGraph
        switch validateGraph(input.firstGraph, selectedID: orderedIDs[0], reference: reference) {
        case .valid(let graph): first = graph
        case .blocked(let reason): return .blocked(reason)
        }
        let second: ValidatedGraph
        switch validateGraph(input.secondGraph, selectedID: orderedIDs[1], reference: reference) {
        case .valid(let graph): second = graph
        case .blocked(let reason): return .blocked(reason)
        }

        guard let firstRoot = first.rows[orderedIDs[0]],
              let secondRoot = second.rows[orderedIDs[1]] else {
            return .blocked(.missingRootSnapshot(orderedIDs.first ?? ""))
        }
        guard let firstAccountID = firstRoot.accountID,
              let secondAccountID = secondRoot.accountID,
              firstAccountID == secondAccountID else { return .blocked(.accountMismatch) }
        guard let firstAmount = firstRoot.amount,
              let secondAmount = secondRoot.amount,
              firstAmount == secondAmount else { return .blocked(.amountMismatch) }

        let originalRows = first.rows.merging(second.rows) { firstValue, _ in firstValue }
        let childrenByParentID = first.childrenByParentID.merging(second.childrenByParentID) {
            firstValue, _ in firstValue
        }
        let firstTransferPeerID = firstRoot.transferID
        let secondTransferPeerID = secondRoot.transferID
        let hasTwoRootTransfers = firstTransferPeerID != nil && secondTransferPeerID != nil
        let hasOneRootTransfer = (firstTransferPeerID != nil) != (secondTransferPeerID != nil)

        if hasTwoRootTransfers {
            guard firstRoot.payeeID == secondRoot.payeeID,
                  let firstDestination = firstRoot.payeeID.flatMap({ reference.destinationByPayeeID[$0] }),
                  let secondDestination = secondRoot.payeeID.flatMap({ reference.destinationByPayeeID[$0] }),
                  firstDestination == secondDestination else {
                return .blocked(.differentTransferDestinations)
            }
        }

        var afterRows = originalRows
        if let peerID = firstTransferPeerID {
            afterRows[orderedIDs[0]] = afterRows[orderedIDs[0]]?.withTransferID(nil)
            afterRows[peerID] = afterRows[peerID]?.withTransferID(nil)
        }
        if let peerID = secondTransferPeerID {
            afterRows[orderedIDs[1]] = afterRows[orderedIDs[1]]?.withTransferID(nil)
            afterRows[peerID] = afterRows[peerID]?.withTransferID(nil)
        }

        let rootPair = chooseKeepDrop(firstRoot, secondRoot)
        let rootTransferPayeeID: String? = {
            if firstTransferPeerID != nil { return firstRoot.payeeID }
            if secondTransferPeerID != nil { return secondRoot.payeeID }
            return nil
        }()
        let rootTransferDestination = rootTransferPayeeID.flatMap { reference.destinationByPayeeID[$0] }
        let rootDestinationIsOffBudget = rootTransferDestination.flatMap {
            reference.accountsByID[$0]?.isOffBudget
        }
        let clearsCategoryForTransfer = hasOneRootTransfer && rootDestinationIsOffBudget == false

        var fieldEffects: [TransactionMergeFieldEffect] = []
        var childMovements: [TransactionMergeChildMovement] = []
        var deletedIDs = Set<String>()

        let rootMerge: PairMerge
        switch mergePair(
            rootPair,
            originalRows: originalRows,
            afterRows: &afterRows,
            childrenByParentID: childrenByParentID,
            transferPayeeID: rootTransferPayeeID,
            clearCategoryForOnBudgetTransfer: clearsCategoryForTransfer,
            fieldEffects: &fieldEffects,
            childMovements: &childMovements,
            deletedIDs: &deletedIDs
        ) {
        case .valid(let pair): rootMerge = pair
        case .blocked(let reason): return .blocked(reason)
        }

        let transferDisposition: TransactionMergeTransferDisposition
        if hasTwoRootTransfers {
            guard let firstPeerID = firstTransferPeerID,
                  let secondPeerID = secondTransferPeerID,
                  let firstPeer = originalRows[firstPeerID],
                  let secondPeer = originalRows[secondPeerID] else {
                return .blocked(.malformedTransfer(orderedIDs[0]))
            }
            guard firstPeer.isChild == false, secondPeer.isChild == false else {
                return .blocked(.malformedTransfer(firstPeer.isChild == true ? firstPeerID : secondPeerID))
            }
            let peerPair = chooseKeepDrop(firstPeer, secondPeer)
            let peerMerge: PairMerge
            switch mergePair(
                peerPair,
                originalRows: originalRows,
                afterRows: &afterRows,
                childrenByParentID: childrenByParentID,
                transferPayeeID: nil,
                clearCategoryForOnBudgetTransfer: false,
                fieldEffects: &fieldEffects,
                childMovements: &childMovements,
                deletedIDs: &deletedIDs
            ) {
            case .valid(let pair): peerMerge = pair
            case .blocked(let reason): return .blocked(reason)
            }
            guard let destination = rootTransferDestination else {
                return .blocked(.missingTransferDestination(rootMerge.keptID))
            }
            afterRows[rootMerge.keptID] = afterRows[rootMerge.keptID]?.withTransferID(peerMerge.keptID)
            afterRows[peerMerge.keptID] = afterRows[peerMerge.keptID]?.withTransferID(rootMerge.keptID)
            transferDisposition = .mergedPairs(
                keptPeerID: peerMerge.keptID,
                droppedPeerID: peerMerge.droppedID,
                destinationAccountID: destination
            )
        } else if hasOneRootTransfer {
            guard let peerID = firstTransferPeerID ?? secondTransferPeerID else {
                return .blocked(.malformedTransfer(orderedIDs[0]))
            }
            guard originalRows[peerID] != nil,
                  let destination = rootTransferDestination else {
                return .blocked(.malformedTransfer(peerID))
            }
            afterRows[rootMerge.keptID] = afterRows[rootMerge.keptID]?.withTransferID(peerID)
            afterRows[peerID] = afterRows[peerID]?.withTransferID(rootMerge.keptID)
            transferDisposition = .adoptedPair(peerID: peerID, destinationAccountID: destination)
        } else {
            transferDisposition = .none
        }

        if let proposedFailure = validateProposedGraph(
            afterRows,
            reference: reference
        ) {
            return .blocked(proposedFailure)
        }
        let snapshots = afterRows.values.sorted { $0.id < $1.id }
        let beforeSnapshots = originalRows.values.sorted { $0.id < $1.id }
        let tombstones = snapshots.filter { $0.tombstone == true }.map(\.id)
        let tombstoneSet = Set(tombstones)
        let tombstonedPeers = Set(tombstones.filter { id in
            guard let peerID = originalRows[id]?.transferID else { return false }
            return tombstoneSet.contains(peerID)
        }).sorted()
        let activePairs = Set(snapshots.compactMap { snapshot -> TransactionMergeTransferPair? in
            guard snapshot.tombstone != true, let peerID = snapshot.transferID else { return nil }
            return TransactionMergeTransferPair(snapshot.id, peerID)
        }).sorted {
            ($0.firstTransactionID, $0.secondTransactionID) < ($1.firstTransactionID, $1.secondTransactionID)
        }
        let metadata = TransactionMergeReferenceMetadata(
            accounts: input.referenceMetadata.accounts.sorted { $0.id < $1.id },
            transferPayeeDestinations: input.referenceMetadata.transferPayeeDestinations.sorted {
                ($0.payeeID, $0.accountID) < ($1.payeeID, $1.accountID)
            }
        )
        let fingerprintInputs = TransactionMergeFingerprintInputs(
            orderedTransactionIDs: orderedIDs,
            firstGraph: first.rows.values.sorted { $0.id < $1.id },
            secondGraph: second.rows.values.sorted { $0.id < $1.id },
            referenceMetadata: metadata
        )
        let resources = affectedResources(beforeSnapshots)
        let reconciledIDs = beforeSnapshots.filter { $0.reconciled == true }.map(\.id).sorted()
        return .ready(TransactionMergePlan(
            orderedTransactionIDs: orderedIDs,
            keptTransactionID: rootMerge.keptID,
            droppedTransactionID: rootMerge.droppedID,
            fieldEffects: fieldEffects.sorted {
                ($0.transactionID, $0.field.rawValue) < ($1.transactionID, $1.field.rawValue)
            },
            childMovements: childMovements.sorted { $0.childID < $1.childID },
            transferDisposition: transferDisposition,
            reciprocalTransferPairs: activePairs,
            beforeSnapshots: beforeSnapshots,
            afterSnapshots: snapshots,
            tombstonedTransactionIDs: tombstones,
            tombstonedPeerIDs: tombstonedPeers,
            reconciledTransactionIDs: reconciledIDs,
            affectedResources: resources,
            fingerprintInputs: fingerprintInputs
        ))
    }

    private struct ValidatedReference {
        let accountsByID: [String: TransactionMergeAccountMetadata]
        let destinationByPayeeID: [String: String]
    }

    private static func validatedReference(
        _ metadata: TransactionMergeReferenceMetadata
    ) -> ValidatedReference? {
        guard metadata.accounts.allSatisfy({ !$0.id.isEmpty }),
              metadata.transferPayeeDestinations.allSatisfy({ !$0.payeeID.isEmpty && !$0.accountID.isEmpty }) else {
            return nil
        }
        let accounts = Dictionary(grouping: metadata.accounts, by: \.id)
        let destinations = Dictionary(grouping: metadata.transferPayeeDestinations, by: \.payeeID)
        guard accounts.values.allSatisfy({ $0.count == 1 }),
              destinations.values.allSatisfy({ $0.count == 1 }) else { return nil }
        let accountsByID = Dictionary(uniqueKeysWithValues: metadata.accounts.map { ($0.id, $0) })
        guard metadata.transferPayeeDestinations.allSatisfy({ accountsByID[$0.accountID] != nil }) else {
            return nil
        }
        return ValidatedReference(
            accountsByID: accountsByID,
            destinationByPayeeID: Dictionary(uniqueKeysWithValues: metadata.transferPayeeDestinations.map {
                ($0.payeeID, $0.accountID)
            })
        )
    }

    private static func validateGraph(
        _ snapshots: [TransactionBatchTransactionSnapshot],
        selectedID: String,
        reference: ValidatedReference
    ) -> Check<ValidatedGraph> {
        var rows: [String: TransactionBatchTransactionSnapshot] = [:]
        let orderedSnapshots = snapshots.sorted { $0.id < $1.id }
        for snapshot in orderedSnapshots {
            guard !snapshot.id.isEmpty, rows[snapshot.id] == nil else {
                return .blocked(.malformedRow(snapshot.id))
            }
            rows[snapshot.id] = snapshot
        }
        guard let selected = rows[selectedID] else { return .blocked(.missingRootSnapshot(selectedID)) }
        if selected.isChild == true || selected.parentID != nil {
            return .blocked(.selectedChild(selectedID))
        }
        guard !orderedSnapshots.isEmpty else { return .blocked(.missingRootSnapshot(selectedID)) }

        var childrenByParentID: [String: [String]] = [:]
        for snapshot in orderedSnapshots {
            guard let accountID = snapshot.accountID, !accountID.isEmpty,
                  reference.accountsByID[accountID] != nil,
                  let dateValue = snapshot.dateValue, YearMonth(validatingPackedDate: dateValue) != nil,
                  snapshot.amount != nil,
                  snapshot.isParent != nil,
                  snapshot.isChild != nil,
                  snapshot.tombstone == false else {
                if let accountID = snapshot.accountID, !accountID.isEmpty,
                   reference.accountsByID[accountID] == nil {
                    return .blocked(.missingAccountMetadata(accountID))
                }
                return .blocked(.malformedRow(snapshot.id))
            }
            if hasSplitError(snapshot.splitError) { return .blocked(.splitHasError(snapshot.id)) }
            if snapshot.isParent == true && snapshot.isChild == true {
                return .blocked(.malformedSplit(snapshot.id))
            }
            if snapshot.isChild == true {
                guard let parentID = snapshot.parentID, !parentID.isEmpty, parentID != snapshot.id else {
                    return .blocked(.malformedSplit(snapshot.id))
                }
                childrenByParentID[parentID, default: []].append(snapshot.id)
            } else if snapshot.parentID != nil {
                return .blocked(.malformedSplit(snapshot.id))
            }
        }

        for snapshot in orderedSnapshots {
            let children = childrenByParentID[snapshot.id, default: []]
            if snapshot.isParent == true {
                guard !children.isEmpty else { return .blocked(.zeroChildSplit(snapshot.id)) }
                guard snapshot.categoryID == nil else { return .blocked(.malformedSplit(snapshot.id)) }
                guard children.allSatisfy({ rows[$0]?.isChild == true }) else {
                    return .blocked(.malformedSplit(snapshot.id))
                }
                guard splitIsBalanced(parent: snapshot, childIDs: children, rows: rows) else {
                    return .blocked(.malformedSplit(snapshot.id))
                }
            } else if !children.isEmpty {
                return .blocked(.malformedSplit(snapshot.id))
            }
        }
        for child in orderedSnapshots where child.isChild == true {
            guard let parentID = child.parentID,
                  let parent = rows[parentID], parent.isParent == true else {
                return .blocked(.malformedSplit(child.id))
            }
        }

        if let transferFailure = validateTransferLinks(rows, reference: reference, allowTombstones: false) {
            return .blocked(transferFailure)
        }
        if let disconnectedID = disconnectedRowID(
            rows: rows,
            childrenByParentID: childrenByParentID,
            selectedID: selectedID
        ) {
            return .blocked(.malformedRow(disconnectedID))
        }
        return .valid(ValidatedGraph(rows: rows, childrenByParentID: childrenByParentID))
    }

    private static func disconnectedRowID(
        rows: [String: TransactionBatchTransactionSnapshot],
        childrenByParentID: [String: [String]],
        selectedID: String
    ) -> String? {
        var adjacent: [String: Set<String>] = [:]
        for (parentID, childIDs) in childrenByParentID {
            for childID in childIDs {
                adjacent[parentID, default: []].insert(childID)
                adjacent[childID, default: []].insert(parentID)
            }
        }
        for snapshot in rows.values {
            guard let peerID = snapshot.transferID else { continue }
            adjacent[snapshot.id, default: []].insert(peerID)
            adjacent[peerID, default: []].insert(snapshot.id)
        }

        var reachable: Set<String> = [selectedID]
        var pending = [selectedID]
        while let currentID = pending.popLast() {
            for neighborID in adjacent[currentID, default: []].sorted()
                where reachable.insert(neighborID).inserted {
                pending.append(neighborID)
            }
        }
        return Set(rows.keys).subtracting(reachable).sorted().first
    }

    private static func validateTransferLinks(
        _ rows: [String: TransactionBatchTransactionSnapshot],
        reference: ValidatedReference,
        allowTombstones: Bool
    ) -> TransactionMergeBlockedReason? {
        let active = allowTombstones
            ? rows.filter { $0.value.tombstone == false }
            : rows
        var incoming: [String: [String]] = [:]
        for snapshot in active.values.sorted(by: { $0.id < $1.id }) {
            if let peerID = snapshot.transferID {
                guard !peerID.isEmpty else { return .malformedTransfer(snapshot.id) }
                incoming[peerID, default: []].append(snapshot.id)
            }
        }
        for targetID in incoming.keys.sorted() where incoming[targetID, default: []].count > 1 {
            return .extraIncomingTransfer(targetID)
        }
        for snapshot in active.values.sorted(by: { $0.id < $1.id }) {
            guard let peerID = snapshot.transferID else { continue }
            guard let peer = active[peerID], peerID != snapshot.id,
                  peer.transferID == snapshot.id,
                  let accountID = snapshot.accountID,
                  let peerAccountID = peer.accountID,
                  accountID != peerAccountID,
                  let amount = snapshot.amount,
                  amount != Int.min,
                  peer.amount == -amount else {
                return .malformedTransfer(snapshot.id)
            }
            guard let payeeID = snapshot.payeeID,
                  reference.destinationByPayeeID[payeeID] == peerAccountID else {
                return .missingTransferDestination(snapshot.id)
            }
            guard let peerPayeeID = peer.payeeID,
                  reference.destinationByPayeeID[peerPayeeID] == accountID else {
                // Attribute the block to the row that owns the missing payee
                // mapping, not to the row whose reciprocal check noticed it.
                return .missingTransferDestination(peer.id)
            }
        }
        return nil
    }

    private static func mergePair(
        _ chosen: PairMerge,
        originalRows: [String: TransactionBatchTransactionSnapshot],
        afterRows: inout [String: TransactionBatchTransactionSnapshot],
        childrenByParentID: [String: [String]],
        transferPayeeID: String?,
        clearCategoryForOnBudgetTransfer: Bool,
        fieldEffects: inout [TransactionMergeFieldEffect],
        childMovements: inout [TransactionMergeChildMovement],
        deletedIDs: inout Set<String>
    ) -> Check<PairMerge> {
        guard let keep = originalRows[chosen.keptID],
              let drop = originalRows[chosen.droppedID],
              let proposed = afterRows[chosen.keptID] else {
            return .blocked(.malformedRow(chosen.keptID))
        }
        let keepChildren = childrenByParentID[keep.id, default: []].sorted()
        let dropChildren = childrenByParentID[drop.id, default: []].sorted()
        let keepWasSplit = !keepChildren.isEmpty
        let dropWasSplit = !dropChildren.isEmpty
        let adoptingSplit = !keepWasSplit && dropWasSplit

        let payeeFallback = javascriptOr(keep.payeeID, drop.payeeID)
        var categoryAfter = javascriptOr(keep.categoryID, drop.categoryID)
        let payeeAfter = transferPayeeID ?? payeeFallback
        if adoptingSplit { categoryAfter = nil }
        if clearCategoryForOnBudgetTransfer { categoryAfter = nil }

        if keepWasSplit {
            guard categoryAfter == nil, doesNotAcquireParentPayee(payeeAfter, from: keep.payeeID) else {
                return .blocked(.invalidProposedParentFields(keep.id))
            }
        } else if adoptingSplit {
            // RULE A: the newly converted parent may retain its own payee, but
            // a truthy value newly sourced from the dropped family is not admitted.
            guard doesNotAcquireParentPayee(payeeAfter, from: keep.payeeID) else {
                return .blocked(.invalidProposedParentFields(keep.id))
            }
        }

        let merged = proposed.mergingFields(
            payeeID: payeeAfter,
            categoryID: categoryAfter,
            notes: javascriptOr(keep.notes, drop.notes),
            cleared: javascriptOr(keep.cleared, drop.cleared),
            reconciled: javascriptOr(keep.reconciled, drop.reconciled),
            scheduleID: javascriptOr(keep.scheduleID, drop.scheduleID),
            isParent: adoptingSplit ? true : proposed.isParent,
            isChild: adoptingSplit ? false : proposed.isChild,
            parentID: adoptingSplit ? nil : proposed.parentID,
            splitError: adoptingSplit ? nil : proposed.splitError
        )
        afterRows[keep.id] = merged
        fieldEffects.append(contentsOf: makeFieldEffects(
            keep: keep,
            drop: drop,
            after: merged,
            adoptingSplit: adoptingSplit,
            transferPayeeID: transferPayeeID,
            clearCategoryForOnBudgetTransfer: clearCategoryForOnBudgetTransfer
        ))

        if adoptingSplit {
            for childID in dropChildren {
                guard let child = afterRows[childID] else { return .blocked(.malformedSplit(childID)) }
                afterRows[childID] = child.reparented(to: keep.id)
                childMovements.append(TransactionMergeChildMovement(
                    childID: childID,
                    originalParentID: drop.id,
                    newParentID: keep.id
                ))
            }
            tombstone(drop.id, afterRows: &afterRows, deletedIDs: &deletedIDs)
        } else {
            tombstoneComponent(
                drop.id,
                afterRows: &afterRows,
                childrenByParentID: childrenByParentID,
                visited: &deletedIDs
            )
        }
        return .valid(chosen)
    }

    private static func chooseKeepDrop(
        _ first: TransactionBatchTransactionSnapshot,
        _ second: TransactionBatchTransactionSnapshot
    ) -> PairMerge {
        if isTruthy(second.importedID), !isTruthy(first.importedID) {
            return PairMerge(keptID: second.id, droppedID: first.id)
        }
        if isTruthy(first.importedID), !isTruthy(second.importedID) {
            return PairMerge(keptID: first.id, droppedID: second.id)
        }
        if isTruthy(second.importedPayee), !isTruthy(first.importedPayee) {
            return PairMerge(keptID: second.id, droppedID: first.id)
        }
        if isTruthy(first.importedPayee), !isTruthy(second.importedPayee) {
            return PairMerge(keptID: first.id, droppedID: second.id)
        }
        guard let firstDate = first.dateValue, let secondDate = second.dateValue else {
            return PairMerge(keptID: second.id, droppedID: first.id)
        }
        if firstDate < secondDate {
            return PairMerge(keptID: first.id, droppedID: second.id)
        }
        return PairMerge(keptID: second.id, droppedID: first.id)
    }

    private static func makeFieldEffects(
        keep: TransactionBatchTransactionSnapshot,
        drop: TransactionBatchTransactionSnapshot,
        after: TransactionBatchTransactionSnapshot,
        adoptingSplit: Bool,
        transferPayeeID: String?,
        clearCategoryForOnBudgetTransfer: Bool
    ) -> [TransactionMergeFieldEffect] {
        func textEffect(
            _ field: TransactionMergeField,
            _ kept: String?,
            _ dropped: String?,
            _ result: String?,
            _ winner: TransactionMergeFieldWinner
        ) -> TransactionMergeFieldEffect {
            TransactionMergeFieldEffect(
                transactionID: keep.id,
                field: field,
                beforeValue: .text(kept),
                droppedValue: .text(dropped),
                afterValue: .text(result),
                winner: winner
            )
        }
        func booleanEffect(
            _ field: TransactionMergeField,
            _ kept: Bool?,
            _ dropped: Bool?,
            _ result: Bool?
        ) -> TransactionMergeFieldEffect {
            TransactionMergeFieldEffect(
                transactionID: keep.id,
                field: field,
                beforeValue: .boolean(kept),
                droppedValue: .boolean(dropped),
                afterValue: .boolean(result),
                winner: .logicalOr
            )
        }
        let effects = [
            TransactionMergeFieldEffect(transactionID: keep.id, field: .accountID,
                beforeValue: .text(keep.accountID), droppedValue: .text(drop.accountID), afterValue: .text(after.accountID), winner: .keptIdentity),
            TransactionMergeFieldEffect(transactionID: keep.id, field: .dateValue,
                beforeValue: .integer(keep.dateValue), droppedValue: .integer(drop.dateValue), afterValue: .integer(after.dateValue), winner: .keptIdentity),
            TransactionMergeFieldEffect(transactionID: keep.id, field: .amount,
                beforeValue: .integer(keep.amount), droppedValue: .integer(drop.amount), afterValue: .integer(after.amount), winner: .keptIdentity),
            textEffect(.payeeID, keep.payeeID, drop.payeeID, after.payeeID,
                transferPayeeID != nil ? .transferDestination : (isTruthy(keep.payeeID) ? .keptValue : .droppedFallback)),
            textEffect(.categoryID, keep.categoryID, drop.categoryID, after.categoryID,
                adoptingSplit ? .splitParentConstraint : (clearCategoryForOnBudgetTransfer ? .transferDestination : (isTruthy(keep.categoryID) ? .keptValue : .droppedFallback))),
            textEffect(.notes, keep.notes, drop.notes, after.notes,
                isTruthy(keep.notes) ? .keptValue : .droppedFallback),
            booleanEffect(.cleared, keep.cleared, drop.cleared, after.cleared),
            booleanEffect(.reconciled, keep.reconciled, drop.reconciled, after.reconciled),
            textEffect(.scheduleID, keep.scheduleID, drop.scheduleID, after.scheduleID,
                isTruthy(keep.scheduleID) ? .keptValue : .droppedFallback),
            textEffect(.importedID, keep.importedID, drop.importedID, after.importedID, .keptIdentity),
            textEffect(.importedPayee, keep.importedPayee, drop.importedPayee, after.importedPayee, .keptIdentity),
            textEffect(.importedDescription, keep.importedDescription, drop.importedDescription, after.importedDescription, .keptIdentity),
            TransactionMergeFieldEffect(transactionID: keep.id, field: .startingBalance,
                beforeValue: .boolean(keep.startingBalance), droppedValue: .boolean(drop.startingBalance), afterValue: .boolean(after.startingBalance), winner: .keptIdentity),
            TransactionMergeFieldEffect(transactionID: keep.id, field: .sortOrder,
                beforeValue: .decimal(keep.sortOrder), droppedValue: .decimal(drop.sortOrder), afterValue: .decimal(after.sortOrder), winner: .keptIdentity),
        ]
        return effects
    }

    private static func tombstoneComponent(
        _ transactionID: String,
        afterRows: inout [String: TransactionBatchTransactionSnapshot],
        childrenByParentID: [String: [String]],
        visited: inout Set<String>
    ) {
        guard visited.insert(transactionID).inserted,
              let row = afterRows[transactionID] else { return }
        afterRows[transactionID] = row.tombstoned()
        for childID in childrenByParentID[transactionID, default: []] {
            tombstoneComponent(childID, afterRows: &afterRows, childrenByParentID: childrenByParentID, visited: &visited)
        }
        if let peerID = row.transferID {
            tombstoneComponent(peerID, afterRows: &afterRows, childrenByParentID: childrenByParentID, visited: &visited)
        }
    }

    private static func tombstone(
        _ transactionID: String,
        afterRows: inout [String: TransactionBatchTransactionSnapshot],
        deletedIDs: inout Set<String>
    ) {
        guard let row = afterRows[transactionID] else { return }
        afterRows[transactionID] = row.tombstoned()
        deletedIDs.insert(transactionID)
    }

    private static func validateProposedGraph(
        _ rows: [String: TransactionBatchTransactionSnapshot],
        reference: ValidatedReference
    ) -> TransactionMergeBlockedReason? {
        var childrenByParentID: [String: [String]] = [:]
        let active = rows.filter { $0.value.tombstone == false }
        for snapshot in active.values.sorted(by: { $0.id < $1.id }) {
            guard let accountID = snapshot.accountID, !accountID.isEmpty,
                  reference.accountsByID[accountID] != nil,
                  let dateValue = snapshot.dateValue, YearMonth(validatingPackedDate: dateValue) != nil,
                  snapshot.amount != nil,
                  let isParent = snapshot.isParent,
                  let isChild = snapshot.isChild else {
                if let accountID = snapshot.accountID, !accountID.isEmpty,
                   reference.accountsByID[accountID] == nil {
                    return .missingAccountMetadata(accountID)
                }
                return .malformedRow(snapshot.id)
            }
            if isParent && isChild { return .malformedSplit(snapshot.id) }
            if isChild {
                guard let parentID = snapshot.parentID, !parentID.isEmpty,
                      let parent = active[parentID], parent.isParent == true else {
                    return .malformedSplit(snapshot.id)
                }
                childrenByParentID[parentID, default: []].append(snapshot.id)
            } else if snapshot.parentID != nil {
                return .malformedSplit(snapshot.id)
            }
            if isParent && snapshot.categoryID != nil {
                return .invalidProposedParentFields(snapshot.id)
            }
            if hasSplitError(snapshot.splitError) { return .splitHasError(snapshot.id) }
        }
        for snapshot in active.values.sorted(by: { $0.id < $1.id }) {
            let children = childrenByParentID[snapshot.id, default: []]
            if snapshot.isParent == true {
                guard !children.isEmpty else { return .zeroChildSplit(snapshot.id) }
                guard splitIsBalanced(parent: snapshot, childIDs: children, rows: active) else {
                    return .malformedSplit(snapshot.id)
                }
            } else if !children.isEmpty {
                return .malformedSplit(snapshot.id)
            }
        }
        return validateTransferLinks(rows, reference: reference, allowTombstones: true)
    }

    private static func splitIsBalanced(
        parent: TransactionBatchTransactionSnapshot,
        childIDs: [String],
        rows: [String: TransactionBatchTransactionSnapshot]
    ) -> Bool {
        guard let parentAmount = parent.amount else { return false }
        let children = childIDs.compactMap { rows[$0] }
        guard children.count == childIDs.count else { return false }
        var total = 0
        for child in children {
            guard let amount = child.amount else { return false }
            let (nextTotal, overflow) = total.addingReportingOverflow(amount)
            guard !overflow else { return false }
            total = nextTotal
        }
        guard total == parentAmount else { return false }
        let family = SplitTransactionRecord(
            id: parent.id,
            amount: parentAmount,
            account: parent.accountID,
            date: parent.dateValue.map { String($0) },
            category: parent.categoryID,
            payee: parent.payeeID,
            notes: parent.notes,
            cleared: parent.cleared,
            reconciled: parent.reconciled,
            startingBalance: parent.startingBalance,
            sortOrder: parent.sortOrder,
            isParent: true,
            isChild: false,
            parentID: nil,
            transferID: parent.transferID,
            error: nil,
            deleted: false,
            subtransactions: children.map { child in
                SplitTransactionRecord(
                    id: child.id,
                    amount: child.amount ?? 0,
                    account: child.accountID,
                    date: child.dateValue.map { String($0) },
                    category: child.categoryID,
                    payee: child.payeeID,
                    notes: child.notes,
                    cleared: child.cleared,
                    reconciled: child.reconciled,
                    startingBalance: child.startingBalance,
                    sortOrder: child.sortOrder,
                    isParent: false,
                    isChild: true,
                    parentID: parent.id,
                    transferID: child.transferID,
                    error: nil,
                    deleted: false
                )
            }
        )
        return SplitTransactionFamilyOps.recalculateSplit(family).error == nil
    }

    private static func affectedResources(
        _ snapshots: [TransactionBatchTransactionSnapshot]
    ) -> TransactionMergeAffectedResources {
        TransactionMergeAffectedResources(
            changed: ChangedResources(
                accounts: Array(Set(snapshots.compactMap(\.accountID))).sorted(),
                months: Array(Set(snapshots.compactMap { snapshot in
                    snapshot.dateValue.flatMap { YearMonth(validatingPackedDate: $0)?.rawValue }
                })).sorted(),
                transactions: snapshots.map(\.id).sorted()
            ),
            payeeIDs: Array(Set(snapshots.compactMap(\.payeeID))).sorted(),
            categoryIDs: Array(Set(snapshots.compactMap(\.categoryID))).sorted()
        )
    }

    private static func hasSplitError(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.isEmpty && value != "null"
    }

    /// JavaScript string truthiness for the source's `||` merge expressions.
    private static func isTruthy(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.isEmpty
    }

    private static func javascriptOr(_ first: String?, _ second: String?) -> String? {
        isTruthy(first) ? first : second
    }

    /// Parent rows may retain the keeper's payee, but cannot acquire a truthy
    /// payee from a dropped simple row. Falsey fallback values remain governed
    /// by JavaScript `||` semantics and do not identify a payee.
    private static func doesNotAcquireParentPayee(_ proposed: String?, from kept: String?) -> Bool {
        proposed == kept || !isTruthy(proposed)
    }

    /// Preserve JavaScript's operand result for optional booleans, not merely a
    /// non-null fallback: `false || null` is null while `false || false` is false.
    private static func javascriptOr(_ first: Bool?, _ second: Bool?) -> Bool? {
        first == true ? first : second
    }
}
