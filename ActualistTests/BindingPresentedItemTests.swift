import SwiftUI
import Testing
@testable import Actualist

struct BindingPresentedItemTests {
    private struct Item: Identifiable, Equatable {
        let id: String
    }

    /// Binding get/set are `@Sendable`; this box is the test's single source of
    /// truth and is only used on one thread.
    private final class ItemBox: @unchecked Sendable {
        var value: Item?

        init(_ value: Item? = nil) {
            self.value = value
        }
    }

    @Test func matchingIDIsPresentedAndOthersAreNot() {
        let box = ItemBox(Item(id: "apple"))
        let source = Binding(get: { box.value }, set: { box.value = $0 })

        #expect(source.isPresented(matching: "apple").wrappedValue)
        #expect(!source.isPresented(matching: "etsy").wrappedValue)
    }

    @Test func nilItemIsNotPresented() {
        let box = ItemBox()
        let source = Binding(get: { box.value }, set: { box.value = $0 })

        #expect(!source.isPresented(matching: "apple").wrappedValue)
    }

    @Test func dismissMatchingIDClearsItem() {
        let box = ItemBox(Item(id: "apple"))
        let presented = Binding(get: { box.value }, set: { box.value = $0 })
            .isPresented(matching: "apple")

        presented.wrappedValue = false

        #expect(box.value == nil)
    }

    @Test func dismissOtherIDLeavesItem() {
        let box = ItemBox(Item(id: "apple"))
        let other = Binding(get: { box.value }, set: { box.value = $0 })
            .isPresented(matching: "etsy")

        other.wrappedValue = false

        #expect(box.value?.id == "apple")
    }

    @Test func writingTrueDoesNotChangeItem() {
        let box = ItemBox(Item(id: "apple"))
        let presented = Binding(get: { box.value }, set: { box.value = $0 })
            .isPresented(matching: "apple")

        presented.wrappedValue = true

        #expect(box.value?.id == "apple")
    }
}
