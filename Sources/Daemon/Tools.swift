import Foundation

func agentId(_ obj: [String: Any]) -> String {
    if let a = asString(obj["agent"]), !a.isEmpty { return a }
    return "default"
}

func num(_ obj: [String: Any], _ key: String) -> Double? {
    asDouble(obj[key])
}

func textOf(_ obj: [String: Any]) -> String {
    if let t = asString(obj["text"]) { return t }
    if let v = asString(obj["value"]) { return v }
    return ""
}

/// What one tool call did, including what it is allowed to claim.
///
/// One implementation serves both the HTTP surface and MCP: the same guarantees
/// have to hold however an agent reaches it.
enum Tools {
    static let names: [String] = [
        "bind_app", "bind", "rebind", "launch_app", "launch", "quit_app", "unbind",
        "list_windows", "get_desktop_state", "get_window_state", "get_accessibility_tree",
        "click", "double_click", "right_click", "move_cursor", "move", "mouse_drag", "scroll",
        "type_text", "type", "press_key", "key", "hotkey", "set_value", "set_caret",
        "click_label", "press_button", "get_text", "set_mode", "pause", "resume",
        "stop_driver", "start_driver", "status", "show_dashboard", "clipboard_read",
        "clipboard_write", "screenshot", "record", "log_friction", "friction_log",
        "workspace", "open_file", "close_file", "documents", "wait_for",
        "op_log", "log_stats", "set_watch",
    ]

    // MARK: worker selection

    /// The worker for whatever is currently bound, or the session worker when
    /// nothing is. Called once per request, so a rebind between actions is
    /// picked up without extra bookkeeping.
    static func boundHelper(_ shared: Shared, _ pool: WorkerPool, _ agent: String = "default") -> Helper {
        if let t = shared.effectiveTarget(for: agent), !t.identity.isEmpty { return pool.forApp(t.identity) }
        return pool.session()
    }

    /// Tools that change the binding or produce a file, rather than acting on the
    /// app. Kept as data because the dispatcher and the self-tests must agree on
    /// it: a name that is listed but not routed falls through to "unknown tool".
    static let sessionTools: Set<String> = [
        "show_dashboard", "start_driver", "resume", "stop_driver", "pause", "set_mode",
        "status", "list_windows", "get_desktop_state", "bind_app", "bind", "rebind",
        "launch_app", "launch", "quit_app", "unbind", "get_window_state",
        "get_accessibility_tree", "screenshot", "record", "open_file", "close_file",
        "documents", "log_friction", "friction_log", "workspace", "wait_for",
        "op_log", "log_stats", "set_watch",
    ]

    /// Every name the dispatcher can reach.
    static var routedNames: Set<String> { sessionTools.union(Set(names).subtracting(sessionTools)) }

    // MARK: entry

    static func execute(
        tool: String,
        args: [String: Any],
        callMode: Mode?,
        shared: Shared,
        pool: WorkerPool,
        mode: Mode,
        agent: String = "default"
    ) -> ActionReport {
        let helper = boundHelper(shared, pool, agent)
        return run(tool: tool, args: args, mode: mode, shared: shared, helper: helper,
                   pool: pool, agent: agent)
    }

    // MARK: dispatcher

    static func run(
        tool: String,
        args obj: [String: Any],
        mode: Mode,
        shared: Shared,
        helper: Helper,
        pool: WorkerPool,
        agent: String = "default"
    ) -> ActionReport {
        guard names.contains(tool) else {
            return ActionReport.err(
                "unknown tool \"\(tool)\". Tools: bind_app, list_windows, get_accessibility_tree, click, type_text, press_key, click_label, screenshot, set_mode, pause, resume")
        }
        var report: ActionReport

        if sessionTools.contains(tool) {
            report = sessionAndArtifactTool(tool, obj, shared, helper, pool, agent)
        } else {
            report = actingTool(tool, obj, mode, shared, helper, agent)
        }
        return report
    }

    // MARK: session / artifact tools
    //
    // These are the calls that change the binding or produce a file. They are
    // kept apart from the tools that act on the app so the focus guard is
    // applied in exactly one place.

