import SwiftUI

struct PayeesView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel = PayeesViewModel()
    @State private var isCreatePresented = false
    @State private var isMergeTargetPresented = false
    @State private var pendingMergeTarget: ManagedPayee?
    @State private var pendingDeletePayee: ManagedPayee?
    @State private var isBulkDeleteConfirmationPresented = false

    var body: some View {
        List {
            if privacyModeEnabled {
                privacyBanner
            }

            if viewModel.snapshot.hasUnreadableRuleReferences {
                Label {
                    Text("One or more rules could not be inspected. Deleting payees is disabled to protect rule references.")
                } icon: {
                    Image(systemName: "exclamationmark.shield.fill")
                        .foregroundStyle(ActualistTheme.warning)
                }
                .font(.caption)
                .settingsRowChrome()
            }

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(ActualistTheme.danger)
                    .settingsRowChrome()
            }

            if viewModel.unusedPayeeCount > 0 {
                Picker("Payees", selection: $viewModel.listFilter) {
                    Text("All").tag(PayeesViewModel.ListFilter.all)
                    Text("Unused (\(viewModel.unusedPayeeCount))").tag(PayeesViewModel.ListFilter.unused)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
            }

            Section("Payees") {
                if viewModel.isLoading && viewModel.snapshot.payees.isEmpty {
                    ProgressView("Loading payees")
                } else if viewModel.regularPayees.isEmpty {
                    ContentUnavailableView(
                        viewModel.searchText.isEmpty ? "No Payees" : "No Matching Payees",
                        systemImage: "person.crop.circle.badge.questionmark"
                    )
                } else {
                    ForEach(viewModel.regularPayees) { payee in
                        regularPayeeRow(payee)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if payee.canDelete && !viewModel.isSelecting && !privacyModeEnabled {
                                    Button("Delete") {
                                        pendingDeletePayee = payee
                                    }
                                    .tint(ActualistTheme.danger)
                                }
                            }
                    }
                }
            }
            .settingsSectionChrome()

            if !viewModel.transferPayees.isEmpty {
                Section {
                    ForEach(viewModel.transferPayees) { payee in
                        NavigationLink {
                            PayeeRulesView(payee: payee)
                        } label: {
                            PayeeManagementRow(
                                payee: payee,
                                isSelected: false,
                                showsSelection: false,
                                isPrivacyModeEnabled: privacyModeEnabled
                            )
                        }
                        .disabled(privacyModeEnabled)
                    }
                } header: {
                    Text("Transfer Payees")
                } footer: {
                    Text("Transfer payees are linked to accounts and cannot be edited here.")
                }
                .settingsSectionChrome()
            }

            if viewModel.snapshot.supportsCategoryLearning && !privacyModeEnabled {
                Section {
                    Toggle(
                        "Category Learning",
                        isOn: Binding(
                            get: { viewModel.snapshot.globalCategoryLearningEnabled },
                            set: { enabled in
                                Task { _ = await viewModel.setGlobalCategoryLearning(enabled, using: appState) }
                            }
                        )
                    )
                    .disabled(viewModel.isSubmitting)
                } footer: {
                    Text("When enabled, Actual may create category rules from repeated payee choices. Disabling it keeps existing rules.")
                }
                .settingsSectionChrome()
            }
        }
        .scrollContentBackground(.hidden)
        .background(ActualistTheme.background)
        .foregroundStyle(ActualistTheme.primaryText)
        .tint(ActualistTheme.accent)
        .navigationTitle("Payees")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $viewModel.searchText, prompt: "Search payees")
        .toolbar {
            if canShowMutationControls {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(viewModel.isSelecting ? "Done" : "Select") {
                        if viewModel.isSelecting {
                            viewModel.endSelection()
                        } else {
                            viewModel.beginSelection()
                        }
                    }
                    .disabled(viewModel.isSubmitting || viewModel.regularPayees.count < 2)
                }

                if !viewModel.isSelecting {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            viewModel.errorMessage = nil
                            isCreatePresented = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("Add Payee")
                        .disabled(!viewModel.snapshot.supportsCreate || viewModel.isSubmitting)
                    }
                }

                if viewModel.isSelecting {
                    ToolbarItemGroup(placement: .bottomBar) {
                        Button(viewModel.areAllVisiblePayeesSelected ? "Deselect All" : "Select All") {
                            viewModel.toggleAllVisibleSelection()
                        }
                        .disabled(viewModel.visibleRegularPayeeIDs.isEmpty)
                        Spacer()
                        Menu {
                            if viewModel.snapshot.supportsFavorite {
                                Button(viewModel.selectedAreAllFavorites ? "Unfavorite" : "Favorite") {
                                    Task {
                                        _ = await viewModel.setFavoriteForSelection(
                                            !viewModel.selectedAreAllFavorites,
                                            using: appState
                                        )
                                    }
                                }
                            }
                            if viewModel.snapshot.supportsCategoryLearning
                                && viewModel.snapshot.globalCategoryLearningEnabled {
                                Button(viewModel.selectedAllLearnCategories ? "Disable Learning" : "Enable Learning") {
                                    Task {
                                        _ = await viewModel.setLearningForSelection(
                                            !viewModel.selectedAllLearnCategories,
                                            using: appState
                                        )
                                    }
                                }
                            }
                            Button("Merge") {
                                isMergeTargetPresented = true
                            }
                            .disabled(!viewModel.canBeginMerge)
                            Divider()
                            Button("Delete", role: .destructive) {
                                isBulkDeleteConfirmationPresented = true
                            }
                            .disabled(!viewModel.canDeleteSelection)
                        } label: {
                            Label("\(viewModel.selectedPayeeIDs.count) Selected", systemImage: "ellipsis.circle")
                        }
                        .disabled(viewModel.selectedPayeeIDs.isEmpty || viewModel.isSubmitting)
                    }
                }

                if !viewModel.isSelecting && viewModel.snapshot.canUndo {
                    ToolbarItem(placement: .bottomBar) {
                        Button("Undo", systemImage: "arrow.uturn.backward") {
                            Task { _ = await viewModel.undo(using: appState) }
                        }
                        .disabled(viewModel.isSubmitting)
                    }
                }
            }
        }
        .task {
            await viewModel.load(using: appState)
        }
        .refreshable {
            await viewModel.refresh(using: appState)
        }
        .onChange(of: appState.localDataRevision) {
            Task { await viewModel.load(using: appState) }
        }
        .sheet(isPresented: $isCreatePresented) {
            PayeeNameEntrySheet(viewModel: viewModel)
            .appSwitcherPrivacyAwareDragIndicator()
            .appSwitcherPrivacyProtected()
        }
        .sheet(isPresented: $isMergeTargetPresented) {
            PayeeMergeTargetSheet(payees: viewModel.selectedPayees) { payee in
                pendingMergeTarget = payee
                isMergeTargetPresented = false
            }
            .appSwitcherPrivacyAwareDragIndicator()
            .appSwitcherPrivacyProtected()
        }
        .confirmationDialog(
            "Merge Payees?",
            isPresented: Binding(
                get: { pendingMergeTarget != nil },
                set: { if !$0 { pendingMergeTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let target = pendingMergeTarget {
                Button("Merge into \(target.displayName)", role: .destructive) {
                    pendingMergeTarget = nil
                    Task { _ = await viewModel.merge(into: target.id, using: appState) }
                }
            }
            Button("Cancel", role: .cancel) {
                pendingMergeTarget = nil
            }
        } message: {
            if let target = pendingMergeTarget {
                Text("Transactions will display as \(target.displayName). The other selected payees will be removed.")
            }
        }
        .confirmationDialog(
            "Delete Payee?",
            isPresented: Binding(
                get: { pendingDeletePayee != nil },
                set: { if !$0 { pendingDeletePayee = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let payee = pendingDeletePayee {
                Button("Delete \(payee.displayName)", role: .destructive) {
                    pendingDeletePayee = nil
                    Task { _ = await viewModel.delete(payeeID: payee.id, using: appState) }
                }
            }
            Button("Cancel", role: .cancel) {
                pendingDeletePayee = nil
            }
        } message: {
            Text("Only unused payees without rule references can be deleted.")
        }
        .confirmationDialog(
            "Delete Selected Payees?",
            isPresented: $isBulkDeleteConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Delete \(viewModel.selectedPayeeIDs.count) Payees", role: .destructive) {
                Task { _ = await viewModel.deleteSelection(using: appState) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only the selected unused payees without rule references will be removed. You can undo this change while this budget remains open.")
        }
    }

    @ViewBuilder
    private func regularPayeeRow(_ payee: ManagedPayee) -> some View {
        if viewModel.isSelecting {
            Button {
                viewModel.toggleSelection(payee.id)
            } label: {
                PayeeManagementRow(
                    payee: payee,
                    isSelected: viewModel.selectedPayeeIDs.contains(payee.id),
                    showsSelection: true,
                    isPrivacyModeEnabled: privacyModeEnabled
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink {
                PayeeDetailView(payeeID: payee.id, viewModel: viewModel)
            } label: {
                PayeeManagementRow(
                    payee: payee,
                    isSelected: false,
                    showsSelection: false,
                    isPrivacyModeEnabled: privacyModeEnabled
                )
            }
            .disabled(privacyModeEnabled)
        }
    }

    private var privacyModeEnabled: Bool {
        appState.settings.randomizedDisplayValuesEnabled
    }

    private var canShowMutationControls: Bool {
        !privacyModeEnabled
    }

    private var privacyBanner: some View {
        Label {
            Text("Payee names and editing are hidden while sample values are on.")
        } icon: {
            Image(systemName: "eye.slash.fill")
                .foregroundStyle(ActualistTheme.warning)
        }
        .font(.caption)
        .settingsRowChrome()
    }
}

private struct PayeeManagementRow: View {
    let payee: ManagedPayee
    let isSelected: Bool
    let showsSelection: Bool
    let isPrivacyModeEnabled: Bool

    var body: some View {
        HStack(spacing: 12) {
            if showsSelection {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? ActualistTheme.accent : ActualistTheme.secondaryText)
                    .font(.title3)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(displayName)
                        .foregroundStyle(ActualistTheme.primaryText)
                    if payee.favorite && !payee.isTransfer {
                        Image(systemName: "bookmark.fill")
                            .font(.caption2)
                            .foregroundStyle(ActualistTheme.accent)
                    }
                    if !payee.learnCategories && !payee.isTransfer {
                        Image(systemName: "lightbulb.slash.fill")
                            .font(.caption2)
                            .foregroundStyle(ActualistTheme.danger)
                    }
                }
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(ActualistTheme.secondaryText)
            }
            Spacer(minLength: 8)
            if payee.isTransfer {
                Image(systemName: "arrow.left.arrow.right")
                    .foregroundStyle(ActualistTheme.secondaryText)
            }
        }
        .contentShape(Rectangle())
    }

    private var statusText: String {
        if payee.isTransfer {
            return "Managed by account"
        }
        var parts = [
            payee.transactionCount == 0
                ? "Unused"
                : "\(payee.transactionCount) \(payee.transactionCount == 1 ? "transaction" : "transactions")"
        ]
        if payee.ruleReferenceCount > 0 {
            parts.append(
                "\(payee.ruleReferenceCount) \(payee.ruleReferenceCount == 1 ? "rule" : "rules")"
            )
        }
        return parts.joined(separator: " • ")
    }

    private var displayName: String {
        guard isPrivacyModeEnabled else {
            return payee.displayName
        }
        return PrivacyDisplay.name(
            for: payee.isTransfer ? .account : .payee,
            seed: "managed-payee-\(payee.id)"
        )
    }
}

private struct PayeeDetailView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let payeeID: String
    @Bindable var viewModel: PayeesViewModel
    @State private var name = ""
    @State private var isDeleteConfirmationPresented = false

    var body: some View {
        Form {
            Section("Name") {
                TextField("Payee name", text: $name)
                    .textInputAutocapitalization(.words)
            }
            .settingsSectionChrome()

            if let payee, viewModel.snapshot.supportsFavorite {
                Section {
                    Toggle("Favorite", isOn: Binding(
                        get: { payee.favorite },
                        set: { favorite in
                            Task {
                                _ = await viewModel.setFavorite(
                                    payeeID: payeeID,
                                    favorite: favorite,
                                    using: appState
                                )
                            }
                        }
                    ))
                    .tint(ActualistTheme.positive)
                    .disabled(viewModel.isSubmitting)
                } footer: {
                    Text("Favorite payees appear first when choosing a payee for a transaction.")
                }
                .settingsSectionChrome()
            }

            if let payee,
               viewModel.snapshot.supportsCategoryLearning,
               viewModel.snapshot.globalCategoryLearningEnabled {
                Section {
                    Toggle("Learn Categories", isOn: Binding(
                        get: { payee.learnCategories },
                        set: { enabled in
                            Task {
                                _ = await viewModel.setLearning(
                                    payeeID: payeeID,
                                    enabled: enabled,
                                    using: appState
                                )
                            }
                        }
                    ))
                    .tint(ActualistTheme.positive)
                    .disabled(viewModel.isSubmitting)
                } footer: {
                    Text("Actual may update this payee's category rule after the same category is used three times among its five latest transactions.")
                }
                .settingsSectionChrome()
            }

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(ActualistTheme.danger)
                    .settingsRowChrome()
            }

            if let payee {
                Section("Usage") {
                    LabeledContent("Transactions", value: "\(payee.transactionCount)")
                    NavigationLink {
                        PayeeRulesView(payee: payee)
                    } label: {
                        LabeledContent("Rules", value: "\(payee.ruleReferenceCount)")
                    }
                }
                .settingsSectionChrome()

                if payee.canDelete {
                    Section {
                        Button("Delete Payee", role: .destructive) {
                            isDeleteConfirmationPresented = true
                        }
                        .disabled(viewModel.isSubmitting)
                    } footer: {
                        Text("This payee is unused and is not referenced by any rule.")
                    }
                    .settingsSectionChrome()
                } else {
                    Section {
                        Text(deleteUnavailableReason(payee))
                            .font(.caption)
                            .foregroundStyle(ActualistTheme.secondaryText)
                    }
                    .settingsSectionChrome()
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(ActualistTheme.background)
        .foregroundStyle(ActualistTheme.primaryText)
        .navigationTitle("Edit Payee")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") {
                    Task {
                        if await viewModel.rename(payeeID: payeeID, name: name, using: appState) {
                            dismiss()
                        }
                    }
                }
                .disabled(!canSave)
            }
        }
        .onAppear {
            viewModel.errorMessage = nil
            name = payee?.name ?? ""
        }
        .confirmationDialog(
            "Delete Payee?",
            isPresented: $isDeleteConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task {
                    if await viewModel.delete(payeeID: payeeID, using: appState) {
                        dismiss()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This unused payee will be removed.")
        }
    }

    private var payee: ManagedPayee? {
        viewModel.snapshot.payees.first { $0.id == payeeID }
    }

    private var canSave: Bool {
        guard let payee else { return false }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != payee.name && !viewModel.isSubmitting
    }

    private func deleteUnavailableReason(_ payee: ManagedPayee) -> String {
        if payee.transactionCount > 0 {
            return "This payee is in use. Merge it into another payee before deleting it."
        }
        if payee.ruleReferenceCount > 0 {
            return "This payee is referenced by a rule and cannot be deleted."
        }
        if viewModel.snapshot.hasUnreadableRuleReferences {
            return "Deletion is disabled because one or more rules could not be inspected."
        }
        return "This budget does not support deleting payees."
    }
}

private struct PayeeNameEntrySheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: PayeesViewModel
    @State private var name = ""
    @State private var isSubmitting = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("Payee name", text: $name)
                    .textInputAutocapitalization(.words)
                    .settingsRowChrome()

                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(ActualistTheme.danger)
                        .settingsRowChrome()
                }
            }
            .scrollContentBackground(.hidden)
            .background(ActualistTheme.background)
            .navigationTitle("New Payee")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        isSubmitting = true
                        Task {
                            if await viewModel.create(name: name, using: appState) {
                                dismiss()
                            }
                            isSubmitting = false
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSubmitting)
                }
            }
        }
    }
}

private struct PayeeMergeTargetSheet: View {
    @Environment(\.dismiss) private var dismiss
    let payees: [ManagedPayee]
    let onChoose: (ManagedPayee) -> Void

    var body: some View {
        NavigationStack {
            List(payees) { payee in
                Button {
                    onChoose(payee)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(payee.displayName)
                            .foregroundStyle(ActualistTheme.primaryText)
                        Text("Keep this payee")
                            .font(.caption)
                            .foregroundStyle(ActualistTheme.secondaryText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .settingsRowChrome()
            }
            .scrollContentBackground(.hidden)
            .background(ActualistTheme.background)
            .navigationTitle("Choose Payee to Keep")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
