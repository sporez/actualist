import Foundation

/// Prepared Developer-sheet readout of the in-memory primary-unreachable cache.
/// Hosts are host-only; the view must not re-parse URLs or compute TTL.
struct ServerEndpointHealthDisplay: Equatable, Sendable {
    struct Pair: Equatable, Sendable, Identifiable {
        var id: String
        var primaryHost: String
        var fallbackHost: String
        var isDown: Bool
        var statusText: String
        var isCurrentPair: Bool
    }

    var pairs: [Pair]
    var willSkipPrimary: Bool
    var summaryText: String

    static let empty = ServerEndpointHealthDisplay(
        pairs: [],
        willSkipPrimary: false,
        summaryText: "No fallback configured"
    )
}

/// In-memory TTL cache of "this primary is unreachable via this fallback."
/// Main-actor value type: every failover caller is already on the store's actor.
@MainActor
struct ServerEndpointHealth {
    var now: () -> Date
    var ttl: TimeInterval

    private struct Entry {
        var primary: URL
        var fallback: URL
        var downUntil: Date
    }

    private var entries: [String: Entry] = [:]

    init(
        now: @escaping () -> Date = Date.init,
        ttl: TimeInterval = 15 * 60
    ) {
        self.now = now
        self.ttl = ttl
    }

    func shouldSkipPrimary(primary: URL, fallback: URL) -> Bool {
        guard let entry = entries[Self.key(primary: primary, fallback: fallback)] else {
            return false
        }
        return now() < entry.downUntil
    }

    mutating func notePrimaryUnreachable(primary: URL, fallback: URL) {
        let pairKey = Self.key(primary: primary, fallback: fallback)
        entries[pairKey] = Entry(
            primary: primary,
            fallback: fallback,
            downUntil: now().addingTimeInterval(ttl)
        )
    }

    mutating func notePrimarySucceeded(primary: URL, fallback: URL) {
        entries[Self.key(primary: primary, fallback: fallback)] = nil
    }

    mutating func clear() {
        entries.removeAll()
    }

    func display(currentPrimary: URL?, currentFallback: URL?) -> ServerEndpointHealthDisplay {
        let instant = now()
        let currentKey: String?
        if let currentPrimary, let currentFallback {
            currentKey = Self.key(primary: currentPrimary, fallback: currentFallback)
        } else {
            currentKey = nil
        }

        var pairs: [ServerEndpointHealthDisplay.Pair] = []
        var willSkipPrimary = false

        if let currentPrimary, let currentFallback, let currentKey {
            let entry = entries[currentKey]
            let isDown = entry.map { instant < $0.downUntil } ?? false
            willSkipPrimary = isDown
            pairs.append(
                Self.makePair(
                    primary: currentPrimary,
                    fallback: currentFallback,
                    downUntil: isDown ? entry?.downUntil : nil,
                    now: instant,
                    isCurrent: true
                )
            )
        }

        let leftover = entries.values
            .filter { instant < $0.downUntil }
            .filter { Self.key(primary: $0.primary, fallback: $0.fallback) != currentKey }
            .sorted { lhs, rhs in
                if lhs.primary.absoluteString != rhs.primary.absoluteString {
                    return lhs.primary.absoluteString < rhs.primary.absoluteString
                }
                return lhs.fallback.absoluteString < rhs.fallback.absoluteString
            }
        pairs.append(contentsOf: leftover.map { entry in
            Self.makePair(
                primary: entry.primary,
                fallback: entry.fallback,
                downUntil: entry.downUntil,
                now: instant,
                isCurrent: false
            )
        })

        let summaryText: String
        if currentFallback == nil, pairs.isEmpty {
            summaryText = "No fallback configured"
        } else if willSkipPrimary {
            summaryText = "Skipping primary"
        } else {
            summaryText = "Primary will be tried"
        }

        return ServerEndpointHealthDisplay(
            pairs: pairs,
            willSkipPrimary: willSkipPrimary,
            summaryText: summaryText
        )
    }

    private static func key(primary: URL, fallback: URL) -> String {
        "\(primary.absoluteString)\0\(fallback.absoluteString)"
    }

    private static func host(from url: URL) -> String {
        if let host = url.host, !host.isEmpty {
            return host
        }
        return url.absoluteString
    }

    private static func remainingStatusText(downUntil: Date, now: Date) -> String {
        let remaining = downUntil.timeIntervalSince(now)
        let minutes = Int(remaining / 60)
        if minutes < 1 {
            return "Down · less than 1 min left"
        }
        return "Down · \(minutes) min left"
    }

    private static func makePair(
        primary: URL,
        fallback: URL,
        downUntil: Date?,
        now: Date,
        isCurrent: Bool
    ) -> ServerEndpointHealthDisplay.Pair {
        let isDown = downUntil.map { now < $0 } ?? false
        return ServerEndpointHealthDisplay.Pair(
            id: key(primary: primary, fallback: fallback),
            primaryHost: host(from: primary),
            fallbackHost: host(from: fallback),
            isDown: isDown,
            statusText: isDown
                ? remainingStatusText(downUntil: downUntil ?? now, now: now)
                : "Not cached",
            isCurrentPair: isCurrent
        )
    }
}
