import SwiftUI

struct AccountRenameSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.actualistDensity) private var density

    @Bindable var coordinator: AccountLifecycleCoordinator
    let onSubmit: () -> Void
    let onRetry: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                if coordinator.isPrivacyModeEnabled {
                    AccountLifecyclePrivacyUnavailableView(action: "rename accounts", onCancel: cancel)
                } else {
                    ReviewSheetContent {
                        ReviewSheetHeader(
                            title: coordinator.renameDraft?.account.name ?? "Account",
                            subtitle: "Choose a name for this account."
                        )

                        VStack(alignment: .leading, spacing: 10) {
                            Text("Name")
                                .font(ActualistTypography.rowLabel(for: density))
                                .foregroundStyle(ActualistTheme.secondaryText)
                            TextField("Account name", text: nameBinding)
                                .font(ActualistTypography.rowTitle(for: density))
                                .foregroundStyle(ActualistTheme.primaryText)
                                .textInputAutocapitalization(.words)
                                .submitLabel(.done)
                                .disabled(!coordinator.canEditRename)
                                .onSubmit(onSubmit)
                                .accessibilityIdentifier("account-lifecycle-rename-field")
                        }
                        .actualistReviewCard(padding: 16)

                        if let message = validationMessage {
                            Label(message, systemImage: "exclamationmark.triangle.fill")
                                .font(ActualistTypography.rowTitle(for: density))
                                .foregroundStyle(ActualistTheme.danger)
                                .fixedSize(horizontal: false, vertical: true)
                                .actualistReviewCard(padding: 14)
                                .accessibilityIdentifier("account-lifecycle-rename-message")
                        }
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .reviewSheetBottomBar {
                        Button(role: .cancel, action: cancel) {
                            Text("Cancel")
                                .font(.subheadline.weight(.semibold))
                                .frame(minHeight: 32)
                                .padding(.horizontal, 12)
                        }
                        .buttonStyle(.glass)
                        if coordinator.errorMessage != nil {
                            Button(action: onRetry) {
                                Text("Edit Again")
                                    .font(.subheadline.weight(.semibold))
                                    .multilineTextAlignment(.center)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, minHeight: 32)
                            }
                            .buttonStyle(.glassProminent)
                            .tint(ActualistTheme.accent)
                        } else {
                            Button(action: onSubmit) {
                                if coordinator.isSubmitting {
                                    ProgressView()
                                        .frame(maxWidth: .infinity, minHeight: 32)
                                } else {
                                    Text("Rename Account")
                                        .font(.subheadline.weight(.semibold))
                                        .multilineTextAlignment(.center)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .frame(maxWidth: .infinity, minHeight: 32)
                                }
                            }
                            .buttonStyle(.glassProminent)
                            .tint(ActualistTheme.accent)
                            .disabled(!coordinator.canSubmitRename)
                            .accessibilityIdentifier("account-lifecycle-rename-button")
                        }
                    }
                }
            }
            .background(ActualistTheme.background)
            .toolbar(.hidden, for: .navigationBar)
        }
        .presentationDetents([.medium])
    }

    private var nameBinding: Binding<String> {
        Binding(
            get: { coordinator.renameDraft?.name ?? "" },
            set: { coordinator.updateRenameName($0) }
        )
    }

    private var validationMessage: String? {
        if let message = coordinator.errorMessage { return message }
        if let message = coordinator.renameDraft?.validationMessage { return message }
        return coordinator.renameDraft?.validationError?.localizedDescription
    }

    private func cancel() {
        coordinator.cancel()
        dismiss()
    }
}

