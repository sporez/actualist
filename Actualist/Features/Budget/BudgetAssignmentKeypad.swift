import SwiftUI

struct BudgetAssignmentKeypad: View {
    @Environment(\.actualistDensity) private var density

    let canSubmit: Bool
    let canApplyTemplate: Bool
    let isSubmitting: Bool
    let errorMessage: String?
    let appendDigit: (Int) -> Void
    let setMode: (BudgetAssignmentInputMode) -> Void
    let applyTemplate: () -> Void
    let moveMoney: () -> Void
    let details: () -> Void
    let deleteDigit: () -> Void
    let clearOrCancel: () -> Void
    let cancel: () -> Void
    let submit: () -> Void

    @State private var keyPressCount = 0

    var body: some View {
        VStack(spacing: BudgetKeypadLayout.stackSpacing) {
            HStack(spacing: 12) {
                keypadToolbarButton(title: "Apply Category Template", systemImage: "sparkles", isEnabled: canApplyTemplate) {
                    applyTemplate()
                }
                keypadToolbarButton(title: "Move Money", systemImage: "arrow.right", isEnabled: true) {
                    moveMoney()
                }
                keypadToolbarButton(title: "Details", systemImage: "ellipsis", isEnabled: true, action: details)

                Button(action: cancel) {
                    Image(systemName: "keyboard.chevron.compact.down")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(ActualistTheme.secondaryText)
                        .frame(
                            width: BudgetKeypadLayout.dismissButtonWidth,
                            height: BudgetKeypadLayout.toolbarButtonHeight
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss keypad")
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(ActualistTypography.rowLabel(for: density))
                    .foregroundStyle(ActualistTheme.danger)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Grid(
                horizontalSpacing: BudgetKeypadLayout.gridHorizontalSpacing,
                verticalSpacing: BudgetKeypadLayout.gridVerticalSpacing
            ) {
                GridRow {
                    digitButton(7)
                    digitButton(8)
                    digitButton(9)
                    modeButton(systemImage: "minus", mode: .subtraction, label: "Subtract from budgeted")
                }

                GridRow {
                    digitButton(4)
                    digitButton(5)
                    digitButton(6)
                    modeButton(systemImage: "plus", mode: .addition, label: "Add to budgeted")
                }

                GridRow {
                    digitButton(1)
                    digitButton(2)
                    digitButton(3)
                    modeButton(systemImage: "equal", mode: .direct, label: "Set budgeted amount")
                }

                GridRow {
                    iconButton(
                        systemImage: "xmark.circle.fill",
                        foreground: ActualistTheme.secondaryText,
                        label: "Clear amount"
                    ) {
                        clearOrCancel()
                    }
                    digitButton(0)
                    iconButton(
                        systemImage: "delete.left",
                        foreground: ActualistTheme.accent,
                        label: "Delete last digit"
                    ) {
                        deleteDigit()
                    }
                    Button {
                        submit()
                        keyPressCount += 1
                    } label: {
                        Text(isSubmitting ? "Saving" : "Done")
                            .font(ActualistTypography.control(for: density))
                            .frame(maxWidth: .infinity)
                            .frame(height: BudgetKeypadLayout.actionHeight)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(ActualistTheme.accent)
                    .disabled(!canSubmit)
                    .accessibilityLabel("Save assignment")
                }
            }
        }
        .padding(.horizontal, BudgetKeypadLayout.horizontalPadding)
        .padding(.top, BudgetKeypadLayout.topPadding)
        .padding(.bottom, BudgetKeypadLayout.bottomPadding)
        .background(ActualistTheme.elevatedSurface)
        .disabled(isSubmitting)
        .sensoryFeedback(.impact(weight: .heavy, intensity: 1.0), trigger: keyPressCount)
    }

    private func keypadToolbarButton(
        title: String,
        systemImage: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.title3.weight(.bold))
                Text(title)
                    .font(ActualistTypography.rowLabel(for: density))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.74)
            }
            .foregroundStyle(isEnabled ? ActualistTheme.accent : ActualistTheme.secondaryText)
            .frame(maxWidth: .infinity)
            .frame(height: BudgetKeypadLayout.toolbarButtonHeight)
            .background(ActualistTheme.control, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }

    private func digitButton(_ digit: Int) -> some View {
        Button {
            appendDigit(digit)
            keyPressCount += 1
        } label: {
            Text(String(digit))
                .font(ActualistTypography.keypadDigit(for: density))
                .foregroundStyle(ActualistTheme.primaryText)
                .frame(maxWidth: .infinity)
                .frame(height: BudgetKeypadLayout.keyHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(BudgetKeypadPressStyle())
        .accessibilityLabel(String(digit))
    }

    private func modeButton(
        systemImage: String,
        mode: BudgetAssignmentInputMode,
        label: String
    ) -> some View {
        iconButton(systemImage: systemImage, foreground: ActualistTheme.accent, label: label) {
            setMode(mode)
        }
    }

    private func iconButton(
        systemImage: String,
        foreground: Color,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
            keyPressCount += 1
        } label: {
            Image(systemName: systemImage)
                .font(ActualistTypography.keypadSymbol(for: density))
                .foregroundStyle(foreground)
                .frame(maxWidth: .infinity)
                .frame(height: BudgetKeypadLayout.keyHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(BudgetKeypadPressStyle())
        .accessibilityLabel(label)
    }
}
