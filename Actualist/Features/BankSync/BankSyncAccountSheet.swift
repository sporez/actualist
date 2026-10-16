import SwiftUI

/// Half-sheet for one account: link it to a remote SimpleFIN account, or
/// unlink it. Presenting-only; intents live in `BankSyncViewModel`.
struct BankSyncAccountSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let viewModel: BankSyncViewModel
    let line: BankSyncViewModel.AccountLine

    @State private var selectedRemoteID: String?

    var body: some View {
        List {
            ReviewSheetListHeader(title: line.name)
            if line.isLinked {
                linkedSection
            } else {
                linkSection
            }
        }
        .reviewSheetList()
        .reviewSheetBottomBar {
            ReviewSheetSecondaryButton(title: "Close", role: nil) { dismiss() }
        }
        .task(id: viewModel.canLinkAccounts) {
            await viewModel.ensureRemoteAccounts()
        }
        .onDisappear {
            viewModel.dismissAccountSheet()
        }
        .reviewSheetPresentation(detents: [.medium, .large], appState: appState)
    }

    private var linkedSection: some View {
        Section {
            LabeledContent("Bank account") {
                Text(viewModel.linkedAccountDisplayName(for: line))
                    .foregroundStyle(ActualistTheme.secondaryText)
                    .lineLimit(2)
            }
            LabeledContent("Last synced") {
                Text(line.lastSyncText)
                    .foregroundStyle(ActualistTheme.secondaryText)
            }
            if line.isSyncable {
                Button(role: .destructive) {
                    Task {
                        await viewModel.unlinkSelected()
                        dismiss()
                    }
                } label: {
                    SettingsActionLabel(title: "Unlink Bank Account", systemImage: "link.badge.plus")
                }
            }
        } footer: {
            Text(linkedFooterText)
                .font(.caption)
                .foregroundStyle(ActualistTheme.secondaryText)
        }
        .settingsSectionChrome()
    }

    private var linkedFooterText: String {
        if line.isSyncable {
            return "Unlinking keeps this account’s transactions. Only the bank connection is removed."
        }
        return "This account is linked through another bank provider. Unlink it in the Actual web app first."
    }

    private var linkSection: some View {
        Section {
            if !viewModel.canLinkAccounts {
                Text("Bank accounts cannot be linked because your server is not set up for SimpleFIN.")
                    .foregroundStyle(ActualistTheme.secondaryText)
            } else {
                switch viewModel.remoteAccountsStatus {
                case .idle, .loading:
                    Text("Loading bank accounts…")
                        .foregroundStyle(ActualistTheme.secondaryText)
                case .failed(let message):
                    Text(message)
                        .foregroundStyle(ActualistTheme.danger)
                case .ready:
                    if viewModel.linkableRemoteAccounts.isEmpty {
                        Text("No bank accounts found.")
                            .foregroundStyle(ActualistTheme.secondaryText)
                    }
                }
            }
            ForEach(viewModel.linkableRemoteAccounts, id: \.accountID) { remote in
                Button {
                    selectedRemoteID = remote.accountID
                    Task {
                        await viewModel.link(selectedRemote: remote)
                        dismiss()
                    }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(remote.name)
                                .foregroundStyle(ActualistTheme.primaryText)
                            if let institution = remote.institution ?? remote.orgName {
                                Text(institution)
                                    .font(.caption)
                                    .foregroundStyle(ActualistTheme.secondaryText)
                            }
                        }
                        Spacer()
                        if selectedRemoteID == remote.accountID {
                            ProgressView()
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text("Link a Bank Account")
        } footer: {
            Text("Linking does not download transactions. Tap Sync All afterward to get them.")
                .font(.caption)
                .foregroundStyle(ActualistTheme.secondaryText)
        }
        .settingsSectionChrome()
    }
}
