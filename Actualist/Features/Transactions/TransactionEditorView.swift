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
        onSaved: (() -> Void)? = nil
    ) {
        _viewModel = State(
            initialValue: TransactionEditorViewModel(
                editing: editingTransaction,
                payeeName: prefilledPayeeName,
                categoryName: prefilledCategoryName
            )
        )
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
                        if isReadOnly {
                            readOnlyNotice
                        } else {
                            saveButton
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 18)
                    .padding(.bottom, 32)
                    // Read-only viewing: all inputs (amount, pickers, splits, toggles) are
                    // inert; only the close button and scrolling remain interactive.
                    .disabled(isReadOnly)
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
                isAmountFocused = true
            }
        }
        .sheet(isPresented: $isPayeePickerPresented) {
            PayeeSelectionView(viewModel: viewModel)
        }
        .sheet(isPresented: $isCategoryPickerPresented) {
            TransactionCategorySelectionView(viewModel: viewModel)
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
                Text("The total is \(mismatch.transactionTotal.actualMoney.formatted()), but the splits add up to \(mismatch.splitTotal.actualMoney.formatted()). How would you like to handle the unassigned \(abs(mismatch.difference).actualMoney.formatted())?")
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
                        viewModel.selectedAccountID = account.id
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

                        Button {
                            viewModel.removeSplit(rowID: row.id)
                        } label: {
                            Image(systemName: "ellipsis")
                                .foregroundStyle(ActualistTheme.secondaryText)
                        }
                        .buttonStyle(.plain)
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

    /// Local-first keeps complex existing rows read-only, but developer builds can expose
    /// basic field edits without enabling deletes, splits, or transfers.
    private var isReadOnly: Bool {
        if viewModel.isEditing {
            return !appState.capabilities.canUpdateSimpleTransactions || viewModel.isComplexTransactionEdit
        }
        return !appState.capabilities.canCreateTransactions
    }

    private var readOnlyNotice: some View {
        Label(viewModel.isComplexTransactionEdit ? "Read-only. Split and transfer edits are not available yet." : "Read-only. Editing is unavailable in this mode.", systemImage: "lock.fill")
            .font(ActualistTypography.control(for: density))
            .foregroundStyle(ActualistTheme.secondaryText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(ActualistTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .padding(.top, 4)
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

struct TransactionCategorySelectionView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.actualistDensity) private var density
    let viewModel: TransactionEditorViewModel?
    let providedCategoryGroups: [TransactionEditorCategoryGroup]
    let providedSelectedCategoryID: String?
    let isLoadingProvidedCategories: Bool
    let showsUncategorizedOption: Bool
    let allowsSplitSelection: Bool
    let onSelectCategory: ((TransactionEditorCategoryOption) -> Void)?
    let onClearCategory: (() -> Void)?
    @State private var searchText = ""
    @State private var isSplitMode = false
    @FocusState private var isSearchFocused: Bool

    init(viewModel: TransactionEditorViewModel) {
        self.viewModel = viewModel
        providedCategoryGroups = []
        providedSelectedCategoryID = nil
        isLoadingProvidedCategories = false
        showsUncategorizedOption = true
        allowsSplitSelection = true
        onSelectCategory = nil
        onClearCategory = nil
    }

    init(
        categoryGroups: [TransactionEditorCategoryGroup],
        selectedCategoryID: String? = nil,
        isLoading: Bool = false,
        showsUncategorizedOption: Bool = false,
        onSelectCategory: @escaping (TransactionEditorCategoryOption) -> Void
    ) {
        viewModel = nil
        providedCategoryGroups = categoryGroups
        providedSelectedCategoryID = selectedCategoryID
        isLoadingProvidedCategories = isLoading
        self.showsUncategorizedOption = showsUncategorizedOption
        allowsSplitSelection = false
        self.onSelectCategory = onSelectCategory
        onClearCategory = nil
    }

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var categoryGroups: [TransactionEditorCategoryGroup] {
        if let viewModel {
            return viewModel.categorySelectionGroups(matching: searchText)
        }

        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSearch.isEmpty else {
            return providedCategoryGroups
        }

        return providedCategoryGroups.compactMap { group in
            let options = group.options.filter { option in
                option.title.localizedCaseInsensitiveContains(trimmedSearch)
                    || group.name.localizedCaseInsensitiveContains(trimmedSearch)
            }

            guard !options.isEmpty else {
                return nil
            }

            return TransactionEditorCategoryGroup(
                id: group.id,
                name: group.name,
                options: options
            )
        }
    }

    private var selectedCategoryID: String? {
        viewModel?.selectedCategoryID ?? providedSelectedCategoryID
    }

    private var isLoadingCategories: Bool {
        viewModel?.isLoadingCategoryBalances ?? isLoadingProvidedCategories
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ActualistTheme.background.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        searchField

                        if trimmedSearchText.isEmpty && !isSplitMode && showsUncategorizedOption {
                            uncategorizedButton
                        }

                        if isLoadingCategories, categoryGroups.isEmpty {
                            ProgressView("Loading categories")
                                .foregroundStyle(ActualistTheme.secondaryText)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 18)
                        } else if categoryGroups.isEmpty {
                            Text("No matching categories")
                                .font(ActualistTypography.rowTitle(for: density))
                                .foregroundStyle(ActualistTheme.secondaryText)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 18)
                        } else {
                            destinationGroups
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 18)
                    .padding(.bottom, 28)
                }
            }
            .navigationTitle("Category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .actualistToolbarGlassButton()
                }

                ToolbarItem(placement: .topBarTrailing) {
                    if allowsSplitSelection, let viewModel {
                        Button {
                            if isSplitMode {
                                viewModel.finalizeSplitSelection()
                                dismiss()
                            } else {
                                viewModel.beginSplitSelection()
                                isSplitMode = true
                            }
                        } label: {
                            Text(isSplitMode ? "Done" : "Split")
                        }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear {
            isSplitMode = viewModel?.isSplit ?? false
            Task {
                await Task.yield()
                isSearchFocused = true
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(ActualistTheme.secondaryText)

            TextField("Search Categories", text: $searchText)
                .textInputAutocapitalization(.words)
                .font(ActualistTypography.rowTitle(for: density))
                .foregroundStyle(ActualistTheme.primaryText)
                .focused($isSearchFocused)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(ActualistTheme.secondaryText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(ActualistTheme.control, in: Capsule())
    }

    private var uncategorizedButton: some View {
        Button {
            viewModel?.clearCategory()
            onClearCategory?()
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Text("Uncategorized")
                    .font(ActualistTypography.rowTitle(for: density))
                    .foregroundStyle(ActualistTheme.primaryText)

                Spacer()

                if selectedCategoryID == nil {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(ActualistTheme.positive)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(ActualistTheme.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var destinationGroups: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(categoryGroups) { group in
                VStack(alignment: .leading, spacing: 10) {
                    Text(group.name)
                        .font(ActualistTypography.rowLabel(for: density).weight(.bold))
                        .foregroundStyle(ActualistTheme.primaryText)
                        .padding(.horizontal, 22)

                    VStack(spacing: 0) {
                        ForEach(group.options) { option in
                            categoryButton(option)

                            if option.id != group.options.last?.id {
                                Divider()
                                    .overlay(ActualistTheme.separator)
                                    .padding(.leading, 22)
                            }
                        }
                    }
                    .background(ActualistTheme.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                }
            }
        }
    }

    private func categoryButton(_ option: TransactionEditorCategoryOption) -> some View {
        Button {
            if isSplitMode, let viewModel {
                viewModel.toggleSplitCategory(option)
            } else {
                viewModel?.selectCategory(option)
                onSelectCategory?(option)
                dismiss()
            }
        } label: {
            HStack(spacing: 12) {
                Text(option.title)
                    .font(ActualistTypography.rowTitle(for: density))
                    .foregroundStyle(ActualistTheme.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)

                Spacer()

                if let valueText = option.valueText {
                    Text(valueText)
                        .font(ActualistTypography.rowBadge(for: density))
                        .foregroundStyle(categoryValueForeground(option))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5)
                        .background(categoryValueBackground(option), in: Capsule())
                }

                if (isSplitMode && viewModel?.isSplitCategorySelected(option) == true)
                    || (!isSplitMode && option.id == selectedCategoryID) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(ActualistTheme.positive)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func categoryValueBackground(_ option: TransactionEditorCategoryOption) -> Color {
        guard let amount = option.amount else {
            return Color.clear
        }

        if amount < 0 {
            return ActualistTheme.danger
        } else if amount == 0 {
            return ActualistTheme.neutral
        } else {
            return ActualistTheme.positive
        }
    }

    private func categoryValueForeground(_ option: TransactionEditorCategoryOption) -> Color {
        option.amount == 0 ? ActualistTheme.secondaryText : .black.opacity(0.78)
    }
}

private struct PayeeSelectionView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.actualistDensity) private var density
    @Bindable var viewModel: TransactionEditorViewModel
    @State private var searchText = ""

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var payeeSections: [TransactionEditorPayeeSection] {
        viewModel.payeeSections(matching: searchText)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ActualistTheme.background.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        searchField

                        if viewModel.shouldOfferCustomPayee(matching: searchText) {
                            Button {
                                viewModel.useCustomPayee(trimmedSearchText, using: appState)
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "plus.circle.fill")
                                        .foregroundStyle(ActualistTheme.accent)
                                    Text("Use \"\(trimmedSearchText)\"")
                                        .font(ActualistTypography.rowTitle(for: density))
                                        .foregroundStyle(ActualistTheme.primaryText)
                                        .lineLimit(1)
                                    Spacer()
                                }
                                .padding(16)
                                .background(ActualistTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }

                        if viewModel.isLoading {
                            ProgressView("Loading payees")
                                .foregroundStyle(ActualistTheme.secondaryText)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 18)
                        } else if payeeSections.isEmpty {
                            Text("No matching payees")
                                .font(ActualistTypography.rowTitle(for: density))
                                .foregroundStyle(ActualistTheme.secondaryText)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 18)
                        } else {
                            LazyVStack(spacing: 0) {
                                ForEach(payeeSections) { section in
                                    if let title = section.title {
                                        sectionHeader(title)
                                    }

                                    ForEach(section.options) { option in
                                        payeeRow(option)

                                        if option.id != section.options.last?.id {
                                            Divider()
                                                .overlay(ActualistTheme.separator)
                                                .padding(.leading, option.isTransfer ? 50 : 16)
                                        }
                                    }
                                }
                            }
                            .background(ActualistTheme.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 18)
                    .padding(.bottom, 32)
                }
            }
            .navigationTitle("Payee")
            .navigationBarTitleDisplayMode(.inline)
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
        }
        .presentationDetents([.large])
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(ActualistTheme.secondaryText)

            TextField("Search or enter custom payee", text: $searchText)
                .textInputAutocapitalization(.words)
                .font(ActualistTypography.rowTitle(for: density))
                .foregroundStyle(ActualistTheme.primaryText)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(ActualistTheme.secondaryText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(ActualistTheme.control, in: Capsule())
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(ActualistTypography.rowTitle(for: density).weight(.semibold))
            .foregroundStyle(ActualistTheme.accent)
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func payeeRow(_ option: TransactionEditorPayeeOption) -> some View {
        Button {
            viewModel.selectPayee(option.payee, using: appState)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                if option.isTransfer {
                    Image(systemName: "arrow.left.arrow.right.circle.fill")
                        .foregroundStyle(ActualistTheme.accent)
                        .font(.body)
                }

                Text(option.title)
                    .font(ActualistTypography.rowTitle(for: density))
                    .foregroundStyle(ActualistTheme.primaryText)
                    .lineLimit(1)

                Spacer()

                if option.payee.id == viewModel.selectedPayeeID {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(ActualistTheme.positive)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, density.transactionRowVerticalPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private extension View {
    func transactionEditorPanel() -> some View {
        background(ActualistTheme.surface, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }
}
