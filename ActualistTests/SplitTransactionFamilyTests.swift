import Foundation
import Testing
@testable import Actualist

struct SplitTransactionFamilyTests {
    @Test func makeChildInheritsAndHonorsNullOverrides() throws {
        let fixture = try familyFixture()
        let expected = try decodeRecords(fixture.caseData("make-child-inheritance-and-null-overrides"))
        let parent = baseParent
        let inherited = SplitTransactionFamilyOps.makeChild(
            parent: parent,
            data: SplitTransactionPatch(id: "child-inherited", amount: -4_000, sortOrder: .value(-1))
        )
        let overridden = SplitTransactionFamilyOps.makeChild(
            parent: parent,
            data: SplitTransactionPatch(
                id: "child-overrides",
                amount: 1_000,
                category: .value(nil),
                payee: .value(nil),
                notes: .value("child note"),
                sortOrder: .value(-2)
            )
        )
        #expect(inherited.selected() == expected[0])
        #expect(overridden.selected() == expected[1])
        #expect(inherited.isEffectiveChild)
        #expect(inherited.effectiveParentID == parent.id)
        #expect(!inherited.isEffectiveParent)
    }

    @Test func recalculateExactMismatchAndMixedSignMatchOracle() throws {
        let fixture = try familyFixture()
        let expected = try decodeObject(
            RecalculateExpected.self,
            fixture.caseData("recalculate-exact-mismatch-and-mixed-sign")
        )
        let exact = SplitTransactionFamilyOps.recalculateSplit(
            parent(isParent: true, payee: nil, children: [
                child("child-1", amount: -6_000, sortOrder: -1),
                child("child-2", amount: -4_000, sortOrder: -2),
            ])
        )
        let mismatch = SplitTransactionFamilyOps.recalculateSplit(
            parent(isParent: true, payee: nil, children: [
                child("child-1", amount: -4_000, sortOrder: -1),
                child("child-2", amount: -5_000, sortOrder: -2),
            ])
        )
        let mixed = SplitTransactionFamilyOps.recalculateSplit(
            parent(isParent: true, payee: nil, children: [
                child("child-1", amount: -11_000, sortOrder: -1),
                child("child-2", amount: 1_000, sortOrder: -2),
                child("child-3", amount: 0, sortOrder: -3),
            ])
        )
        #expect(selectedFamily(exact) == expected.exact.value)
        #expect(selectedFamily(mismatch) == expected.mismatch.value)
        #expect(selectedFamily(mixed) == expected.mixedSign.value)
        #expect(mismatch.error?.type == "SplitTransactionError")
        #expect(mismatch.error?.version == 1)
        #expect(mismatch.error?.difference == -1_000)
        #expect(mixed.error == nil)
    }

    @Test func splitConversionNullsParentPayeeAndStartsWithError() throws {
        let fixture = try familyFixture()
        let expected = try decodeObject(
            RowsFamilyExpected.self,
            fixture.caseData("low-level-split-conversion-nulls-parent-payee-and-starts-with-error")
        )
        let result = SplitTransactionFamilyOps.splitTransaction(
            [baseParent],
            id: baseParent.id,
            createSubtransactions: { parent in
                [
                    SplitTransactionFamilyOps.makeChild(
                        parent: parent,
                        data: SplitTransactionPatch(
                            id: "child-1",
                            amount: -6_000,
                            category: .value("groceries"),
                            sortOrder: .value(-1)
                        )
                    ),
                    SplitTransactionFamilyOps.makeChild(
                        parent: parent,
                        data: SplitTransactionPatch(
                            id: "child-2",
                            amount: -4_000,
                            category: .value(nil),
                            payee: .value(nil),
                            notes: .value("override"),
                            sortOrder: .value(-2)
                        )
                    ),
                ]
            }
        )
        let observed = SplitTransactionFamilyOps.family(from: result.data)
        #expect(observed.rows == expected.rows)
        #expect(observed.family == expected.familyValue)
        #expect(observed.family?.parent.payee == nil)
        #expect(observed.family?.parent.error?.difference == -10_000)
    }

    @Test func updateConversionMaterializesExactFamily() throws {
        let fixture = try familyFixture()
        let expected = try decodeObject(
            ResultExpected.self,
            fixture.caseData("update-conversion-materializes-exact-family")
        )
        var conversion = baseParent
        conversion.subtransactions = [
            SplitTransactionRecord(
                id: "child-1",
                amount: -6_000,
                category: "groceries",
                payee: "coffee",
                sortOrder: -1
            ),
            SplitTransactionRecord(
                id: "child-2",
                amount: -4_000,
                category: nil,
                payee: nil,
                notes: "override",
                sortOrder: -2
            ),
        ]
        let result = SplitTransactionFamilyOps.updateTransaction([baseParent], transaction: conversion)
        let observed = SplitTransactionFamilyOps.family(from: result.data)
        #expect(observed.rows == expected.result.rows)
        #expect(observed.family == expected.result.familyValue)
        #expect(observed.family?.parent.payee == "coffee")
        #expect(observed.family?.parent.error == nil)
    }

