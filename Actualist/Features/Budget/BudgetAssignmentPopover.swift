import SwiftUI

struct BudgetAssignmentPopover: View {
    @Environment(AppState.self) private var appState
    @Bindable var viewport: BudgetViewportModel
    let actions: BudgetWorkspaceActions
    let categoryName: String

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Text(categoryName).font(.headline).lineLimit(2)
                Text(BudgetMonthNavigationPresentation.title(for: viewport.selectedCell?.month))
                    .font(.subheadline).foregroundStyle(ActualistTheme.secondaryText)
                if let display = viewport.assignmentAmountDisplay(randomized: appState.settings.randomizedDisplayValuesEnabled) {
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
                showsMoveMoney: !viewport.isTrackingBudget,
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
        .background { hardwareKeyShortcuts }
    }

    /// Hardware keyboard input. On device the popover's content never became
    /// first responder (`onKeyPress` and focus requests were dropped), while
    /// the dismiss button's `.cancelAction` shortcut worked, so every key the
    /// keypad accepts is a shortcut on an invisible button, routed through
    /// the same `handleHardwareInput` the key handler used. Escape stays on the
    /// dismiss button.
    private var hardwareKeyShortcuts: some View {
        ZStack {
            ForEach(Self.hardwareShortcuts.indices, id: \.self) { index in
                let shortcut = Self.hardwareShortcuts[index]
                Button("") { Task { await viewport.handleHardwareInput(shortcut.input) } }
                    .keyboardShortcut(shortcut.key, modifiers: shortcut.modifiers)
            }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private struct HardwareShortcut {
        let key: KeyEquivalent
        let modifiers: EventModifiers
        let input: String
    }

    private static let hardwareShortcuts: [HardwareShortcut] =
        (0...9).map { HardwareShortcut(key: KeyEquivalent(Character(String($0))), modifiers: [], input: String($0)) } + [
            HardwareShortcut(key: ".", modifiers: [], input: "."),
            HardwareShortcut(key: "+", modifiers: [], input: "+"),
            HardwareShortcut(key: "=", modifiers: [.shift], input: "+"),
            HardwareShortcut(key: "-", modifiers: [], input: "-"),
            HardwareShortcut(key: "=", modifiers: [], input: "="),
            HardwareShortcut(key: .return, modifiers: [], input: "\r"),
            HardwareShortcut(key: .delete, modifiers: [], input: "\u{8}"),
            HardwareShortcut(key: .tab, modifiers: [], input: "\t"),
            HardwareShortcut(key: .tab, modifiers: [.shift], input: "\u{19}"),
        ]
}
