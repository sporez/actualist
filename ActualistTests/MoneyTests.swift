import Foundation
import Testing
@testable import Actualist

struct MoneyTests {
    @Test func formatsActualMinorUnitsAsCurrency() {
        #expect(123456.actualMoney.formatted().contains("1,234.56"))
    }

    @Test func serverURLAddsVersionPathWhenMissing() {
        #expect(ServerURLNormalizer.normalize("http://localhost:5007") == "http://localhost:5007/v1")
        #expect(ServerURLNormalizer.normalize("localhost:5007") == "http://localhost:5007/v1")
        #expect(ServerURLNormalizer.normalize("http://localhost:5007/v1") == "http://localhost:5007/v1")
    }

    @Test func budgetSyncIDPrefersGroupID() throws {
        let json = """
        {
          "id": "friendly-name",
          "cloudFileId": "d76ea46f-a902-48e6-a72a-a9be53de7d96",
          "groupId": "9e5a0d5b-7b6b-40d2-a752-1f7da0516288",
          "name": "Personal"
        }
        """.data(using: .utf8)!

        let budget = try JSONDecoder().decode(ActualBudget.self, from: json)
        #expect(budget.syncID == "9e5a0d5b-7b6b-40d2-a752-1f7da0516288")
    }
}
