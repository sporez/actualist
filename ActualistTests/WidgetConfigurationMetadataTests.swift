import Foundation
import Testing
@testable import Actualist

struct WidgetConfigurationMetadataTests {
    @Test(arguments: ["CategoryBalanceConfigurationIntent", "AccountBalancesConfigurationIntent"])
    func balanceSelectionsSurviveResizing(intent: String) throws {
        let parameter = intent == "CategoryBalanceConfigurationIntent" ? "categories" : "accounts"
        let sizes = try collectionSizes(intent: intent, parameter: parameter)
        let allFamilies = try #require(sizes["*"] as? [String: Int])
        #expect(allFamilies["min"] == 1)
        #expect(allFamilies["max"] == WidgetCategoryBalanceCapacity.extraLarge)
    }

    @Test func quickActionsSelectionRequiresExactlyFourEntries() throws {
        let sizes = try collectionSizes(intent: "QuickActionsConfigurationIntent", parameter: "actions")
        let medium = try #require(sizes["systemMedium"] as? [String: Int])
        #expect(medium["min"] == WidgetQuickActions.capacity)
        #expect(medium["max"] == WidgetQuickActions.capacity)
    }

    private func collectionSizes(intent: String, parameter name: String) throws -> [String: Any] {
        let plugInsURL = try #require(Bundle.main.builtInPlugInsURL)
        let plugInURLs = try FileManager.default.contentsOfDirectory(
            at: plugInsURL,
            includingPropertiesForKeys: nil
        )
        let widgetURL = try #require(plugInURLs.first { url in
            Bundle(url: url)?.bundleIdentifier == "com.sporez.actualist.widgets"
        })
        let metadataURL = widgetURL
            .appendingPathComponent("Metadata.appintents")
            .appendingPathComponent("extract.actionsdata")
        let payload = try JSONSerialization.jsonObject(
            with: Data(contentsOf: metadataURL)
        ) as? [String: Any]
        let actions = try #require(payload?["actions"] as? [String: Any])
        let action = try #require(
            actions[intent] as? [String: Any]
        )
        let parameters = try #require(action["parameters"] as? [[String: Any]])
        let parameter = try #require(parameters.first { parameter in
            parameter["name"] as? String == name
        })
        let metadata = try #require(parameter["typeSpecificMetadata"] as? [Any])
        let collectionMetadata = try #require(
            metadata.compactMap { $0 as? [String: Any] }.first
        )
        let collectionSizes = try #require(
            collectionMetadata["collectionSizes"] as? [String: Any]
        )
        return try #require(collectionSizes["sizes"] as? [String: Any])
    }
}
