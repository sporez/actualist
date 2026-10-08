import SwiftUI

struct BudgetHoldSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var model: BudgetHoldViewModel
    @FocusState private var isAmountFocused: Bool

    init(target: BudgetHoldTarget) {
        _model = State(initialValue: BudgetHoldViewModel(target: target))
    }

    var body: some View {
        NavigationStack {
            Group {
                if appState.settings.randomizedDisplayValuesEnabled {
                    ContentUnavailableView("Sample Values", systemImage: "eye.slash", description: Text("Turn off Sample Values to hold or release money."))
                } else if appState.settings.selectedBudgetID != model.target.budgetID {
                    ContentUnavailableView("Budget Changed", systemImage: "calendar", description: Text("Close this sheet and open the selected budget."))
                } else if model.draft != nil {
                    reviewContent
                } else if model.isLoading {
                    ProgressView("Loading budget")
                } else {
                    VStack(spacing: 16) {
                        if let error = model.errorMessage {
                            Text(error).foregroundStyle(ActualistTheme.danger)
                        } else {
                            Text("The review is not loaded.")
                        }
                        Button("Try Again") { Task { await model.load(using: appState) } }
                            .buttonStyle(.glass)
                    }
                    .padding()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ActualistTheme.background)
            .navigationTitle("Hold for Next Month")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") {
                        model.cancel()
                        dismiss()
                    }
                    .labelStyle(.iconOnly)
                    .disabled(model.isSaving)
                    .accessibilityIdentifier("budget-hold-close")
                }
            }
            .actualistKeyboardDone(isVisible: isAmountFocused) { isAmountFocused = false }
        }
        .frame(idealWidth: 520)
        .accessibilityIdentifier("budget-hold-sheet")
        .presentationDetents([.large])
        .presentationSizing(.page.fitted(horizontal: true, vertical: false))
        .interactiveDismissDisabled(model.isSaving)
        .task { await model.prepare(using: appState) }
        .onDisappear { model.cancel() }
        .onChange(of: appState.settings.selectedBudgetID) {
            model.invalidate()
            dismiss()
        }
        .onChange(of: appState.settings.randomizedDisplayValuesEnabled) {
            model.invalidate()
            dismiss()
        }
        .alert(model.releaseTitle + "?", isPresented: Binding(
            get: { model.isReviewingRelease },
            set: { if !$0 { model.cancelRelease() } }
        )) {
            Button(model.releaseConfirmationTitle) {
                Task {
                    if await model.submitRelease(using: appState) {
                        ActualistHaptics.success()
                        dismiss()
                    }
                }
            }
            .accessibilityIdentifier("budget-hold-release-confirm")
            Button("Cancel", role: .cancel) { model.cancelRelease() }
        } message: {
            Text(model.releaseMessage)
        }
    }

    private var reviewContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(model.monthContext)
                    .font(.subheadline)
                    .foregroundStyle(ActualistTheme.secondaryText)
                    .accessibilityIdentifier("budget-hold-month")

                card {
                    amountRow("To Budget", value: model.availableText, id: "budget-hold-current-available",
                              foreground: (model.draft?.review.toBudget ?? 0) < 0 ? ActualistTheme.danger
                                : (model.draft?.review.toBudget ?? 0) > 0 ? ActualistTheme.positive : ActualistTheme.secondaryText)
                    Divider()
                    amountRow("Currently Held for \(model.nextMonthName)", value: model.heldText, id: "budget-hold-current-held")
                    if model.hasHeldMoney {
                        Button(model.releaseTitle + "…") {
                            isAmountFocused = false
                            model.requestRelease()
                        }
                        .font(.subheadline.weight(.medium))
                        .frame(minHeight: 28, alignment: .leading)
                        .buttonStyle(.plain)
                        .foregroundStyle(ActualistTheme.accent)
                        .disabled(!model.canRelease)
                        .accessibilityIdentifier("budget-hold-release")
                    }
                }

                card {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Amount to Hold")
                            .font(.headline)
                        Spacer(minLength: 8)
                        Button("Use All") { model.useAllAvailable() }
                            .font(.subheadline.weight(.semibold))
                            .frame(minHeight: 44)
                            .buttonStyle(.plain)
                            .foregroundStyle(ActualistTheme.accent)
                            .disabled(!model.canEnterHold)
                            .accessibilityIdentifier("budget-hold-use-all")
                    }
                    MoneyAmountEntryField(
                        text: Binding(get: { model.amountText }, set: { model.setAmountText($0) }),
                        displayText: model.amountDisplayText,
                        foreground: ActualistTheme.primaryText,
                        keyboard: .decimal,
                        focus: $isAmountFocused,
                        accessibilityLabel: "Amount to hold",
                        accessibilityIdentifier: "budget-hold-amount",
                        alignment: .leading,
                        font: .largeTitle.weight(.semibold)
                    )
                    .monospacedDigit()
                    .padding(14)
                    .background(ActualistTheme.background, in: RoundedRectangle(cornerRadius: 12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(isAmountFocused ? ActualistTheme.accent : ActualistTheme.separator,
                                          lineWidth: isAmountFocused ? 2 : 1)
                    }
                    .disabled(!model.canEnterHold)

                    Text(model.holdExplanation)
                        .font(.footnote)
                        .foregroundStyle(ActualistTheme.secondaryText)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                card {
                    Text("After Holding")
                        .font(.headline)
                    amountRow("To Budget", value: model.resultingAvailableText, id: "budget-hold-result-available")
                    Divider()
                    amountRow("Held for \(model.nextMonthName)", value: model.resultingHeldText,
                              id: "budget-hold-result-held", foreground: model.canHold ? ActualistTheme.positive : ActualistTheme.secondaryText)
                }

                if let error = model.errorMessage {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(ActualistTheme.danger)
                    Button("Refresh Review") { Task { await model.load(using: appState) } }
                        .buttonStyle(.glass)
                }
            }
            .padding(20)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("budget-hold-review")
        .scrollDismissesKeyboard(.interactively)
        .foregroundStyle(ActualistTheme.primaryText)
        .safeAreaBar(edge: .bottom, spacing: 0) {
            Button {
                isAmountFocused = false
                Task {
                    if await model.submitHold(using: appState) {
                        ActualistHaptics.success()
                        dismiss()
                    }
                }
            } label: {
                HStack {
                    if model.isSaving { ProgressView() }
                    Text(model.holdTitle)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 36)
            }
            .buttonStyle(.glassProminent)
            .tint(ActualistTheme.accent)
            .disabled(!model.canHold)
            .accessibilityIdentifier("budget-hold-confirm")
            .frame(maxWidth: 480)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ActualistTheme.surface, in: RoundedRectangle(cornerRadius: 18))
    }

    private func amountRow(_ label: String, value: String, id: String, foreground: Color = ActualistTheme.primaryText) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(label).foregroundStyle(ActualistTheme.secondaryText)
                    .fixedSize()
                Spacer(minLength: 8)
                Text(value).fontWeight(.semibold).monospacedDigit()
                    .foregroundStyle(foreground)
                    .fixedSize()
                    .accessibilityIdentifier(id)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(label).foregroundStyle(ActualistTheme.secondaryText)
                Text(value).fontWeight(.semibold).monospacedDigit()
                    .foregroundStyle(foreground)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .accessibilityIdentifier(id)
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity)
    }
}
