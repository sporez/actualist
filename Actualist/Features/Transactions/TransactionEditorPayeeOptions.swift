import Foundation

struct TransactionEditorPayeeOption: Identifiable, Hashable {
    let payee: ActualPayee
    let transferAccountName: String?

    var id: String {
        payee.id ?? payee.name
    }

    var title: String {
        transferAccountName ?? payee.name
    }

    var isTransfer: Bool {
        payee.transferAccount != nil
    }
}

struct TransactionEditorPayeeSection: Identifiable, Hashable {
    enum Kind: String {
        case payees
        case transfers
    }

    let kind: Kind
    let options: [TransactionEditorPayeeOption]

    var id: Kind {
        kind
    }
}

struct TransactionEditorPayeeOptions {
    let accounts: [ActualAccount]
    let payees: [ActualPayee]

    var sections: [TransactionEditorPayeeSection] {
        let options = payees.compactMap(option(for:))
        return [
            TransactionEditorPayeeSection(
                kind: .payees,
                options: options.filter { !$0.isTransfer }
            ),
            TransactionEditorPayeeSection(
                kind: .transfers,
                options: options.filter(\.isTransfer)
            )
        ]
        .filter { !$0.options.isEmpty }
    }

    var pickerItems: [PayeePickerItem] {
        sections.flatMap { section in
            section.options.map { option in
                PayeePickerItem(
                    id: option.id, title: option.title, isTransfer: option.isTransfer,
                    searchAliases: [option.payee.name, option.transferAccountName].compactMap { $0 }
                )
            }
        }
    }

    func displayName(for payee: ActualPayee) -> String {
        transferAccountName(for: payee) ?? payee.name
    }

    private func option(for payee: ActualPayee) -> TransactionEditorPayeeOption? {
        let transferAccountName = transferAccountName(for: payee)
        let title = transferAccountName ?? payee.name
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        return TransactionEditorPayeeOption(
            payee: payee,
            transferAccountName: transferAccountName
        )
    }

    private func transferAccountName(for payee: ActualPayee) -> String? {
        guard let transferAccountID = payee.transferAccount else {
            return nil
        }

        if let accountName = accounts.first(where: { $0.id == transferAccountID })?.name,
           !accountName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return accountName
        }

        let fallbackName = payee.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallbackName.isEmpty ? nil : fallbackName
    }
}
