import CoreGraphics
import Foundation
import Testing
@testable import Actualist

struct BudgetLayoutMetricsTests {
    @Test func sharedLayoutFitsThreeTwoValueMonths() {
        let metrics = BudgetLayoutMetrics.resolve(.init(rootWidth: 1400, budgetDetailWidth: 1100))
        #expect(metrics.visibleMonthCount == 3)
        #expect(metrics.monthColumnWidth >= BudgetLayoutMetrics.minimumMoneyColumnWidth * 2)
        #expect(metrics.tableWidth <= 1068)
    }

    @Test func pendingRangeChangeSizesTheMonthsActuallyRendered() {
        for density in ActualistDisplayDensity.allCases {
            for scale in [1.0, 1.45] {
                for width in [700.0, 960, 1100] {
                    let inputs = BudgetLayoutInputs(rootWidth: 2000, budgetDetailWidth: width,
                                                   dynamicTypeScale: scale, density: density)
                    for count in 1...5 {
                        let rendered = BudgetLayoutMetrics.resolve(inputs, renderedMonthCount: count)
                        #expect(rendered.visibleMonthCount == count)
                        #expect(rendered.tableWidth <= width - inputs.horizontalMargins + 0.001)
                        #expect(rendered.monthColumnWidth >= 0)
                    }
                    let target = BudgetLayoutMetrics.resolve(inputs)
                    #expect(BudgetLayoutMetrics.resolve(inputs, renderedMonthCount: target.visibleMonthCount) == target)
                }
            }
        }
    }

    @Test func sameCountGeometryFollowsWidthAndOverrideIsBounded() {
        let smaller = BudgetLayoutInputs(rootWidth: 1400, budgetDetailWidth: 980)
        let larger = BudgetLayoutInputs(rootWidth: 1400, budgetDetailWidth: 1000)
        let first = BudgetLayoutMetrics.resolve(smaller, renderedMonthCount: 3)
        let second = BudgetLayoutMetrics.resolve(larger, renderedMonthCount: 3)
        #expect(second.tableWidth - first.tableWidth == 20)
        #expect(second.monthColumnWidth > first.monthColumnWidth)
        #expect(BudgetLayoutMetrics.resolve(larger, renderedMonthCount: 99).visibleMonthCount == 5)
        #expect(BudgetLayoutMetrics.resolve(larger, renderedMonthCount: 0).visibleMonthCount == 1)
    }

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
        let single = BudgetLayoutMetrics.resolve(BudgetLayoutInputs(rootWidth: 900, budgetDetailWidth: 660))

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

    @Test func monthChoicesOfferOnlyWhatFits() {
        #expect(MonthDisplayPreference.choices(monthsThatFit: 1).isEmpty)
        #expect(MonthDisplayPreference.choices(monthsThatFit: 2) == [.automatic, .fixed(1), .fixed(2)])
        #expect(MonthDisplayPreference.choices(monthsThatFit: 5).count == 6)
        #expect(MonthDisplayPreference.choices(monthsThatFit: 99).count == 6)
    }

    @Test func displayedChoiceMatchesTheScreenWithoutChangingTheSavedCeiling() {
        let saved = MonthDisplayPreference.fixed(3)

        #expect(saved.displayed(monthsThatFit: 2) == .fixed(2))
        #expect(saved.displayed(monthsThatFit: 5) == .fixed(3))
        #expect(MonthDisplayPreference.automatic.displayed(monthsThatFit: 2) == .automatic)
        #expect(saved.resolvedCount == 3)
    }

    @Test func displayedChoiceIsAlwaysOffered() {
        for fit in 2...5 {
            let choices = MonthDisplayPreference.choices(monthsThatFit: fit)
            for preference in MonthDisplayPreference.allCases {
                #expect(choices.contains(preference.displayed(monthsThatFit: fit)))
            }
        }
    }

