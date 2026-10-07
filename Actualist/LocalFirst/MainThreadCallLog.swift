import Foundation
import Synchronization

#if DEBUG
/// DEBUG-only record of blocking import stages (ZIP extraction, decryption,
/// sanitizing, portable validation) that ran on the main thread. Fixtures call
/// these stages directly from main-actor tests, so a `dispatchPrecondition`
/// would crash them; tests instead look up the unique key their own scenario
/// passes through each stage (a path under their store root, or a fresh IV).
enum MainThreadCallLog {
    private static let entries = Mutex<Set<String>>([])

    static func record(_ stage: String, key: String) {
        guard Thread.isMainThread else { return }
        entries.withLock { _ = $0.insert("\(stage)|\(key)") }
    }

    static func mainThreadCalls(stage: String, keyContaining fragment: String) -> [String] {
        entries.withLock { set in
            set.filter { $0.hasPrefix("\(stage)|") && $0.contains(fragment) }.sorted()
        }
    }
}
#endif
