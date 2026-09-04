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
}
