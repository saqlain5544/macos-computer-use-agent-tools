import Foundation

/// Everything the server threads and the dashboard share.
///
/// One lock guards all of it. Everything in here is small and read-mostly
/// (counters, the binding, the last tree), and no worker call is made while it
/// is held, so contention is not a concern.
final class Shared {
    private let lock = NSLock()

    private var _running = true
    private var _mode: Mode = .background
    private var _target: Target?
    private var _port: UInt16 = 0
    private var _fps: Double = 0
    private var _frames: UInt64 = 0
    private var _agents: Set<String> = []
    private var _frontmost = ""
    private var _focusEvents: UInt32 = 0
    private var _actionsTotal: UInt64 = 0
    private var _log: [[String: Any]] = []
    private var _permissions = Permissions()
    private var _lastError = ""
    private var _workerReady = false
    private var _boundsRefreshedAt: UInt64 = 0
    private let startedAt = UInt64(Date().timeIntervalSince1970)
    private var _screenLocked = false
    private var _tree: [Node] = []

    // MARK: accessors

    var running: Bool {
        get { locked { _running } }
        set { locked { _running = newValue } }
    }

    var mode: Mode {
        get { locked { _mode } }
        set { locked { _mode = newValue } }
    }

    var target: Target? {
        get { locked { _target } }
        set { locked { _target = newValue } }
    }

    var port: UInt16 {
        get { locked { _port } }
        set { locked { _port = newValue } }
    }

    var fps: Double {
        get { locked { _fps } }
        set { locked { _fps = newValue } }
    }

    var frames: UInt64 {
        get { locked { _frames } }
        set { locked { _frames = newValue } }
    }

    var frontmost: String {
        get { locked { _frontmost } }
        set { locked { _frontmost = newValue } }
    }

    var focusEvents: UInt32 {
        get { locked { _focusEvents } }
        set { locked { _focusEvents = newValue } }
    }

    var actionsTotal: UInt64 {
        get { locked { _actionsTotal } }
        set { locked { _actionsTotal = newValue } }
    }

    var permissions: Permissions {
        get { locked { _permissions } }
        set { locked { _permissions = newValue } }
    }

    var lastError: String {
        get { locked { _lastError } }
        set { locked { _lastError = newValue } }
    }

    var workerReady: Bool {
        get { locked { _workerReady } }
        set { locked { _workerReady = newValue } }
    }

    var screenLocked: Bool {
        get { locked { _screenLocked } }
        set { locked { _screenLocked = newValue } }
    }

    var tree: [Node] {
        get { locked { _tree } }
        set { locked { _tree = newValue } }
    }

    var boundsRefreshedAt: UInt64 {
        get { locked { _boundsRefreshedAt } }
        set { locked { _boundsRefreshedAt = newValue } }
    }

    var agents: [String] {
        locked { Array(_agents).sorted() }
    }

    func noteAgent(_ id: String) {
        guard !id.isEmpty else { return }
        locked { _agents.insert(id) }
    }

    var uptime: UInt64 { UInt64(Date().timeIntervalSince1970) - startedAt }

    var recentLog: [[String: Any]] {
        locked { Array(_log.suffix(40)) }
    }

    func record(tool: String, detail: String, ok: Bool, mode: Mode, focusChanged: Bool) {
        locked {
            _log.append([
                "tool": tool, "detail": detail, "ok": ok,
                "mode": mode.rawValue, "focus_changed": focusChanged,
                "at": Int(Date().timeIntervalSince1970),
            ])
            if _log.count > 200 { _log.removeFirst(_log.count - 200) }
        }
    }

