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
        NavigationStack {
            List {
                if line.isLinked {
                    linkedSection
                } else {
                    linkSection
                }
            }
            .scrollContentBackground(.hidden)
            .background(ActualistTheme.background)
            .foregroundStyle(ActualistTheme.primaryText)
            .tint(ActualistTheme.accent)
            .navigationTitle(line.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close")
                }
            }
        }
        .onDisappear {
            viewModel.dismissAccountSheet()
        }
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
            return "Unlinking leaves this account's transactions in place and only clears the bank connection."
        }
        return "This account is linked through another provider. SimpleFIN Bank Sync cannot change that connection."
    }

    private var linkSection: some View {
        Section {
            if !viewModel.canLinkAccounts {
                Text("Bank accounts cannot be linked because the server has no SimpleFIN setup.")
                    .foregroundStyle(ActualistTheme.secondaryText)
            } else if viewModel.linkableRemoteAccounts.isEmpty {
                Text("No bank accounts are available from the server.")
                    .foregroundStyle(ActualistTheme.secondaryText)
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
            Text("Linking does not download anything yet. Use Sync All afterwards to review and import transactions.")
                .font(.caption)
                .foregroundStyle(ActualistTheme.secondaryText)
        }
        .settingsSectionChrome()
    }
}
