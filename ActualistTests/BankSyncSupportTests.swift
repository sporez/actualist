import Foundation
import GRDB
import Testing
@testable import Actualist

/// Phase 1 tests for the currency-safe bank-sync amount helper and the
/// open-time bank-sync schema backfill.
struct BankSyncSupportTests {
    private let usd = BudgetCurrency.usd
    private let jpy = BudgetCurrency.jpy
    private let three = BudgetCurrency(code: "XXX", decimalPlaces: 3, hideFraction: false)

    // MARK: - Decimal strings → minor units

    @Test func twoDecimalCurrency() {
        #expect(BankSyncAmounts.minorUnits(fromDecimal: "12.34", currency: usd) == 1234)
        #expect(BankSyncAmounts.minorUnits(fromDecimal: "-12.34", currency: usd) == -1234)
        #expect(BankSyncAmounts.minorUnits(fromDecimal: "+0.05", currency: usd) == 5)
        #expect(BankSyncAmounts.minorUnits(fromDecimal: "0", currency: usd) == 0)
        #expect(BankSyncAmounts.minorUnits(fromDecimal: "1234.00", currency: usd) == 123_400)
        #expect(BankSyncAmounts.minorUnits(fromDecimal: " 88.10 ", currency: usd) == 8810)
    }

    @Test func zeroDecimalCurrency() {
        #expect(BankSyncAmounts.minorUnits(fromDecimal: "1234.56", currency: jpy) == 1235)
        #expect(BankSyncAmounts.minorUnits(fromDecimal: "1234", currency: jpy) == 1234)
        #expect(BankSyncAmounts.minorUnits(fromDecimal: "-0.4", currency: jpy) == 0)
    }

    @Test func threeDecimalCurrency() {
        #expect(BankSyncAmounts.minorUnits(fromDecimal: "1.234", currency: three) == 1234)
        #expect(BankSyncAmounts.minorUnits(fromDecimal: "-1.235", currency: three) == -1235)
    }

    @Test func junkIsRejectedNotGuessed() {
        #expect(BankSyncAmounts.minorUnits(fromDecimal: nil, currency: usd) == nil)
        #expect(BankSyncAmounts.minorUnits(fromDecimal: "", currency: usd) == nil)
        #expect(BankSyncAmounts.minorUnits(fromDecimal: "  ", currency: usd) == nil)
        #expect(BankSyncAmounts.minorUnits(fromDecimal: "12abc", currency: usd) == nil)
        #expect(BankSyncAmounts.minorUnits(fromDecimal: "1.2.3", currency: usd) == nil)
        #expect(BankSyncAmounts.minorUnits(fromDecimal: "1,234.56", currency: usd) == nil)
        #expect(BankSyncAmounts.minorUnits(fromDecimal: "1e5", currency: usd) == nil)
        #expect(BankSyncAmounts.minorUnits(fromDecimal: "-", currency: usd) == nil)
        #expect(BankSyncAmounts.minorUnits(fromDecimal: ".50", currency: usd) == nil)
    }

    // MARK: - UTC day from UNIX seconds

    @Test func utcDayFromUnixSeconds() {
        #expect(BankSyncAmounts.dayID(fromUnixSeconds: 1_709_253_000) == "20240301")
        #expect(BankSyncAmounts.dayID(fromUnixSeconds: 0) == "19700101")
    }

    // MARK: - 90-day lookback

