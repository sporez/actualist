import Foundation
import Testing
@testable import Actualist

struct WidgetConfigurationMetadataTests {
    @Test func categorySelectionLimitsMatchWidgetLayoutCapacities() throws {
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
            actions["CategoryBalanceConfigurationIntent"] as? [String: Any]
        )
        let parameters = try #require(action["parameters"] as? [[String: Any]])
        let categories = try #require(parameters.first { parameter in
            parameter["name"] as? String == "categories"
        })
        let metadata = try #require(categories["typeSpecificMetadata"] as? [Any])
        let collectionMetadata = try #require(
            metadata.compactMap { $0 as? [String: Any] }.first
        )
        let collectionSizes = try #require(
            collectionMetadata["collectionSizes"] as? [String: Any]
        )
        let sizes = try #require(collectionSizes["sizes"] as? [String: Any])
        let medium = try #require(sizes["systemMedium"] as? [String: Int])
        let large = try #require(sizes["systemLarge"] as? [String: Int])

        #expect(medium["min"] == 1)
        #expect(medium["max"] == WidgetCategoryBalanceCapacity.medium)
        #expect(large["min"] == 1)
        #expect(large["max"] == WidgetCategoryBalanceCapacity.large)
    }
}