    private static func sessionAndArtifactTool(
        _ tool: String,
        _ obj: [String: Any],
        _ shared: Shared,
        _ helper: Helper,
        _ pool: WorkerPool,
        _ agent: String
    ) -> ActionReport {
        switch tool {
        case "show_dashboard":
            // The daemon may be headless, so a dashboard is a separate viewer
            // process. One is enough: if one is already up, raise it instead of
            // piling up windows that all show the same state.
            if let existing = DashboardViewer.runningInstance() {
                existing.activate(options: [.activateAllWindows])
                return ActionReport.ok("dashboard focused")
            }
            do {
                try DashboardViewer.start()
                return ActionReport.ok("dashboard opened")
            } catch {
                return ActionReport.err("could not open the dashboard: \(error.localizedDescription)")
            }

        case "start_driver", "resume":
            shared.running = true
            return ActionReport.ok("driver resumed")

        case "stop_driver", "pause":
            shared.running = false
            return ActionReport.ok("driver paused; actions are refused until resume")

        case "set_mode":
            guard let m = Mode.parse(asString(obj["mode"])) else {
                return ActionReport.err("mode must be \"background\" or \"focused\"")
            }
            // Background is the default and the only mode an agent may choose.
            // Watching an app is the person's decision, so focused mode needs
            // their consent, not the agent's preference.
            if m == .focused, !shared.watchEnabled {
                return ActionReport.err(
                    "focused mode is not available: whether an app comes to the front is the person's decision. "
                    + "Work in background mode; ask them to enable Watch in the Quiet Driver dashboard if they want to see it.")
            }
            shared.mode = m
            Server.logEvent("mode", ["to": m.rawValue], shared: shared)
            return ActionReport.ok("mode is now \(m.rawValue)")

        case "set_watch":
            // Operator control: the dashboard's Watch toggle and the CLI use it.
            // It is deliberately absent from the MCP surface.
            let enabled = asBool(obj["enabled"]) ?? asBool(obj["watch"]) ?? false
            shared.watchEnabled = enabled
            if !enabled, shared.mode == .focused {
                shared.mode = .background
            }
            Server.logEvent("watch", ["enabled": enabled], shared: shared)
            return ActionReport.ok(enabled
                ? "watching enabled: focused mode is now allowed"
                : "watching disabled; mode is background")

        case "status":
            // Reading state never needs a binding: an agent asks for status
            // before it has bound anything, and over MCP that is usually the
            // first call it makes.
            var snap = shared.snapshot
            let mine = shared.effectiveTarget(for: agent)
            snap["target"] = mine?.json ?? NSNull()
            snap["bindings"] = shared.bindings
            var r = ActionReport.ok("\(mine?.label ?? "nothing bound") · mode \(shared.mode.rawValue) · \(shared.actionsTotal) actions")
            snap["frontmost"] = shared.frontmost
            r.payload = snap
            return r

        case "list_windows", "get_desktop_state":
            let wins = helper.windowsList().filter { $0.layer == 0 }
            let front = helper.frontmost()
            var r = ActionReport.ok("\(wins.count) windows; frontmost \(front.name)")
            r.payload = [
                "frontmost": ["pid": Int(front.pid), "name": front.name],
                "windows": wins.map { w in
                    ["app": w.owner, "pid": Int(w.pid), "window_id": Int(w.windowId),
                     "title": w.title, "on_screen": w.onScreen, "bounds": w.bounds.json]
                },
            ]
            return r

        case "bind_app", "bind":
            var selector = asString(obj["app"]) ?? asString(obj["bundle_id"]) ?? asString(obj["name"]) ?? ""
            if selector.isEmpty, let n = asInt(obj["pid"]) { selector = String(n) }
            if selector.isEmpty { selector = textOf(obj) }
            let window = asInt(obj["window_id"]).flatMap { UInt32(exactly: $0) }
            let owner = agent.isEmpty ? "default" : agent
            let takeover = asBool(obj["takeover"]) ?? false
            // The binding that this agent held before, not the session's: with
            // per-agent bindings a session-wide lookup leaves a worker behind
            // for every app an agent hops through.
            let previous = shared.effectiveTarget(for: agent)?.identity
            do {
                let t = try Session.bind(helper, shared, pool, selector: selector,
                                         window: window, owner: owner, takeover: takeover)
                // Reap the old app's worker, but only if no other agent still
                // holds that app.
                if let prev = previous, prev != t.identity,
                   shared.owner(ofIdentity: prev, excluding: agent) == nil {
                    pool.release(prev)
                }
                _ = pool.forApp(t.identity)
                let label = t.windowId == 0
                    ? "bound to \(t.appName) as \"\(t.owner)\" (no window yet — use open_file to open a document)"
                    : "bound to \(t.label) as \"\(t.owner)\""
                var r = ActionReport.ok(label)
                r.payload = t.json
                return r
            } catch {
                return ActionReport.err("\(error)")
            }

        case "rebind":
            do {
                let t = try Session.rebind(helper, shared, agent)
                var r = ActionReport.ok("re-bound to \(t.label) (pid \(t.pid))")
                r.payload = t.json
                return r
            } catch {
                return ActionReport.err("\(error)")
            }

        case "launch_app", "launch":
            let name = asString(obj["app"]) ?? asString(obj["bundle_id"]) ?? ""
            if name.isEmpty { return ActionReport.err("launch_app needs an \"app\" name or bundle id") }
            do {
                let (pid, launched) = try helper.launch(name)
                var r = ActionReport.ok("launched \(launched) in the background" + (pid != 0 ? " (pid \(pid))" : ""))
                r.payload = ["app": launched, "pid": Int(pid)]
                return r
            } catch {
                return ActionReport.err("\(error)")
            }

        case "quit_app":
            let name = asString(obj["app"]) ?? asString(obj["bundle_id"]) ?? ""
            if name.isEmpty { return ActionReport.err("quit_app needs an \"app\" name or bundle id") }
            let wasBound = shared.effectiveTarget(for: agent).map {
                $0.identity.caseInsensitiveCompare(name) == .orderedSame
                    || $0.appName.caseInsensitiveCompare(name) == .orderedSame
            } ?? false
            let force = asBool(obj["force"]) ?? false
            do {
                let n = try helper.quitApp(name, force: force)
                if wasBound, var t = shared.effectiveTarget(for: agent) {
                    t.pid = 0
                    t.windowId = 0
                    shared.setTarget(t, for: shared.bindingKey(for: agent))
                }
                return ActionReport.ok("quit \(n)")
            } catch {
                if wasBound, var t = shared.effectiveTarget(for: agent) {
                    t.pid = 0
                    t.windowId = 0
                    shared.setTarget(t, for: shared.bindingKey(for: agent))
                }
                return ActionReport.err("\(error)")
            }

        case "unbind":
            // Only this agent's binding goes: another agent may hold the same
            // app, and its worker must survive.
            let released = shared.releaseTarget(for: agent)
            shared.tree = []
            if let id = released, shared.owner(ofIdentity: id, excluding: agent) == nil {
                pool.release(id)
            }
            return ActionReport.ok("unbound")

        case "get_window_state", "get_accessibility_tree":
            do {
                let t = try Session.currentTarget(shared, agent)
                let nodes = ((try? helper.tree(pid: t.pid, max: 800)) ?? []).filter { $0.worthShowing }
                shared.tree = nodes
                var r = ActionReport.ok("\(nodes.count) accessibility nodes from \(t.label)")
                r.payload = ["nodes": nodes.map { $0.json }]
                return r
            } catch {
                return ActionReport.err("\(error)")
            }

        case "screenshot":
            let t: Target
            do { t = try Session.liveTarget(shared, helper, force: true, agent) }
            catch { return ActionReport.err("\(error)") }
            let agent = agentId(obj)
            let path: String
            do {
                path = try Workspace.resolveOutput(agent, "screenshot", "png", requested: asString(obj["path"]))
            } catch { return ActionReport.err("\(error)") }

            // A window the window server still lists but that is already closed
            // cannot be captured; that ghost clears within a frame or two, so
            // re-resolve and retry rather than reporting the capture tool's
            // error, which tells an agent nothing.
            var captured = t.windowId
            var attempt = Result { try helper.screenshot(windowId: captured, path: path) }
            for _ in 0..<3 {
                if case .success = attempt { break }
                usleep(150_000)
                guard let fresh = Session.rebindExcluding(shared, helper, badWindowId: captured, agent) else {
                    return ActionReport.err(noWindowReason(helper, t, "no window to capture"))
                }
                captured = fresh.windowId
                attempt = Result { try helper.screenshot(windowId: captured, path: path) }
            }
            if case .failure(let why) = attempt {
                // Every retry failed. Say what that means for the caller rather
                // than repeating the capture tool's error, which reads like a
                // driver bug.
                let hasWindow = helper.windowsList().contains {
                    $0.pid == t.pid && Session.isUsableWindow($0)
                }
                return ActionReport.err(hasWindow
                    ? "\(t.label) could not be captured (\(why)); its window may be closing — bind again or open a document"
                    : noWindowReason(helper, t, "\(why)"))
            }
            switch attempt {
            case .success(let shot):
                var r = ActionReport.ok("captured \(shot.w)x\(shot.h) of \(t.label) (\(shot.bytes) bytes) to \(path)")
                r.payload = ["path": path, "width": shot.w, "height": shot.h,
                             "bytes": shot.bytes, "window": t.label]
                return r
            case .failure(let e):
                return ActionReport.err("\(e)")
            }

        case "record":
            let t: Target
            do { t = try Session.liveTarget(shared, helper, force: true, agent) }
            catch { return ActionReport.err("\(error)") }
            let agent = agentId(obj)
            let path: String
            do {
                path = try Workspace.resolveOutput(agent, "recording", "mov", requested: asString(obj["path"]))
            } catch { return ActionReport.err("\(error)") }
            let seconds = min(60.0, max(0.5, num(obj, "seconds") ?? 3.0))
            let attempt = Result { try helper.record(pid: t.pid, seconds: seconds, path: path) }
            switch attempt {
            case .success(let v):
                let frames = asInt(v["frames"]) ?? 0
                let bytes = asInt(v["bytes"]) ?? 0
                let w = asInt(v["width"]) ?? 0
                let h = asInt(v["height"]) ?? 0
                var r = ActionReport.ok("recorded \(frames) frames of \(t.label) (\(w)x\(h)) to \(path)")
                r.payload = ["path": path, "frames": frames, "bytes": bytes,
                             "seconds": seconds, "width": w, "height": h]
                return r
            case .failure(let e):
                return ActionReport.err("\(e)")
            }

        case "open_file":
            let t: Target
            do { t = try Session.currentTarget(shared, agent) } catch { return ActionReport.err("\(error)") }
            let path = asString(obj["path"]) ?? ""
            if path.trimmingCharacters(in: .whitespaces).isEmpty {
                return ActionReport.err("open_file needs a \"path\"")
            }
            let app = asString(obj["app"]) ?? t.appName
            do {
                try helper.openFile(app: app, path: path)
                var r = ActionReport.ok("opened \(path) in \(app) (no panel, no focus change)")
                r.payload = ["path": path, "app": app]
                return r
            } catch { return ActionReport.err("\(error)") }

        case "close_file":
            let t: Target
            do { t = try Session.liveTarget(shared, helper, force: true, agent) }
            catch { return ActionReport.err("\(error)") }
            var name = asString(obj["name"]) ?? ""
            if name.trimmingCharacters(in: .whitespaces).isEmpty {
                name = helper.documents(pid: t.pid).first ?? ""
            }
            if name.isEmpty { return ActionReport.err("no document to close") }
            let closedWasBound = t.windowId != 0
                && (t.windowTitle == name || t.windowTitle.isEmpty)
            do {
                let closed = try helper.closeFile(pid: t.pid, name: name)
                if closedWasBound, var cur = shared.effectiveTarget(for: agent) {
                    cur.windowId = 0
                    cur.windowTitle = ""
                    cur.bounds = Rect()
                    shared.setTarget(cur, for: shared.bindingKey(for: agent))
                    shared.boundsRefreshedAt = 0
                }
                var r = ActionReport.ok("closed \(closed)")
                r.payload = ["closed": closed]
                return r
            } catch { return ActionReport.err("\(error)") }

        case "documents":
            let t: Target
            do { t = try Session.liveTarget(shared, helper, force: true, agent) }
            catch { return ActionReport.err("\(error)") }
            let docs = helper.documents(pid: t.pid)
            var r = ActionReport.ok("\(docs.count) open document(s)")
            r.payload = ["documents": docs]
            return r

        case "log_friction":
            let agent = agentId(obj)
            let problem = asString(obj["problem"]) ?? asString(obj["text"]) ?? ""
            if problem.trimmingCharacters(in: .whitespaces).isEmpty {
                return ActionReport.err("log_friction needs a \"problem\" describing what went wrong")
            }
            let entry: [String: Any] = [
                "at": Int(Date().timeIntervalSince1970),
                "agent": agent,
                "source_tool": asString(obj["source_tool"]) ?? asString(obj["related_tool"]) ?? "",
                "problem": problem,
                "detail": asString(obj["detail"]) ?? "",
                "target": shared.target?.label ?? "",
                "mode": shared.mode.rawValue,
            ]
            do {
                let path = try Workspace.logFriction(entry)
                var r = ActionReport.ok("logged a friction point to \(path)")
                r.payload = entry
                return r
            } catch { return ActionReport.err("\(error)") }

        case "friction_log":
            let limit = max(1, asInt(obj["limit"]) ?? 50)
            let entries = Workspace.readFriction(limit: limit)
            var r = ActionReport.ok("\(entries.count) friction entries logged")
            r.payload = ["entries": entries, "path": Workspace.frictionLogPath]
            return r

        case "wait_for":
            return waitFor(obj, shared, helper, agent)

        case "op_log":
            // The driver's own history, for an agent that wants to see what it
            // (or another agent) has been doing, and for whoever is analysing.
            guard let log = OpLog.shared else {
                return ActionReport.err("the operation log is disabled (QD_OP_LOG=0)")
            }
            let limit = min(1000, max(1, asInt(obj["limit"]) ?? 100))
            let rows = log.read(limit: limit,
                                agent: asString(obj["agent_filter"]),
                                tool: asString(obj["tool_filter"]),
                                onlyFailures: asBool(obj["only_failures"]) ?? false,
                                sinceSeconds: asInt(obj["since_seconds"]))
            var r = ActionReport.ok("\(rows.count) operation record(s)")
            r.payload = ["entries": rows, "log_directory": log.directory]
            return r

        case "log_stats":
            guard let log = OpLog.shared else {
                return ActionReport.err("the operation log is disabled (QD_OP_LOG=0)")
            }
            let seconds = max(10, asInt(obj["since_seconds"]) ?? 3600)
            var r = ActionReport.ok("operation summary over the last \(seconds)s")
            r.payload = log.summary(sinceSeconds: seconds)
            return r

        case "workspace":
            let agent = agentId(obj)
            do {
                let dir = try Workspace.ensureAgentDir(agent)
                var r = ActionReport.ok("workspace \(dir)")
                r.payload = ["dir": dir, "files": Workspace.listFiles(agent),
                             "friction_log": Workspace.frictionLogPath]
                return r
            } catch { return ActionReport.err("\(error)") }

        default:
            return ActionReport.err("unknown tool \"\(tool)\"")
        }
    }