    @Test func lookbackNeverStartsEarlierThan89DaysAgo() {
        let now = BankSyncAmounts.date(fromDayID: "20260830")!
        #expect(BankSyncAmounts.lookbackStartDate(
            oldestLiveTransactionDayID: "20200101",
            now: now
        ) == "2026-06-02")
    }

    @Test func lookbackUsesNewerOldestTransaction() {
        let now = BankSyncAmounts.date(fromDayID: "20260830")!
        #expect(BankSyncAmounts.lookbackStartDate(
            oldestLiveTransactionDayID: "20260801",
            now: now
        ) == "2026-08-01")
    }

    // MARK: - Schema backfill + find-or-create banks

    @Test func backfillCreatesBanksTableAndLinkColumns() async throws {
        let (_, path, cleanup) = try makeLegacyBudgetDatabase()
        defer { cleanup() }
        let columns = try columnsOfTable("accounts", path: path)
        for column in ["account_id", "account_sync_source", "bank", "balance_current",
                       "balance_available", "balance_limit", "last_sync"] {
            #expect(columns.contains(column), "missing \(column)")
        }
        let banksColumns = try columnsOfTable("banks", path: path)
        for column in ["id", "bank_id", "name"] {
            #expect(banksColumns.contains(column), "missing banks.\(column)")
        }
    }

    @Test func sameBankIDSameNameReusesBankRow() async throws {
        let (database, _, cleanup) = try makeLegacyBudgetDatabase()
        defer { cleanup() }
        let first = try await database.findOrCreateBank(
            bankID: "firstbank.example",
            name: "First Bank",
            makeID: { "banks_1" }
        )
        let second = try await database.findOrCreateBank(
            bankID: "firstbank.example",
            name: "First Bank",
            makeID: { "banks_2" }
        )
        #expect(first.id == "banks_1")
        #expect(second.id == "banks_1")
    }

    @Test func sameBankIDDifferentNameCreatesDistinctBankRow() async throws {
        let (database, _, cleanup) = try makeLegacyBudgetDatabase()
        defer { cleanup() }
        let first = try await database.findOrCreateBank(
            bankID: "firstbank.example",
            name: "First Bank",
            makeID: { "banks_1" }
        )
        let second = try await database.findOrCreateBank(
            bankID: "firstbank.example",
            name: "First Bank UK",
            makeID: { "banks_2" }
        )
        #expect(first.id != second.id)
        #expect(second.id == "banks_2")
    }

    @Test func sameBankIDNilNamePairsWithNilNameRow() async throws {
        let (database, _, cleanup) = try makeLegacyBudgetDatabase()
        defer { cleanup() }
        let first = try await database.findOrCreateBank(
            bankID: "org_9",
            name: nil,
            makeID: { "banks_1" }
        )
        let second = try await database.findOrCreateBank(
            bankID: "org_9",
            name: nil,
            makeID: { "banks_2" }
        )
        #expect(first.id == second.id)
    }

    // MARK: - Fixtures

    /// A budget with an `accounts` table but no banks table and no link
    /// columns, as an older import would look. The legacy schema is written
    /// before `BudgetDatabase` opens the file so the open-time backfill runs
    /// against it.
    private func columnsOfTable(_ table: String, path: URL) throws -> Set<String> {
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: path.path, configuration: configuration)
        defer { try? queue.close() }
        return try queue.read { db in
            Set(try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))")
                .compactMap { $0["name"] as String? })
        }
    }

    private func makeLegacyBudgetDatabase() throws -> (BudgetDatabase, URL, () -> Void) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("actualist-banksync-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("budget.sqlite")

        let legacyQueue = try DatabaseQueue(path: url.path)
        try legacyQueue.write { db in
            try db.execute(sql: "CREATE TABLE accounts (id TEXT PRIMARY KEY, name TEXT)")
            try db.execute(sql: "INSERT INTO accounts (id, name) VALUES ('acct_local', 'Checking')")
        }
        try legacyQueue.close()

        let database = try BudgetDatabase(databaseURL: url)
        return (database, url, { try? FileManager.default.removeItem(at: directory) })
    }
}

struct BankSyncSessionCacheTests {
    private let checking = SimpleFINRemoteAccount(
        accountID: "sfin-1",
        name: "Checking",
        balance: "1.00",
        currency: "USD",
        institution: nil,
        orgName: "Bank",
        orgDomain: nil,
        orgID: nil
    )

    @Test func remembersSimpleFINSupportPerServerURL() {
        var cache = BankSyncSessionCache()
        cache.rememberSimpleFINSupport(.configured, for: "https://a.example")
        cache.rememberSimpleFINSupport(.notConfigured, for: "https://b.example")
        #expect(cache.simpleFINSupport(for: "https://a.example") == .configured)
        #expect(cache.simpleFINSupport(for: "https://b.example") == .notConfigured)
        #expect(cache.simpleFINSupport(for: "https://c.example") == nil)
    }

    @Test func changingSimpleFINSupportClearsThatProvidersRemotes() {
        var cache = BankSyncSessionCache()
        cache.rememberSimpleFINSupport(.configured, for: "https://a.example")
        cache.rememberSimpleFINRemoteAccounts([checking], for: "https://a.example")
        cache.rememberSimpleFINSupport(.configured, for: "https://a.example")
        #expect(cache.simpleFINRemoteAccounts(for: "https://a.example")?.map(\.accountID) == ["sfin-1"])
        cache.rememberSimpleFINSupport(.notConfigured, for: "https://a.example")
        #expect(cache.simpleFINRemoteAccounts(for: "https://a.example") == nil)
    }

    @Test func clearDropsEveryProvider() {
        var cache = BankSyncSessionCache()
        cache.rememberSimpleFINSupport(.configured, for: "https://a.example")
        cache.rememberSimpleFINRemoteAccounts([checking], for: "https://a.example")
        cache.clear()
        #expect(cache.simpleFINSupport(for: "https://a.example") == nil)
        #expect(cache.simpleFINRemoteAccounts(for: "https://a.example") == nil)
    }
}
