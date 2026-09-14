import SwiftUI

struct AccountReconciliationTargetSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.actualistDensity) private var density
    @Bindable var coordinator: AccountReconciliationCoordinator
    let privacyModeEnabled: Bool
    let onRetry: () -> Void

    @FocusState private var isAmountFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                ActualistTheme.background.ignoresSafeArea()

                if let presentation = coordinator.targetPresentation(
                    privacyModeEnabled: privacyModeEnabled
                ) {
                    targetContent(presentation)
                } else if let errorMessage = coordinator.startErrorMessage {
                    startError(errorMessage)
                } else {
                    ProgressView("Loading account balance")
                        .tint(ActualistTheme.accent)
                }
            }
            .navigationTitle("Reconcile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        coordinator.cancel()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .actualistToolbarGlassButton()
                    .accessibilityLabel("Close Reconcile")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        isAmountFocused = false
                    }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
    }

    private func targetContent(
        _ presentation: AccountReconciliationTargetPresentation
    ) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 8) {
                    Text(presentation.accountName)
                        .font(ActualistTypography.sectionTitle(for: density))
                        .foregroundStyle(ActualistTheme.secondaryText)

                    if presentation.isPrivacyProtected {
                        Text(presentation.amountText)
                            .font(ActualistTypography.editorAmount(for: density))
                            .foregroundStyle(ActualistTheme.primaryText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.55)
                            .accessibilityLabel("Sample target balance")
                    } else {
                        MoneyAmountEntryField(
                            text: targetTextBinding,
                            displayText: presentation.amountText,
                            foreground: ActualistTheme.primaryText,
                            keyboard: .signedDecimal,
                            focus: $isAmountFocused,
                            accessibilityLabel: "Target Balance",
                            accessibilityIdentifier: "reconciliation-target-field"
                        )
                    }

                    Text("Balance shown by your bank")
                        .font(ActualistTypography.body(for: density))
                        .foregroundStyle(ActualistTheme.secondaryText)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.vertical, 28)
                .background(
                    ActualistTheme.elevatedSurface,
                    in: RoundedRectangle(cornerRadius: 32, style: .continuous)
                )

                VStack(spacing: 0) {
                    detailRow(label: "Cleared balance", value: presentation.clearedBalanceText)
                    if let synced = presentation.lastSyncedBalanceText {
                        Divider().overlay(ActualistTheme.separator)
                        Button {
                            coordinator.useLastSyncedBalance()
                        } label: {
                            detailRow(label: "Last synced balance", value: synced, showsChevron: true)
                        }
                        .buttonStyle(.plain)
                        .disabled(presentation.isPrivacyProtected)
                    }
                    Divider().overlay(ActualistTheme.separator)
                    detailRow(label: "Last reconciled", value: presentation.lastReconciledText)
                }
                .padding(.horizontal, 16)
                .background(
                    ActualistTheme.surface,
                    in: RoundedRectangle(cornerRadius: 24, style: .continuous)
                )

                if let validationMessage = presentation.validationMessage {
                    Text(validationMessage)
                        .font(ActualistTypography.rowTitle(for: density))
                        .foregroundStyle(
                            presentation.isPrivacyProtected
                                ? ActualistTheme.secondaryText
                                : ActualistTheme.danger
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("reconciliation-target-message")
                }

                Button {
                    coordinator.confirmTarget()
                } label: {
                    Label("Start Reconciliation", systemImage: "checkmark.circle.fill")
                        .font(ActualistTypography.control(for: density))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.glassProminent)
                .tint(ActualistTheme.accent)
                .disabled(!presentation.canContinue)
                .accessibilityIdentifier("reconciliation-start-button")
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 32)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func startError(_ message: String) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(ActualistTheme.danger)
            Text(message)
                .font(ActualistTypography.rowTitle(for: density))
                .foregroundStyle(ActualistTheme.primaryText)
                .multilineTextAlignment(.center)
            Button("Try Again", action: onRetry)
                .buttonStyle(.glassProminent)
                .tint(ActualistTheme.accent)
        }
        .padding(24)
    }

    private var targetTextBinding: Binding<String> {
        Binding(
            get: { coordinator.targetEntry?.input.text ?? "" },
            set: coordinator.updateTargetText
        )
    }

    private func detailRow(
        label: String,
        value: String,
        showsChevron: Bool = false
    ) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(ActualistTypography.body(for: density))
                .foregroundStyle(ActualistTheme.secondaryText)
            Spacer(minLength: 8)
            Text(value)
                .font(ActualistTypography.rowValue(for: density))
                .foregroundStyle(ActualistTheme.primaryText)
                .multilineTextAlignment(.trailing)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(ActualistTheme.secondaryText)
            }
        }
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }
}

