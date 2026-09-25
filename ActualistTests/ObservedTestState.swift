import Observation

/// Await an observable test condition without keeping a task runnable while it changes.
@MainActor
final class ObservedTestState {
    private let condition: @MainActor () -> Bool
    private let reached = TestLatch()

    init(_ condition: @escaping @MainActor () -> Bool) {
        self.condition = condition
    }

    func wait() async {
        arm()
        await reached.wait()
    }

    private func arm() {
        let satisfied = withObservationTracking {
            condition()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.arm() }
        }
        if satisfied { reached.trip() }
    }
}