    /// Wait for something to become true, on the driver's side.
    ///
    /// An agent that has to poll does one round trip per check and picks its own
    /// backoff; doing it here is one call and a steady interval. The condition
    /// kinds are the ones that actually come up: a control appearing (a button
    /// that enables when work finishes), text arriving in a field, a document
    /// opening, a window appearing, or the tree changing at all.
    private static func waitFor(_ obj: [String: Any], _ shared: Shared, _ helper: Helper,
                               _ agent: String = "default") -> ActionReport {
        let kind = (asString(obj["kind"]) ?? asString(obj["for"]) ?? "").lowercased()
        let timeoutMs = min(30_000, max(50, asInt(obj["timeout_ms"]) ?? 5_000))
        let intervalMs = min(1_000, max(20, asInt(obj["interval_ms"]) ?? 100))
        let wanted = asString(obj["label"]) ?? asString(obj["text"]) ?? asString(obj["value"])
            ?? asString(obj["name"]) ?? ""
        let contains = asBool(obj["contains"]) ?? false

        if kind.isEmpty {
            return ActionReport.err("wait_for needs a \"kind\": label, text, document, window, or change")
        }
        let target: Target
        do { target = try Session.liveTarget(shared, helper, force: false, agent) }
        catch { return ActionReport.err("\(error)") }

        let started = Date()
        let deadline = started.addingTimeInterval(Double(timeoutMs) / 1000.0)
        var lastSeen = ""
        var baseline = ""

        if kind == "change" {
            guard let sig = try? helper.treeSignature(pid: target.pid), !sig.isEmpty else {
                return ActionReport.err("could not read the accessibility tree to watch for a change")
            }
            baseline = sig
        }

        while true {
            switch kind {
            case "label":
                if wanted.isEmpty { return ActionReport.err("wait_for kind=\"label\" needs a \"label\"") }
                if let present = try? helper.hasLabel(pid: target.pid, label: wanted), present {
                    return waitReport("\"\(wanted)\" appeared", started, target)
                }
                lastSeen = "no control labelled \"\(wanted)\""
            case "text", "value":
                guard let current = try? helper.textField(pid: target.pid) else {
                    lastSeen = "no text field"
                    break
                }
                let matched = contains ? current.contains(wanted) : current == wanted
                if matched { return waitReport("the text field became \"\(wanted)\"", started, target) }
                lastSeen = "text field is \"\(current.prefix(80))\""
            case "document":
                if wanted.isEmpty { return ActionReport.err("wait_for kind=\"document\" needs a \"name\"") }
                let docs = helper.documents(pid: target.pid)
                if docs.contains(where: { $0.localizedCaseInsensitiveContains(wanted) }) {
                    return waitReport("document \"\(wanted)\" opened", started, target)
                }
                lastSeen = "documents: \(docs.isEmpty ? "none" : docs.joined(separator: ", "))"
            case "window":
                if wanted.isEmpty { return ActionReport.err("wait_for kind=\"window\" needs a \"name\"") }
                let wins = helper.windowsList().filter {
                    $0.pid == target.pid && Session.isUsableWindow($0)
                }
                if wins.contains(where: { $0.title.localizedCaseInsensitiveContains(wanted) }) {
                    return waitReport("window \"\(wanted)\" appeared", started, target)
                }
                lastSeen = "\(wins.count) window(s), none matching \"\(wanted)\""
            case "change":
                if let sig = try? helper.treeSignature(pid: target.pid), !sig.isEmpty, sig != baseline {
                    return waitReport("the accessibility tree changed", started, target)
                }
                lastSeen = "the tree has not changed"
            default:
                return ActionReport.err(
                    "wait_for kind must be label, text, document, window, or change (got \"\(kind)\")")
            }
            if Date() >= deadline {
                return ActionReport.err(
                    "waited \(timeoutMs) ms for \(kind) and gave up: \(lastSeen)")
            }
            usleep(UInt32(intervalMs) * 1000)
        }
    }

