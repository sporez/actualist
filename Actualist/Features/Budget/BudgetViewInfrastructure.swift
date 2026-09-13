import SwiftUI

enum BudgetLayout {
    static let screenHorizontalPadding: CGFloat = 14
    static let sectionSpacing: CGFloat = 14
    static let rowSpacing: CGFloat = 8
    static let rowHorizontalPadding: CGFloat = 10
    static let chevronWidth: CGFloat = 24
    static let emojiSize: CGFloat = 20
    static let emojiNameSpacing: CGFloat = 6
    static let assignedWidth: CGFloat = 96
    static let availableWidth: CGFloat = 104
    static let availablePillHorizontalPadding: CGFloat = 6
    static let rolloverBadgeSize: CGFloat = 12
    static let rolloverBadgeArrowSize: CGFloat = 6
    static let rolloverBadgeRingWidth: CGFloat = 1.5
    static let rolloverBadgeOffset: CGFloat = 5
    static let alertHorizontalPadding: CGFloat = 16
    static let alertVerticalPadding: CGFloat = 10
    static let summaryStackedVerticalPadding: CGFloat = 6
    static let summaryMetricSpacing: CGFloat = 2
    static let summaryColumnSpacing: CGFloat = 12
    static let assignmentScrollBottomClearance: CGFloat = 160
    static let assignmentScrollVisibilityMargin: CGFloat = 20
    static let addTransactionFloatingPadding: CGFloat = 12
    static let hiddenCategoryOpacity: Double = 0.5
    static let monthResizeAnimation = Animation.easeInOut(duration: 0.2)
    static let assignmentKeypadAnimation = Animation.smooth(duration: 0.24)
    static let addTransactionExpansionAnimation = Animation.smooth(duration: 0.22)
}

struct BudgetCarryoverBadge: View {
    let fill: Color
    let foreground: Color

    var body: some View {
        Image(systemName: "arrow.right")
            .font(.system(size: BudgetLayout.rolloverBadgeArrowSize, weight: .heavy))
            .foregroundStyle(foreground)
            .frame(width: BudgetLayout.rolloverBadgeSize, height: BudgetLayout.rolloverBadgeSize)
            .background(fill, in: Circle())
            .padding(BudgetLayout.rolloverBadgeRingWidth)
            .background(ActualistTheme.surface, in: Circle())
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

struct BudgetTemplateConfirmationModifier: ViewModifier {
    @Environment(AppState.self) private var appState
    @Binding var confirmation: BudgetTemplateConfirmation?
    var categoryID: String?
    var month: String?
    var modeIdentity: BudgetModeIdentity?
    let apply: (BudgetTemplateConfirmation, BudgetModeIdentity?) -> Void

    func body(content: Content) -> some View {
        content.sheet(item: $confirmation) { confirmation in
            BudgetTemplateConfirmationSheet(
                confirmation: confirmation,
                categoryID: categoryID,
                month: month ?? "",
                modeIdentity: modeIdentity,
                cancel: {
                    self.confirmation = nil
                },
                apply: { reviewedMode in
                    self.confirmation = nil
                    apply(confirmation, reviewedMode)
                }
            )
            .presentationDetents([.medium, .large])
            .appSwitcherPrivacyAwareDragIndicator()
            .presentationBackground(ActualistTheme.background)
            .appSwitcherPrivacyProtected(using: appState)
        }
    }
}

enum BudgetScrollTarget {
    static func category(_ categoryID: String) -> String {
        "budget-category-\(categoryID)"
    }
}

enum BudgetAssignmentScrollGeometry {
    static func openingTarget(
        currentOffset: CGFloat,
        topInset: CGFloat,
        rowFrame: CGRect,
        insetBottomY: CGFloat,
        keypadHeight: CGFloat,
        visibilityMargin: CGFloat
    ) -> CGFloat? {
        guard insetBottomY > 0, keypadHeight > 0 else {
            return nil
        }

        let finalVisibleBottom = insetBottomY - keypadHeight - visibilityMargin
        let requiredMovement = rowFrame.maxY - finalVisibleBottom
        guard requiredMovement > 0.5 else {
            return nil
        }

        return max(0, currentOffset) + max(0, topInset) + requiredMovement
    }
}

struct BudgetAssignmentOpeningRequest: Equatable {
    let categoryID: String
    let scrollTarget: CGFloat
}

enum BudgetKeypadLayout {
    static let keyHeight: CGFloat = 46
    static let keyPressHighlightWidth: CGFloat = 74
    static let keyPressHighlightHeight: CGFloat = 44
    static let actionHeight: CGFloat = 54
    static let toolbarButtonHeight: CGFloat = 68
    static let stackSpacing: CGFloat = 14
    static let gridHorizontalSpacing: CGFloat = 22
    static let gridVerticalSpacing: CGFloat = 14
    static let horizontalPadding: CGFloat = 18
    static let topPadding: CGFloat = 18
    static let bottomPadding: CGFloat = 22
    static let dismissButtonWidth: CGFloat = 52
    // Native prominent glass adds layout around the label's fixed frame.
    static let prominentActionChromeAllowance: CGFloat = 14
    static let initialHeight = topPadding + toolbarButtonHeight + stackSpacing
        + (keyHeight * 3) + actionHeight + prominentActionChromeAllowance
        + (gridVerticalSpacing * 3) + bottomPadding
}

struct BudgetKeypadPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                Capsule(style: .continuous)
                    .fill(ActualistTheme.control)
                    .overlay {
                        Capsule(style: .continuous)
                            .stroke(ActualistTheme.separator, lineWidth: 1)
                    }
                    .frame(
                        width: BudgetKeypadLayout.keyPressHighlightWidth,
                        height: BudgetKeypadLayout.keyPressHighlightHeight
                    )
                    .opacity(configuration.isPressed ? 1 : 0)
                    .scaleEffect(configuration.isPressed ? 1 : 0.82)
            }
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}
