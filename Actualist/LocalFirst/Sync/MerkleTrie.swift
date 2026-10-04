import Foundation

/// Actual's merkle trie of message timestamps (`packages/crdt/src/crdt/merkle.ts`).
///
/// A trinary radix trie keyed by `floor(millis / 60000)` written in base 3. Every
/// node carries the XOR of the hashes of the timestamps beneath it, so two
/// devices that hold the same messages have equal root hashes and a differing
/// pair of tries points at the earliest minute where they disagree. Hashes are
/// JS int32 values, so they are `Int32` here and the wire JSON keeps them signed.
struct MerkleTrie: Equatable, Sendable {
    private(set) var hash: Int32 = 0
    private var children: [UInt8: MerkleTrie] = [:]

    /// Deepest key upstream can produce is 16 digits; anything deeper is not Actual's.
    private static let maximumDepth = 20
    private static let fullKeyLength = 16
    private static let millisecondsPerMinute: Int64 = 60_000

    static let empty = MerkleTrie()

    init() {}

    var isEmpty: Bool { hash == 0 && children.isEmpty }

    // MARK: Insert

    /// XORs `hash` into the root and every node on the minute's base-3 key path.
    mutating func insert(minute: Int64, hash: Int32) {
        self.hash ^= hash
        let digits = String(max(minute, 0), radix: 3).utf8.map { $0 &- UInt8(ascii: "0") }
        insert(digits[...], hash: hash)
    }

    mutating func insert(_ timestamp: SyncTimestamp) {
        insert(
            minute: timestamp.milliseconds / Self.millisecondsPerMinute,
            hash: MerkleHash.hash(of: timestamp)
        )
    }

    private mutating func insert(_ digits: ArraySlice<UInt8>, hash: Int32) {
        guard let digit = digits.first else { return }
        var child = children[digit] ?? MerkleTrie()
        child.hash ^= hash
        child.insert(digits.dropFirst(), hash: hash)
        children[digit] = child
    }

    // MARK: Prune

    /// Keeps the last `keep` child keys at every level. Upstream does nothing to
    /// a node whose hash is 0, so neither does this.
    func pruned(keep: Int = 2) -> MerkleTrie {
        guard hash != 0 else { return self }
        var next = MerkleTrie()
        next.hash = hash
        for key in children.keys.sorted().suffix(keep) {
            next.children[key] = children[key]?.pruned(keep: keep)
        }
        return next
    }

    // MARK: Diff

    /// Milliseconds of the earliest minute window where the tries disagree, or
    /// nil when the roots match. An empty trie against a non-empty one is 0.
    static func diff(_ first: MerkleTrie, _ second: MerkleTrie) -> Int64? {
        if first.hash == second.hash { return nil }
        var node1 = first
        var node2 = second
        var key = ""
        while true {
            var differing: UInt8?
            for digit in Set(node1.children.keys).union(node2.children.keys).sorted() {
                // Pruning is lossy: a key missing on either side ends the descent.
                guard let next1 = node1.children[digit], let next2 = node2.children[digit] else { break }
                if next1.hash != next2.hash {
                    differing = digit
                    break
                }
            }
            guard let differing else { return milliseconds(forKey: key) }
            key.append(String(differing))
            node1 = node1.children[differing] ?? MerkleTrie()
            node2 = node2.children[differing] ?? MerkleTrie()
        }
    }

    private static func milliseconds(forKey key: String) -> Int64 {
        let padded = key + String(repeating: "0", count: max(0, fullKeyLength - key.count))
        return (Int64(padded, radix: 3) ?? 0) * millisecondsPerMinute
    }

    // MARK: Wire and storage JSON (upstream shape)

    /// `{"0":{...},"hash":123}`, the shape upstream stores and sends.
    var jsonString: String {
        var parts = children.keys.sorted().compactMap { key in
            children[key].map { "\"\(key)\":\($0.jsonString)" }
        }
        parts.append("\"hash\":\(hash)")
        return "{" + parts.joined(separator: ",") + "}"
    }

    /// nil for empty or unreadable JSON, so a server that sends no merkle (or
    /// garbage) simply skips divergence detection.
    init?(jsonString: String) {
        guard !jsonString.isEmpty,
              let data = jsonString.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let node = Self(jsonObject: object, depth: 0) else {
            return nil
        }
        self = node
    }

    init?(jsonObject: Any) {
        guard let node = Self(jsonObject: jsonObject, depth: 0) else { return nil }
        self = node
    }

    private init?(jsonObject: Any, depth: Int) {
        guard depth <= Self.maximumDepth, let dictionary = jsonObject as? [String: Any] else {
            return nil
        }
        if let rawHash = dictionary["hash"] {
            // A server number may exceed Int32; JS `^` truncates the same way.
            guard let number = rawHash as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
                return nil
            }
            hash = Int32(truncatingIfNeeded: number.int64Value)
        }
        for digit in 0...2 {
            guard let rawChild = dictionary[String(digit)] else { continue }
            guard let child = Self(jsonObject: rawChild, depth: depth + 1) else { return nil }
            children[UInt8(digit)] = child
        }
    }
}

/// `murmurhash.v3(Timestamp.toString())` with seed 0 (`timestamp.ts` `hash()`).
enum MerkleHash {
    /// Hashes the canonical `Timestamp.toString()` form, not the stored text: an
    /// uppercase 4-digit hex counter and the node left-padded with `0` to 16.
    static func hash(of timestamp: SyncTimestamp) -> Int32 {
        hash(canonical(timestamp))
    }

    static func canonical(_ timestamp: SyncTimestamp) -> String {
        let counter = String(format: "%04X", timestamp.counter)
        let node = String(repeating: "0", count: max(0, 16 - timestamp.node.count)) + timestamp.node
        return "\(timestamp.wallTime)-\(counter)-\(node)"
    }

    /// Murmur3 x86 32-bit over `charCodeAt & 0xff`, returned as a JS int32.
    static func hash(_ string: String) -> Int32 {
        let bytes = string.utf16.map { UInt8(truncatingIfNeeded: $0) }
        let c1: UInt32 = 0xcc9e2d51
        let c2: UInt32 = 0x1b873593
        var h1: UInt32 = 0
        let blockCount = bytes.count / 4
        for block in 0..<blockCount {
            let base = block * 4
            var k1 = UInt32(bytes[base])
                | UInt32(bytes[base + 1]) << 8
                | UInt32(bytes[base + 2]) << 16
                | UInt32(bytes[base + 3]) << 24
            k1 = k1 &* c1
            k1 = (k1 << 15) | (k1 >> 17)
            k1 = k1 &* c2
            h1 ^= k1
            h1 = (h1 << 13) | (h1 >> 19)
            h1 = h1 &* 5 &+ 0xe6546b64
        }
        var k1: UInt32 = 0
        let tail = blockCount * 4
        switch bytes.count & 3 {
        case 3:
            k1 ^= UInt32(bytes[tail + 2]) << 16
            fallthrough
        case 2:
            k1 ^= UInt32(bytes[tail + 1]) << 8
            fallthrough
        case 1:
            k1 ^= UInt32(bytes[tail])
            k1 = k1 &* c1
            k1 = (k1 << 15) | (k1 >> 17)
            k1 = k1 &* c2
            h1 ^= k1
        default:
            break
        }
        h1 ^= UInt32(truncatingIfNeeded: bytes.count)
        h1 ^= h1 >> 16
        h1 = h1 &* 0x85ebca6b
        h1 ^= h1 >> 13
        h1 = h1 &* 0xc2b2ae35
        h1 ^= h1 >> 16
        return Int32(bitPattern: h1)
    }
}
