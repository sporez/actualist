import SwiftUI

struct AccountTransactionFeedRows: View {
    @Environment(\.actualistDensity) private var density

    let groups: AccountTransactionFeedGroups
    let scope: TransactionFeedScope
    let isSelectionMode: Bool
    let selectedIdentities: Set<TransactionSelectionIdentity>
    let selectionFailureMessage: String?
    let isPrivacyModeEnabled: Bool
    let highlightsIncomeAmounts: Bool
    let deletingTransactionID: String?
    @Binding var deletePresentation: TransactionDeletePresentation?
    let onOpenTransaction: (ActualTransaction) -> Void
    let onToggleSelection: (ActualTransaction) -> Void
    let onConvertToSchedule: (TransactionScheduleConversionEntryPoint) -> Void
    let onRequestDelete: (ActualTransaction) -> Void
    let onConfirmDelete: (ActualTransaction) -> Void

    var body: some View {
        if let selectionFailureMessage {
            Text(selectionFailureMessage)
                .font(ActualistTypography.rowTitle(for: density))
                .foregroundStyle(ActualistTheme.danger)
                .padding(.horizontal, 16)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }

        ForEach(groups.values) { group in
            Text(group.title)
                .font(ActualistTypography.sectionTitle(for: density))
                .foregroundStyle(ActualistTheme.primaryText)
                .textCase(nil)
                .padding(.top, 16)
                .padding(.bottom, 8)
                .padding(.horizontal, density.rowHorizontalPadding)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)

            ForEach(Array(group.rows.enumerated()), id: \.element.id) { index, row in
                transactionButton(
                    for: row,
                    showsBottomSeparator: index < group.rows.count - 1
                )
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(ActualistTheme.surface)
            }
        }
    }

    @ViewBuilder
    private func transactionButton(
        for row: AccountTransactionRowPresentation,
        showsBottomSeparator: Bool
    ) -> some View {
        let identity = row.selectionIdentity
        let isSelected = identity.map(selectedIdentities.contains) ?? false
        let button = baseTransactionButton(
            for: row,
            showsBottomSeparator: showsBottomSeparator,
            identity: identity,
            isSelected: isSelected
        )

        if isSelectionMode, let identity {
            button
                .accessibilityIdentifier("transaction-selection-\(identity.transactionID)")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
        } else if isSelectionMode {
            button
                .disabled(true)
                .accessibilityLabel("Selection unavailable")
                .accessibilityHint("This transaction has no saved identifier and cannot be selected.")
        } else if let entryPoint = row.scheduleConversionEntryPoint {
            button
                .contextMenu {
                    Button {
                        onConvertToSchedule(entryPoint)
                    } label: {
                        Label("Convert to Schedule…", systemImage: "calendar.badge.plus")
                    }
                    .accessibilityIdentifier("transaction-convert-to-schedule-\(entryPoint.transactionID)")
                }
        } else {
            button
        }
    }

    private func baseTransactionButton(
        for row: AccountTransactionRowPresentation,
        showsBottomSeparator: Bool,
        identity: TransactionSelectionIdentity?,
        isSelected: Bool
    ) -> some View {
        Button {
            if isSelectionMode {
                onToggleSelection(row.transaction)
            } else {
                onOpenTransaction(row.transaction)
            }
        } label: {
            HStack(spacing: 10) {
                if isSelectionMode {
                    Image(systemName: selectionSymbol(identity: identity, isSelected: isSelected))
                        .font(.title3.weight(.medium))
                        .foregroundStyle(selectionColor(identity: identity, isSelected: isSelected))
                        .frame(width: 26)
                        .accessibilityHidden(true)
                }

                TransactionRow(
                    transaction: row.transaction,
                    semantics: row.semantics,
                    accountName: row.accountName,
                    isPrivacyModeEnabled: isPrivacyModeEnabled,
                    highlightsIncomeAmounts: highlightsIncomeAmounts,
                    isNew: row.isNew,
                    showsBottomSeparator: showsBottomSeparator
                )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("transaction-row-\(row.transaction.id ?? row.id)")
        .disabled(isSelectionMode && identity == nil || deletingTransactionID == row.transaction.rowID)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !isSelectionMode {
                Button {
                    onRequestDelete(row.transaction)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .tint(ActualistTheme.danger)
                .disabled(row.transaction.id == nil || deletingTransactionID != nil)
            }
        }
        .confirmationDialog(
            deletePresentation?.confirmationTitle ?? "Delete Transaction?",
            isPresented: $deletePresentation.isPresented(matching: row.id),
            titleVisibility: .visible
        ) {
            Button(
                deletePresentation?.actionTitle ?? "Delete Transaction",
                role: .destructive
            ) {
                onConfirmDelete(row.transaction)
            }

            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                deletePresentation?.message
                    ?? "Delete \(row.payeeName)? Actualist will confirm the server update before refreshing \(scope.refreshTargetDescription)."
            )
        }
    }

    private func selectionSymbol(identity: TransactionSelectionIdentity?, isSelected: Bool) -> String {
        guard identity != nil else { return "exclamationmark.circle" }
        return isSelected ? "checkmark.circle.fill" : "circle"
    }

    private func selectionColor(identity: TransactionSelectionIdentity?, isSelected: Bool) -> Color {
        guard identity != nil else { return ActualistTheme.warning }
        return isSelected ? ActualistTheme.positive : ActualistTheme.secondaryText
    }
}

/// SwiftUI compares a view's stored properties on every parent update. Passed
/// as a plain array, the feed was deep-compared row by row before the always
/// unequal closures forced a re-render anyway, which stalled tab switches and
/// pull-to-refresh. A reference compares by identity instead.
final class AccountTransactionFeedGroups {
    let values: [AccountTransactionDateGroupPresentation]

    init(_ values: [AccountTransactionDateGroupPresentation]) {
        self.values = values
    }
}
