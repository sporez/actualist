import Testing
@testable import Actualist

@MainActor
struct TransactionEditorPickerTests {
    @Test func groupSearchKeepsWholeGroupAndCategorySearchPreservesBalances() {
        let groceries = TransactionEditorCategoryOption(id: "food", title: "Groceries", amount: 1200, valueText: "$12.00")
        let fuel = TransactionEditorCategoryOption(id: "fuel", title: "Fuel", amount: -500, valueText: "-$5.00")
        let groups = [
            TransactionEditorCategoryGroup(id: "daily", name: "Everyday", options: [groceries, fuel]),
            TransactionEditorCategoryGroup(id: "empty", name: "Everyday Empty", options: [])
        ]
        let groupMatch = TransactionEditorCategoryOptions.matching(groups, query: " EVERYday ")
        #expect(groupMatch.map(\.id) == ["daily"])
        #expect(groupMatch.first?.options == [groceries, fuel])
        #expect(TransactionEditorCategoryOptions.matching(groups, query: "grocer").first?.options == [groceries])
        #expect(TransactionEditorCategoryOptions.matching(groups, query: "missing").isEmpty)
    }

    @Test func sharedPayeeRowsAndSplitSelectionResolveTransferAccountNames() throws {
        let model = TransactionEditorViewModel()
        model.accounts = [ActualAccount(id: "checking", name: "Checking", offbudget: false, closed: false)]
        model.payees = [ActualPayee(id: "transfer", name: "", category: nil, transferAccount: "checking")]
        let item = try #require(model.payeePickerItems.first)
        #expect(item.title == "Checking")
        #expect(item.isTransfer)
        #expect(item.matches(searchText: "transfer"))
        model.beginSplit()
        let rowID = try #require(model.splitRows.first?.id)
        model.selectSplitPayee(rowID: rowID, payeeID: item.id)
        let row = try #require(model.splitRows.first)
        #expect(row.payeeID == "transfer")
        #expect(row.payeeName == "Checking")
        #expect(row.isTransfer)
    }
}
