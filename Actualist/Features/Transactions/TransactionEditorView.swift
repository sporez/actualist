import SwiftUI

struct TransactionEditorView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel = TransactionEditorViewModel()
    @State private var isPayeePickerPresented = false
    @FocusState private var isAmountFocused: Bool

    let prefilledAccount: ActualAccount?
    let onSaved: (() -> Void)?

    init(
        prefilledAccount: ActualAccount?,
        onSaved: (() -> Void)? = nil
    ) {
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
                        metadataDetails
                        submissionError
                        saveButton
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 18)
                    .padding(.bottom, 32)
                }
                .scrollDismissesKeyboard(.interactively)
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
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .task {
            await viewModel.load(using: appState, prefilledAccount: prefilledAccount)
            isAmountFocused = true
        }
        .sheet(isPresented: $isPayeePickerPresented) {
            PayeeSelectionView(viewModel: viewModel)
        }
    }

    private var amountHeader: some View {
        VStack(spacing: 18) {
            ZStack {
                Text(viewModel.formattedAmount)
                    .font(.system(size: 56, weight: .bold, design: .rounded))
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

            Divider().overlay(ActualistTheme.separator).padding(.leading, 58)

            editorPickerRow(
                title: "Category",
                systemImage: "tray.full.fill",
                value: viewModel.selectedCategoryName
            ) {
                Button("Uncategorized") {
                    viewModel.selectedCategoryID = nil
                }

                ForEach(viewModel.categories) { category in
                    if let categoryID = category.id {
                        Button(category.name.actualistCategoryNameParts.name) {
                            viewModel.selectedCategoryID = categoryID
                        }
                    }
                }
            }

            Divider().overlay(ActualistTheme.separator).padding(.leading, 58)

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

            Divider().overlay(ActualistTheme.separator).padding(.leading, 58)

            HStack(spacing: 16) {
                Image(systemName: "calendar")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(ActualistTheme.secondaryText)
                    .frame(width: 42)

                DatePicker(
                    "Date",
                    selection: $viewModel.date,
                    displayedComponents: .date
                )
                .font(.headline)
                .foregroundStyle(ActualistTheme.primaryText)
                .tint(ActualistTheme.accent)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 18)
        }
        .transactionEditorPanel()
    }

    private var metadataDetails: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: "note.text")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(ActualistTheme.secondaryText)
                    .frame(width: 42)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Notes")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(ActualistTheme.secondaryText)

                    TextField("Optional", text: $viewModel.notes, axis: .vertical)
                        .lineLimit(2...4)
                        .font(.headline)
                        .foregroundStyle(ActualistTheme.primaryText)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 18)

            Divider().overlay(ActualistTheme.separator).padding(.leading, 58)

            Toggle(isOn: $viewModel.isCleared) {
                HStack(spacing: 16) {
                    Image(systemName: "c.circle")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(ActualistTheme.secondaryText)
                        .frame(width: 42)

                    Text("Cleared")
                        .font(.headline)
                        .foregroundStyle(ActualistTheme.primaryText)
                }
            }
            .tint(ActualistTheme.positive)
            .padding(.horizontal, 18)
            .padding(.vertical, 18)
        }
        .transactionEditorPanel()
    }

    private var saveButton: some View {
        Button {
            Task {
                if await viewModel.submit(using: appState) {
                    onSaved?()
                    dismiss()
                }
            }
        } label: {
            Label(viewModel.saveButtonTitle, systemImage: viewModel.isSubmitting ? "arrow.triangle.2.circlepath" : "checkmark.circle.fill")
                .font(.headline.weight(.bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        }
        .buttonStyle(.glassProminent)
        .tint(ActualistTheme.accent)
        .disabled(!viewModel.canSave)
        .padding(.top, 4)
    }

    @ViewBuilder
    private var submissionError: some View {
        if let errorMessage = viewModel.errorMessage {
            Text(errorMessage)
                .font(.callout.weight(.semibold))
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

    private func editorButtonRow(
        title: String,
        systemImage: String,
        value: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: systemImage)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(ActualistTheme.secondaryText)
                    .frame(width: 42)

                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(ActualistTheme.secondaryText)
                    Text(value)
                        .font(.headline)
                        .foregroundStyle(ActualistTheme.primaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(ActualistTheme.secondaryText)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 18)
        .padding(.vertical, 18)
    }

    private func editorTextFieldRow(
        title: String,
        systemImage: String,
        text: Binding<String>,
        prompt: String
    ) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(ActualistTheme.secondaryText)
                .frame(width: 42)

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(ActualistTheme.secondaryText)
                TextField(prompt, text: text)
                    .font(.headline)
                    .foregroundStyle(ActualistTheme.primaryText)
                    .textInputAutocapitalization(.words)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 18)
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
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(ActualistTheme.secondaryText)
                    .frame(width: 42)

                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(ActualistTheme.secondaryText)
                        Text(value)
                            .font(.headline)
                            .foregroundStyle(ActualistTheme.primaryText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(ActualistTheme.secondaryText)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 18)
        .padding(.vertical, 18)
    }
}

private struct PayeeSelectionView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: TransactionEditorViewModel
    @State private var searchText = ""

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredPayees: [ActualPayee] {
        viewModel.filteredPayees(matching: searchText)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ActualistTheme.background.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        searchField

                        if !trimmedSearchText.isEmpty {
                            Button {
                                viewModel.useCustomPayee(trimmedSearchText, using: appState)
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "plus.circle.fill")
                                        .foregroundStyle(ActualistTheme.accent)
                                    Text("Use \"\(trimmedSearchText)\"")
                                        .font(.headline.weight(.semibold))
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
                        } else if filteredPayees.isEmpty {
                            Text("No matching payees")
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(ActualistTheme.secondaryText)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 18)
                        } else {
                            LazyVStack(spacing: 0) {
                                ForEach(filteredPayees, id: \.pickerID) { payee in
                                    Button {
                                        viewModel.selectPayee(payee, using: appState)
                                        dismiss()
                                    } label: {
                                        HStack {
                                            Text(payee.name)
                                                .font(.headline)
                                                .foregroundStyle(ActualistTheme.primaryText)
                                                .lineLimit(1)
                                            Spacer()
                                            if payee.id == viewModel.selectedPayeeID {
                                                Image(systemName: "checkmark.circle.fill")
                                                    .foregroundStyle(ActualistTheme.positive)
                                            }
                                        }
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 14)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)

                                    if payee.pickerID != filteredPayees.last?.pickerID {
                                        Divider()
                                            .overlay(ActualistTheme.separator)
                                            .padding(.leading, 16)
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
                .font(.headline)
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
}

private extension ActualPayee {
    var pickerID: String {
        id ?? name
    }
}

private extension View {
    func transactionEditorPanel() -> some View {
        background(ActualistTheme.surface, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }
}
