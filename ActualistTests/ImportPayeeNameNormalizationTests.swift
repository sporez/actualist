import Testing
@testable import Actualist

/// Expected values come from running upstream's `title()` (loot-core
/// `server/accounts/title/index.ts`, pinned Actual v26.9.0) on each input.
struct ImportPayeeNameNormalizationTests {
    @Test(arguments: [
        ("STARBUCKS COFFEE #123", "Starbucks Coffee #123"),
        ("amazon.com", "Amazon.Com"),
        ("the home depot", "The Home Depot"),
        ("SQ *JOE'S PIZZA", "Sq *Joe's Pizza"),
        ("pay to the order of", "Pay to the Order of"),
        ("github inc", "GitHub Inc"),
        ("NEXT.JS hosting", "Next.js Hosting"),
        ("(paren) shop", "(paren) shop"),
        ("o'reilly auto parts", "O'reilly Auto Parts"),
        ("7-eleven", "7-Eleven"),
        ("AT&T wireless", "At&T Wireless"),
        ("dns api http", "DNS API HTTP"),
        ("ÉCOLE de paris", "École De Paris"),
        ("  lead", "  Lead"),
        (" a of the", " A of the"),
        ("wal-mart: the store; of x", "Wal-Mart: The Store; Of X"),
        ("Bob's    Burgers", "Bob's    Burgers"),
        ("café olé", "Café Olé"),
    ])
    func titleCaseMatchesUpstream(input: String, expected: String) {
        #expect(ImportPayeeNameNormalization.titleCase.normalize(input) == expected)
    }

    @Test func originalLeavesTheNameAlone() {
        #expect(ImportPayeeNameNormalization.original.normalize("STARBUCKS COFFEE") == "STARBUCKS COFFEE")
    }

    @Test func profilesCarryTheirUpstreamDefaults() {
        #expect(ImportReconcileOptions.csv == ImportReconcileOptions(
            isBankSyncAccount: false,
            strictIdChecking: true,
            reimportDeleted: true,
            defaultCleared: true,
            payeeNameNormalization: .titleCase
        ))
        #expect(ImportReconcileOptions.bankSync.isBankSyncAccount)
        #expect(!ImportReconcileOptions.bankSync.strictIdChecking)
        #expect(ImportReconcileOptions.bankSync.reimportDeleted == nil)
        #expect(ImportReconcileOptions.bankSync.payeeNameNormalization == .original)
    }
}