    var snapshot: [String: Any] {
        locked {
            [
                "running": _running,
                "mode": _mode.rawValue,
                "target": _target?.json ?? NSNull(),
                "port": Int(_port),
                "fps": _fps,
                "frames": Int(_frames),
                "agents": _agents.sorted(),
                "frontmost": _frontmost,
                "focus_events": Int(_focusEvents),
                "actions_total": Int(_actionsTotal),
                "permissions": _permissions.json,
                "last_error": _lastError,
                "worker_ready": _workerReady,
                "screen_locked": _screenLocked,
                "started_at": Int(startedAt),
                "log": Array(_log.suffix(40)),
            ]
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

// MARK: - binding

enum SessionError: Error, CustomStringConvertible {
    case failed(String)
    var description: String {
        switch self {
        case .failed(let s): return s
        }
    }
}

enum Session {
    static let boundsRefreshMs: UInt64 = 250

    static func currentTarget(_ shared: Shared) throws -> Target {
        guard let t = shared.target, t.pid != 0 || !t.identity.isEmpty else {
            throw SessionError.failed("no app is bound yet — run {\"tool\":\"bind_app\",\"app\":\"<name>\"} first (GET /windows lists them)")
        }
        return t
    }

    /// Is this a real window an agent can act in?
    ///
    /// Filters two things macOS adds to every app's window list: the accessory
    /// panels it hangs off apps by title, and the untitled full-width strips
    /// (1512x33) that are menu bar or status items but still report layer 0.
    static func isUsableWindow(_ w: Window) -> Bool {
        w.layer == 0 && !isAccessory(w.title) && w.bounds.w >= 120 && w.bounds.h >= 80
    }

    static func isAccessory(_ title: String) -> Bool {
        let t = title.lowercased()
        let exact = ["open", "save", "save as", "print", "page setup", "open…", "save…", "export"]
        return exact.contains(t)
            || t.contains("accessory view")
            || t.contains("save panel")
            || t.contains("open panel")
            || t.contains("toolbar")
            || t.contains("sheet")
    }

    /// Find the window an app selector refers to.
    static func resolveWindow(_ windows: [Window], selector: String) throws -> Window {
        let sel = selector.trimmingCharacters(in: .whitespaces)
        if sel.isEmpty {
            throw SessionError.failed("bind needs an app name, bundle id, pid, or window title")
        }
        if let pid = Int32(sel) {
            if let w = windows.first(where: { $0.pid == pid }) { return w }
            throw SessionError.failed("no window found for pid \(pid)")
        }
        if let w = windows.first(where: { $0.owner.caseInsensitiveCompare(sel) == .orderedSame }) { return w }
        if let w = windows.first(where: { $0.title.caseInsensitiveCompare(sel) == .orderedSame }) { return w }
        let needle = sel.lowercased()
        if let w = windows.first(where: { $0.owner.lowercased().contains(needle) }) { return w }
        var names = Array(Set(windows.map { $0.owner })).sorted()
        names = Array(names.prefix(40))
        throw SessionError.failed("no app matched \"\(sel)\". Running apps: \(names.joined(separator: ", "))")
    }

    static func bind(
        _ helper: Helper,
        _ shared: Shared,
        _ pool: WorkerPool,
        selector: String,
        window: UInt32?,
        owner: String,
        takeover: Bool
    ) throws -> Target {
        let all = helper.windowsList()
        let layer0 = all.filter { $0.layer == 0 && $0.windowId > 0 }

        // Usually the selector names a window. If it names a running app that
        // has no window at all — the normal state right after launch, and the
        // state after every document is closed — bind the app with window 0 and
        // let open_file give it one.
        var pid: Int32 = 0
        var pickedOwner = ""
        var candidates: [Window] = []
        if let picked = try? resolveWindow(layer0, selector: selector) {
            pid = picked.pid
            pickedOwner = picked.owner
            candidates = layer0.filter { $0.pid == pid }
        } else {
            guard let resolved = try? helper.resolve(selector) else {
                _ = try resolveWindow(layer0, selector: selector)   // produce its error
                throw SessionError.failed("no app matched \"\(selector)\"")
            }
            pid = resolved.pid
            pickedOwner = resolved.name
            candidates = layer0.filter { $0.pid == pid }
        }

        let byArea: (Window, Window) -> Bool = { a, b in
            (a.bounds.w * a.bounds.h) < (b.bounds.w * b.bounds.h)
        }
        var chosen: Window?
        if let id = window {
            chosen = candidates.first { $0.windowId == id }
        }
        if chosen == nil {
            chosen = candidates
                .filter { !$0.title.isEmpty && isUsableWindow($0) }
                .max(by: byArea)
        }
        if chosen == nil {
            chosen = candidates.first { isUsableWindow($0) }
        }
        // Never fall back to an accessory window. macOS hangs strips like
        // "Save Panel Accessory View" off apps, and binding one gives an agent a
        // 1428x128 rectangle that is not the app.
        //
        // Binding an app with no window at all is allowed: that is the normal
        // state right after launch, and open_file is how a document gets opened.
        let win = chosen ?? Window(pid: pid, windowId: 0, owner: pickedOwner, title: "",
                                   layer: 0, onScreen: false, bounds: Rect())

        // Identity: prefer the bundle id so a relaunch can be re-bound without
        // matching on pid; fall back to the app name.
        var identity = win.owner
        if let resolved = try? helper.resolve(win.owner), !resolved.bundleId.isEmpty {
            identity = resolved.bundleId
        }

        if let existing = shared.target, existing.identity == identity,
           existing.owner != owner, !owner.isEmpty, !takeover {
            throw SessionError.failed(
                "\(existing.label) is already bound by \"\(existing.owner)\"; pass takeover:true to take it over")
        }

        let target = Target(
            pid: pid, identity: identity, appName: win.owner, windowId: win.windowId,
            windowTitle: win.title, bounds: win.bounds, owner: owner)

        shared.target = target
        shared.noteAgent(owner)
        shared.tree = (try? helper.tree(pid: pid, max: 400)) ?? []
        shared.record(tool: "bind", detail: "bound to \(win.label)", ok: true, mode: shared.mode, focusChanged: false)

        // Give the app its worker now: the first action on it should not pay for
        // a process spawn.
        _ = pool.forApp(identity)
        return target
    }

    /// Re-resolve the bound app after it was quit and relaunched: same identity,
    /// new pid and window. Also refreshes the window rectangle.
    static func rebind(_ helper: Helper, _ shared: Shared) throws -> Target {
        guard let current = shared.target else {
            throw SessionError.failed("nothing to rebind")
        }
        let name = current.appName
        let pid: Int32
        if let resolved = try? helper.resolve(current.identity) {
            pid = resolved.pid
        } else if let resolved = try? helper.resolve(current.appName) {
            pid = resolved.pid
        } else {
            throw SessionError.failed("\(name) is not running")
        }
        let wins = helper.windowsList().filter { $0.layer == 0 }
        let own = wins.filter { $0.pid == pid }

        var chosen = own.first { $0.windowId == current.windowId && isUsableWindow($0) }
        if chosen == nil {
            chosen = own.filter { !$0.title.isEmpty && isUsableWindow($0) }
                .max(by: { ($0.bounds.w * $0.bounds.h) < ($1.bounds.w * $1.bounds.h) })
        }
        if chosen == nil {
            chosen = own.filter { isUsableWindow($0) }
                .max(by: { ($0.bounds.w * $0.bounds.h) < ($1.bounds.w * $1.bounds.h) })
        }
        guard let win = chosen else {
            throw SessionError.failed("\(name) has no document window")
        }
        let updated = Target(
            pid: pid, identity: current.identity, appName: win.owner,
            windowId: win.windowId, windowTitle: win.title, bounds: win.bounds, owner: current.owner)
        shared.target = updated
        shared.boundsRefreshedAt = 0
        return updated
    }

    /// The bound target, refreshed and verified live.
    static func liveTarget(_ shared: Shared, _ helper: Helper, force: Bool) throws -> Target {
        var target = try currentTarget(shared)
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        let due = force || nowMs &- min(nowMs, shared.boundsRefreshedAt) >= boundsRefreshMs
        if target.pid != 0 && !due { return target }

        if let win = refreshBounds(helper, target) {
            target.bounds = win.bounds
            target.windowId = win.windowId
            target.windowTitle = win.title
            shared.boundsRefreshedAt = nowMs
            var fresh = shared.target ?? target
            fresh.bounds = win.bounds
            fresh.windowId = win.windowId
            fresh.windowTitle = win.title
            shared.target = fresh
            return target
        }
        do {
            target = try rebind(helper, shared)
        } catch {
            let appRunning = (try? helper.resolve(target.identity)) != nil
                || (try? helper.resolve(target.appName)) != nil
            if appRunning {
                throw SessionError.failed(
                    "\(target.appName) is running but has no window to act on (\(error)); open a document with open_file, or bind a different window")
            }
            throw SessionError.failed(
                "\(target.appName) is not running (\(error)); relaunch it and the next action will re-bind automatically")
        }
        return target
    }

    static func refreshBounds(_ helper: Helper, _ target: Target) -> Window? {
        guard target.windowId != 0 else { return nil }
        return helper.windowsList().first { $0.windowId == target.windowId }
    }

    static func globalPoint(_ target: Target, _ x: Double, _ y: Double) -> Point {
        (x: target.bounds.x + x, y: target.bounds.y + y)
    }

    /// Focus behaviour, and an honest report of what it did.
    ///
    /// Background mode never calls this. In focused mode the target is raised,
    /// the action runs, and the app the person was using is put back.
    static func withFocus<T>(_ helper: Helper, _ target: Target, _ body: () -> T) -> (T, Bool, Bool) {
        let (beforePid, _) = helper.frontmost()
        if beforePid == target.pid {
            return (body(), false, false)
        }
        var cameForward = (try? helper.activate(pid: target.pid)) != nil
        if !cameForward {
            cameForward = waitForFrontmost(helper, target.pid, ms: 300)
        }
        try? helper.raiseWindow(pid: target.pid)
        let out = body()
        let changed = cameForward && beforePid != 0 && beforePid != target.pid
        var restored = false
        if changed {
            restored = (try? helper.activate(pid: beforePid)) != nil
                || waitForFrontmost(helper, beforePid, ms: 400)
        }
        return (out, changed, restored)
    }

    static func waitForFrontmost(_ helper: Helper, _ pid: Int32, ms: Int) -> Bool {
        let deadline = Date().addingTimeInterval(Double(ms) / 1000.0)
        while Date() < deadline {
            if helper.frontmost().pid == pid { return true }
            usleep(30_000)
        }
        return false
    }
}
