import Foundation

struct BudgetCategoryOutlineDraft: Equatable, Sendable {
    struct Group: Equatable, Identifiable, Sendable {
        let id: String
        let name: String
        let isIncome: Bool
        let hidden: Bool
        var categories: [Category]
    }

    struct Category: Equatable, Identifiable, Sendable {
        let id: String
        let name: String
        let isIncome: Bool
        let hidden: Bool
    }

    private let originalGroups: [Group]
    private(set) var groups: [Group]

    init(groups: [BudgetMonthCategoryGroup], isTrackingBudget: Bool) {
        let managedGroups = isTrackingBudget ? groups : groups.filter { !$0.isIncome }
        let outline = managedGroups.map { group in
            Group(
                id: group.id,
                name: group.name,
                isIncome: group.isIncome,
                hidden: group.hidden == true,
                categories: group.categories.map {
                    Category(id: $0.id, name: $0.name, isIncome: $0.isIncome, hidden: $0.hidden == true)
                }
            )
        }
        originalGroups = outline
        self.groups = outline
    }

    var command: BudgetCategoryOutlineCommand? {
        guard groups != originalGroups else { return nil }
        return BudgetCategoryOutlineCommand(groups: groups.map {
            .init(id: $0.id, categoryIDs: $0.categories.map(\.id))
        })
    }

    mutating func moveCategory(
        id: String,
        toGroupID: String,
        beforeCategoryID: String?
    ) throws {
        guard let sourceGroupIndex = groups.firstIndex(where: { group in
            group.categories.contains { $0.id == id }
        }),
        let categoryIndex = groups[sourceGroupIndex].categories.firstIndex(where: { $0.id == id }),
        let destinationGroupIndex = groups.firstIndex(where: { $0.id == toGroupID }) else {
            throw LocalFirstError.invalidLocalWrite("the category outline changed before it could be saved")
        }
        let category = groups[sourceGroupIndex].categories[categoryIndex]
        if sourceGroupIndex == destinationGroupIndex, beforeCategoryID == id {
            return
        }
        guard category.isIncome == groups[destinationGroupIndex].isIncome else {
            throw LocalFirstError.invalidLocalWrite("income and expense categories cannot be mixed")
        }
        if groups[destinationGroupIndex].categories.contains(where: {
            $0.id != id && $0.name.compare(category.name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) {
            throw LocalFirstError.invalidLocalWrite("A category with the name \(category.name) already exists.")
        }
        if let beforeCategoryID,
           !groups[destinationGroupIndex].categories.contains(where: { $0.id == beforeCategoryID }) {
            throw LocalFirstError.invalidLocalWrite("the category outline changed before it could be saved")
        }

        groups[sourceGroupIndex].categories.remove(at: categoryIndex)
        guard let updatedDestinationIndex = groups.firstIndex(where: { $0.id == toGroupID }) else { return }
        let insertionIndex = beforeCategoryID.flatMap { targetID in
            groups[updatedDestinationIndex].categories.firstIndex { $0.id == targetID }
        } ?? groups[updatedDestinationIndex].categories.endIndex
        groups[updatedDestinationIndex].categories.insert(category, at: insertionIndex)
    }

    mutating func moveGroup(id: String, beforeGroupID: String?) throws {
        guard let moving = groups.first(where: { $0.id == id }) else {
            throw LocalFirstError.invalidLocalWrite("the category outline changed before it could be saved")
        }
        if beforeGroupID == id {
            return
        }
        if let beforeGroupID {
            guard let target = groups.first(where: { $0.id == beforeGroupID }) else {
                throw LocalFirstError.invalidLocalWrite("the category outline changed before it could be saved")
            }
            guard target.isIncome == moving.isIncome else {
                throw LocalFirstError.invalidLocalWrite("income and expense groups cannot be mixed")
            }
        }

        var sameKind = groups.filter { $0.isIncome == moving.isIncome && $0.id != id }
        let insertionIndex = beforeGroupID.flatMap { targetID in
            sameKind.firstIndex { $0.id == targetID }
        } ?? sameKind.endIndex
        sameKind.insert(moving, at: insertionIndex)
        var replacement = sameKind.makeIterator()
        groups = groups.map { group in
            group.isIncome == moving.isIncome ? replacement.next() ?? group : group
        }
    }
}