    @Test func parentPayeeUpdateMatchesOracleOverlay() throws {
        let fixture = try familyFixture()
        let expected = try decodeObject(
            ResultExpected.self,
            fixture.caseData("parent-payee-update-preserves-child-override")
        )
        let exactParent = SplitTransactionFamilyOps.recalculateSplit(
            parent(isParent: true, payee: nil, children: [
                child("child-1", amount: -6_000, sortOrder: -1),
                child("child-2", amount: -4_000, sortOrder: -2),
            ])
        )
        let source = [
            exactParent.selected(),
            SplitTransactionFamilyOps.makeChild(
                parent: exactParent,
                data: SplitTransactionPatch(
                    id: "child-1",
                    amount: -6_000,
                    payee: .value("coffee"),
                    notes: .value("inherited payee"),
                    sortOrder: .value(-1)
                )
            ),
            SplitTransactionFamilyOps.makeChild(
                parent: exactParent,
                data: SplitTransactionPatch(
                    id: "child-2",
                    amount: -4_000,
                    payee: .value("market"),
                    notes: .value("override payee"),
                    sortOrder: .value(-2)
                )
            ),
        ]
        var overlay = exactParent
        overlay.payee = "tea"
        let result = SplitTransactionFamilyOps.updateTransaction(source, transaction: overlay)
        let observed = SplitTransactionFamilyOps.family(from: result.data)
        #expect(observed.rows == expected.result.rows)
        #expect(observed.family == expected.result.familyValue)
    }

    @Test func childDeleteRecalculatesParentError() throws {
        let fixture = try familyFixture()
        let expected = try decodeObject(
            ResultExpected.self,
            fixture.caseData("child-delete-recalculates-parent-error")
        )
        let exactParent = SplitTransactionFamilyOps.recalculateSplit(
            parent(isParent: true, payee: nil, children: [
                child("child-1", amount: -6_000, sortOrder: -1),
                child("child-2", amount: -4_000, sortOrder: -2),
            ])
        )
        let source = [
            exactParent.selected(),
            SplitTransactionFamilyOps.makeChild(
                parent: exactParent,
                data: SplitTransactionPatch(
                    id: "child-1",
                    amount: -6_000,
                    payee: .value("coffee"),
                    notes: .value("inherited payee"),
                    sortOrder: .value(-1)
                )
            ),
            SplitTransactionFamilyOps.makeChild(
                parent: exactParent,
                data: SplitTransactionPatch(
                    id: "child-2",
                    amount: -4_000,
                    payee: .value("market"),
                    notes: .value("override payee"),
                    sortOrder: .value(-2)
                )
            ),
        ]
        let result = SplitTransactionFamilyOps.deleteTransaction(source, id: "child-1")
        let observed = SplitTransactionFamilyOps.family(from: result.data)
        #expect(observed.rows == expected.result.rows)
        #expect(observed.family == expected.result.familyValue)
        #expect(observed.family?.parent.error?.difference == -6_000)
        #expect(Set(result.diff.deleted) == ["child-1"])
    }

    @Test func finalChildDeleteCollapsesParent() throws {
        let fixture = try familyFixture()
        let expected = try decodeObject(
            ResultExpected.self,
            fixture.caseData("final-child-delete-collapses-parent")
        )
        let exactParent = SplitTransactionFamilyOps.recalculateSplit(
            parent(isParent: true, payee: nil, children: [
                child("child-1", amount: -6_000, sortOrder: -1),
                child("child-2", amount: -4_000, sortOrder: -2),
            ])
        )
        let source = [
            exactParent.selected(),
            SplitTransactionFamilyOps.makeChild(
                parent: exactParent,
                data: SplitTransactionPatch(
                    id: "only-child",
                    amount: -10_000,
                    category: .value("utilities"),
                    sortOrder: .value(-1)
                )
            ),
        ]
        let result = SplitTransactionFamilyOps.deleteTransaction(source, id: "only-child")
        let observed = SplitTransactionFamilyOps.family(from: result.data)
        #expect(observed.rows == expected.result.rows)
        #expect(observed.family == expected.result.familyValue)
        #expect(observed.family?.parent.isParent == false)
        #expect(observed.family?.parent.error == nil)
        #expect(observed.family?.children.isEmpty == true)
    }