struct AccountReopenSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.actualistDensity) private var density

    @Bindable var coordinator: AccountLifecycleCoordinator
    let onConfirm: () -> Void
    let onRetry: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                if coordinator.isPrivacyModeEnabled {
                    AccountLifecyclePrivacyUnavailableView(action: "reopen accounts", onCancel: cancel)
                } else {
                    ReviewSheetContent {
                        ReviewSheetHeader(
                            title: accountName,
                            subtitle: "Return this account to your open accounts."
                        )

                        VStack(alignment: .leading, spacing: 14) {
                            Label {
                                Text("This account will return to the open account list with its existing history and settings.")
                                    .font(ActualistTypography.body(for: density))
                                    .foregroundStyle(ActualistTheme.secondaryText)
                            } icon: {
                                Image(systemName: "arrow.uturn.backward.circle.fill")
                                    .font(.title3)
                                    .foregroundStyle(ActualistTheme.accent)
                            }
                            .fixedSize(horizontal: false, vertical: true)

                            if let errorMessage = coordinator.errorMessage {
                                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                                    .font(ActualistTypography.rowTitle(for: density))
                                    .foregroundStyle(ActualistTheme.danger)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .accessibilityIdentifier("account-lifecycle-reopen-error")
                            }
                        }
                        .actualistReviewCard(padding: 16)
                    }
                    .reviewSheetBottomBar {
                        Button(role: .cancel, action: cancel) {
                            Text("Cancel")
                                .font(.subheadline.weight(.semibold))
                                .frame(minHeight: 32)
                                .padding(.horizontal, 12)
                        }
                        .buttonStyle(.glass)
                        if coordinator.errorMessage != nil {
                            Button(action: onRetry) {
                                Text("Edit Again")
                                    .font(.subheadline.weight(.semibold))
                                    .multilineTextAlignment(.center)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, minHeight: 32)
                            }
                            .buttonStyle(.glassProminent)
                            .tint(ActualistTheme.accent)
                        } else {
                            Button(action: onConfirm) {
                                if coordinator.isSubmitting {
                                    ProgressView()
                                        .frame(maxWidth: .infinity, minHeight: 32)
                                } else {
                                    Text("Reopen Account")
                                        .font(.subheadline.weight(.semibold))
                                        .multilineTextAlignment(.center)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .frame(maxWidth: .infinity, minHeight: 32)
                                }
                            }
                            .buttonStyle(.glassProminent)
                            .tint(ActualistTheme.accent)
                            .disabled(!coordinator.canConfirmReopen)
                            .accessibilityIdentifier("account-lifecycle-reopen-button")
                        }
                    }
                }
            }
            .background(ActualistTheme.background)
            .toolbar(.hidden, for: .navigationBar)
        }
        .presentationDetents([.medium])
    }

    private var accountName: String {
        coordinator.reopenSession?.account.name ?? "Account"
    }

    private func cancel() {
        coordinator.cancel()
        dismiss()
    }
}

