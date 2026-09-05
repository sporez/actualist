import SwiftUI

struct BudgetAssignmentPopover: View {
    @Bindable var viewport: BudgetViewportModel
    let actions: BudgetWorkspaceActions
    let categoryName: String
    @FocusState private var keyboardFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Text(categoryName).font(.headline).lineLimit(2)
                Text(BudgetMonthNavigationPresentation.title(for: viewport.selectedCell?.month))
                    .font(.subheadline).foregroundStyle(ActualistTheme.secondaryText)
                if let display = viewport.assignmentAmountDisplay {
                    Text(display.primaryText).font(.title2.weight(.bold)).monospacedDigit()
                    if let secondary = display.secondaryText {
                        Text(secondary).font(.headline).foregroundStyle(ActualistTheme.accent)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding()
            .accessibilityIdentifier("assignment-popover")

            BudgetAssignmentKeypad(
                canSubmit: viewport.assignmentWorkflow.canSubmit,
                showsApplyTemplate: viewport.assignmentHasTemplate,
                canApplyTemplate: viewport.assignmentWorkflow.canApplyCategoryTemplate,
                isSubmitting: viewport.assignmentWorkflow.isSubmitting,
                errorMessage: viewport.assignmentWorkflow.errorMessage,
                appendDigit: { viewport.appendKeypadDigit($0) },
                setMode: { viewport.setAssignmentInputMode($0) },
                applyTemplate: {
                    if let cell = viewport.selectedCell { actions.requestCategoryTemplate(cell) }
                },
                moveMoney: {
                    if let cell = viewport.selectedCell { actions.beginMoveMoney(cell) }
                },
                details: { viewport.showAssignmentDetails() },
                deleteDigit: { viewport.deleteKeypadDigit() },
                clearOrCancel: { viewport.clearKeypadInput() },
                cancel: { viewport.cancelAssignmentEditing() },
                submit: { Task { await viewport.submitAssignment() } }
            )
        }
        .frame(width: 370)
        .background(ActualistTheme.elevatedSurface)
        .focusable(true, interactions: .edit)
        .focused($keyboardFocused)
        .focusEffectDisabled()
        .task {
            await Task.yield()
            keyboardFocused = true
        }
        .onKeyPress(phases: .down) { press in
            let input: String
            switch press.key {
            case .return: input = "\r"
            case .escape: input = "\u{1b}"
            case .tab: input = press.modifiers.contains(.shift) ? "\u{19}" : "\t"
            case .delete: input = "\u{8}"
            default: input = press.characters
            }
            guard BudgetAssignmentHardwareInput.action(for: input) != nil else { return .ignored }
            Task { await viewport.handleHardwareInput(input) }
            return .handled
        }
    }

}