    @Test func detachChildPreservesNonChildFields() throws {
        let fixture = try familyFixture()
        let expected = try JSONSerialization.jsonObject(with: fixture.caseData("detach-child-preserves-nonchild-fields")) as? [String: Any]
        let exactParent = SplitTransactionFamilyOps.recalculateSplit(
            parent(isParent: true, payee: nil, children: [
                child("child-1", amount: -6_000, sortOrder: -1),
                child("child-2", amount: -4_000, sortOrder: -2),
            ])
        )
        let source = [
            exactParent,
            SplitTransactionFamilyOps.makeChild(
                parent: exactParent,
                data: SplitTransactionPatch(
                    id: "child-1",
                    amount: -6_000,
                    payee: .value("coffee"),
                    notes: .value("inherited payee"),
                    sortOrder: .value(-1)
                )
            ),
            SplitTransactionFamilyOps.makeChild(
                parent: exactParent,
                data: SplitTransactionPatch(
                    id: "child-2",
                    amount: -4_000,
                    payee: .value("market"),
                    notes: .value("override payee"),
                    sortOrder: .value(-2)
                )
            ),
        ]
        let result = SplitTransactionFamilyOps.makeAsNonChildTransactions(
            childTransactionsToUpdate: [source[1]],
            transactions: source
        )
        let updated = expected?["updated"] as? [[String: Any]]
        let deleted = expected?["deleted"] as? [[String: Any]]
        #expect(result.updated.map(\.id) == updated?.compactMap { $0["id"] as? String })
        #expect(result.deleted.map(\.id) == deleted?.compactMap { $0["id"] as? String })
        #expect(result.updated.map(\.isChild) == [false, false])
        #expect(result.updated.map(\.parentID) == [nil, nil])
        #expect(result.updated.map(\.payee) == ["coffee", "market"])
        #expect(result.updated.map(\.startingBalance) == [nil, nil])
        #expect(result.deleted.first?.isParent == true)
    }

    @Test func parentZeroSplitHasNoErrorAndMismatchedZeroChildIsRepresentable() {
        let zeroParent = SplitTransactionFamilyOps.splitTransaction(
            [SplitTransactionRecord(id: "zero", amount: 0, account: "checking", date: "2026-08-15")],
            id: "zero"
        )
        #expect(zeroParent.newTransaction?.error == nil)
        let mismatchedZero = SplitTransactionFamilyOps.recalculateSplit(
            SplitTransactionRecord(
                id: "zero",
                amount: 0,
                isParent: true,
                subtransactions: [
                    SplitTransactionRecord(id: "child", amount: 1, isChild: true, parentID: "zero"),
                ]
            )
        )
        #expect(mismatchedZero.error?.difference == -1)
    }

    private var baseParent: SplitTransactionRecord {
        SplitTransactionRecord(
            id: "parent-1",
            amount: -10_000,
            account: "checking",
            date: "2026-08-15",
            category: "groceries",
            payee: "coffee",
            notes: "parent note",
            cleared: true,
            reconciled: false,
            startingBalance: false,
            sortOrder: 100
        )
    }

    private func parent(
        isParent: Bool,
        payee: String?,
        children: [SplitTransactionRecord]
    ) -> SplitTransactionRecord {
        var record = baseParent
        record.isParent = isParent
        record.payee = payee
        record.subtransactions = children
        return record
    }

    private func child(_ id: String, amount: Int, sortOrder: Double) -> SplitTransactionRecord {
        SplitTransactionFamilyOps.makeChild(
            parent: baseParent,
            data: SplitTransactionPatch(id: id, amount: amount, sortOrder: .value(sortOrder))
        )
    }

    private func selectedFamily(_ record: SplitTransactionRecord) -> SplitTransactionFamily {
        SplitTransactionFamily(
            parent: record.selected(),
            children: record.subtransactions.map { $0.selected() }
        )
    }

    private func familyFixture() throws -> FamilyFixture {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "ActualistTests/Fixtures/ActualCore26_8_1/Splits/family-transformations.json")
        let data = try Data(contentsOf: url)
        return try FamilyFixture(data: data)
    }

    private func decodeRecords(_ data: Data) throws -> [SplitTransactionRecord] {
        try JSONDecoder().decode([SplitTransactionRecord].self, from: data)
    }

    private func decodeObject<Value: Decodable>(_ type: Value.Type, _ data: Data) throws -> Value {
        try JSONDecoder().decode(type, from: data)
    }
}

private struct FamilyFixture {
    let cases: [String: Data]

    init(data: Data) throws {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let rawCases = object?["cases"] as? [[String: Any]] ?? []
        var decoded: [String: Data] = [:]
        for item in rawCases {
            guard let id = item["id"] as? String else { continue }
            decoded[id] = try JSONSerialization.data(withJSONObject: item["expected"] as Any)
        }
        cases = decoded
    }

    func caseData(_ id: String) throws -> Data {
        guard let data = cases[id] else {
            throw NSError(
                domain: "SplitTransactionFamilyTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "missing family fixture \(id)"]
            )
        }
        return data
    }
}

private struct RecalculateExpected: Decodable {
    let exact: DecodedFamily
    let mismatch: DecodedFamily
    let mixedSign: DecodedFamily
}

private struct RowsFamilyExpected: Decodable {
    let rows: [SplitTransactionRecord]
    let family: DecodedFamily

    var familyValue: SplitTransactionFamily { family.value }
}

private struct ResultExpected: Decodable {
    let result: RowsFamilyExpected
}

private struct DecodedFamily: Decodable {
    let parent: SplitTransactionRecord
    let children: [SplitTransactionRecord]

    var value: SplitTransactionFamily {
        SplitTransactionFamily(parent: parent, children: children)
    }
}