struct AccountLifecycleReviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.actualistDensity) private var density

    let presentation: AccountLifecycleReviewPresentation
    let didReplaceReview: Bool
    let isSubmitting: Bool
    let isRefreshing: Bool
    let onDestinationChange: @MainActor @Sendable (String?) -> Void
    let onCategoryChange: @MainActor @Sendable (String?) -> Void
    let onConfirm: (() -> Void)?
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                if presentation.isPrivacyProtected {
                    AccountLifecyclePrivacyUnavailableView(action: "change accounts", onCancel: cancel)
                } else {
                    ReviewSheetContent {
                        ReviewSheetHeader(
                            title: presentation.accountName,
                            subtitle: "Review the account effects before continuing."
                        )

                        if didReplaceReview {
                            Label(
                                "The account changed while you were reviewing it. Check the updated effects before continuing.",
                                systemImage: "arrow.triangle.2.circlepath"
                            )
                            .font(ActualistTypography.rowTitle(for: density))
                            .foregroundStyle(ActualistTheme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                            .actualistReviewCard()
                            .accessibilityIdentifier("account-lifecycle-review-changed")
                        }

                        VStack(spacing: 12) {
                            ForEach(presentation.rows) { row in
                                ReviewSummaryRow(
                                    title: row.label,
                                    value: row.value,
                                    symbol: symbol(for: row.id)
                                )
                            }
                        }
                        .actualistReviewCard(padding: 16)
                        .accessibilityIdentifier("account-lifecycle-consequences")

                        if presentation.showsDestinationPicker {
                            lifecyclePicker(
                                title: "Transfer to",
                                symbol: "arrow.left.arrow.right",
                                choices: presentation.destinationChoices,
                                selection: presentation.selectedDestinationID,
                                accessibilityIdentifier: "account-lifecycle-destination-picker",
                                onChange: onDestinationChange
                            )
                        }

                        if presentation.showsCategoryPicker {
                            lifecyclePicker(
                                title: "Category",
                                symbol: "tag",
                                choices: presentation.categoryChoices,
                                selection: presentation.selectedCategoryID,
                                accessibilityIdentifier: "account-lifecycle-category-picker",
                                onChange: onCategoryChange
                            )
                        }

                        ForEach(presentation.blockerMessages, id: \.self) { message in
                            Label(message, systemImage: "exclamationmark.triangle.fill")
                                .font(ActualistTypography.rowTitle(for: density))
                                .foregroundStyle(ActualistTheme.danger)
                                .fixedSize(horizontal: false, vertical: true)
                                .actualistReviewCard(padding: 14)
                        }
                    }
                    .reviewSheetBottomBar {
                        Button(role: .cancel, action: cancel) {
                            Text("Cancel")
                                .font(.subheadline.weight(.semibold))
                                .frame(minHeight: 32)
                                .padding(.horizontal, 12)
                        }
                        .buttonStyle(.glass)
                        if let actionTitle = presentation.actionTitle, let onConfirm {
                            Button(role: .destructive, action: onConfirm) {
                                if isSubmitting {
                                    ProgressView()
                                        .frame(maxWidth: .infinity, minHeight: 32)
                                } else {
                                    Text(actionTitle)
                                        .font(.subheadline.weight(.semibold))
                                        .multilineTextAlignment(.center)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .frame(maxWidth: .infinity, minHeight: 32)
                                }
                            }
                            .buttonStyle(.glassProminent)
                            .tint(ActualistTheme.danger)
                            .disabled(!presentation.canConfirm || isSubmitting || isRefreshing)
                            .accessibilityIdentifier("account-lifecycle-close-button")
                        }
                    }
                }
            }
            .background(ActualistTheme.background)
            .toolbar(.hidden, for: .navigationBar)
        }
        .presentationDetents([.large])
    }

    private func lifecyclePicker(
        title: String,
        symbol: String,
        choices: [AccountLifecycleChoice],
        selection: String?,
        accessibilityIdentifier: String,
        onChange: @escaping @MainActor @Sendable (String?) -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(ActualistTheme.secondaryText)
                .frame(width: 26, height: 26)
                .background(ActualistTheme.control, in: RoundedRectangle(cornerRadius: 9))
                .accessibilityHidden(true)
            Picker(
                title,
                selection: Binding(
                    get: { selection },
                    set: onChange
                )
            ) {
                Text("Choose…").tag(String?.none)
                ForEach(choices) { choice in
                    Text(choice.name).tag(Optional(choice.id))
                }
            }
            .pickerStyle(.menu)
            .disabled(isSubmitting || isRefreshing)
            .accessibilityIdentifier(accessibilityIdentifier)
        }
        .actualistReviewCard(padding: 12)
    }

    private func symbol(for rowID: String) -> String {
        switch rowID {
        case "balance": "dollarsign"
        case "transactions": "list.bullet.rectangle"
        case "destination": "arrow.left.arrow.right"
        case "category": "tag"
        case "bank": "building.columns"
        case "schedules", "schedule-posting": "calendar"
        default: "info.circle"
        }
    }

    private func cancel() {
        onCancel()
        dismiss()
    }
}

private struct AccountLifecyclePrivacyUnavailableView: View {
    let action: String
    let onCancel: () -> Void

    var body: some View {
        ReviewSheetContent {
            ReviewSheetHeader(title: "Sample Values")
            Label("Turn off Sample Values to \(action).", systemImage: "eye.slash")
                .foregroundStyle(ActualistTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .actualistReviewCard()
        }
        .reviewSheetBottomBar {
            Button(role: .cancel, action: onCancel) {
                Text("Cancel")
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 32)
                    .padding(.horizontal, 12)
            }
            .buttonStyle(.glass)
            Spacer(minLength: 0)
        }
    }
}
