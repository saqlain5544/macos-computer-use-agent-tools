import Foundation

/// The person's own pointer, tracked so the driver can prove it never moved.
typealias Point = (x: Double, y: Double)

/// One worker per bound app.
///
/// The daemon is a single process: it owns the lock, the state, and the
/// HTTP/MCP surfaces. Talking to an app is a different job, and it should not be
/// shared between apps — a slow call against one app must not block work on
/// another, and a crash in one worker must not take the driver down.
///
/// So each bound app gets its own worker process, keyed by the app's identity
/// (its bundle id) so a quit-and-relaunch reuses the same slot, and reaped when
/// the binding is released.
final class WorkerPool {
    private let lock = NSLock()
    private var workers: [String: Helper] = [:]
    private let helperPath: String
    /// The agent's virtual cursor. Session state, not app state.
    private var pointer: Point = (0, 0)
    private var pointerAt = Date(timeIntervalSince1970: 0)

    init(helperPath: String) {
        self.helperPath = helperPath
    }

    /// The worker for an app, created on first use.
    func forApp(_ identity: String) -> Helper {
        let key = identity.isEmpty ? "unknown" : identity
        lock.lock()
        if let existing = workers[key] {
            lock.unlock()
            return existing
        }
        lock.unlock()

        let fresh = Helper(helperPath: helperPath)
        lock.lock()
        if let existing = workers[key] {
            lock.unlock()
            return existing
        }
        workers[key] = fresh
        lock.unlock()
        return fresh
    }

    /// A worker for work that has no binding yet (the startup probe, the
    /// dashboard's own reads). Keyed separately so it never masquerades as an
    /// app worker.
    func session() -> Helper { forApp("__session__") }

    /// Drop a worker; its process exits when the handle is released.
    func release(_ identity: String) {
        lock.lock()
        let h = workers.removeValue(forKey: identity)
        lock.unlock()
        h?.stop()
    }

    /// Drop every worker (shutdown).
    func releaseAll() {
        lock.lock()
        let all = workers.values
        workers.removeAll()
        lock.unlock()
        for h in all { h.stop() }
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return workers.count
    }

    var identities: [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(workers.keys)
    }

    func pointerNow() -> Point {
        let p = session().pointerNow()
        lock.lock()
        if p.0 != 0 || p.1 != 0 {
            pointer = p
            pointerAt = Date()
        }
        let value = pointer
        lock.unlock()
        return value
    }

    func pointerMoved(since before: Point) -> Bool {
        let now = pointerNow()
        return abs(now.x - before.x) > 0.5 || abs(now.y - before.y) > 0.5
    }
}
