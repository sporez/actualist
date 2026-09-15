import SwiftUI

/// The keypad overlays a stable viewport; only its additional occlusion becomes scrollable clearance.
struct BudgetAssignmentViewport<Content: View, Keypad: View, Floating: View>: View {
    @Bindable var presentation: BudgetAssignmentScrollPresentation
    let viewModel: BudgetViewModel
    let isPresented: Bool
    let monthSwipeBlocked: Bool
    let beginEditing: (String) -> Void
    @ViewBuilder let content: () -> Content
    @ViewBuilder let keypad: () -> Keypad
    @ViewBuilder let floating: (Bool) -> Floating

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                content()
                    .padding(.horizontal, BudgetLayout.screenHorizontalPadding)
                    .padding(.top, 4)
                    .padding(.bottom, presentation.bottomPadding)
            }
            .scrollPosition($presentation.position)
            .scrollIndicators(.hidden)
            .accessibilityIdentifier("budget-compact-scroll")
            .background(ActualistTheme.background)
            .onScrollGeometryChange(for: BudgetAssignmentScrollPresentation.Sample.self) { geometry in
                .init(position: geometry.contentOffset.y + geometry.contentInsets.top,
                      maximum: max(0, geometry.contentSize.height - geometry.containerSize.height),
                      contentHeight: geometry.contentSize.height,
                      visibleOffset: geometry.visibleRect.minY)
            } action: { _, current in
                presentation.update(current)
            }
            .onScrollPhaseChange { _, phase in
                presentation.updateScrollPhase(phase)
            }
            .modifier(BudgetMonthSwipeModifier(model: viewModel,
                presentationBlocked: monthSwipeBlocked || presentation.phase != .idle,
                verticalOffset: presentation.sample.visibleOffset))
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: presentation.floatingHeight)
            }

            floating(presentation.expansion.isExpanded)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                    presentation.measureFloatingHeight($0)
                }
                .opacity(isPresented ? 0 : 1)
                .allowsHitTesting(!isPresented)
                .accessibilityHidden(isPresented)

            if isPresented {
                keypad()
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                        presentation.measureKeypadHeight($0)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: {
            presentation.viewportBottom = $0
        }
        .animation(BudgetLayout.assignmentKeypadAnimation, value: isPresented)
        .task(id: presentation.readyRequest) {
            guard let request = presentation.readyRequest else { return }
            // Leave the layout callback before asking ScrollPosition to animate.
            await Task.yield()
            guard !Task.isCancelled, presentation.readyRequest == request else { return }
            withAnimation(BudgetLayout.assignmentKeypadAnimation) {
                if presentation.begin(request), request.startsEditing {
                    beginEditing(request.categoryID)
                }
            }
        }
        .onChange(of: isPresented) { _, visible in
            if !visible { presentation.close() }
        }
        .onChange(of: viewModel.selectedMonth) { presentation.cancelPendingPresentation() }
    }
}
