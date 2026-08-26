import SwiftUI

extension Binding {
    /// A per-row `confirmationDialog` flag for a shared optional item.
    ///
    /// `confirmationDialog` only accepts `Binding<Bool>`, but iOS 26 anchors
    /// the popover to the view that owns that binding. Each row therefore
    /// needs a Bool that is true only while *this* identity is pending.
    /// Dismiss writes `false`; clear the item only when this identity still
    /// owns it so a sibling or recycled row cannot steal the presentation.
    func isPresented<Item: Identifiable & Sendable>(
        matching id: Item.ID
    ) -> Binding<Bool> where Value == Item?, Item.ID: Sendable {
        let handle = BindingHandle(self)
        return Binding<Bool>(
            get: { handle.get()?.id == id },
            set: { isPresented in
                guard !isPresented, handle.get()?.id == id else {
                    return
                }
                handle.set(nil)
            }
        )
    }
}

/// SwiftUI `Binding` get/set run on the view that created them. This handle
/// exists only so those closures can be stored in `Binding.init(get:set:)`,
/// which is `@Sendable`. The handle is not shared across isolation domains.
private struct BindingHandle<Value>: @unchecked Sendable {
    let get: () -> Value
    let set: (Value) -> Void

    init(_ binding: Binding<Value>) {
        get = { binding.wrappedValue }
        set = { binding.wrappedValue = $0 }
    }
}
