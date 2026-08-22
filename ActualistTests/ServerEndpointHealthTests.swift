import Foundation
import Testing
@testable import Actualist

@MainActor
struct ServerEndpointHealthTests {
    private let primary = URL(string: "https://home.example")!
    private let fallback = URL(string: "https://away.example")!
    private let otherFallback = URL(string: "https://other.example")!
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Skip / TTL

    @Test func freshHealthNeverSkips() {
        let health = makeHealth()

        #expect(!health.shouldSkipPrimary(primary: primary, fallback: fallback))
    }

    @Test func markingUnreachableSkipsBeforeTTL() {
        var clock = start
        var health = makeHealth(now: { clock })

        health.notePrimaryUnreachable(primary: primary, fallback: fallback)

        clock = start.addingTimeInterval(60)
        #expect(health.shouldSkipPrimary(primary: primary, fallback: fallback))
    }

    @Test func skipExpiresAfterTTL() {
        var clock = start
        var health = makeHealth(now: { clock }, ttl: 60)

        health.notePrimaryUnreachable(primary: primary, fallback: fallback)
        clock = start.addingTimeInterval(60)
        #expect(!health.shouldSkipPrimary(primary: primary, fallback: fallback))
    }

    @Test func successClearsSkipImmediately() {
        var health = makeHealth()

        health.notePrimaryUnreachable(primary: primary, fallback: fallback)
        health.notePrimarySucceeded(primary: primary, fallback: fallback)

        #expect(!health.shouldSkipPrimary(primary: primary, fallback: fallback))
    }

    @Test func differentPairDoesNotInheritDownFlag() {
        var health = makeHealth()

        health.notePrimaryUnreachable(primary: primary, fallback: fallback)

        #expect(!health.shouldSkipPrimary(primary: primary, fallback: otherFallback))
        #expect(
            !health.shouldSkipPrimary(
                primary: URL(string: "https://other-home.example")!,
                fallback: fallback
            )
        )
    }

    @Test func clearDropsEveryPair() {
        var health = makeHealth()

        health.notePrimaryUnreachable(primary: primary, fallback: fallback)
        health.notePrimaryUnreachable(primary: primary, fallback: otherFallback)
        health.clear()

        #expect(!health.shouldSkipPrimary(primary: primary, fallback: fallback))
        #expect(!health.shouldSkipPrimary(primary: primary, fallback: otherFallback))
    }

    @Test func unreachableUsesInjectedClockAndTTL() {
        var clock = start
        var health = makeHealth(now: { clock }, ttl: 90)

        health.notePrimaryUnreachable(primary: primary, fallback: fallback)
        clock = start.addingTimeInterval(89)
        #expect(health.shouldSkipPrimary(primary: primary, fallback: fallback))
        clock = start.addingTimeInterval(90)
        #expect(!health.shouldSkipPrimary(primary: primary, fallback: fallback))
    }

    // MARK: - Display

    @Test func displayWithNoFallbackAndNothingCached() {
        let health = makeHealth()
        let display = health.display(currentPrimary: primary, currentFallback: nil)

        #expect(display == .empty)
        #expect(display.summaryText == "No fallback configured")
        #expect(!display.willSkipPrimary)
        #expect(display.pairs.isEmpty)
    }

    @Test func displayCurrentPairNotCached() {
        let health = makeHealth()
        let display = health.display(currentPrimary: primary, currentFallback: fallback)

        #expect(display.summaryText == "Primary will be tried")
        #expect(!display.willSkipPrimary)
        #expect(display.pairs.count == 1)
        #expect(display.pairs[0].primaryHost == "home.example")
        #expect(display.pairs[0].fallbackHost == "away.example")
        #expect(display.pairs[0].statusText == "Not cached")
        #expect(!display.pairs[0].isDown)
        #expect(display.pairs[0].isCurrentPair)
    }

    @Test func displayCurrentPairMarkedDownUsesRemainingTTL() {
        var clock = start
        var health = makeHealth(now: { clock }, ttl: 15 * 60)

        health.notePrimaryUnreachable(primary: primary, fallback: fallback)
        clock = start.addingTimeInterval(14 * 60)
        let display = health.display(currentPrimary: primary, currentFallback: fallback)

        #expect(display.summaryText == "Skipping primary")
        #expect(display.willSkipPrimary)
        #expect(display.pairs.count == 1)
        #expect(display.pairs[0].isDown)
        #expect(display.pairs[0].isCurrentPair)
        #expect(display.pairs[0].statusText.contains("1 min"))
        #expect(display.pairs[0].primaryHost == "home.example")
        #expect(!display.pairs[0].primaryHost.contains("https://"))
    }

    @Test func displayExpiredPairIsNotCached() {
        var clock = start
        var health = makeHealth(now: { clock }, ttl: 60)

        health.notePrimaryUnreachable(primary: primary, fallback: fallback)
        clock = start.addingTimeInterval(60)
        let display = health.display(currentPrimary: primary, currentFallback: fallback)

        #expect(display.summaryText == "Primary will be tried")
        #expect(!display.willSkipPrimary)
        #expect(display.pairs.count == 1)
        #expect(display.pairs[0].statusText == "Not cached")
        #expect(!display.pairs[0].isDown)
    }

    @Test func displayListsLeftoverPairAfterFallbackURLChange() {
        var health = makeHealth()

        health.notePrimaryUnreachable(primary: primary, fallback: fallback)
        let display = health.display(currentPrimary: primary, currentFallback: otherFallback)

        #expect(display.summaryText == "Primary will be tried")
        #expect(!display.willSkipPrimary)
        #expect(display.pairs.count == 2)
        #expect(display.pairs[0].fallbackHost == "other.example")
        #expect(display.pairs[0].isCurrentPair)
        #expect(!display.pairs[0].isDown)
        #expect(display.pairs[1].fallbackHost == "away.example")
        #expect(!display.pairs[1].isCurrentPair)
        #expect(display.pairs[1].isDown)
    }

    @Test func displayHostsAreHostOnly() {
        var health = makeHealth()
        health.notePrimaryUnreachable(primary: primary, fallback: fallback)
        let display = health.display(currentPrimary: primary, currentFallback: fallback)

        #expect(display.pairs[0].primaryHost == "home.example")
        #expect(display.pairs[0].fallbackHost == "away.example")
        #expect(!display.pairs[0].primaryHost.contains("https://"))
        #expect(!display.pairs[0].primaryHost.contains("/"))
    }

    private func makeHealth(
        now: @escaping () -> Date = Date.init,
        ttl: TimeInterval = 15 * 60
    ) -> ServerEndpointHealth {
        ServerEndpointHealth(now: now, ttl: ttl)
    }
}
