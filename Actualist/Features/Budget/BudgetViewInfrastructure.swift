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
    static let rolloverIndicatorReservedWidth: CGFloat = 12
    static let rolloverIndicatorSize: CGFloat = 7
    static let rolloverIndicatorTopPadding: CGFloat = 3
    static let rolloverIndicatorTrailingPadding: CGFloat = 4
    static let alertHorizontalPadding: CGFloat = 16
    static let alertVerticalPadding: CGFloat = 10
    static let summaryStackedVerticalPadding: CGFloat = 6
    static let summaryMetricSpacing: CGFloat = 2
    static let summaryColumnSpacing: CGFloat = 12
    static let assignmentScrollBottomClearance: CGFloat = 160
    static let assignmentScrollVisibilityMargin: CGFloat = 20
    static let assignmentKeypadAnimation = Animation.smooth(duration: 0.24)
    static let assignmentScrollAnimation = Animation.smooth(duration: 0.22)
    static let assignmentScrollDelays: [UInt64] = [
        0,
        140_000_000,
        280_000_000,
        460_000_000
    ]
}

struct BudgetTemplateConfirmationModifier: ViewModifier {
    @Binding var confirmation: BudgetTemplateConfirmation?
    let apply: (BudgetTemplateConfirmation) -> Void

    func body(content: Content) -> some View {
        content.sheet(item: $confirmation) { confirmation in
            BudgetTemplateConfirmationSheet(
                confirmation: confirmation,
                cancel: {
                    self.confirmation = nil
                },
                apply: {
                    self.confirmation = nil
                    apply(confirmation)
                }
            )
            .presentationDetents([.height(310)])
            .appSwitcherPrivacyAwareDragIndicator()
            .presentationBackground(ActualistTheme.background)
            .appSwitcherPrivacyProtected()
        }
    }
}

private struct BudgetTemplateConfirmationSheet: View {
    let confirmation: BudgetTemplateConfirmation
    let cancel: () -> Void
    let apply: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 8) {
                Text("Are you sure?")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(ActualistTheme.primaryText)
                    .multilineTextAlignment(.center)

                Text(confirmation.message)
                    .font(.subheadline)
                    .foregroundStyle(ActualistTheme.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 10) {
                Button(role: confirmation.buttonRole) {
                    apply()
                } label: {
                    Text(confirmation.actionTitle)
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.glassProminent)
                .tint(confirmation.buttonTint)

                Button(role: .cancel) {
                    cancel()
                } label: {
                    Text("Cancel")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.glass)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 24)
    }
}

enum BudgetScrollTarget {
    static func category(_ categoryID: String) -> String {
        "budget-category-\(categoryID)"
    }

    static func assignmentAnchor(_ categoryID: String) -> String {
        "budget-assignment-anchor-\(categoryID)"
    }
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
}

struct BudgetAssignmentKeypadHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

extension View {
    func readHeight<Key: PreferenceKey>(into key: Key.Type) -> some View where Key.Value == CGFloat {
        overlay {
            GeometryReader { geometry in
                Color.clear.preference(key: key, value: geometry.size.height)
            }
        }
    }
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
