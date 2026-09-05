import CoreGraphics

/// Wide-table geometry follows Display Size; Dynamic Type is applied separately.
struct BudgetGridDensityMetrics: Equatable {
    let density: ActualistDisplayDensity

    var categoryWidthScale: CGFloat {
        switch density {
        case .dense: 13 / 15
        case .compact: 1
        case .comfortable: 16 / 15
        case .large: 17 / 15
        }
    }

    var moneyWidthScale: CGFloat {
        switch density {
        case .dense: 12 / 13
        case .compact: 1
        case .comfortable: 15 / 13
        case .large: 17 / 13
        }
    }

    var rowHeight: CGFloat { max(44, 28 + density.transactionRowVerticalPadding * 2) }
    var groupHeight: CGFloat { rowHeight + 4 }
    var headerSpacing: CGFloat { density.transactionRowVerticalPadding * 0.8 }
    var headerPadding: CGFloat { density.transactionRowVerticalPadding }
    var cellPadding: CGFloat { density.rowHorizontalPadding * 4 / 7 }
}
