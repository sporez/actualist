import SwiftUI

/// Where a row sits in a rounded group, for rows that cannot share one container
/// (lazy stacks and `List` sections). Each row draws its own share of the card.
struct GroupedRowPosition: Equatable {
    static let cornerRadius: CGFloat = 18

    let isFirst: Bool
    let isLast: Bool

    init(index: Int, count: Int) {
        isFirst = index == 0
        isLast = index == count - 1
    }

    var showsSeparator: Bool { !isLast }

    var shape: UnevenRoundedRectangle {
        let top = isFirst ? Self.cornerRadius : 0
        let bottom = isLast ? Self.cornerRadius : 0
        return UnevenRoundedRectangle(
            topLeadingRadius: top,
            bottomLeadingRadius: bottom,
            bottomTrailingRadius: bottom,
            topTrailingRadius: top,
            style: .continuous
        )
    }
}
