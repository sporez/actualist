import Foundation
import Testing
@testable import Actualist

struct BankSyncFieldMappingTests {
    private func transaction(
        amount: String = "-10.00",
        payeeName: String = "Coffee Shop",
        notes: String? = "provider #memo",
        dayID: String = "20240301",
        raw: [String: SimpleFINRawValue] = [:]
    ) -> SimpleFINRemoteTransaction {
        let seconds = Int64(BankSyncAmounts.date(fromDayID: dayID)!.timeIntervalSince1970)
        return SimpleFINRemoteTransaction(
            id: "t1",
            dateUnixSeconds: seconds,
            amount: amount,
            currency: "USD",
            payeeName: payeeName,
            notes: notes,
            booked: true,
            accountID: "acct",
            rawFields: SimpleFINRawFields(raw)
        )
    }

    @Test func missingJSONUsesDefaultMappingAndEscapesImportedNotes() {
        let resolved = BankSyncFieldMapping.resolve(
            transaction: transaction(),
            amountMinorUnits: -1_000,
            mappings: .defaults,
            importNotes: true
        )
        #expect(resolved?.payeeName == "Coffee Shop")
        #expect(resolved?.notes == "provider ##memo")
        #expect(
            resolved?.dateUnixSeconds.map(BankSyncAmounts.dayID(fromUnixSeconds:)) == "20240301"
        )
    }

    @Test func notesPreferenceFalseClearsProviderNotesBeforeRules() {
        let resolved = BankSyncFieldMapping.resolve(
            transaction: transaction(),
            amountMinorUnits: -1_000,
            mappings: .defaults,
            importNotes: false
        )
        #expect(resolved?.notes == nil)
        #expect(resolved?.payeeName == "Coffee Shop")
    }

    @Test func paymentMappingChangesPayeeSourceIndependentlyOfDeposit() throws {
        let mappings = try BankSyncFieldMapping.parse("""
            {"payment":{"date":"date","payee":"altPayee","notes":"notes"},\
            "deposit":{"date":"date","payee":"depositPayee","notes":"notes"}}
            """)
        let payment = BankSyncFieldMapping.resolve(
            transaction: transaction(raw: ["altPayee": .string("Mapped Payee")]),
            amountMinorUnits: -1_000,
            mappings: mappings,
            importNotes: true
        )
        let deposit = BankSyncFieldMapping.resolve(
            transaction: transaction(
                amount: "20.00",
                raw: ["depositPayee": .string("Deposit Payee")]
            ),
            amountMinorUnits: 2_000,
            mappings: mappings,
            importNotes: true
        )
        #expect(payment?.payeeName == "Mapped Payee")
        #expect(deposit?.payeeName == "Deposit Payee")
    }

    @Test func mappingDateChangesNormalizedMatchDate() throws {
        let mappings = try BankSyncFieldMapping.parse("""
            {"payment":{"date":"altDate","payee":"payeeName","notes":"notes"},\
            "deposit":{"date":"date","payee":"payeeName","notes":"notes"}}
            """)
        let resolved = BankSyncFieldMapping.resolve(
            transaction: transaction(raw: ["altDate": .string("2024-01-15")]),
            amountMinorUnits: -1_000,
            mappings: mappings,
            importNotes: true
        )
        #expect(
            resolved?.dateUnixSeconds.map(BankSyncAmounts.dayID(fromUnixSeconds:)) == "20240115"
        )
    }

    @Test func mappedNotesHonorImportNotesPreference() throws {
        let mappings = try BankSyncFieldMapping.parse("""
            {"payment":{"date":"date","payee":"payeeName","notes":"altNotes"},\
            "deposit":{"date":"date","payee":"payeeName","notes":"notes"}}
            """)
        let imported = BankSyncFieldMapping.resolve(
            transaction: transaction(raw: ["altNotes": .string("mapped #note")]),
            amountMinorUnits: -1_000,
            mappings: mappings,
            importNotes: true
        )
        let suppressed = BankSyncFieldMapping.resolve(
            transaction: transaction(raw: ["altNotes": .string("mapped #note")]),
            amountMinorUnits: -1_000,
            mappings: mappings,
            importNotes: false
        )
        #expect(imported?.notes == "mapped ##note")
        #expect(suppressed?.notes == nil)
    }

    @Test func missingMappedPayeeKeyFallsBackToCanonicalPayee() throws {
        let mappings = try BankSyncFieldMapping.parse("""
            {"payment":{"date":"date","payee":"missing","notes":"notes"},\
            "deposit":{"date":"date","payee":"payeeName","notes":"notes"}}
            """)
        let resolved = BankSyncFieldMapping.resolve(
            transaction: transaction(),
            amountMinorUnits: -1_000,
            mappings: mappings,
            importNotes: true
        )
        #expect(resolved?.payeeName == "Coffee Shop")
    }

    @Test func missingMappedNotesKeyDoesNotFallBackToCanonicalNotes() throws {
        let mappings = try BankSyncFieldMapping.parse("""
            {"payment":{"date":"date","payee":"payeeName","notes":"missing"},\
            "deposit":{"date":"date","payee":"payeeName","notes":"notes"}}
            """)
        let resolved = BankSyncFieldMapping.resolve(
            transaction: transaction(),
            amountMinorUnits: -1_000,
            mappings: mappings,
            importNotes: true
        )
        #expect(resolved?.notes == nil)
    }

    @Test func missingPaymentSideFailsClosed() throws {
        let mappings = try BankSyncFieldMapping.parse("""
            {"deposit":{"date":"date","payee":"payeeName","notes":"notes"}}
            """)
        #expect(
            BankSyncFieldMapping.resolve(
                transaction: transaction(),
                amountMinorUnits: -1_000,
                mappings: mappings,
                importNotes: true
            ) == nil
        )
    }

    @Test(arguments: [
        "{",
        "[]",
        "null",
        "\"x\"",
        "{\"payment\":\"nope\"}",
        "{\"payment\":{\"date\":1}}"
    ])
    func malformedJSONThrows(_ json: String) {
        #expect(throws: BankSyncFieldMapping.ParseError.invalid) {
            _ = try BankSyncFieldMapping.parse(json)
        }
    }
}
