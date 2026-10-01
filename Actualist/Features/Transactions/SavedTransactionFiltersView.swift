import SwiftUI

struct SavedTransactionFiltersView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var coordinator: SavedTransactionFiltersCoordinator

    var body: some View {
        NavigationStack {
            ReviewSheetContent {
                if coordinator.unavailableMessage == nil {
                    saveCurrentFilterCard
                }
                if let unavailableMessage = coordinator.unavailableMessage {
                    ContentUnavailableView(
                        "Saved Filters Unavailable",
                        systemImage: "line.3.horizontal.decrease.circle",
                        description: Text(unavailableMessage)
                    )
                } else if coordinator.isLoading && coordinator.filters.isEmpty {
                    ProgressView("Loading saved filters")
                        .frame(maxWidth: .infinity)
                } else if coordinator.filters.isEmpty {
                    ContentUnavailableView(
                        "No Saved Filters",
                        systemImage: "line.3.horizontal.decrease.circle",
                        description: Text("Save this filter to use it again.")
                    )
                } else {
                    LazyVStack(spacing: 8) {
                        ForEach(coordinator.filters) { filter in filterRow(filter) }
                    }
                }
                if let message = coordinator.errorMessage {
                    Label(message, systemImage: "exclamationmark.circle")
                        .font(.footnote)
                        .foregroundStyle(ActualistTheme.danger)
                        .actualistReviewCard(padding: 12)
                }
                if let message = coordinator.statusMessage {
                    Label(message, systemImage: "checkmark.circle")
                        .font(.footnote)
                        .foregroundStyle(ActualistTheme.positive)
                        .actualistReviewCard(padding: 12)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .reviewSheetBottomBar {
                Button {
                    dismiss()
                } label: {
                    Text("Done")
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(.glassProminent)
                .tint(ActualistTheme.accent)
            }
        }
        .frame(idealWidth: 560)
        .presentationSizing(.page.fitted(horizontal: true, vertical: false))
        .presentationBackground(ActualistTheme.background)
        .task { await coordinator.load() }
        .onDisappear { coordinator.cancel() }
        .confirmationDialog(
            "Delete Saved Filter?",
            isPresented: deleteConfirmationBinding,
            titleVisibility: .visible,
            presenting: coordinator.filterBeingDeleted
        ) { filter in
            Button("Delete \(filter.name)", role: .destructive) {
                Task { await coordinator.confirmDelete() }
            }
            Button("Cancel", role: .cancel) { coordinator.cancelDelete() }
        } message: { filter in
            Text("This removes \(filter.name) from your saved filters.")
        }
        .alert("Rename Saved Filter", isPresented: renameBinding) {
            TextField("Name", text: $coordinator.nameDraft)
            Button("Save") { Task { await coordinator.confirmRename() } }
            Button("Cancel", role: .cancel) { coordinator.cancelRename() }
        } message: {
            Text("Choose a name for this filter.")
        }
    }

    private var saveCurrentFilterCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            ReviewSheetHeader(
                title: "Save Current Filters",
                subtitle: "Keep these conditions for another review."
            )
            Text(coordinator.currentConditionsSummary)
                .font(.footnote)
                .foregroundStyle(ActualistTheme.secondaryText)
            TextField("Filter name", text: $coordinator.nameDraft)
                .reviewSheetFieldStyle()
                .accessibilityIdentifier("saved-transaction-filter-name")
            Button {
                Task { await coordinator.saveCurrentConditions() }
            } label: {
                Label(coordinator.isSaving ? "Saving…" : "Save Filter", systemImage: "bookmark")
                    .frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.glassProminent)
            .tint(ActualistTheme.accent)
            .disabled(!coordinator.canSaveCurrentConditions)
            .accessibilityIdentifier("saved-transaction-filter-save")
        }
        .actualistReviewCard()
    }

    private func filterRow(_ filter: SavedTransactionFilter) -> some View {
        HStack(spacing: 10) {
            Button { coordinator.apply(filter) } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(filter.name.isEmpty ? "Unnamed Filter" : filter.name)
                        .font(.headline)
                        .foregroundStyle(ActualistTheme.primaryText)
                    Text(filter.isSupported ? conditionSummary(filter) : "Contains conditions this version cannot apply")
                        .font(.footnote)
                        .foregroundStyle(ActualistTheme.secondaryText)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!filter.isSupported)
            .accessibilityIdentifier("saved-transaction-filter-apply-\(filter.id)")

            Menu {
                if filter.isSupported {
                    Button("Rename", systemImage: "pencil") { coordinator.beginRename(filter) }
                }
                Button("Delete", systemImage: "trash", role: .destructive) {
                    coordinator.requestDelete(filter)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Actions for \(filter.name)")
        }
        .actualistReviewCard(padding: 12)
    }

    private func conditionSummary(_ filter: SavedTransactionFilter) -> String {
        let count = filter.queryConditions?.count ?? 0
        return "\(count) condition\(count == 1 ? "" : "s") · \((filter.queryJoin ?? .and).rawValue.uppercased())"
    }

    private var deleteConfirmationBinding: Binding<Bool> {
        Binding(
            get: { coordinator.filterBeingDeleted != nil },
            set: { if !$0 { coordinator.cancelDelete() } }
        )
    }

    private var renameBinding: Binding<Bool> {
        Binding(
            get: { coordinator.filterBeingRenamed != nil },
            set: { if !$0 { coordinator.cancelRename() } }
        )
    }
}
