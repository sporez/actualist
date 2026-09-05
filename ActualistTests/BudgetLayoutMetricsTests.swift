import CoreGraphics
import Foundation
import Testing
@testable import Actualist

struct BudgetLayoutMetricsTests {
    @Test func autoUsesMeasuredBudgetDetailWidthWithoutSubtractingSidebarAgain() {
        let metrics = BudgetLayoutMetrics.resolve(
            BudgetLayoutInputs(rootWidth: 1_400, budgetDetailWidth: 960, sidebarWidth: 300)
        )

        #expect(metrics.presentationMode == .multiMonth)
        #expect(metrics.visibleMonthCount == 3)
    }

    @Test func fixedPreferenceClampsRenderedCountButRemainsFive() {
        let preference = MonthDisplayPreference.fixed(5)
        let metrics = BudgetLayoutMetrics.resolve(
            BudgetLayoutInputs(rootWidth: 1_100, budgetDetailWidth: 760, preference: preference)
        )

        #expect(preference == .fixed(5))
        #expect(metrics.visibleMonthCount == 2)
    }

    @Test func fixedPreferenceRestoresWhenCapacityReturns() {
        let preference = MonthDisplayPreference.fixed(5)
        let metrics = BudgetLayoutMetrics.resolve(
            BudgetLayoutInputs(rootWidth: 1_700, budgetDetailWidth: 1_400, preference: preference)
        )

        #expect(metrics.visibleMonthCount == 5)
    }

    @Test func fixedOneMonthCapsScanWidthWithoutChangingAutoCapacity() {
        let inputs = BudgetLayoutInputs(
            rootWidth: 1_500,
            budgetDetailWidth: 1_200,
            preference: .fixed(1)
        )
        let fixed = BudgetLayoutMetrics.resolve(inputs)
        let automatic = BudgetLayoutMetrics.resolve(
            BudgetLayoutInputs(rootWidth: inputs.rootWidth, budgetDetailWidth: inputs.budgetDetailWidth)
        )
        let availableWidth = inputs.budgetDetailWidth! - inputs.horizontalMargins

        #expect(fixed.presentationMode == .splitSingleMonth)
        #expect(fixed.tableWidth <= BudgetLayoutMetrics.maximumSingleMonthTableWidth)
        #expect(fixed.tableWidth <= availableWidth)
        #expect(automatic.visibleMonthCount >= 3)
        #expect(automatic.tableWidth <= availableWidth)
        #expect(automatic.tableWidth > fixed.tableWidth)
    }

    @Test func dynamicTypeIncreasesMinimumWidthsAndCategoryWidth() {
        let regular = BudgetLayoutMetrics.resolve(
            BudgetLayoutInputs(rootWidth: 1_400, budgetDetailWidth: 1_100)
        )
        let accessibility = BudgetLayoutMetrics.resolve(
            BudgetLayoutInputs(rootWidth: 1_400, budgetDetailWidth: 1_100, dynamicTypeScale: 2)
        )

        #expect(accessibility.categoryColumnWidth > regular.categoryColumnWidth)
        #expect(accessibility.visibleMonthCount < regular.visibleMonthCount)
    }

    @Test func invalidGeometryFallsBackSafely() {
        let metrics = BudgetLayoutMetrics.resolve(
            BudgetLayoutInputs(rootWidth: .nan, budgetDetailWidth: .infinity, inspectorWidth: -.infinity)
        )

        #expect(metrics.presentationMode == .compact)
        #expect(metrics.visibleMonthCount == 1)
        #expect(metrics.categoryColumnWidth.isFinite)
        #expect(metrics.monthColumnWidth.isFinite)
    }

    @Test func narrowRootRemainsCompactAndSingleMonthHasInspectorCapacity() {
        let compact = BudgetLayoutMetrics.resolve(BudgetLayoutInputs(rootWidth: 699, budgetDetailWidth: 900))
        let single = BudgetLayoutMetrics.resolve(BudgetLayoutInputs(rootWidth: 900, budgetDetailWidth: 700))

        #expect(compact.presentationMode == .compact)
        #expect(single.presentationMode == .splitSingleMonth)
        #expect(single.inspectorAvailable)
    }

    @Test func narrowInspectorFallbackFitsMeasuredDetailWidth() {
        let metrics = BudgetLayoutMetrics.resolve(
            BudgetLayoutInputs(rootWidth: 1_000, budgetDetailWidth: 300, inspectorWidth: 400)
        )
        #expect(metrics.presentationMode == .splitSingleMonth)
        #expect(metrics.categoryColumnWidth + metrics.monthColumnWidth <= 268)
    }

    @Test func invalidStoredPreferenceDecodesAsAutomatic() throws {
        let value = try JSONDecoder().decode(MonthDisplayPreference.self, from: Data("\"99\"".utf8))
        #expect(value == .automatic)
    }

    @Test func everyMonthPreferenceRoundTripsThroughCodable() throws {
        for preference in MonthDisplayPreference.allCases {
            let data = try JSONEncoder().encode(preference)
            let decoded = try JSONDecoder().decode(MonthDisplayPreference.self, from: data)
            #expect(decoded == preference)
        }
    }

    @Test func settingsMissingMonthPreferenceUsesAutomatic() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(settings.monthDisplayPreference == .automatic)
    }
}

extension BudgetLayoutMetricsTests {
    @Test func everyDensityFitsAndRetainsFixedPreference() {
        for density in ActualistDisplayDensity.allCases {
            for width in [520.0, 760, 1100, 1400] {
                for inspector in [0.0, 380] {
                    let input = BudgetLayoutInputs(rootWidth: width + 272, inspectorWidth: inspector, preference: .fixed(5), density: density)
                    let result = BudgetLayoutMetrics.resolve(input)
                    #expect(result.visibleMonthCount >= 1 && result.visibleMonthCount <= 5)
                    #expect(result.tableWidth <= max(width - inspector, 0) + 0.001)
                    #expect(result.monthColumnWidth >= 0)
                    #expect(input.preference == .fixed(5))
                }
            }
        }
    }

    @Test func densityChangesRowsAndReducesCapacityBeforeClipping() {
        let densities = ActualistDisplayDensity.allCases
        let heights = densities.map { BudgetGridDensityMetrics(density: $0).rowHeight }
        #expect(zip(heights, heights.dropFirst()).allSatisfy { $0 < $1 })
        let capacities = densities.map {
            BudgetLayoutMetrics.resolve(.init(rootWidth: 1400, budgetDetailWidth: 1160, density: $0)).visibleMonthCount
        }
        #expect(capacities.first! > capacities.last!)
        #expect(zip(capacities, capacities.dropFirst()).allSatisfy { $0 >= $1 })
        for density in densities {
            let regular = BudgetLayoutMetrics.resolve(.init(rootWidth: 2000, budgetDetailWidth: 1500, density: density))
            let largeType = BudgetLayoutMetrics.resolve(.init(rootWidth: 2000, budgetDetailWidth: 1500, dynamicTypeScale: 2, density: density))
            #expect(largeType.visibleMonthCount < regular.visibleMonthCount)
            #expect(largeType.categoryColumnWidth > regular.categoryColumnWidth)
        }
    }
}
