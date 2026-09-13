import SwiftUI

/// Keeps native vertical scrolling and observes only inward edge drags.
struct BudgetMonthSwipeModifier: ViewModifier {
    @Environment(AppState.self) private var appState
    @Environment(\.budgetRootWidth) private var rootWidth
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var transition = BudgetMonthSwipeTransition()
    @State private var gestureRevision = 0
    @State private var viewport: CGRect = .zero
    @State private var previewPosition = ScrollPosition(y: 0)
    @State private var slideOffset: CGFloat = 0
    @GestureState private var drag = BudgetMonthSwipePolicy.Drag()
    let model: BudgetViewModel
    let presentationBlocked: Bool
    let verticalOffset: CGFloat
    private let policy = BudgetMonthSwipePolicy()

    private var surfaceAvailable: Bool {
        appState.settings.monthSwipingEnabled && !presentationBlocked && scenePhase == .active && appState.selectedTab == .budget
            && AdaptiveRootPresentationMode.mode(for: rootWidth, dynamicTypeScale: dynamicTypeSize.budgetLayoutScale) == .compact
    }

    private var enabled: Bool {
        surfaceAvailable && !transition.isReleased
            && BudgetMonthSwipeNavigation.isAvailable(model: model, budgetID: appState.settings.selectedBudgetID)
    }

    func body(content: Content) -> some View {
        let offset = reduceMotion || !surfaceAvailable ? 0 : slideOffset
        content
            // Native buttons must cancel their pending tap when a drag wins.
            .disabled((enabled && policy.suppressesControls(drag)) || transition.isReleased)
            .contentShape(Rectangle())
            .visualEffect { content, _ in content.offset(x: offset) }
            .overlay(alignment: .topLeading) {
                if !reduceMotion, let preview = transition.preview, let request = transition.request {
                    ScrollView {
                        BudgetCompactMonthContent(viewModel: preview)
                            .padding(.horizontal, BudgetLayout.screenHorizontalPadding)
                            .padding(.top, 4)
                            .padding(.bottom, BudgetLayout.sectionSpacing)
                    }
                    .scrollPosition($previewPosition)
                    .onAppear { previewPosition.scrollTo(y: verticalOffset) }
                    .scrollIndicators(.hidden)
                    .background(ActualistTheme.background)
                    .offset(x: offset - request.direction.translationSign * viewport.width)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                if viewport.width != frame.width { cancel() }
                viewport = frame
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: policy.recognitionDistance, coordinateSpace: .global)
                    .updating($drag) { value, state, _ in update(&state, value: value) }
                    .onChanged { value in
                        var current = drag
                        update(&current, value: value)
                        if case .horizontal(let direction) = current.recognition {
                            prepare(direction)
                            slideOffset = policy.previewOffset(current)
                        }
                    }
                    .onEnded { value in
                        var final = drag
                        update(&final, value: value)
                        slideOffset = policy.previewOffset(final)
                        let committed = policy.committedDirection(final)
                        if let committed { prepare(committed) }
                        transition.release(commit: committed != nil)
                        if committed == nil || transition.request == nil { springBack() }
                    }
            )
            .onChange(of: drag == .init()) { _, reset in
                if reset && !transition.isReleased && slideOffset != 0 {
                    transition.release(commit: false)
                    springBack()
                }
            }
            .onChange(of: transition.commitReadyID) { _, id in
                guard let id, let request = transition.request else { return }
                withAnimation(reduceMotion ? nil : .spring(duration: policy.settleDuration, bounce: 0), completionCriteria: .removed) {
                    slideOffset = request.direction.translationSign * viewport.width
                } completion: {
                    guard transition.request?.id == id else { return }
                    transition.complete(id: id, model: model, repository: appState.budgetRepository)
                }
            }
            .onChange(of: transition.request?.id) { _, id in
                if id == nil { slideOffset = 0 }
            }
            .onChange(of: surfaceAvailable) { _, available in if !available { cancel() } }
            .onChange(of: model.budgetMonth) { transition.invalidateIfNeeded(model: model) }
            .onChange(of: model.isLoading) { transition.invalidateIfNeeded(model: model) }
            .onChange(of: model.selectedMonth) { gestureRevision += 1; transition.invalidateIfNeeded(model: model) }
            .onChange(of: appState.settings.selectedBudgetID) { cancel() }
            .onDisappear { cancel() }
    }

    private func update(_ state: inout BudgetMonthSwipePolicy.Drag, value: DragGesture.Value) {
        policy.update(&state,
                      start: CGPoint(x: value.startLocation.x - viewport.minX, y: value.startLocation.y - viewport.minY),
                      translation: value.translation, viewport: viewport.size, enabled: enabled, revision: gestureRevision)
    }

    private func prepare(_ direction: BudgetMonthSwipePolicy.Direction) {
        let store = appState.localFirstStore
        transition.prepare(direction, model: model, budgetID: appState.settings.selectedBudgetID) { budgetID, month in
            try await store.readBudgetMonth(budgetID: budgetID, month: month)
        }
    }

    private func springBack() {
        let id = transition.request?.id
        withAnimation(reduceMotion ? nil : .spring(duration: policy.settleDuration, bounce: policy.springBounce), completionCriteria: .removed) {
            slideOffset = 0
        } completion: {
            if transition.request?.id == id { transition.cancel() }
        }
    }

    private func cancel() {
        gestureRevision += 1
        transition.cancel()
        slideOffset = 0
    }
}
