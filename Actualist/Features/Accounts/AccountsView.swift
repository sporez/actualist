import SwiftUI

struct AccountsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.actualistDensity) private var density
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var expandedSections: Set<AccountSectionKind> = [.budget, .offBudget]

    /// Reactive snapshot from the shared store: shows cached balances instantly and updates
    /// as the background refresh lands.
    private var accounts: [AccountDisplay] {
        guard let budgetID = appState.settings.selectedBudgetID else {
            return []
        }
        return appState.dataStore.accountDisplays(budgetID: budgetID)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    accountSection(kind: .budget, title: "Budget Accounts", rows: openBudgetAccounts)
                    accountSection(kind: .offBudget, title: "Off Budget", rows: offBudgetAccounts)
                    accountSection(
                        kind: .closed,
                        title: "Closed",
                        rows: closedAccounts
                    )

                    Button {
                    } label: {
                        Label("Add Account", systemImage: "plus.circle")
                            .font(ActualistTypography.control(for: density))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    .tint(ActualistTheme.accent)
                    .padding(.top, 8)

                    if isLoading {
                        ProgressView("Loading accounts")
                            .foregroundStyle(ActualistTheme.secondaryText)
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(ActualistTypography.rowTitle(for: density))
                            .foregroundStyle(ActualistTheme.danger)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 28)
            }
            .background(ActualistTheme.background)
            .navigationTitle("Accounts")
            .navigationDestination(for: ActualAccount.self) { account in
                AccountTransactionsView(account: account)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await load() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .actualistToolbarGlassButton()
                }
            }
            .task { await load() }
            .refreshable { await load() }
        }
    }

    private var openBudgetAccounts: [AccountDisplay] {
        accounts.filter { !$0.account.closed && !$0.account.offbudget }
    }

    private var offBudgetAccounts: [AccountDisplay] {
        accounts.filter { !$0.account.closed && $0.account.offbudget }
    }

    private var closedAccounts: [AccountDisplay] {
        accounts.filter { $0.account.closed }
    }

    @ViewBuilder
    private func accountSection(kind: AccountSectionKind, title: String, rows: [AccountDisplay]) -> some View {
        if !rows.isEmpty {
            let isExpanded = expandedSections.contains(kind)

            VStack(alignment: .leading, spacing: 10) {
                Button {
                    withAnimation(.smooth(duration: 0.2)) {
                        if isExpanded {
                            expandedSections.remove(kind)
                        } else {
                            expandedSections.insert(kind)
                        }
                    }
                } label: {
                    HStack {
                        Image(systemName: "chevron.down")
                            .rotationEffect(.degrees(isExpanded ? 0 : -90))
                        Text(sectionTitle(title, count: rows.count, isExpanded: isExpanded))
                            .font(ActualistTypography.sectionTitle(for: density))
                        Spacer()
                        Text(total(rows).actualMoney.formatted())
                            .font(ActualistTypography.rowValue(for: density))
                            .foregroundStyle(ActualistTheme.secondaryText)
                    }
                    .foregroundStyle(ActualistTheme.primaryText)
                }
                .buttonStyle(.plain)

                if isExpanded {
                    VStack(spacing: 0) {
                        ForEach(rows) { row in
                            NavigationLink(value: row.account) {
                                AccountRow(row: row)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .background(ActualistTheme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
            }
        }
    }

    private func sectionTitle(_ title: String, count: Int, isExpanded: Bool) -> String {
        isExpanded ? title : "\(title) (\(count))"
    }

    private func total(_ rows: [AccountDisplay]) -> Int {
        rows.reduce(0) { $0 + ($1.balance ?? 0) }
    }

    private func load() async {
        await appState.loadBudgets()

        guard let budgetID = appState.settings.selectedBudgetID else {
            return
        }

        isLoading = true
        errorMessage = nil
        do {
            try await appState.dataStore.refreshAccountsWithBalances(budgetID: budgetID)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

private enum AccountSectionKind: Hashable {
    case budget
    case offBudget
    case closed
}

struct AccountRow: View {
    @Environment(\.actualistDensity) private var density

    let row: AccountDisplay

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: row.account.offbudget ? "tray.full.fill" : "banknote.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(ActualistTheme.accent)
                .frame(width: density.iconSize, height: density.iconSize)
                .background(ActualistTheme.elevatedSurface, in: Circle())

            Text(row.account.name)
                .font(ActualistTypography.rowTitle(for: density))
                .foregroundStyle(ActualistTheme.primaryText)
                .lineLimit(1)

            Spacer()

            Text((row.balance ?? 0).actualMoney.formatted())
                .font(ActualistTypography.rowValue(for: density))
                .foregroundStyle((row.balance ?? 0) >= 0 ? ActualistTheme.positive : ActualistTheme.primaryText)

            Image(systemName: "chevron.right")
                .foregroundStyle(ActualistTheme.secondaryText)
        }
        .padding(.horizontal, density.rowHorizontalPadding)
        .padding(.vertical, density.accountRowVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(ActualistTheme.separator)
                .frame(height: 1)
                .padding(.leading, density.iconSize + density.rowHorizontalPadding + 12)
        }
    }
}
