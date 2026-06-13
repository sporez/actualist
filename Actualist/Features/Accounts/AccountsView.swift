import SwiftUI

struct AccountsView: View {
    @Environment(AppState.self) private var appState
    @State private var accounts: [AccountDisplay] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var closedExpanded = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    accountSection(title: "Budget Accounts", rows: openBudgetAccounts, collapsedSummary: nil)
                    accountSection(title: "Off Budget", rows: offBudgetAccounts, collapsedSummary: nil)
                    accountSection(
                        title: "Closed",
                        rows: closedAccounts,
                        collapsedSummary: "\(closedAccounts.count) closed accounts"
                    )

                    Button {
                    } label: {
                        Label("Add Account", systemImage: "plus.circle")
                            .font(.headline.weight(.bold))
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
                            .font(.callout.weight(.semibold))
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
    private func accountSection(title: String, rows: [AccountDisplay], collapsedSummary: String?) -> some View {
        if !rows.isEmpty || collapsedSummary != nil {
            VStack(alignment: .leading, spacing: 12) {
                Button {
                    if collapsedSummary != nil {
                        withAnimation(.smooth(duration: 0.2)) {
                            closedExpanded.toggle()
                        }
                    }
                } label: {
                    HStack {
                        Image(systemName: "chevron.down")
                            .rotationEffect(.degrees(collapsedSummary == nil || closedExpanded ? 0 : -90))
                        Text(title)
                            .font(.title2.weight(.bold))
                        Spacer()
                        Text(total(rows).actualMoney.formatted())
                            .font(.headline.weight(.bold))
                            .foregroundStyle(ActualistTheme.secondaryText)
                    }
                    .foregroundStyle(ActualistTheme.primaryText)
                }
                .buttonStyle(.plain)

                if collapsedSummary != nil && !closedExpanded {
                    GlassPanel {
                        HStack {
                            Text(collapsedSummary ?? "")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(ActualistTheme.secondaryText)
                        }
                        .foregroundStyle(ActualistTheme.primaryText)
                    }
                } else {
                    VStack(spacing: 0) {
                        ForEach(rows) { row in
                            NavigationLink(value: row.account) {
                                AccountRow(row: row)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .background(ActualistTheme.surface, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                }
            }
        }
    }

    private func total(_ rows: [AccountDisplay]) -> Int {
        rows.reduce(0) { $0 + ($1.balance ?? 0) }
    }

    private func load() async {
        await appState.loadBudgets()

        guard let budgetID = appState.settings.selectedBudgetID,
              let client = appState.makeClient() else {
            return
        }

        isLoading = true
        errorMessage = nil
        do {
            let apiAccounts = try await client.accounts(budgetID: budgetID)
            var displays: [AccountDisplay] = []
            for account in apiAccounts {
                let balance = try? await client.balance(budgetID: budgetID, accountID: account.id)
                displays.append(AccountDisplay(account: account, balance: balance))
            }
            accounts = displays
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

struct AccountRow: View {
    let row: AccountDisplay

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: row.account.offbudget ? "tray.full.fill" : "banknote.fill")
                .font(.title2)
                .foregroundStyle(ActualistTheme.accent)
                .frame(width: 42, height: 42)
                .background(ActualistTheme.elevatedSurface, in: Circle())

            Text(row.account.name)
                .font(.headline)
                .foregroundStyle(ActualistTheme.primaryText)
                .lineLimit(1)

            Spacer()

            Text((row.balance ?? 0).actualMoney.formatted())
                .font(.headline.weight(.bold))
                .foregroundStyle((row.balance ?? 0) >= 0 ? ActualistTheme.positive : ActualistTheme.primaryText)

            Image(systemName: "chevron.right")
                .foregroundStyle(ActualistTheme.secondaryText)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(ActualistTheme.separator)
                .frame(height: 1)
                .padding(.leading, 76)
        }
    }
}
