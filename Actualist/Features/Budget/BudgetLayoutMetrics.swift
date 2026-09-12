import CoreGraphics
import SwiftUI

enum BudgetPresentationMode: Equatable {
    case compact
    case splitSingleMonth
    case multiMonth
}

/// The inputs measured by the adaptive shell. `budgetDetailWidth` should be
/// the width inside the native split view (and inspector, when presented).
/// When it is present, the resolver does not subtract those widths again.
struct BudgetLayoutInputs: Equatable {
    var rootWidth: CGFloat
    /// The measured detail container width before content margins. When set,
    /// sidebar and inspector widths are not subtracted a second time.
    var budgetDetailWidth: CGFloat?
    var sidebarWidth: CGFloat = BudgetLayoutMetrics.defaultSidebarWidth
    var inspectorWidth: CGFloat = 0
    var dynamicTypeScale: CGFloat = 1
    var horizontalMargins: CGFloat = BudgetLayoutMetrics.defaultHorizontalMargins
    var preference: MonthDisplayPreference = .automatic
    var density: ActualistDisplayDensity = .compact

    init(
        rootWidth: CGFloat,
        budgetDetailWidth: CGFloat? = nil,
        sidebarWidth: CGFloat = BudgetLayoutMetrics.defaultSidebarWidth,
        inspectorWidth: CGFloat = 0,
        dynamicTypeScale: CGFloat = 1,
        horizontalMargins: CGFloat = BudgetLayoutMetrics.defaultHorizontalMargins,
        preference: MonthDisplayPreference = .automatic,
        density: ActualistDisplayDensity = .compact
    ) {
        self.rootWidth = rootWidth
        self.budgetDetailWidth = budgetDetailWidth
        self.sidebarWidth = sidebarWidth
        self.inspectorWidth = inspectorWidth
        self.dynamicTypeScale = dynamicTypeScale
        self.horizontalMargins = horizontalMargins
        self.preference = preference
        self.density = density
    }
}

struct BudgetLayoutMetrics: Equatable {
    static let compactRootWidth: CGFloat = defaultSidebarWidth + singleMonthMinimumWidth + defaultHorizontalMargins
    static let singleMonthMinimumWidth: CGFloat = 520
    static let defaultSidebarWidth: CGFloat = 240
    static let defaultHorizontalMargins: CGFloat = 32
    static let minimumMonthGroupWidth: CGFloat = 216
    static let minimumMoneyColumnWidth: CGFloat = 104
    static let minimumCategoryColumnWidth: CGFloat = 180
    static let preferredCategoryColumnWidth: CGFloat = 240
    static let maximumCategoryColumnWidth: CGFloat = 300
    static let maximumSingleMonthTableWidth: CGFloat = 760
    static let supportedMonthRange = 1...5

    let presentationMode: BudgetPresentationMode
    let visibleMonthCount: Int
    let categoryColumnWidth: CGFloat
    let monthColumnWidth: CGFloat
    let inspectorAvailable: Bool

    var tableWidth: CGFloat {
        categoryColumnWidth + monthColumnWidth * CGFloat(visibleMonthCount)
    }