    @Test func monthsThatFitIgnoresTheChosenCount() {
        let inputs = BudgetLayoutInputs(rootWidth: 1_500, budgetDetailWidth: 1_200, preference: .fixed(1))

        #expect(BudgetLayoutMetrics.resolve(inputs).visibleMonthCount == 1)
        #expect(BudgetLayoutMetrics.monthsThatFit(inputs) >= 3)
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
    private static let defaultTextScale: CGFloat = 1.1
    private static let preferredCategoryWidth = BudgetLayoutMetrics.preferredCategoryColumnWidth * defaultTextScale
    private static let categoryFloor = BudgetLayoutMetrics.compressedCategoryColumnWidth * defaultTextScale

    private func portraitMetrics(detailWidth: CGFloat, preference: MonthDisplayPreference = .automatic) -> BudgetLayoutMetrics {
        BudgetLayoutMetrics.resolve(BudgetLayoutInputs(
            rootWidth: 1_032,
            budgetDetailWidth: detailWidth,
            dynamicTypeScale: Self.defaultTextScale,
            preference: preference
        ))
    }

    @Test func categoryColumnGivesUpOnlyWhatASecondMonthNeeds() {
        // A 13-inch iPad in portrait beside the widest sidebar.
        let metrics = portraitMetrics(detailWidth: 742)

        #expect(metrics.visibleMonthCount == 2)
        #expect(metrics.categoryColumnWidth < Self.preferredCategoryWidth)
        #expect(metrics.categoryColumnWidth >= Self.categoryFloor)
        #expect(abs(metrics.tableWidth - (742 - BudgetLayoutMetrics.defaultHorizontalMargins)) < 0.001)
    }

    @Test func categoryColumnKeepsItsWidthWhenTwoMonthsAlreadyFit() {
        let metrics = portraitMetrics(detailWidth: 777)

        #expect(metrics.visibleMonthCount == 2)
        #expect(metrics.categoryColumnWidth == Self.preferredCategoryWidth)
    }

    @Test func categoryColumnStopsAtItsFloorAndTheBudgetStaysOnOneMonth() {
        let atFloor = Self.categoryFloor + BudgetLayoutMetrics.minimumMonthGroupWidth * Self.defaultTextScale * 2
            + BudgetLayoutMetrics.defaultHorizontalMargins
        let justBelow = portraitMetrics(detailWidth: atFloor - 1)
        let justAbove = portraitMetrics(detailWidth: atFloor + 1)

        #expect(justBelow.visibleMonthCount == 1)
        #expect(justBelow.categoryColumnWidth == Self.preferredCategoryWidth)
        #expect(justAbove.visibleMonthCount == 2)
        #expect(justAbove.categoryColumnWidth >= Self.categoryFloor)
    }

    @Test func categoryColumnNeverShrinksForAThirdMonth() {
        // An 11-inch iPad in landscape.
        let metrics = portraitMetrics(detailWidth: 955)

        #expect(metrics.visibleMonthCount == 2)
        #expect(metrics.categoryColumnWidth == Self.preferredCategoryWidth)
    }

    @Test func choosingOneMonthKeepsTheFullCategoryColumn() {
        let metrics = portraitMetrics(detailWidth: 742, preference: .fixed(1))

        #expect(metrics.visibleMonthCount == 1)
        #expect(metrics.categoryColumnWidth == Self.preferredCategoryWidth)
    }

    @Test func aPendingSingleMonthKeepsTheFullCategoryColumn() {
        let inputs = BudgetLayoutInputs(
            rootWidth: 1_032,
            budgetDetailWidth: 742,
            dynamicTypeScale: Self.defaultTextScale
        )
        let pending = BudgetLayoutMetrics.resolve(inputs, renderedMonthCount: 1)

        #expect(pending.visibleMonthCount == 1)
        #expect(pending.categoryColumnWidth == Self.preferredCategoryWidth)
    }

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
