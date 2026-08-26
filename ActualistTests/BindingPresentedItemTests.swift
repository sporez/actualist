import SwiftUI
import Testing
@testable import Actualist

struct BindingPresentedItemTests {
    private struct Item: Identifiable, Equatable {
        let id: String
    }

    @Test func matchingIDIsPresentedAndOthersAreNot() {
        var item: Item? = Item(id: "apple")
        let source = Binding(get: { item }, set: { item = $0 })

        #expect(source.isPresented(matching: "apple").wrappedValue)
        #expect(!source.isPresented(matching: "etsy").wrappedValue)
    }

    @Test func nilItemIsNotPresented() {
        var item: Item?
        let source = Binding(get: { item }, set: { item = $0 })

        #expect(!source.isPresented(matching: "apple").wrappedValue)
    }

    @Test func dismissMatchingIDClearsItem() {
        var item: Item? = Item(id: "apple")
        let presented = Binding(get: { item }, set: { item = $0 })
            .isPresented(matching: "apple")

        presented.wrappedValue = false

        #expect(item == nil)
    }

    @Test func dismissOtherIDLeavesItem() {
        var item: Item? = Item(id: "apple")
        let other = Binding(get: { item }, set: { item = $0 })
            .isPresented(matching: "etsy")

        other.wrappedValue = false

        #expect(item?.id == "apple")
    }

    @Test func writingTrueDoesNotChangeItem() {
        var item: Item? = Item(id: "apple")
        let presented = Binding(get: { item }, set: { item = $0 })
            .isPresented(matching: "apple")

        presented.wrappedValue = true

        #expect(item?.id == "apple")
    }
}
