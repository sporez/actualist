import SwiftUI

/// The scroll view keeps native vertical recognition; this simultaneous gesture
/// observes only inward, edge-originating horizontal movement.
struct BudgetMonthSwipeModifier: ViewModifier {
    @Environment(AppState.self) private var appState
    @Environment(\.budgetRootWidth) private var rootWidth
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var navigation = BudgetMonthSwipeNavigation()
    @State private var gestureRevision = 0
    @State private var viewport: CGRect = .zero
    @GestureState private var drag = BudgetMonthSwipePolicy.Drag()
    let model: BudgetViewModel
    let presentationBlocked: Bool
    private let policy = BudgetMonthSwipePolicy()

    private var surfaceAvailable: Bool {
        !presentationBlocked && scenePhase == .active && appState.selectedTab == .budget
            && AdaptiveRootPresentationMode.mode(for: rootWidth, dynamicTypeScale: dynamicTypeSize.budgetLayoutScale) == .compact
    }

    private var enabled: Bool {
        surfaceAvailable && navigation.requestID == nil
            && BudgetMonthSwipeNavigation.isAvailable(model: model, budgetID: appState.settings.selectedBudgetID)
    }

    func body(content: Content) -> some View {
        let offset = reduceMotion || !surfaceAvailable ? 0 : policy.previewOffset(drag)
        content
            // Native buttons must cancel their pending tap when a drag wins.
            .disabled((enabled && policy.suppressesControls(drag)) || navigation.requestID != nil)
            .contentShape(Rectangle())
            .visualEffect { content, _ in
                content.offset(x: offset)
            }
            .animation(reduceMotion ? nil : .easeOut(duration: policy.settleDuration), value: drag == .init())
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                if viewport.width != frame.width {
                    gestureRevision += 1
                    navigation.cancel()
                }
                viewport = frame
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: policy.recognitionDistance, coordinateSpace: .global)
                    .updating($drag) { value, state, _ in
                        policy.update(&state,
                                      start: CGPoint(x: value.startLocation.x - viewport.minX, y: value.startLocation.y - viewport.minY),
                                      translation: value.translation, viewport: viewport.size, enabled: enabled, revision: gestureRevision)
                    }
                    .onEnded { value in
                        var final = drag
                        policy.update(&final,
                                      start: CGPoint(x: value.startLocation.x - viewport.minX, y: value.startLocation.y - viewport.minY),
                                      translation: value.translation, viewport: viewport.size, enabled: enabled, revision: gestureRevision)
                        if let direction = policy.committedDirection(final) {
                            navigation.navigate(direction, model: model,
                                                budgetID: appState.settings.selectedBudgetID,
                                                repository: appState.budgetRepository)
                        }
                    }
            )
            .onChange(of: surfaceAvailable) { _, available in
                if !available { navigation.cancel() }
            }
            .onChange(of: enabled) { _, available in
                if !available { gestureRevision += 1 }
            }
            .onChange(of: model.selectedMonth) { gestureRevision += 1 }
            .onChange(of: appState.settings.selectedBudgetID) {
                gestureRevision += 1
                navigation.cancel()
            }
            .onDisappear { navigation.cancel() }
    }
}
