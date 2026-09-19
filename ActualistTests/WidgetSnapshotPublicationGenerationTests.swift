import Testing
@testable import Actualist

struct WidgetSnapshotPublicationGenerationTests {
    @Test func beginningANewerPublicationInvalidatesOlderWork() {
        var generation = WidgetSnapshotPublicationGeneration()
        let first = generation.begin()
        let second = generation.begin()

        #expect(!generation.isCurrent(first))
        #expect(generation.isCurrent(second))
    }

    @Test func financialPublicationRejectsStaleObservationCallbacksAcrossSessions() {
        var gate = WidgetFinancialPublicationGate()
        let first = gate.begin()
        #expect(gate.isActive)
        #expect(gate.accepts(first))
        #expect(gate.begin() == first)

        gate.end()
        #expect(!gate.isActive)
        #expect(!gate.accepts(first))

        let second = gate.begin()
        #expect(second != first)
        #expect(!gate.accepts(first))
        #expect(gate.accepts(second))
    }
}