struct AccountReconciliationPanel: View {
    @Environment(\.actualistDensity) private var density

    let presentation: AccountReconciliationPanelPresentation
    let onCreateAdjustment: () -> Void
    let onLockTransactions: () -> Void
    let onExit: () -> Void
    let onRetryRefresh: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Reconciling", systemImage: "checkmark.seal.fill")
                    .font(ActualistTypography.sectionTitle(for: density))
                    .foregroundStyle(ActualistTheme.accent)
                Spacer()
                if presentation.submittingAction == .refresh {
                    ProgressView()
                        .controlSize(.small)
                        .tint(ActualistTheme.accent)
                }
            }
            .padding(.bottom, 8)

            amountRow(label: "Target", value: presentation.targetText)
            Divider().overlay(ActualistTheme.separator)
            amountRow(label: "Cleared", value: presentation.clearedBalanceText)
            Divider().overlay(ActualistTheme.separator)
            amountRow(
                label: "Difference",
                value: presentation.differenceText,
                foreground: differenceForeground
            )

            if let errorMessage = presentation.errorMessage {
                Text(errorMessage)
                    .font(ActualistTypography.rowLabel(for: density))
                    .foregroundStyle(ActualistTheme.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 10)
                Button("Refresh balances", action: onRetryRefresh)
                    .buttonStyle(.plain)
                    .font(ActualistTypography.control(for: density))
                    .foregroundStyle(ActualistTheme.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
            }

            if presentation.isPrivacyProtected {
                Text("Turn off Sample Values to change reconciliation data.")
                    .font(ActualistTypography.rowLabel(for: density))
                    .foregroundStyle(ActualistTheme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 12)
            }

            primaryButton
                .padding(.top, 14)

            Button("Exit reconciliation", action: onExit)
                .buttonStyle(.plain)
                .font(ActualistTypography.control(for: density))
                .foregroundStyle(ActualistTheme.secondaryText)
                .disabled(isBusy || presentation.isPrivacyProtected)
                .padding(.top, 14)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            ActualistTheme.surface,
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch presentation.primaryAction {
        case .createAdjustment:
            Button(action: onCreateAdjustment) {
                actionLabel(
                    title: presentation.submittingAction == .createAdjustment
                        ? "Creating Transaction"
                        : "Create reconciliation transaction",
                    systemImage: "plus.circle.fill"
                )
            }
            .buttonStyle(.glassProminent)
            .tint(ActualistTheme.accent)
            .disabled(isBusy || presentation.isPrivacyProtected)
            .accessibilityIdentifier("reconciliation-adjustment-button")
        case .lockTransactions:
            Button(action: onLockTransactions) {
                actionLabel(
                    title: presentation.submittingAction == .lockTransactions
                        ? "Locking Transactions"
                        : "Lock transactions",
                    systemImage: "lock.fill"
                )
            }
            .buttonStyle(.glassProminent)
            .tint(ActualistTheme.positive)
            .disabled(isBusy || presentation.isPrivacyProtected)
            .accessibilityIdentifier("reconciliation-lock-button")
        case nil:
            EmptyView()
        }
    }

    private func actionLabel(title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(ActualistTypography.control(for: density))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
    }

    private func amountRow(
        label: String,
        value: String,
        foreground: Color = ActualistTheme.primaryText
    ) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(ActualistTypography.body(for: density))
                .foregroundStyle(ActualistTheme.secondaryText)
            Spacer()
            Text(value)
                .font(ActualistTypography.rowValue(for: density))
                .foregroundStyle(foreground)
        }
        .padding(.vertical, 10)
    }

    private var differenceForeground: Color {
        switch presentation.differenceTone {
        case .balanced:
            ActualistTheme.positive
        case .remaining:
            ActualistTheme.warning
        case .unavailable:
            ActualistTheme.danger
        }
    }

    private var isBusy: Bool {
        presentation.submittingAction != nil
    }
}
