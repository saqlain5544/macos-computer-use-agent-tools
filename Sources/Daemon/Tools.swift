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
        "clipboard_write", "screenshot", "ocr", "record", "log_friction", "friction_log",
        "workspace", "open_file", "close_file", "documents", "wait_for", "stage", "unstage",
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
        "get_accessibility_tree", "screenshot", "ocr", "record", "open_file", "close_file", "stage", "unstage",
        "documents", "log_friction", "friction_log", "workspace", "wait_for",
        "op_log", "log_stats", "set_watch",
    ]

    /// Every name the dispatcher can reach.
    static var routedNames: Set<String> { sessionTools.union(Set(names).subtracting(sessionTools)) }

    // MARK: entry

    /// Mouse events are routed by the window server's hit testing, which only
    /// sees windows on the Space that is showing. A window on another Space never
    /// receives them, while accessibility actions and *keyboard* events posted to
    /// the process do (both measured). Saying so is better than returning "click
    /// delivered" while nothing happens.
    static func offScreenReason(_ target: Target, _ tool: String) -> String? {
        guard !target.onScreen else { return nil }
        return "\(target.label) is not on the current Space, so a raw \(tool) cannot reach it: "
            + "the window server hit-tests only windows that are showing. Accessibility actions "
            + "(click_label, set_value, press_key, get_accessibility_tree) and typing do work there. "
            + "To drive this app by mouse, it has to be on the current Space — the person can show it, "
            + "or enable watching so the driver may bring it forward. Pass force:true to send it anyway."
    }

    /// Put the target's window on the driver's own display so the window server
    /// will route mouse events to it. Returns a note for the reply, or nil if
    /// staging was not possible.
    static func autoStage(_ target: inout Target, shared: Shared, helper: Helper, agent: String) -> String? {
        guard target.windowId != 0 else { return nil }
        let size = CGSize(width: target.bounds.w, height: target.bounds.h)
        let staged = WorkDisplay.shared.stage(identity: target.identity, windowId: target.windowId,
                                              size: size, helper: helper, pid: target.pid)
        guard staged.error == nil else { return nil }
        let original = Rect(x: target.bounds.x, y: target.bounds.y, w: target.bounds.w, h: target.bounds.h)
        var fresh = shared.effectiveTarget(for: agent) ?? target
        fresh.originalFrame = original
        fresh.wasFullscreen = staged.wasFullscreen
        fresh.bounds = Rect(x: staged.frame.origin.x, y: staged.frame.origin.y,
                            w: staged.frame.width, h: staged.frame.height)
        fresh.onScreen = true
        fresh.workDisplay = WorkDisplay.shared.displayID
        WorkDisplay.shared.note(identity: target.identity, agent: agent, label: target.label)
        shared.setTarget(fresh, for: shared.bindingKey(for: agent))
        target = fresh
        return " (the window was off the showing Space, so it was staged on the driver's own display to make the click reach it; unstage puts it back)"
    }

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
                var notes: [String] = []
                if !t.onScreen {
                    notes.append("this window is not on the current Space, so clicks and drags cannot "
                                 + "reach it; click_label and other accessibility actions still work, "
                                 + "and screenshots work too")
                }
                var payload = t.json
                let others = shared.otherWindows
                if !others.isEmpty {
                    payload["other_windows"] = others
                    notes.append("the app has \(others.count + 1) windows; pass window_id to choose another")
                }
                var r = ActionReport.ok(notes.isEmpty ? label : label + " — " + notes.joined(separator: "; "))
                r.payload = payload
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

        case "unbind", "unbind_app":
            // Put a staged window back before letting go of it: leaving an app
            // parked on the driver's display would be a surprise to the person
            // who later looks at that app.
            if let t = shared.effectiveTarget(for: agent), let original = t.originalFrame {
                _ = WorkDisplay.shared.restore(windowId: t.windowId, pid: t.pid,
                                               frame: original.cgRect, helper: helper,
                                               fullscreen: t.wasFullscreen)
                WorkDisplay.shared.forget(identity: t.identity)
            }
            // Only this agent's binding goes: another agent may hold the same
            // app, and its worker must survive.
            let released = shared.releaseTarget(for: agent)
            shared.tree = []
            if let id = released, shared.owner(ofIdentity: id, excluding: agent) == nil {
                pool.release(id)
            }
            return ActionReport.ok("unbound")

        case "stage":
            // Give this window a display of its own, so the window server will
            // route mouse events to it. The person's screen, Space and pointer
            // are untouched: a virtual display has no physical output.
            let t: Target
            do { t = try Session.liveTarget(shared, helper, force: true, agent) }
            catch { return ActionReport.err("\(error)") }
            guard t.windowId != 0 else { return ActionReport.err("nothing to stage: no window") }
            if t.onScreen {
                return ActionReport.ok("\(t.label) is already on the person's display, so it needs no staging. "
                    + "A mouse action still needs the app to be active: with watching on the driver takes the "
                    + "front for the action and puts it back; with watching off it cannot.")
            }
            let size = CGSize(width: t.bounds.w, height: t.bounds.h)
            let staged = WorkDisplay.shared.stage(identity: t.identity, windowId: t.windowId,
                                                  size: size, helper: helper, pid: t.pid)
            // Verify with the window server rather than the attempt, and give it a
            // moment: a window that just moved to another display reports
            // off-screen until the display server has processed the move.
            var live: Window? = nil
            if staged.error == nil {
                for pass in 0..<2 {
                    for _ in 0..<30 {
                        live = helper.windowsList().first { $0.windowId == t.windowId }
                        if live?.onScreen == true { break }
                        usleep(50_000)
                    }
                    if live?.onScreen == true { break }
                    // A window that was already sitting at the work display's
                    // coordinates before the display existed does not register as
                    // on-screen. Nudge it so the window server re-homes it.
                    if pass == 0 {
                        _ = WorkDisplay.shared.stage(identity: t.identity, windowId: t.windowId,
                                                     size: CGSize(width: t.bounds.w, height: t.bounds.h),
                                                     helper: helper, pid: t.pid)
                    }
                }
                if let live = live, !live.onScreen {
                    // Put it back rather than leaving the app somewhere odd.
                    _ = WorkDisplay.shared.restore(windowId: t.windowId, pid: t.pid,
                                                   frame: t.bounds.cgRect, helper: helper,
                                                   fullscreen: t.wasFullscreen)
                    WorkDisplay.shared.forget(identity: t.identity)
                    return ActionReport.err("could not stage \(t.label): the window moved but the window server still reports it off screen")
                }
            }
            guard let error = staged.error.map({ $0 }) else {
                var fresh = shared.effectiveTarget(for: agent) ?? t
                fresh.originalFrame = Rect(x: t.bounds.x, y: t.bounds.y, w: t.bounds.w, h: t.bounds.h)
                fresh.wasFullscreen = staged.wasFullscreen
                fresh.bounds = Rect(x: staged.frame.origin.x, y: staged.frame.origin.y,
                                    w: staged.frame.width, h: staged.frame.height)
                fresh.onScreen = true
                shared.setTarget(fresh, for: shared.bindingKey(for: agent))
                var r = ActionReport.ok("staged \(t.label) on the driver's work display: it is now clickable, and the person's screen is unchanged")
                fresh.workDisplay = t.workDisplay != 0 ? t.workDisplay : WorkDisplay.shared.displayID
                WorkDisplay.shared.note(identity: t.identity, agent: agent, label: t.label)
                shared.setTarget(fresh, for: shared.bindingKey(for: agent))
                r.payload = ["display": Int(fresh.workDisplay),
                             "frame": ["x": staged.frame.origin.x, "y": staged.frame.origin.y,
                                       "w": staged.frame.width, "h": staged.frame.height],
                             "original": fresh.originalFrame.map { ["x": $0.x, "y": $0.y, "w": $0.w, "h": $0.h] } ?? [:]]
                return r
            }
            return ActionReport.err("could not stage \(t.label): \(error)")

        case "unstage":
            let t: Target
            do { t = try Session.liveTarget(shared, helper, force: false, agent) }
            catch { return ActionReport.err("\(error)") }
            guard let original = t.originalFrame else {
                return ActionReport.ok("\(t.label) was not staged by the driver")
            }
            let ok = WorkDisplay.shared.restore(windowId: t.windowId, pid: t.pid, frame: original.cgRect,
                                                helper: helper, fullscreen: t.wasFullscreen)
            WorkDisplay.shared.forget(identity: t.identity)
            var fresh = shared.effectiveTarget(for: agent) ?? t
            fresh.originalFrame = nil
            fresh.wasFullscreen = false
            fresh.workDisplay = 0
            fresh.bounds = original
            shared.setTarget(fresh, for: shared.bindingKey(for: agent))
            return ActionReport.ok(ok
                ? "put \(t.label) back where it was"
                : "\(t.label) could not be moved back; it is still at its current position")

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
            // A window the window server still lists but that is already closed
            // cannot be captured. Alternate between retrying the same window (a
            // ghost clears within a frame or two) and resolving a different one;
            // give up with what actually failed rather than claiming there is no
            // window, which sends an agent looking for the wrong problem.
            var current = t.windowId
            var switched = ""
            var lastError = ""
            var shot: (w: Int, h: Int, bytes: Int, scale: Double)?
            for attempt in 0..<4 {
                if attempt > 0 { usleep(150_000) }
                // Only replace a window that no longer exists. Capturing a
                // different window than the caller is bound to would make every
                // coordinate measured from the picture wrong, silently.
                if attempt > 0,
                   !helper.windowsList().contains(where: { $0.windowId == current }),
                   let fresh = Session.rebindExcluding(shared, helper, badWindowId: current, agent) {
                    current = fresh.windowId
                    switched = " (the bound window had gone; captured \(fresh.label) instead)"
                }
                do {
                    shot = try helper.screenshot(windowId: current, path: path,
                                             native: asBool(obj["native"]) ?? false)
                    break
                } catch {
                    lastError = "\(error)"
                }
            }
            if let shot = shot {
                var r = ActionReport.ok("captured \(shot.w)x\(shot.h) of \(t.label) (\(shot.bytes) bytes) to \(path)")
                r.payload = ["path": path, "width": shot.w, "height": shot.h,
                             "bytes": shot.bytes, "window": t.label,
                             "point_size": true, "native_scale": shot.scale]

                // Canvas apps draw their whole UI: a design tool reports a
                // handful of accessibility nodes for the entire screen, so a
                // picture on its own leaves an agent with no names and no
                // coordinates. Read the text too, and say where it is. This
                // costs ~200 ms and only for apps that give us nothing.
                let nodes = ((try? helper.tree(pid: t.pid, max: 60)) ?? []).count
                if nodes < 20, let read = try? helper.ocr(windowId: current), !read.boxes.isEmpty {
                    r.payload?["text"] = read.lines
                    r.payload?["text_boxes"] = read.boxes
                    r.detail += " · read \(read.count) text line(s) from the pixels (this app exposes only \(nodes) controls)"
                }
                if !switched.isEmpty { r.detail = r.detail.replacingOccurrences(of: " to \(path)", with: " to \(path)") + switched }
                return r
            }
            // Every retry failed. Say what that means for the caller rather than
            // repeating the capture tool's error, which reads like a driver bug.
            let hasWindow = helper.windowsList().contains {
                $0.pid == t.pid && Session.isUsableWindow($0)
            }
            return ActionReport.err(hasWindow
                ? "\(t.label) could not be captured (\(lastError)); its window may be closing — bind again or open a document"
                : noWindowReason(helper, t, lastError))

        case "ocr":
            // Read what is on screen as text. The route into canvas apps: a
            // design or CAD tool draws its whole UI, so accessibility has
            // nothing and screenshots give an agent pixels but no names.
            let t: Target
            do { t = try Session.liveTarget(shared, helper, force: false, agent) }
            catch { return ActionReport.err("\(error)") }
            do {
                let read = try helper.ocr(windowId: t.windowId)
                var r = ActionReport.ok("read \(read.count) line(s) of text from \(t.label)")
                if read.lines.isEmpty {
                    r = ActionReport.ok("no text found on \(t.label) — the window may be blank or all graphic")
                }
                r.payload = ["lines": read.lines, "boxes": read.boxes, "count": read.count]
                return r
            } catch {
                return ActionReport.err("\(error)")
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
        var target: Target
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

            // Off the showing Space? Give the window a display of its own and
            // carry on. The person's screen is untouched, and the alternative is
            // a mouse tool that cannot work for the rest of the session.
            var stagedNote = ""
            if mode == .background, !(asBool(obj["force"]) ?? false), !target.onScreen {
                if let staged = autoStage(&target, shared: shared, helper: helper, agent: agent) {
                    stagedNote = staged
                } else if !shared.watchEnabled {
                    // Neither a display of its own nor permission to bring the
                    // app forward: the click genuinely cannot reach it.
                    if let reason = offScreenReason(target, tool) {
                        return ActionReport.err(reason)
                    }
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
