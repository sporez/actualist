import Foundation
import Testing
@testable import Actualist

@MainActor
struct BudgetSessionTransitionCoordinatorTests {
    @Test func sameKindRequestForTheSameBudgetSharesTheOwnerResult() async {
        let coordinator = BudgetSessionTransitionCoordinator()
        let gate = ParkedOperation()
        let runs = Recorder<Int>()
        let first = Task {
            await coordinator.run(.select, budgetID: "b") { () -> String in
                runs.append(1)
                await gate.park()
                return "opened"
            }
        }
        await gate.parked.wait()
        let second = Task {
            await coordinator.run(.select, budgetID: "b") { () -> String in
                runs.append(1)
                return "second"
            }
        }
        await ObservedTestState { coordinator.waitingRequestCount == 1 }.wait()
        gate.release()

        #expect(await first.value == "opened")
        #expect(await second.value == "opened")
        #expect(runs.values.count == 1)
        #expect(!coordinator.isTransitionInFlight)
    }

    @Test func otherKindForTheSameBudgetRunsAfterTheOwnerFinishes() async {
        let coordinator = BudgetSessionTransitionCoordinator()
        let gate = ParkedOperation()
        let order = Recorder<String>()
        let restore = Task {
            await coordinator.run(.restore, budgetID: "b") {
                await gate.park()
                order.append("restore")
            }
        }
        await gate.parked.wait()
        let intent = Task {
            await coordinator.run(.intent, budgetID: "b") { () -> Bool in
                order.append("intent")
                return true
            }
        }
        await ObservedTestState { coordinator.waitingRequestCount == 1 }.wait()
        #expect(order.values.isEmpty)
        gate.release()

        await restore.value
        #expect(await intent.value == true)
        #expect(order.values == ["restore", "intent"])
    }

    @Test func otherBudgetIsRefusedWhileATransitionIsInFlight() async {
        let coordinator = BudgetSessionTransitionCoordinator()
        let gate = ParkedOperation()
        let toB = Task {
            await coordinator.run(.select, budgetID: "b", keepsShell: true) { await gate.park() }
        }
        await gate.parked.wait()
        #expect(coordinator.isTransitionInFlight)
        #expect(coordinator.keepsShell)

        let toC = await coordinator.run(.select, budgetID: "c") { true }
        let background = await coordinator.run(.background, budgetID: "a") { true }
        gate.release()
        await toB.value

        #expect(toC == nil)
        #expect(background == nil)
        #expect(!coordinator.keepsShell)
        #expect(!coordinator.isReplacingSession(of: "b"))
    }

    @Test func onlyAnotherBudgetOrAReimportReplacesASession() async {
        let coordinator = BudgetSessionTransitionCoordinator()
        let gate = ParkedOperation()
        let restore = Task { await coordinator.run(.restore, budgetID: "a") { await gate.park() } }
        await gate.parked.wait()
        #expect(!coordinator.isReplacingSession(of: "a"))
        #expect(coordinator.isReplacingSession(of: "b"))
        gate.release()
        await restore.value

        let reimportGate = ParkedOperation()
        let reimport = Task { await coordinator.run(.reimport, budgetID: "a") { await reimportGate.park() } }
        await reimportGate.parked.wait()
        #expect(coordinator.isReplacingSession(of: "a"))
        reimportGate.release()
        await reimport.value
    }

    @Test(arguments: [
        (BudgetSessionTransitionCoordinator.Kind.reimport, BudgetSessionTransitionCoordinator.Kind.select),
        (.select, .reimport),
        (.restore, .discovery)
    ])
    func incompatibleRequestForTheSameBudgetIsRefused(
        inFlight: BudgetSessionTransitionCoordinator.Kind,
        request: BudgetSessionTransitionCoordinator.Kind
    ) async {
        let coordinator = BudgetSessionTransitionCoordinator()
        let gate = ParkedOperation()
        let owner = Task { await coordinator.run(inFlight, budgetID: "b") { await gate.park() } }
        await gate.parked.wait()

        let refused = await coordinator.run(request, budgetID: "b") { true }
        gate.release()
        await owner.value

        #expect(refused == nil)
    }

    @Test func requestInsideTheOwnerTaskRunsInline() async {
        let coordinator = BudgetSessionTransitionCoordinator()
        let nested = await coordinator.run(.restore, budgetID: "b") {
            await coordinator.run(.discovery, budgetID: "b") { "nested" }
        }
        #expect(nested == "nested")
    }

    @Test func cancellingTheCallerDoesNotCancelTheOwner() async {
        let coordinator = BudgetSessionTransitionCoordinator()
        let gate = ParkedOperation()
        let caller = Task {
            await coordinator.run(.select, budgetID: "b") { () -> Bool in
                await gate.park()
                return Task.isCancelled
            }
        }
        await gate.parked.wait()
        caller.cancel()
        gate.release()

        #expect(await caller.value == false)
    }

    @Test func cancelStopsTheOwnerAndFreesTheCoordinator() async {
        let coordinator = BudgetSessionTransitionCoordinator()
        let gate = ParkedOperation()
        let owner = Task {
            await coordinator.run(.select, budgetID: "b") { () -> Bool in
                await gate.park()
                return Task.isCancelled
            }
        }
        await gate.parked.wait()
        coordinator.cancel()
        #expect(!coordinator.isTransitionInFlight)
        let next = await coordinator.run(.select, budgetID: "c") { "c" }
        gate.release()

        #expect(next == "c")
        #expect(await owner.value == true)
    }

    @Test func throwingOperationRethrowsToTheOwnerAndSameKindJoiners() async {
        let coordinator = BudgetSessionTransitionCoordinator()
        let gate = ParkedOperation()
        let first = Task {
            try await coordinator.runThrowing(.discovery, budgetID: "b") { () -> Int in
                await gate.park()
                throw LocalFirstError.budgetNotOpened
            }
        }
        await gate.parked.wait()
        gate.release()

        await #expect(throws: LocalFirstError.budgetNotOpened) { try await first.value }
        #expect(!coordinator.isTransitionInFlight)
    }
}

@MainActor
private final class Recorder<Value> {
    private(set) var values: [Value] = []
    func append(_ value: Value) { values.append(value) }
}

/// Parks one operation until the test releases it.
@MainActor
private final class ParkedOperation {
    let parked = TestLatch()
    private var continuation: CheckedContinuation<Void, Never>?

    func park() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            parked.trip()
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
