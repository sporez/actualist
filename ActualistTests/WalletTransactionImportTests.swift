import Foundation
import Testing
@testable import Actualist

extension LocalFirstActualStoreTests {
    @Test func importWalletTransactionsSkipsExistingFinancialIDs() async throws {
        let firstID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let secondID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let store = try await makeOpenedWritableStore(additionalFixtureSQL: Self.walletImportColumnsSQL)
        let date = try makeDate(year: 2026, month: 7, day: 18)
        let first = try #require(
            WalletTransactionMapper.map(
                WalletTransactionFields(
                    id: firstID,
                    amount: Decimal(string: "8.40")!,
                    creditDebitIndicator: .debit,
                    merchantName: "SQ * WALLET CAFE #99",
                    transactionDescription: "SQ * WALLET CAFE #99",
                    transactionDate: date,
                    status: .booked
                )
            )
        )
        let second = try #require(
            WalletTransactionMapper.map(
                WalletTransactionFields(
                    id: secondID,
                    amount: Decimal(string: "15.00")!,
                    creditDebitIndicator: .credit,
                    merchantName: "Refund",
                    transactionDescription: "Refund",
                    transactionDate: date,
                    status: .pending
                )
            )
        )

        let firstResult = try await store.importWalletTransactions(
            [first],
            intoAccountID: "checking",
            budgetID: "group-1"
        )
        let secondResult = try await store.importWalletTransactions(
            [first, second],
            intoAccountID: "checking",
            budgetID: "group-1"
        )

        let existing = try await store.existingImportedIDs(budgetID: "group-1", accountID: "checking")
        let loaded = try #require(store.cachedAccountTransactions(budgetID: "group-1", accountID: "checking"))
        let importedCafe = try #require(loaded.transactions.first {
            $0.importedPayee == "SQ * WALLET CAFE #99"
        })
        let importedRefund = try #require(loaded.transactions.first { $0.importedPayee == "Refund" })

        #expect(firstResult == WalletTransactionImportResult(importedCount: 1, duplicateCount: 0))
        #expect(secondResult == WalletTransactionImportResult(importedCount: 1, duplicateCount: 1))
        #expect(existing == [firstID.uuidString.lowercased(), secondID.uuidString.lowercased()])
        #expect(importedCafe.amount == -840)
        #expect(importedCafe.cleared == .bool(true))
        #expect(importedCafe.payeeName == "Wallet Cafe")
        #expect(importedRefund.amount == 1_500)
        #expect(importedRefund.cleared == .bool(false))
        #expect(loaded.transactions.filter {
            $0.importedPayee == "SQ * WALLET CAFE #99"
        }.count == 1)
    }

    @Test func importWalletTransactionsAppliesMatchingPayeeRule() async throws {
        let store = try await makeOpenedWritableStore(
            additionalFixtureSQL: """
            \(Self.walletImportColumnsSQL)
            CREATE TABLE rules (
                id TEXT PRIMARY KEY,
                conditions TEXT,
                actions TEXT,
                tombstone INTEGER
            );
            INSERT INTO rules VALUES (
                'wallet-cafe-rule',
                '[{"field":"payee_name","op":"is","value":"Rule Cafe"}]',
                '[{"field":"category","op":"set","value":"groceries"}]',
                0
            );
            """
        )
        let candidate = try #require(
            WalletTransactionMapper.map(
                WalletTransactionFields(
                    id: UUID(uuidString: "99999999-8888-7777-6666-555555555555")!,
                    amount: Decimal(string: "6.25")!,
                    creditDebitIndicator: .debit,
                    merchantName: "Rule Cafe",
                    transactionDescription: "Rule Cafe",
                    transactionDate: try makeDate(year: 2026, month: 7, day: 19),
                    status: .booked
                )
            )
        )

        let result = try await store.importWalletTransactions(
            [candidate],
            intoAccountID: "checking",
            budgetID: "group-1"
        )
        let loaded = try #require(store.cachedAccountTransactions(budgetID: "group-1", accountID: "checking"))
        let imported = try #require(loaded.transactions.first { $0.importedPayee == "Rule Cafe" })

        #expect(result.importedCount == 1)
        #expect(imported.category == "groceries")
        #expect(imported.amount == -625)
    }

    @Test func importWalletTransactionsKeepsRawImportedPayeeForRules() async throws {
        let rawPayee = "SQ * RAW WALLET CAFE #123"
        let store = try await makeOpenedWritableStore(
            additionalFixtureSQL: """
            \(Self.walletImportColumnsSQL)
            CREATE TABLE rules (
                id TEXT PRIMARY KEY,
                conditions TEXT,
                actions TEXT,
                tombstone INTEGER
            );
            INSERT INTO rules VALUES (
                'wallet-raw-payee-rule',
                '[{"field":"imported_payee","op":"is","value":"\(rawPayee)","type":"string"}]',
                '[{"field":"category","op":"set","value":"groceries","type":"id"}]',
                0
            );
            """
        )
        let candidate = try #require(
            WalletTransactionMapper.map(
                WalletTransactionFields(
                    id: UUID(uuidString: "22222222-3333-4444-5555-666666666666")!,
                    amount: Decimal(string: "7.25")!,
                    creditDebitIndicator: .debit,
                    merchantName: rawPayee,
                    transactionDescription: rawPayee,
                    transactionDate: try makeDate(year: 2026, month: 7, day: 20),
                    status: .booked
                )
            )
        )

        _ = try await store.importWalletTransactions(
            [candidate],
            intoAccountID: "checking",
            budgetID: "group-1"
        )

        let loaded = try #require(
            store.cachedAccountTransactions(budgetID: "group-1", accountID: "checking")
        )
        let imported = try #require(loaded.transactions.first {
            $0.importedPayee == rawPayee
        })
        #expect(imported.payeeName == "Raw Wallet Cafe")
        #expect(imported.category == "groceries")
    }

    @Test func walletRemoveNotesRuleProducesFinalNilNotes() async throws {
        let rawPayee = "WALLET MEMO MERCHANT"
        let store = try await makeOpenedWritableStore(additionalFixtureSQL: """
            CREATE TABLE rules (
                id TEXT PRIMARY KEY,
                conditions TEXT,
                actions TEXT,
                tombstone INTEGER
            );
            INSERT INTO rules VALUES (
                'wallet-remove-notes',
                '[{"field":"imported_payee","op":"is","value":"\(rawPayee)","type":"string"}]',
                '[{"field":"notes","op":"set","value":""}]',
                0
            );
            """)
        let candidate = try #require(
            WalletTransactionMapper.map(
                WalletTransactionFields(
                    id: UUID(uuidString: "33333333-4444-5555-6666-777777777777")!,
                    amount: Decimal(string: "5.00")!,
                    creditDebitIndicator: .debit,
                    merchantName: rawPayee,
                    transactionDescription: rawPayee,
                    transactionDate: try makeDate(year: 2026, month: 7, day: 20),
                    status: .booked
                )
            )
        )
        let base = WalletTransactionMapper.draft(
            from: candidate,
            accountID: "checking",
            sortOrder: 1
        )
        let noteBearingDraft = TransactionDraft(
            accountID: base.accountID,
            date: base.date,
            amountMinorUnits: base.amountMinorUnits,
            payeeID: base.payeeID,
            payeeName: base.payeeName,
            categoryID: base.categoryID,
            notes: "Original FinanceKit memo",
            cleared: base.cleared,
            isTransfer: base.isTransfer,
            importedPayee: base.importedPayee,
            importedID: base.importedID,
            sortOrder: base.sortOrder
        )

        let preview = try await store.previewRules(
            for: noteBearingDraft,
            budgetID: "group-1"
        )
        let projected = WalletTransactionMapper.applyingImportPreview(
            noteBearingDraft,
            preview
        )

        #expect(preview.notes == nil)
        #expect(projected.notes == nil)
    }

    @Test func importWalletTransactionsPersistsRuleSplitChildrenAndParentIdentity() async throws {
        let financialID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let store = try await makeOpenedWritableStore(
            additionalFixtureSQL: """
            \(Self.walletImportColumnsSQL)
            CREATE TABLE rules (
                id TEXT PRIMARY KEY,
                conditions TEXT,
                actions TEXT,
                tombstone INTEGER
            );
            INSERT INTO rules VALUES (
                'wallet-split-rule',
                '[{"field":"payee_name","op":"is","value":"Split Cafe"}]',
                '[{"op":"set-split-amount","value":0,"options":{"method":"remainder","splitIndex":1}},{"op":"set","field":"category","value":"groceries","options":{"splitIndex":1}},{"op":"set","field":"notes","value":"child-a","options":{"splitIndex":1}}]',
                0
            );
            """
        )
        let candidate = try #require(
            WalletTransactionMapper.map(
                WalletTransactionFields(
                    id: financialID,
                    amount: Decimal(string: "10.00")!,
                    creditDebitIndicator: .debit,
                    merchantName: "Split Cafe",
                    transactionDescription: "Split Cafe",
                    transactionDate: try makeDate(year: 2026, month: 7, day: 21),
                    status: .booked
                )
            )
        )

        let first = try await store.importWalletTransactions(
            [candidate],
            intoAccountID: "checking",
            budgetID: "group-1"
        )
        let second = try await store.importWalletTransactions(
            [candidate],
            intoAccountID: "checking",
            budgetID: "group-1"
        )
        let loaded = try #require(store.cachedAccountTransactions(budgetID: "group-1", accountID: "checking"))
        let parent = try #require(loaded.transactions.first { $0.importedPayee == "Split Cafe" })
        let child = try #require(parent.subtransactions.first)

        #expect(first == WalletTransactionImportResult(importedCount: 1, duplicateCount: 0))
        #expect(second == WalletTransactionImportResult(importedCount: 0, duplicateCount: 1))
        #expect(parent.isParent)
        #expect(parent.category == nil)
        #expect(parent.importedPayee == "Split Cafe")
        #expect(try await store.existingImportedIDs(budgetID: "group-1", accountID: "checking") == [financialID.uuidString.lowercased()])
        #expect(parent.subtransactions.count == 1)
        #expect(child.amount == -1_000)
        #expect(child.category == "groceries")
        #expect(child.notes == "child-a")
        #expect(child.importedPayee == nil)
        #expect(loaded.transactions.filter { $0.importedPayee == "Split Cafe" }.count == 1)
    }

    @Test func existingImportedIDsAreScopedToTheAccount() async throws {
        let store = try await makeOpenedWritableStore(additionalFixtureSQL: Self.walletImportColumnsSQL)
        let candidate = try #require(
            WalletTransactionMapper.map(
                WalletTransactionFields(
                    id: UUID(uuidString: "12121212-3434-5656-7878-909090909090")!,
                    amount: Decimal(string: "4.00")!,
                    creditDebitIndicator: .debit,
                    merchantName: "Scoped",
                    transactionDescription: "Scoped",
                    transactionDate: try makeDate(year: 2026, month: 7, day: 20),
                    status: .booked
                )
            )
        )

        _ = try await store.importWalletTransactions(
            [candidate],
            intoAccountID: "checking",
            budgetID: "group-1"
        )

        let checking = try await store.existingImportedIDs(budgetID: "group-1", accountID: "checking")
        let credit = try await store.existingImportedIDs(budgetID: "group-1", accountID: "credit")
        #expect(checking == [candidate.financialID])
        #expect(credit.isEmpty)
    }

    private static let walletImportColumnsSQL = """
        ALTER TABLE transactions ADD COLUMN financial_id TEXT;
        ALTER TABLE transactions ADD COLUMN imported_description TEXT;
        ALTER TABLE transactions ADD COLUMN sort_order REAL;
        """
}
