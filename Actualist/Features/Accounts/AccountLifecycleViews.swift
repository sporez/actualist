import SwiftUI

struct AccountRenameSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.actualistDensity) private var density

    @Bindable var coordinator: AccountLifecycleCoordinator
    let onSubmit: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                if coordinator.isPrivacyModeEnabled {
                    AccountLifecyclePrivacyUnavailableView(action: "rename accounts")
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
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
                            .padding(16)
                            .background(
                                ActualistTheme.surface,
                                in: RoundedRectangle(cornerRadius: 22, style: .continuous)
                            )

                            if let message = validationMessage {
                                Text(message)
                                    .font(ActualistTypography.rowTitle(for: density))
                                    .foregroundStyle(ActualistTheme.danger)
                                    .accessibilityIdentifier("account-lifecycle-rename-message")
                            }

                            Button(action: onSubmit) {
                                if coordinator.isSubmitting {
                                    ProgressView()
                                        .frame(maxWidth: .infinity)
                                } else {
                                    Text("Rename Account")
                                        .font(ActualistTypography.control(for: density))
                                        .frame(maxWidth: .infinity)
                                }
                            }
                            .buttonStyle(.glassProminent)
                            .tint(ActualistTheme.accent)
                            .disabled(!coordinator.canSubmitRename)
                            .accessibilityIdentifier("account-lifecycle-rename-button")
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 20)
                    }
                    .scrollDismissesKeyboard(.interactively)
                }
            }
            .background(ActualistTheme.background)
            .navigationTitle("Rename Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        coordinator.cancel()
                        dismiss()
                    }
                }
            }
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
}

struct AccountReopenSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.actualistDensity) private var density

    @Bindable var coordinator: AccountLifecycleCoordinator
    let onConfirm: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                if coordinator.isPrivacyModeEnabled {
                    AccountLifecyclePrivacyUnavailableView(action: "reopen accounts")
                } else {
                    VStack(spacing: 20) {
                        Image(systemName: "arrow.uturn.backward.circle.fill")
                            .font(.largeTitle)
                            .foregroundStyle(ActualistTheme.accent)
                            .accessibilityHidden(true)
                        Text(accountName)
                            .font(ActualistTypography.sectionTitle(for: density))
                            .foregroundStyle(ActualistTheme.primaryText)
                        Text("This account will return to the open account list with its existing history and settings.")
                            .font(ActualistTypography.body(for: density))
                            .foregroundStyle(ActualistTheme.secondaryText)
                            .multilineTextAlignment(.center)

                        if let errorMessage = coordinator.errorMessage {
                            Text(errorMessage)
                                .font(ActualistTypography.rowTitle(for: density))
                                .foregroundStyle(ActualistTheme.danger)
                        }

                        Button(action: onConfirm) {
                            if coordinator.isSubmitting {
                                ProgressView()
                                    .frame(maxWidth: .infinity)
                            } else {
                                Text("Reopen Account")
                                    .font(ActualistTypography.control(for: density))
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(.glassProminent)
                        .tint(ActualistTheme.accent)
                        .disabled(!coordinator.canConfirmReopen)
                        .accessibilityIdentifier("account-lifecycle-reopen-button")
                    }
                    .padding(24)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ActualistTheme.background)
            .navigationTitle("Reopen Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        coordinator.cancel()
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var accountName: String {
        coordinator.reopenSession?.account.name ?? "Account"
    }
}

struct AccountLifecycleReviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.actualistDensity) private var density

    let presentation: AccountLifecycleReviewPresentation
    let didReplaceReview: Bool
    let isSubmitting: Bool
    let onDestinationChange: (String?) -> Void
    let onCategoryChange: (String?) -> Void
    let onConfirm: (() -> Void)?
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                if presentation.isPrivacyProtected {
                    AccountLifecyclePrivacyUnavailableView(action: "change accounts")
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(presentation.accountName)
                                    .font(ActualistTypography.sectionTitle(for: density))
                                    .foregroundStyle(ActualistTheme.primaryText)
                                Text("Review the account effects before continuing.")
                                    .font(ActualistTypography.body(for: density))
                                    .foregroundStyle(ActualistTheme.secondaryText)
                            }

                            if didReplaceReview {
                                Label(
                                    "The account changed while you were reviewing it. Check the updated effects before continuing.",
                                    systemImage: "arrow.triangle.2.circlepath"
                                )
                                .font(ActualistTypography.rowTitle(for: density))
                                .foregroundStyle(ActualistTheme.warning)
                                .accessibilityIdentifier("account-lifecycle-review-changed")
                            }

                            VStack(spacing: 0) {
                                ForEach(Array(presentation.rows.enumerated()), id: \.element.id) { index, row in
                                    consequenceRow(row)
                                    if index < presentation.rows.count - 1 {
                                        Divider().overlay(ActualistTheme.separator)
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                            .background(
                                ActualistTheme.surface,
                                in: RoundedRectangle(cornerRadius: 22, style: .continuous)
                            )

                            if presentation.showsDestinationPicker {
                                lifecyclePicker(
                                    title: "Transfer to",
                                    choices: presentation.destinationChoices,
                                    selection: presentation.selectedDestinationID,
                                    accessibilityIdentifier: "account-lifecycle-destination-picker",
                                    onChange: onDestinationChange
                                )
                            }

                            if presentation.showsCategoryPicker {
                                lifecyclePicker(
                                    title: "Category",
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
                            }

                            if let actionTitle = presentation.actionTitle, let onConfirm {
                                Button(role: .destructive, action: onConfirm) {
                                    if isSubmitting {
                                        ProgressView().frame(maxWidth: .infinity)
                                    } else {
                                        Text(actionTitle).frame(maxWidth: .infinity)
                                    }
                                }
                                .buttonStyle(.glassProminent)
                                .tint(ActualistTheme.danger)
                                .disabled(!presentation.canConfirm || isSubmitting)
                                .accessibilityIdentifier("account-lifecycle-close-button")
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 20)
                    }
                }
            }
            .background(ActualistTheme.background)
            .navigationTitle(presentation.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.large])
    }

    private func consequenceRow(_ row: AccountLifecycleConsequenceRow) -> some View {
        HStack(spacing: 12) {
            Text(row.label)
                .font(ActualistTypography.body(for: density))
                .foregroundStyle(ActualistTheme.secondaryText)
            Spacer(minLength: 8)
            Text(row.value)
                .font(ActualistTypography.rowValue(for: density))
                .foregroundStyle(ActualistTheme.primaryText)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 14)
    }


    private func lifecyclePicker(
        title: String,
        choices: [AccountLifecycleChoice],
        selection: String?,
        accessibilityIdentifier: String,
        onChange: @escaping (String?) -> Void
    ) -> some View {
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
        .disabled(isSubmitting)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

private struct AccountLifecyclePrivacyUnavailableView: View {
    let action: String

    var body: some View {
        ContentUnavailableView(
            "Sample Values",
            systemImage: "eye.slash",
            description: Text("Turn off Sample Values to \(action).")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
