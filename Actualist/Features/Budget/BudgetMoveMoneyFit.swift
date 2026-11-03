import CoreGraphics

/// Fixed sizes of the Move Money screen.
enum BudgetMoveMoneyLayout {
    static let headerHeight: CGFloat = 332
    static let headerTopInset: CGFloat = 56
    static let compactHeaderTopInset: CGFloat = 20
    /// The close button sits this far above the header's text.
    static let closeButtonRaise: CGFloat = 2
    static let closeButtonLeadingInset: CGFloat = 34
    static let headerHorizontalPadding: CGFloat = 34
    static let closeButtonSize: CGFloat = 54
    static let cardHeaderOverlap: CGFloat = 28
    static let headerNameCloseButtonGap: CGFloat = 8
    static let headerCoordinateSpace = "move-money-header"
    /// The reverse-direction button and the least green kept above and below it.
    static let directionButtonMinimumSpace: CGFloat = 54 + 2 * 8
    static let contentBottomPadding: CGFloat = 10
    static let numberPadReservedHeight: CGFloat = 302
    static let compactSubmitReservedHeight: CGFloat = 78
    static let keypadKeyHeight: CGFloat = 54
    static let compactKeypadKeyHeight: CGFloat = 46
    static let keypadTopPadding: CGFloat = 22
    static let compactKeypadTopPadding: CGFloat = 8
    static let keypadRowCount: CGFloat = 4
}

/// How Move Money fits its sheet. A short sheet (iPhone SE, the iPhone Duo
/// front screen, an iPad form sheet, large text) cannot show the destination
/// card above the number pad at the regular sizes, so space comes back in
/// order: green around the reverse-direction button, shorter keypad keys,
/// then the header's top inset. A sheet where the card already fits keeps
/// every regular size.
struct BudgetMoveMoneyFit: Equatable {
    var headerHeight: CGFloat
    var headerTopInset: CGFloat
    var keypadKeyHeight: CGFloat
    var keypadTopPadding: CGFloat

    static let regular = BudgetMoveMoneyFit(
        headerHeight: BudgetMoveMoneyLayout.headerHeight,
        headerTopInset: BudgetMoveMoneyLayout.headerTopInset,
        keypadKeyHeight: BudgetMoveMoneyLayout.keypadKeyHeight,
        keypadTopPadding: BudgetMoveMoneyLayout.keypadTopPadding
    )

    var closeButtonTopInset: CGFloat {
        headerTopInset - BudgetMoveMoneyLayout.closeButtonRaise
    }

    /// Height kept below the card for the number pad or the Done button.
    func bottomReservedHeight(isNumberPadVisible: Bool) -> CGFloat {
        guard isNumberPadVisible else {
            return BudgetMoveMoneyLayout.compactSubmitReservedHeight
        }
        let keypadSaving = BudgetMoveMoneyLayout.keypadRowCount * (Self.regular.keypadKeyHeight - keypadKeyHeight)
            + (Self.regular.keypadTopPadding - keypadTopPadding)
        return BudgetMoveMoneyLayout.numberPadReservedHeight - keypadSaving
    }

    /// - Parameters:
    ///   - containerHeight: Height of the whole screen below the sheet's top.
    ///   - cardHeight: The destination card's natural height.
    ///   - headerContentHeight: Height of the header's title, name and amount.
    ///   Zero heights mean not yet measured and keep the regular sizes.
    static func resolve(
        containerHeight: CGFloat,
        cardHeight: CGFloat,
        headerContentHeight: CGFloat,
        isNumberPadVisible: Bool
    ) -> BudgetMoveMoneyFit {
        guard containerHeight > 0, cardHeight > 0, headerContentHeight > 0 else {
            return .regular
        }

        var fit = BudgetMoveMoneyFit.regular
        var shortfall = cardHeight - fit.cardSpace(containerHeight: containerHeight, isNumberPadVisible: isNumberPadVisible)
        guard shortfall > 0 else {
            return .regular
        }

        let headerFloor = fit.headerTopInset + headerContentHeight
            + BudgetMoveMoneyLayout.directionButtonMinimumSpace + BudgetMoveMoneyLayout.cardHeaderOverlap
        let directionTrim = min(shortfall, max(0, fit.headerHeight - headerFloor))
        fit.headerHeight -= directionTrim
        shortfall -= directionTrim

        if shortfall > 0, isNumberPadVisible {
            fit.keypadKeyHeight = BudgetMoveMoneyLayout.compactKeypadKeyHeight
            fit.keypadTopPadding = BudgetMoveMoneyLayout.compactKeypadTopPadding
            shortfall = cardHeight - fit.cardSpace(containerHeight: containerHeight, isNumberPadVisible: true)
        }

        if shortfall > 0 {
            let insetTrim = min(shortfall, fit.headerTopInset - BudgetMoveMoneyLayout.compactHeaderTopInset)
            fit.headerTopInset -= insetTrim
            fit.headerHeight -= insetTrim
        }
        return fit
    }

    private func cardSpace(containerHeight: CGFloat, isNumberPadVisible: Bool) -> CGFloat {
        containerHeight - headerHeight + BudgetMoveMoneyLayout.cardHeaderOverlap
            - BudgetMoveMoneyLayout.contentBottomPadding - bottomReservedHeight(isNumberPadVisible: isNumberPadVisible)
    }
}
