import Foundation
import Testing
@testable import Actualist

/// Structural checks of the FileImport oracle fixture (`scripts/parity/file-import-oracle/`).
/// Actualist has no ports of the recorded Actual functions yet, so nothing is replayed;
/// each phase of the file-import plan adds its function's replay here. The tests only
/// read the fixture through `OracleJSONFileCache` and build no database, so they do not
/// take `OracleReplayGate`; a replay that builds one must.
struct FileImportOracleReplayTests {
    private static let domain = "FileImport"
    private static let fileName = "file-import-contract.json"
    /// The functions registered in the generator's `registry.mjs`.
    private static let registeredFunctions = [
        "looselyParseAmount", "amountToInteger", "getInitialMappings", "getInitialDateFormat",
    ]

    private func header() throws -> [String: Any] {
        let url = try ParityOraclePin.fixtureURL(Self.domain).appending(path: Self.fileName)
        return try OracleJSON.object(OracleJSONFileCache.jsonObject(at: url), Self.fileName)
    }

    @Test
    func fixtureMatchesThePinnedOracle() throws {
        let pin = try ParityOraclePin.load()
        let oracle = try OracleJSON.object(try header()["oracle"], "oracle")
        #expect(oracle["tag"] as? String == pin.tag)
        #expect(oracle["commit"] as? String == pin.commit)
        #expect(oracle["packageVersion"] as? String == pin.packageVersion)
    }

    @Test
    func fixtureIsSyntheticAndSeeded() throws {
        let header = try header()
        let synthetic = try OracleJSON.object(header["syntheticData"], "syntheticData")
        #expect(synthetic["only"] as? Bool == true)
        #expect(OracleJSON.int(header["seed"]) != nil)
    }

    @Test
    func everyRegisteredFunctionHasCases() throws {
        let cases = try OracleFixtureCases(domain: Self.domain, fileName: Self.fileName, outputKey: "output")
        let sections = try OracleJSON.object(try header()["functions"], "functions")
        #expect(Set(sections.keys) == Set(Self.registeredFunctions))
        var total = 0
        for name in Self.registeredFunctions {
            let section = try OracleJSON.object(sections[name], name)
            let recorded = OracleJSON.int(section["caseCount"]) ?? 0
            let ids = cases.ids.filter { $0.hasPrefix("\(name)/") }
            #expect(recorded > 0, "\(name) has no cases")
            #expect(ids.count == recorded, "\(name) records \(recorded) cases but the fixture holds \(ids.count)")
            total += ids.count
        }
        #expect(total == cases.ids.count, "a fixture case belongs to no registered function")
    }
}