    /// `renderedMonthCount` keeps geometry coherent while the viewport adopts a
    /// new capacity. It does not change the user's month-count preference.
    static func resolve(_ inputs: BudgetLayoutInputs, renderedMonthCount: Int? = nil) -> Self {
        let rootWidth = finiteNonnegative(inputs.rootWidth)
        let scale = min(max(finitePositive(inputs.dynamicTypeScale), 1), 3)
        let density = BudgetGridDensityMetrics(density: inputs.density)
        let moneyScale = scale * density.moneyWidthScale
        let categoryScale = scale * density.categoryWidthScale
        let margins = finiteNonnegative(inputs.horizontalMargins)
        let sidebar = finiteNonnegative(inputs.sidebarWidth)
        let inspector = finiteNonnegative(inputs.inspectorWidth)
        let preferredCategoryWidth = min(
            max(preferredCategoryColumnWidth * categoryScale, minimumCategoryColumnWidth * categoryScale),
            maximumCategoryColumnWidth * categoryScale
        )
        let measuredDetail = inputs.budgetDetailWidth.map(finiteNonnegative)
        let detailWidth = measuredDetail.map { max($0 - margins, 0) }
            ?? max(rootWidth - sidebar - inspector - margins, 0)
        let moneyColumns: CGFloat = 2
        let categoryWidth = min(
            preferredCategoryWidth,
            max(detailWidth - minimumMoneyColumnWidth * moneyColumns * moneyScale, 0)
        )
        let sidebarFits = rootWidth >= sidebar + singleMonthMinimumWidth * scale + margins
        guard sidebarFits else {
            return Self(
                presentationMode: .compact,
                visibleMonthCount: 1,
                categoryColumnWidth: min(categoryWidth, max(detailWidth - minimumMoneyColumnWidth * moneyColumns, 0)),
                monthColumnWidth: max(detailWidth, 0),
                inspectorAvailable: false
            )
        }

        let availableForMonths = max(detailWidth - categoryWidth, 0)
        let minimumGroupWidth = max(minimumMonthGroupWidth, minimumMoneyColumnWidth * moneyColumns) * moneyScale
        let physicallyPossible = max(1, min(supportedMonthRange.upperBound, Int(floor(availableForMonths / minimumGroupWidth))))
        let requested = inputs.preference.resolvedCount
        let capacity = min(max(requested, supportedMonthRange.lowerBound), physicallyPossible)
        let visibleCount = renderedMonthCount.map { min(max($0, 1), supportedMonthRange.upperBound) } ?? capacity
        let mode: BudgetPresentationMode = visibleCount > 1 ? .multiMonth : .splitSingleMonth
        let maximumTableWidth = maximumSingleMonthTableWidth * scale
        let tableWidth = visibleCount == 1 ? min(detailWidth, maximumTableWidth) : detailWidth
        let tableCategoryWidth = visibleCount == 1
            ? min(categoryWidth, max(tableWidth - minimumMoneyColumnWidth * moneyColumns * moneyScale, 0))
            : categoryWidth
        let tableMonthWidth = max(tableWidth - tableCategoryWidth, 0)
        let naturalMonthWidth = visibleCount == 1
            ? tableMonthWidth
            : availableForMonths / CGFloat(visibleCount)
        // A narrow inspector or a pending range shrink can leave less than
        // the readable baseline. Fit the rendered slots until capacity catches
        // up rather than letting a minimum width overlap neighboring columns.
        let monthWidth = visibleCount != capacity || (visibleCount == 1 && naturalMonthWidth < minimumMoneyColumnWidth * moneyColumns * moneyScale)
            ? max(naturalMonthWidth, 0)
            : max(naturalMonthWidth, minimumMoneyColumnWidth * moneyColumns * moneyScale)
        return Self(
            presentationMode: mode,
            visibleMonthCount: visibleCount,
            categoryColumnWidth: tableCategoryWidth,
            monthColumnWidth: monthWidth,
            inspectorAvailable: detailWidth >= (singleMonthMinimumWidth + 80) * scale
        )
    }

    private static func finiteNonnegative(_ value: CGFloat) -> CGFloat {
        value.isFinite ? max(value, 0) : 0
    }

    private static func finitePositive(_ value: CGFloat) -> CGFloat {
        value.isFinite && value > 0 ? value : 1
    }
}

extension DynamicTypeSize {
    var budgetLayoutScale: CGFloat {
        switch self {
        case .xSmall: 0.85
        case .small: 0.9
        case .medium: 1
        case .large: 1.1
        case .xLarge: 1.2
        case .xxLarge: 1.3
        case .xxxLarge: 1.45
        case .accessibility1: 1.65
        case .accessibility2: 1.85
        case .accessibility3: 2.1
        case .accessibility4: 2.35
        case .accessibility5: 2.6
        @unknown default: 1
        }
    }
}

private struct BudgetSidebarLayoutActiveKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var budgetSidebarLayoutActive: Bool {
        get { self[BudgetSidebarLayoutActiveKey.self] }
        set { self[BudgetSidebarLayoutActiveKey.self] = newValue }
    }
}