    private static func waitReport(_ what: String, _ started: Date, _ target: Target) -> ActionReport {
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        var r = ActionReport.ok("\(what) after \(elapsed) ms in \(target.label)")
        r.payload = ["elapsed_ms": elapsed, "window": target.label]
        return r
    }

    private static func noWindowReason(_ helper: Helper, _ t: Target, _ cause: String) -> String {
        let running = (try? helper.resolve(t.identity)) != nil || (try? helper.resolve(t.appName)) != nil
        if running {
            return "\(t.appName) is running but has no document window (\(cause)); open one with open_file, or bind a different window"
        }
        return "\(t.appName) is not running (\(cause)); relaunch it and the next action will re-bind"
    }

    // MARK: tools that act on the bound app

    private static func actingTool(
        _ tool: String,
        _ obj: [String: Any],
        _ mode: Mode,
        _ shared: Shared,
        _ helper: Helper,
        _ agent: String
    ) -> ActionReport {
        let target: Target
        do { target = try Session.liveTarget(shared, helper, force: false, agent) }
        catch { return ActionReport.err("\(error)") }

        func inWindow(_ x: Double, _ y: Double) -> String? {
            if x >= 0, y >= 0, x <= target.bounds.w, y <= target.bounds.h { return nil }
            return "point (\(x), \(y)) is outside the bound window (\(target.bounds.w)x\(target.bounds.h)); coordinates are relative to the window's top-left corner"
        }

        /// Fold a focus outcome into the report: flags the caller promises, the
        /// per-phase timings the log needs, and the app names either side.
        func applyFocus(_ out: ActionReport, _ o: Session.FocusOutcome) -> ActionReport {
            var r = out
            r.focusChanged = o.changed
            r.focusRestored = o.restored
            r.phases["focus_raise_ms"] = round2(o.raiseMs)
            r.phases["focus_restore_ms"] = round2(o.restoreMs)
            r.focusDetail = [
                "changed": o.changed,
                "restored": o.restored,
                "before_app": o.beforeApp,
                "after_app": o.afterApp,
                "raise_ms": round2(o.raiseMs),
                "restore_ms": round2(o.restoreMs),
                "restore_attempts": o.restoreAttempts,
            ]
            return r
        }

        // Every delivered action runs through here so focused mode raises the
        // target for the duration and puts the person's app back afterwards.
        func deliver(_ body: () -> ActionReport) -> ActionReport {
            if mode == .focused {
                let (r, outcome) = Session.withFocus(helper, target, body)
                return applyFocus(r, outcome)
            }
            return body()
        }

        switch tool {
        case "click", "double_click", "right_click", "move_cursor", "move", "mouse_drag", "scroll":
            let x = num(obj, "x") ?? 0
            let y = num(obj, "y") ?? 0
            if let bad = inWindow(x, y) { return ActionReport.err(bad) }
            let before = helper.pointerNow()
            let g = (x: target.bounds.x + x, y: target.bounds.y + y)

            // AX first: pressing the element under the point works even when the
            // window is on another Space or fully occluded.
            let hit = try? helper.elementAt(pid: target.pid, x: g.x, y: g.y)
            if let h = hit {
                if tool == "move" || tool == "move_cursor" {
                    var r = ActionReport.ok("hovering \(h.role) \"\(h.label)\" at (\(x), \(y)) — pointer and focus untouched")
                    r.pointerMoved = helper.pointerMoved(since: before)
                    return r
                }
                if h.canPress, tool != "right_click", tool != "mouse_drag", tool != "scroll" {
                    let press = { () -> Result<Hit, Error> in
                        Result { try helper.pressAt(pid: target.pid, x: g.x, y: g.y) }
                    }
                    var focusOutcome: Session.FocusOutcome?
                    var result: Result<Hit, Error>
                    if mode == .focused {
                        let (res, outcome) = Session.withFocus(helper, target) { press() }
                        result = res
                        focusOutcome = outcome
                    } else {
                        result = press()
                    }
                    var r: ActionReport
                    switch result {
                    case .success(var pressed):
                        if pressed.rect.w == 0 { pressed.rect = h.rect }
                        r = ActionReport.ok(
                            "\(tool == "double_click" ? "double-pressed" : "pressed") \(pressed.role) \"\(pressed.label)\" at (\(x), \(y)) in \(target.label)")
                        r.payload = ["role": pressed.role, "label": pressed.label,
                                     "frame": pressed.rect.json,
                                     "window_local": ["x": x, "y": y]]
                    case .failure(let e):
                        r = ActionReport.err("AXPress at (\(x), \(y)) failed: \(e)")
                    }
                    if let outcome = focusOutcome { r = applyFocus(r, outcome) }
                    r.pointerMoved = helper.pointerMoved(since: before)
                    return r
                }
            }

            let how: String
            switch tool {
            case "double_click": how = "double"
            case "right_click": how = "right"
            case "move", "move_cursor": how = "move"
            default: how = "click"
            }
            let start = helper.pointerNow()
            let action = { () -> Result<(), Error> in
                Result {
                    switch tool {
                    case "mouse_drag":
                        let to = obj["to"] as? [String: Any]
                        let tx = to.flatMap { num($0, "x") } ?? x
                        let ty = to.flatMap { num($0, "y") } ?? y
                        try helper.drag(pid: target.pid, from: g,
                                        to: (target.bounds.x + tx, target.bounds.y + ty))
                    case "scroll":
                        try helper.scroll(pid: target.pid, x: g.x, y: g.y,
                                          lines: Int(num(obj, "lines") ?? 3))
                    default:
                        try helper.click(pid: target.pid, x: g.x, y: g.y, how: how)
                    }
                }
            }
            var r: ActionReport
            if mode == .focused {
                let (res, outcome) = Session.withFocus(helper, target) { action() }
                switch res {
                case .success:
                    r = ActionReport.ok("\(tool) delivered to \(target.label) at (\(x), \(y))")
                case .failure(let e):
                    r = ActionReport.err("\(e)")
                }
                r = applyFocus(r, outcome)
            } else {
                switch action() {
                case .success:
                    r = ActionReport.ok("\(tool) delivered to \(target.label) at (\(x), \(y)) via CGEventPostToPid")
                case .failure(let e):
                    r = ActionReport.err("\(e)")
                }
            }
            r.pointerMoved = helper.pointerMoved(since: start)
            return r

        case "type_text", "type":
            let content = textOf(obj)
            if content.isEmpty { return ActionReport.err("type_text needs a non-empty \"text\" field") }
            let before = helper.pointerNow()
            let pid = target.pid
            let typed = deliver {
                do {
                    let n = try helper.typeText(pid: pid, text: content)
                    let after = (try? helper.textField(pid: pid)) ?? ""
                    return ActionReport.ok("typed \(n) characters into \(target.label); its text field now holds \(after.count) characters")
                } catch { return ActionReport.err("typing failed: \(error)") }
            }
            var r = typed
            r.pointerMoved = helper.pointerMoved(since: before)
            return r

        case "press_key", "key", "hotkey":
            let spec = textOf(obj)
            if spec.isEmpty {
                return ActionReport.err("press_key/hotkey needs a \"text\" field, e.g. \"Return\" or \"cmd+shift+t\"")
            }
            let pid = target.pid
            return deliver {
                do {
                    try helper.key(pid: pid, chord: spec)
                    return ActionReport.ok("sent \(spec) to \(target.label)")
                } catch { return ActionReport.err("\(error)") }
            }

        case "set_value":
            let content = asString(obj["text"]) ?? asString(obj["value"]) ?? ""
            let pid = target.pid
            return deliver {
                do {
                    try helper.setValue(pid: pid, value: content)
                    return ActionReport.ok("set the text field of \(target.label) to \(content.count) characters")
                } catch { return ActionReport.err("\(error)") }
            }

        case "set_caret":
            let location = asInt(obj["location"]) ?? 0
            let length = asInt(obj["length"]) ?? 0
            let pid = target.pid
            return deliver {
                do {
                    let out = try helper.setCaret(pid: pid, location: location, length: length)
                    return ActionReport.ok("moved the insertion point in \(target.label) to \(out.location) (\(out.length) selected)")
                } catch { return ActionReport.err("\(error)") }
            }

        case "click_label", "press_button":
            let label = asString(obj["label"]) ?? ""
            if label.isEmpty { return ActionReport.err("click_label needs a \"label\" field") }
            let pid = target.pid
            let bounds = target.bounds
            return deliver {
                do {
                    let out = try helper.pressLabel(pid: pid, label: label)
                    var r = ActionReport.ok("pressed \"\(out.name)\" in \(target.label)")
                    r.payload = ["label": out.name, "frame": out.rect.json]
                    return r
                } catch { return ActionReport.err("\(error)") }
            }

        case "get_text":
            let pid = target.pid
            return deliver {
                do {
                    let v = try helper.textField(pid: pid)
                    var r = ActionReport.ok("\(v.count) characters in the text field")
                    r.payload = ["value": v]
                    return r
                } catch { return ActionReport.err("\(error)") }
            }

        case "clipboard_read", "clipboard_write":
            return ActionReport.err(
                "\(tool) is not implemented: the clipboard belongs to the person, not the agent")

        default:
            return ActionReport.err("unknown tool \"\(tool)\"")
        }
    }
}
