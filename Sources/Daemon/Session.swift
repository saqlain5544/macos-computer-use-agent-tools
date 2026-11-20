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
    /// One binding per agent. Two agents on two apps must not clobber each
    /// other, which is exactly what a single session-wide binding did.
    private var _targets: [String: Target] = [:]
    /// The most recently bound agent. An agent-less client (a curl, a simple
    /// script, the dashboard) means "the app I am working with", which is the
    /// last one bound rather than whatever happens to be at a fixed key.
    private var _lastBound: String?
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
    /// Whether the person has allowed the driver to bring an app forward.
    ///
    /// Background is the default and the only mode an agent can ask for. Seeing
    /// an app being driven is the person's choice, so focused mode is gated on
    /// this, and only the dashboard, the CLI flag or `set_watch` can turn it on.
    private var _watchEnabled = false
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

    /// The default agent's binding. Tools never use this: they pass their own
    /// agent id, because an agent's binding is its own.
    var target: Target? {
        get { locked { _targets["default"] } }
        set { locked { _targets["default"] = newValue } }
    }

    func target(for agent: String) -> Target? {
        let key = agent.isEmpty ? "default" : agent
        return locked { _targets[key] }
    }

    /// The binding a call should act on.
    ///
    /// Exact match first. If the caller named no agent (or an agent that has not
    /// bound anything) and exactly one binding exists, use it: that is what a
    /// single-agent client means, and it is what every simple HTTP call looks
    /// like. With two bindings there is no safe guess, so the answer is nothing.
    /// How many distinct agents hold a binding right now.
    var bindingCount: Int { locked { _targets.count } }

    func effectiveTarget(for agent: String) -> Target? {
        let key = agent.isEmpty ? "default" : agent
        // An unnamed caller means "the app I just bound" — but only while that is
        // unambiguous. Three real-world agents sharing one daemon proved the
        // danger: a caller that forgot its id silently acted on whichever app was
        // bound last, which was another agent's. With more than one binding, no
        // guess is safe, and the honest answer is to say so.
        if agent.isEmpty || key == "default" {
            return locked {
                if _targets.count > 1 { return nil }
                if let last = _lastBound, let t = _targets[last] { return t }
                return _targets[key]
            }
        }
        return locked { _targets[key] }
    }

    func setTarget(_ target: Target?, for agent: String) {
        let key = agent.isEmpty ? "default" : agent
        locked {
            if let t = target {
                _targets[key] = t
                _lastBound = key
            } else {
                _targets.removeValue(forKey: key)
                if _lastBound == key { _lastBound = _targets.keys.sorted().first }
            }
        }
    }

    /// Every binding, as data for /status and the dashboard.
    var bindings: [[String: Any]] {
        locked {
            _targets.map { agent, t in
                var row = t.json
                row["agent"] = agent
                return row
            }.sorted { ($0["agent"] as? String ?? "") < ($1["agent"] as? String ?? "") }
        }
    }

    /// The key a call should write its refreshed binding back to: the caller's
    /// own if it has one, otherwise the single binding it fell back to.
    func bindingKey(for agent: String) -> String {
        let key = agent.isEmpty ? "default" : agent
        // Writes go back where the read came from, which for an unnamed caller is
        // the most recent binding rather than a "default" slot.
        if agent.isEmpty || key == "default" {
            return locked {
                if let last = _lastBound, _targets[last] != nil { return last }
                return key
            }
        }
        return locked { _targets[key] != nil ? key : key }
    }

    /// Does any agent other than `agent` hold this app?
    func owner(ofIdentity identity: String, excluding agent: String) -> String? {
        let key = agent.isEmpty ? "default" : agent
        return locked {
            _targets.first { $0.key != key && $0.value.identity == identity }?.key
        }
    }

    /// Drop a binding and report the app whose worker can now be released, if no
    /// other agent still holds it.
    func releaseTarget(for agent: String) -> String? {
        let key = agent.isEmpty ? "default" : agent
        return locked {
            guard let removed = _targets.removeValue(forKey: key) else { return nil }
            let stillHeld = _targets.values.contains { $0.identity == removed.identity }
            return stillHeld ? nil : removed.identity
        }
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

    var watchEnabled: Bool {
        get { locked { _watchEnabled } }
        set { locked { _watchEnabled = newValue } }
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
                "target": _targets["default"]?.json ?? NSNull(),
                "bindings": _targets.map { agent, t -> [String: Any] in
                    var row = t.json
                    row["agent"] = agent
                    return row
                }.sorted { ($0["agent"] as? String ?? "") < ($1["agent"] as? String ?? "") },
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
                "watch_enabled": _watchEnabled,
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

    static func currentTarget(_ shared: Shared, _ agent: String = "default") throws -> Target {
        guard let t = shared.effectiveTarget(for: agent), t.pid != 0 || !t.identity.isEmpty else {
            let count = shared.bindingCount
            if count > 1 {
                throw SessionError.failed(
                    "\(count) agents have apps bound, so this call cannot guess which app you mean: "
                    + "pass your own agent id on every call (the one you used with bind_app)")
            }
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

        // Ownership is per app across agents: binding an app someone else holds
        // is refused unless the caller takes it over, and taking it over means
        // the other agent's binding is dropped.
        if let holder = shared.owner(ofIdentity: identity, excluding: owner) {
            if !takeover {
                let label = shared.target(for: holder)?.label ?? identity
                throw SessionError.failed(
                    "\(label) is already bound by \"\(holder)\"; pass takeover:true to take it over")
            }
            shared.setTarget(nil, for: holder)
        }

        let target = Target(
            pid: pid, identity: identity, appName: win.owner, windowId: win.windowId,
            windowTitle: win.title, bounds: win.bounds, owner: owner)

        shared.setTarget(target, for: owner)
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
    static func rebind(_ helper: Helper, _ shared: Shared, _ agent: String = "default") throws -> Target {
        let key = shared.bindingKey(for: agent)
        guard let current = shared.effectiveTarget(for: agent) else {
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
        shared.setTarget(updated, for: agent)
        shared.boundsRefreshedAt = 0
        return updated
    }

    /// Re-resolve to a window of the bound app other than one that is known bad.
    ///
    /// A closed window can linger in the window server's list for a moment, so a
    /// plain rebind happily hands back the same dead id and a capture fails
    /// again. Excluding the window that just failed is what breaks that loop.
    static func rebindExcluding(_ shared: Shared, _ helper: Helper, badWindowId: UInt32,
                                _ agent: String = "default") -> Target? {
        let key = shared.bindingKey(for: agent)
        guard let current = shared.effectiveTarget(for: agent) else { return nil }
        let pid: Int32
        if let resolved = try? helper.resolve(current.identity) {
            pid = resolved.pid
        } else if let resolved = try? helper.resolve(current.appName) {
            pid = resolved.pid
        } else {
            return nil
        }
        let candidates = helper.windowsList()
            .filter { $0.pid == pid && isUsableWindow($0) && $0.windowId != badWindowId }
        guard let win = candidates.max(by: { ($0.bounds.w * $0.bounds.h) < ($1.bounds.w * $1.bounds.h) }) else {
            return nil
        }
        let updated = Target(pid: pid, identity: current.identity, appName: win.owner,
                             windowId: win.windowId, windowTitle: win.title,
                             bounds: win.bounds, owner: current.owner)
        shared.setTarget(updated, for: key)
        shared.boundsRefreshedAt = 0
        return updated
    }

    /// The bound target, refreshed and verified live.
    static func liveTarget(_ shared: Shared, _ helper: Helper, force: Bool,
                           _ agent: String = "default") throws -> Target {
        var target = try currentTarget(shared, agent)
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        let due = force || nowMs &- min(nowMs, shared.boundsRefreshedAt) >= boundsRefreshMs
        if target.pid != 0 && !due { return target }

        if let win = refreshBounds(helper, target) {
            target.bounds = win.bounds
            target.windowId = win.windowId
            target.windowTitle = win.title
            shared.boundsRefreshedAt = nowMs
            var fresh = shared.effectiveTarget(for: agent) ?? target
            fresh.bounds = win.bounds
            fresh.windowId = win.windowId
            fresh.windowTitle = win.title
            shared.setTarget(fresh, for: shared.bindingKey(for: agent))
            return target
        }
        do {
            target = try rebind(helper, shared, agent)
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

    /// What the focus guard did, and what it cost.
    struct FocusOutcome {
        var changed = false
        var restored = false
        var beforeApp = ""
        var beforePid: Int32 = 0
        var afterApp = ""
        var raiseMs = 0.0
        var restoreMs = 0.0
        var restoreAttempts = 0
    }

    /// Focus behaviour, and an honest report of what it did.
    ///
    /// Background mode never calls this. In focused mode the target is raised,
    /// the action runs, and the app the person was using is put back.
    static func withFocus<T>(_ helper: Helper, _ target: Target, _ body: () -> T) -> (T, FocusOutcome) {
        var outcome = FocusOutcome()
        let (beforePid, beforeName) = helper.frontmost()
        outcome.beforePid = beforePid
        outcome.beforeApp = beforeName

        if beforePid == target.pid {
            return (body(), outcome)
        }

        let raiseStarted = Date()
        var cameForward = (try? helper.activate(pid: target.pid)) != nil
        if !cameForward {
            cameForward = waitForFrontmost(helper, target.pid, ms: 300)
        }
        try? helper.raiseWindow(pid: target.pid)
        outcome.raiseMs = Date().timeIntervalSince(raiseStarted) * 1000

        let out = body()
        outcome.changed = cameForward && beforePid != 0 && beforePid != target.pid

        // Put the person's app back, and verify rather than assume.
        //
        // Activation is a request, not a command: a busy app, a freshly raised
        // window, or a modal sheet can swallow the first one. The driver's whole
        // promise is that the person ends up where they started, so this retries
        // and checks the frontmost app instead of trusting the call's return.
        if outcome.changed {
            let restoreStarted = Date()
            for attempt in 0..<3 {
                outcome.restoreAttempts = attempt + 1
                if (try? helper.activate(pid: beforePid)) != nil,
                   waitForFrontmost(helper, beforePid, ms: 300) {
                    outcome.restored = true
                    break
                }
                if attempt < 2 { usleep(120_000) }
            }
            outcome.restoreMs = Date().timeIntervalSince(restoreStarted) * 1000
        }
        let (_, afterName) = helper.frontmost()
        outcome.afterApp = afterName
        return (out, outcome)
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
