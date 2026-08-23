import SwiftUI

struct TransactionEditorView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.actualistDensity) private var density
    @State private var viewModel: TransactionEditorViewModel
    @State private var isPayeePickerPresented = false
    @State private var isCategoryPickerPresented = false
    @FocusState private var isAmountFocused: Bool

    let prefilledAccount: ActualAccount?
    let onSaved: (() -> Void)?

    init(
        prefilledAccount: ActualAccount?,
        editingTransaction: ActualTransaction? = nil,
        prefilledPayeeName: String? = nil,
        prefilledCategoryName: String? = nil,
        shortcutPrefill: ShortcutEditorPrefill? = nil,
        onSaved: (() -> Void)? = nil
    ) {
        let model = TransactionEditorViewModel(
            editing: editingTransaction,
            payeeName: shortcutPrefill?.payeeName ?? prefilledPayeeName,
            categoryName: shortcutPrefill?.categoryName ?? prefilledCategoryName
        )
        if let shortcutPrefill {
            model.applyShortcutPrefill(shortcutPrefill)
        }
        _viewModel = State(initialValue: model)
        self.prefilledAccount = prefilledAccount
        self.onSaved = onSaved
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ActualistTheme.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        amountHeader
                        transactionDetails
                        splitDetails
                        metadataDetails
                        submissionError
                        saveButton
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 18)
                    .padding(.bottom, 32)
                }
                .scrollDismissesKeyboard(.immediately)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .actualistToolbarGlassButton()
                }
            }
            .navigationTitle(viewModel.title)
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .task {
            await viewModel.load(using: appState, prefilledAccount: prefilledAccount)
            if !viewModel.isEditing {
                if let budgetID = appState.settings.selectedBudgetID,
                   !viewModel.selectedPayeeName.isEmpty {
                    await viewModel.previewRules(
                        budgetID: budgetID,
                        repository: appState.transactionRepository,
                        currentBudgetID: { appState.settings.selectedBudgetID }
                    )
                }
                isAmountFocused = true
            }
        }
        .sheet(isPresented: $isPayeePickerPresented) {
            PayeeSelectionView(viewModel: viewModel)
                .appSwitcherPrivacyProtected()
        }
        .sheet(isPresented: $isCategoryPickerPresented) {
            TransactionCategorySelectionView(viewModel: viewModel)
                .appSwitcherPrivacyProtected()
        }
        .confirmationDialog(
            "A Rule Would Delete This Transaction",
            isPresented: deleteReviewBinding,
            titleVisibility: .visible
        ) {
            if viewModel.isEditing {
                Button("Delete Transaction", role: .destructive) {
                    Task {
                        if await viewModel.confirmRuleDelete(using: appState) {
                            onSaved?()
                            dismiss()
                        }
                    }
                }
            }
            Button("Keep Editing", role: .cancel) {
                viewModel.deleteReview.dismissReview()
            }
        } message: {
            Text(
                viewModel.isEditing
                    ? "A matching rule wants to delete this transaction. Delete it, or keep the existing row and leave it unsaved."
                    : "A matching rule would delete this transaction, so it will not be saved."
            )
        }
        .confirmationDialog(
            "Something Doesn't Add Up",
            isPresented: splitMismatchBinding,
            titleVisibility: .visible
        ) {
            Button("Auto-Distribute") {
                viewModel.autoDistributeSplitMismatch()
                Task { await submitAndDismissIfSaved() }
            }
            Button("Update Total") {
                viewModel.updateTotalFromSplits()
                Task { await submitAndDismissIfSaved() }
            }
            Button("Adjust Manually", role: .cancel) {
                viewModel.adjustSplitsManually()
            }
        } message: {
            if let mismatch = viewModel.pendingSplitMismatch {
                Text("The total is \(mismatch.transactionTotal.actualMoney.formatted()), but the splits add up to \(mismatch.splitTotal.actualMoney.formatted()). How would you like to handle the unassigned \(Int(clamping: mismatch.difference.magnitude).actualMoney.formatted())?")
            }
        }
    }

    private var amountHeader: some View {
        VStack(spacing: 18) {
            ZStack {
                Text(viewModel.formattedAmount)
                    .font(ActualistTypography.editorAmount(for: density))
                    .foregroundStyle(viewModel.amountColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)

                TextField("", text: amountDigitsBinding)
                    .focused($isAmountFocused)
                    .keyboardType(.numberPad)
                    .textInputAutocapitalization(.never)
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 18)
            .contentShape(Rectangle())
            .onTapGesture {
                isAmountFocused = true
            }

            Picker("Transaction Type", selection: $viewModel.kind) {
                ForEach(TransactionFlowKind.allCases) { kind in
                    Text(kind.rawValue).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .tint(viewModel.kind == .spend ? ActualistTheme.danger : ActualistTheme.positive)
            .frame(maxWidth: 260)
        }
        .padding(.vertical, 22)
        .padding(.horizontal, 20)
        .background(ActualistTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
    }

    private var transactionDetails: some View {
        VStack(spacing: 0) {
            editorButtonRow(
                title: "Payee",
                systemImage: "arrow.left.arrow.right.circle.fill",
                value: viewModel.selectedPayeeName
            ) {
                isPayeePickerPresented = true
            }

            Divider().overlay(ActualistTheme.separator).padding(.leading, density.iconSize + density.rowHorizontalPadding)

            editorButtonRow(
                title: "Category",
                systemImage: "tray.full.fill",
                value: viewModel.selectedCategoryName,
                isEnabled: !viewModel.isCategoryReadOnly
            ) {
                Task {
                    await viewModel.refreshCategoryBalancesIfNeeded(using: appState)
                    isCategoryPickerPresented = true
                }
            }

            Divider().overlay(ActualistTheme.separator).padding(.leading, density.iconSize + density.rowHorizontalPadding)

            editorPickerRow(
                title: "Account",
                systemImage: "building.columns.fill",
                value: viewModel.selectedAccountName
            ) {
                ForEach(viewModel.accounts) { account in
                    Button(account.name) {
                        viewModel.selectAccount(account)
                    }
                }
            }

            Divider().overlay(ActualistTheme.separator).padding(.leading, density.iconSize + density.rowHorizontalPadding)

            HStack(spacing: 16) {
                Image(systemName: "calendar")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(ActualistTheme.secondaryText)
                    .frame(width: density.iconSize)

                DatePicker(
                    "Date",
                    selection: $viewModel.date,
                    displayedComponents: .date
                )
                .font(ActualistTypography.rowTitle(for: density))
                .foregroundStyle(ActualistTheme.primaryText)
                .tint(ActualistTheme.accent)
            }
            .padding(.horizontal, density.rowHorizontalPadding)
            .padding(.vertical, density.editorRowVerticalPadding)
        }
        .transactionEditorPanel()
    }

    private var metadataDetails: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: "note.text")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(ActualistTheme.secondaryText)
                    .frame(width: density.iconSize)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Notes")
                        .font(ActualistTypography.body(for: density))
                        .foregroundStyle(ActualistTheme.secondaryText)

                    TextField("Optional", text: $viewModel.notes, axis: .vertical)
                        .lineLimit(2...4)
                        .font(ActualistTypography.rowTitle(for: density))
                        .foregroundStyle(ActualistTheme.primaryText)
                }
            }
            .padding(.horizontal, density.rowHorizontalPadding)
            .padding(.vertical, density.editorRowVerticalPadding)

            Divider().overlay(ActualistTheme.separator).padding(.leading, density.iconSize + density.rowHorizontalPadding)

            Toggle(isOn: $viewModel.isCleared) {
                HStack(spacing: 16) {
                    Image(systemName: "c.circle")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(ActualistTheme.secondaryText)
                        .frame(width: density.iconSize)

                    Text("Cleared")
                        .font(ActualistTypography.rowTitle(for: density))
                        .foregroundStyle(ActualistTheme.primaryText)
                }
            }
            .tint(ActualistTheme.positive)
            .padding(.horizontal, density.rowHorizontalPadding)
            .padding(.vertical, density.editorRowVerticalPadding)
        }
        .transactionEditorPanel()
    }

    @ViewBuilder
    private var splitDetails: some View {
        if viewModel.isSplit {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Categories")
                        .font(ActualistTypography.body(for: density))
                        .foregroundStyle(ActualistTheme.secondaryText)

                    Spacer()

                    Text(viewModel.splitRemainingStatusText)
                        .font(ActualistTypography.rowBadge(for: density))
                        .foregroundStyle(viewModel.splitRemainingCents == 0 ? ActualistTheme.secondaryText : ActualistTheme.danger)
                }

                ForEach(viewModel.splitRows) { row in
                    HStack(spacing: 12) {
                        Text(row.categoryName)
                            .font(ActualistTypography.rowTitle(for: density))
                            .foregroundStyle(ActualistTheme.primaryText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)

                        Spacer()

                        TextField("0.00", text: splitAmountBinding(for: row.id))
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .font(ActualistTypography.rowValue(for: density))
                            .foregroundStyle(ActualistTheme.primaryText)
                            .frame(width: 92)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(ActualistTheme.control, in: Capsule())

                        if viewModel.canRemoveSplitRow {
                            Button {
                                viewModel.removeSplit(rowID: row.id)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(ActualistTheme.danger)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove split category")
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
                    .background(ActualistTheme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                }

                Button {
                    Task {
                        await viewModel.refreshCategoryBalancesIfNeeded(using: appState)
                        isCategoryPickerPresented = true
                    }
                } label: {
                    Label("Add a Category", systemImage: "plus.circle.fill")
                        .font(ActualistTypography.control(for: density))
                        .foregroundStyle(ActualistTheme.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .background(ActualistTheme.control, in: Capsule())
            }
            .padding(18)
            .background(ActualistTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
    }

    private var saveButton: some View {
        Button {
            Task { await submitAndDismissIfSaved() }
        } label: {
            Label(viewModel.saveButtonTitle, systemImage: viewModel.isSubmitting ? "arrow.triangle.2.circlepath" : "checkmark.circle.fill")
                .font(ActualistTypography.control(for: density))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        }
        .buttonStyle(.glassProminent)
        .tint(ActualistTheme.accent)
        .disabled(!viewModel.canSave)
        .padding(.top, 4)
    }

    private func submitAndDismissIfSaved() async {
        if await viewModel.submit(using: appState) {
            onSaved?()
            dismiss()
        }
    }

    @ViewBuilder
    private var submissionError: some View {
        if let errorMessage = viewModel.errorMessage {
            Text(errorMessage)
                .font(ActualistTypography.rowTitle(for: density))
                .foregroundStyle(ActualistTheme.danger)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(ActualistTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }

    private var amountDigitsBinding: Binding<String> {
        Binding {
            viewModel.amountDigits
        } set: { newValue in
            viewModel.setAmountInput(newValue)
        }
    }

    private var deleteReviewBinding: Binding<Bool> {
        Binding {
            viewModel.deleteReview.isReviewPresented
        } set: { isPresented in
            if !isPresented {
                viewModel.deleteReview.dismissReview()
            }
        }
    }

    private var splitMismatchBinding: Binding<Bool> {
        Binding {
            viewModel.pendingSplitMismatch != nil
        } set: { isPresented in
            if !isPresented {
                viewModel.adjustSplitsManually()
            }
        }
    }

    private func splitAmountBinding(for rowID: String) -> Binding<String> {
        Binding {
            viewModel.formattedSplitAmount(rowID: rowID)
        } set: { value in
            viewModel.setSplitAmount(rowID: rowID, value: value)
        }
    }

    private func editorButtonRow(
        title: String,
        systemImage: String,
        value: String,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: systemImage)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(ActualistTheme.secondaryText.opacity(isEnabled ? 1 : 0.68))
                    .frame(width: density.iconSize)

                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(ActualistTypography.body(for: density))
                        .foregroundStyle(ActualistTheme.secondaryText.opacity(isEnabled ? 1 : 0.68))
                    Text(value)
                        .font(ActualistTypography.rowTitle(for: density))
                        .foregroundStyle(isEnabled ? ActualistTheme.primaryText : ActualistTheme.secondaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }

                Spacer()

                if isEnabled {
                    Image(systemName: "chevron.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(ActualistTheme.secondaryText)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .padding(.horizontal, density.rowHorizontalPadding)
        .padding(.vertical, density.editorRowVerticalPadding)
    }

    private func editorTextFieldRow(
        title: String,
        systemImage: String,
        text: Binding<String>,
        prompt: String
    ) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(ActualistTheme.secondaryText)
                .frame(width: density.iconSize)

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(ActualistTypography.body(for: density))
                    .foregroundStyle(ActualistTheme.secondaryText)
                TextField(prompt, text: text)
                    .font(ActualistTypography.rowTitle(for: density))
                    .foregroundStyle(ActualistTheme.primaryText)
                    .textInputAutocapitalization(.words)
            }
        }
        .padding(.horizontal, density.rowHorizontalPadding)
        .padding(.vertical, density.editorRowVerticalPadding)
    }

    private func editorPickerRow<MenuContent: View>(
        title: String,
        systemImage: String,
        value: String,
        @ViewBuilder menuContent: () -> MenuContent
    ) -> some View {
        Menu {
            menuContent()
        } label: {
            HStack(spacing: 16) {
                Image(systemName: systemImage)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(ActualistTheme.secondaryText)
                    .frame(width: density.iconSize)

                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(ActualistTypography.body(for: density))
                        .foregroundStyle(ActualistTheme.secondaryText)
                    Text(value)
                        .font(ActualistTypography.rowTitle(for: density))
                        .foregroundStyle(ActualistTheme.primaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ActualistTheme.secondaryText)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, density.rowHorizontalPadding)
        .padding(.vertical, density.editorRowVerticalPadding)
    }
}

private struct PayeeSelectionView: View {
    @Environment(AppState.self) private var appState
    @Bindable var viewModel: TransactionEditorViewModel

    var body: some View {
        PayeePickerView(
            title: "Payee",
            items: pickerItems,
            selectedIDs: Set(viewModel.selectedPayeeID.map { [$0] } ?? []),
            allowsMultipleSelection: false,
            isLoading: viewModel.isLoading,
            searchPrompt: "Search or enter custom payee",
            onSelect: { id in
                guard let payee = viewModel.payees.first(where: { $0.id == id }) else { return }
                viewModel.selectPayee(payee)
                previewRulesForSelection()
            },
            onCustomSelect: { name in
                viewModel.useCustomPayee(name)
                previewRulesForSelection()
            }
        )
    }

    private var pickerItems: [PayeePickerItem] {
        viewModel.payeeSections.flatMap { section in
            section.options.map { option in
                PayeePickerItem(
                    id: option.id,
                    title: option.title,
                    isTransfer: option.isTransfer,
                    searchAliases: [option.payee.name, option.transferAccountName].compactMap { $0 }
                )
            }
        }
    }

    private func previewRulesForSelection() {
        guard let budgetID = appState.settings.selectedBudgetID else { return }
        Task {
            await viewModel.previewRules(
                budgetID: budgetID,
                repository: appState.transactionRepository,
                currentBudgetID: { appState.settings.selectedBudgetID }
            )
        }
    }
}

private extension View {
    func transactionEditorPanel() -> some View {
        background(ActualistTheme.surface, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }
}
