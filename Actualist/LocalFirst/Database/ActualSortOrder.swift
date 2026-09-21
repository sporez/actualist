enum ActualSortOrder {
    static let increment: Double = 16_384

    struct Item: Equatable {
        var id: String
        var sortOrder: Double
    }

    struct Result: Equatable {
        var sortOrder: Double
        var updates: [Item]
    }

    static func shove(items: [Item], targetID: String?) -> Result {
        guard let targetID,
              let targetIndex = items.firstIndex(where: { $0.id == targetID }) else {
            return Result(
                sortOrder: (items.last?.sortOrder ?? 0) + increment,
                updates: []
            )
        }

        let target = items[targetIndex]
        let before = targetIndex > 0 ? items[targetIndex - 1] : nil
        var updates: [Item] = []
        if target.sortOrder - (before?.sortOrder ?? 0) <= 2 {
            var next = targetIndex
            var order = items[next].sortOrder.rounded(.down) + increment
            while next < items.count {
                if order <= items[next].sortOrder {
                    break
                }
                updates.append(Item(id: items[next].id, sortOrder: order))
                next += 1
                order += increment
            }
        }

        return Result(
            sortOrder: targetIndex == 0
                ? target.sortOrder / 2
                : (items[targetIndex - 1].sortOrder + target.sortOrder) / 2,
            updates: updates
        )
    }
}
