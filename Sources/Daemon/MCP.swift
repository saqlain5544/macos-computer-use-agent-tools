import Foundation

/// The MCP surface: JSON-RPC 2.0 over HTTP, plus a stdio bridge.
///
/// The tool names match the HTTP `tool` field so both surfaces behave
/// identically — one implementation, one set of guarantees.
enum MCP {
    static let protocolVersion = "2025-11-25"
    static let supportedVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05", "2024-10-07"]

    static let instructions = """
    Quiet Driver drives real macOS apps in the background: that is the default and the only mode you can choose, and it is the right one — the app can be frontmost, behind other windows, minimised, on another Space, or hidden, and control goes through Accessibility and per-process events so the person's pointer, focus and window order are never touched. Coordinates are relative to the bound window's top-left corner. Whether an app comes to the front is the person's decision, not yours: never ask them to make it visible so your work is easier, and never suggest focused mode. If they say they want to watch, they can enable Watch in the Quiet Driver dashboard themselves. Each agent has a workspace under /tmp/quiet-driver/agent-<id>/ for screenshots and recordings. op_log and log_stats show what you have done and how long it took. When the driver gets in your way, call log_friction with what went wrong.
    """

    // MARK: tool specs

    private static func point() -> [String: Any] {
        ["type": "object",
         "description": "A point in the bound window's own coordinates, relative to its top-left corner.",
         "properties": ["x": ["type": "number", "description": "x offset"],
                        "y": ["type": "number", "description": "y offset"]],
         "required": ["x", "y"]]
    }

    private static func str(_ d: String) -> [String: Any] { ["type": "string", "description": d] }
    private static func flag(_ description: String) -> [String: Any] {
        ["type": "boolean", "description": description]
    }

    private static func num(_ d: String) -> [String: Any] { ["type": "number", "description": d] }
    private static func bool(_ d: String) -> [String: Any] { ["type": "boolean", "description": d] }
    private static func obj(_ props: [String: Any], _ required: [String]) -> [String: Any] {
        ["type": "object", "properties": props, "required": required, "additionalProperties": false]
    }
    private static var agent: [String: Any] {
        str("Your agent id. Gives you your own workspace for screenshots and recordings, and names you as the owner when binding an app.")
    }

    private struct Spec {
        let name: String
        let description: String
        let schema: () -> [String: Any]
    }

    private static func specs() -> [Spec] {
        [
            Spec(name: "bind_app",
                 description: "Bind to a running app. Every later tool acts on it. Coordinates are relative to its window's top-left corner. The app is never brought forward.",
                 schema: { obj(["app": str("App name, bundle id, pid, or window title"),
                                "agent": agent,
                                "window_id": num("Pick a specific window id"),
                                "takeover": bool("Take the app over from another agent")], ["app"]) }),
            Spec(name: "unbind",
                 description: "Release the bound app. Its worker stops and the next action needs a new bind.",
                 schema: { obj(["agent": agent], []) }),
            Spec(name: "rebind",
                 description: "Re-resolve the bound app after it was quit and relaunched. Actions do this automatically; use it when you want it to happen now.",
                 schema: { obj(["agent": agent], []) }),
            Spec(name: "launch_app",
                 description: "Launch an app in the background, without binding it and without stealing focus.",
                 schema: { obj(["agent": agent, "app": str("App name or bundle id")], ["app"]) }),
            Spec(name: "quit_app",
                 description: "Quit an app by name or bundle id. Refuses rather than discarding unsaved work; pass force only when the person has agreed to lose it.",
                 schema: { obj(["agent": agent, "app": str("App name or bundle id"),
                                "force": bool("Terminate even if the app does not quit on its own (discards unsaved work)")], ["app"]) }),
            Spec(name: "list_windows",
                 description: "Every on-screen window with its app, pid, id, title and bounds, plus the frontmost app.",
                 schema: { obj(["agent": agent], []) }),
            Spec(name: "get_accessibility_tree",
                 description: "The bound app's accessibility tree: roles, titles, descriptions, values, frames. Truncated to 800 nodes.",
                 schema: { obj(["agent": agent], []) }),
            Spec(name: "get_desktop_state",
                 description: "The frontmost app, the bound target and the current mode.",
                 schema: { obj(["agent": agent], []) }),
            Spec(name: "click",
                 description: "Click a point in the bound window. Presses the control under the point when there is one, otherwise delivers a click to the app's own process. Never moves the person's pointer.",
                 schema: { obj(["x": num("x in window coordinates"), "y": num("y in window coordinates"),
                                "agent": agent, "force": flag("send the event even when the window is not on the showing Space")], ["x", "y"]) }),
            Spec(name: "double_click",
                 description: "Double-click a point in the bound window.",
                 schema: { obj(["x": num("x"), "y": num("y"), "agent": agent,
                                "force": flag("send the event even when the window is off the showing Space")], ["x", "y"]) }),
            Spec(name: "right_click",
                 description: "Right-click a point in the bound window.",
                 schema: { obj(["agent": agent, "x": num("x"), "y": num("y")], ["x", "y"]) }),
            Spec(name: "move_cursor",
                 description: "Move the agent's virtual cursor over a point. The person's pointer is untouched.",
                 schema: { obj(["x": num("x"), "y": num("y")], ["x", "y"]) }),
            Spec(name: "mouse_drag",
                 description: "Drag inside the bound window from one point to another.",
                 schema: { obj(["x": num("start x"), "y": num("start y"),
                                "to": point(), "agent": agent], ["x", "y", "to"]) }),
            Spec(name: "scroll",
                 description: "Scroll at a point in the bound window.",
                 schema: { obj(["agent": agent, "x": num("x"), "y": num("y"),
                                "lines": num("Lines to scroll; positive scrolls down")], ["x", "y"]) }),
            Spec(name: "type_text",
                 description: "Type text into the bound app's focused text field, wherever the caret is.",
                 schema: { obj(["text": str("Text to type"), "agent": agent], ["text"]) }),
            Spec(name: "press_key",
                 description: "Press one key in the bound app, e.g. \"Return\" or \"Tab\".",
                 schema: { obj(["agent": agent, "text": str("Key name, e.g. Return")], ["text"]) }),
            Spec(name: "hotkey",
                 description: "Press a key chord in the bound app, e.g. \"cmd+shift+t\".",
                 schema: { obj(["agent": agent, "text": str("Chord, e.g. cmd+shift+t")], ["text"]) }),
            Spec(name: "set_value",
                 description: "Set the bound app's text field to a value directly, rather than typing it.",
                 schema: { obj(["agent": agent, "text": str("New value")], ["text"]) }),
            Spec(name: "set_caret",
                 description: "Move the insertion point in the bound app's text field. location 0 = start, 1 = end, other values are an absolute offset.",
                 schema: { obj(["agent": agent, "location": num("0 = start, 1 = end, else absolute offset"),
                                "length": num("0 = no selection, -1 = to the end")], ["location"]) }),
            Spec(name: "click_label",
                 description: "Press a control in the bound app by its label, e.g. \"Equals\" or \"Save\". Matching is exact first, then case-insensitive, then a unique word subset.",
                 schema: { obj(["agent": agent, "label": str("control label")], ["label"]) }),
            Spec(name: "get_text",
                 description: "Read the bound app's text field.",
                 schema: { obj(["agent": agent], []) }),
            Spec(name: "stage",
             description: "Move the bound window onto a display the driver owns, so mouse clicks and drags can reach it. Use this when a window is on another Space or otherwise not visible: afterwards click, double_click, mouse_drag and scroll work normally, and the person's screen, focus and pointer are not touched. Screenshots and keyboard already work without it. unstage puts the window back.",
             schema: {
                obj(["agent": agent], [])
             }),
        Spec(name: "unstage",
             description: "Put a window staged with stage back where it was.",
             schema: {
                obj(["agent": agent], [])
             }),
        Spec(name: "ocr",
             description: "Read the text on the bound window, with the position of each line. Use this in apps that draw their own UI (design, CAD, canvas, games) where the accessibility tree has nothing: it tells you the labels you can see and where they are, so you can click them. Coordinates are window-relative and ready to pass to click.",
             schema: {
                obj(["agent": agent], [])
             }),
        Spec(name: "screenshot",
                 description: "Capture the bound window to a PNG. Works when the app is background, occluded, minimised, on another Space, or hidden. Saved into your workspace unless you give a path.",
                 schema: { obj(["agent": agent,
                                "path": str("Where to save it; absolute or relative to your workspace")], []) }),
            Spec(name: "record",
                 description: "Record the bound window to a .mov for a few seconds. Works in any window state. Saved into your workspace unless you give a path.",
                 schema: { obj(["seconds": num("how long to record, 0.5 - 60"),
                                "path": str("Where to save it"),
                                "agent": agent], []) }),
            Spec(name: "open_file",
                 description: "Open a document in the bound app without showing a file panel and without stealing focus.",
                 schema: { obj(["agent": agent, "path": str("the file to open")], ["path"]) }),
            Spec(name: "close_file",
                 description: "Close one document of the bound app, leaving the app running.",
                 schema: { obj(["agent": agent, "name": str("the document; defaults to the frontmost one")], []) }),
            Spec(name: "documents",
                 description: "The documents the bound app has open.",
                 schema: { obj(["agent": agent], []) }),
            Spec(name: "log_friction",
                 description: "Record a problem you hit while driving an app, so it can be fixed later.",
                 schema: { obj(["problem": str("what went wrong"),
                                "detail": str("anything that helps reproduce it"),
                                "source_tool": str("which tool you were calling"),
                                "agent": agent], ["problem"]) }),
            Spec(name: "friction_log",
                 description: "Read back the friction points logged so far.",
                 schema: { obj(["agent": agent, "limit": num("how many entries")], []) }),
            Spec(name: "workspace",
                 description: "Your own directory for disposable artefacts, and what is in it.",
                 schema: { obj(["agent": agent], []) }),
            Spec(name: "wait_for",
                 description: "Wait for something to become true in the bound app, instead of polling: a control appearing (label), text arriving in a field, a document opening, a window appearing, or the accessibility tree changing at all. Returns the elapsed time, or explains what it last saw when it times out.",
                 schema: { obj(["agent": agent, 
                    "kind": ["type": "string",
                             "enum": ["label", "text", "document", "window", "change"],
                             "description": "What to wait for"],
                    "label": str("For kind=label: the control label"),
                    "text": str("For kind=text: the value the text field should match"),
                    "name": str("For kind=document or window: the name to look for"),
                    "contains": bool("For kind=text: match a substring instead of the whole value"),
                    "timeout_ms": num("How long to wait, default 5000, max 30000"),
                    "interval_ms": num("How often to check, default 100"),
                 ], ["kind"]) }),
            Spec(name: "op_log",
                 description: "Read the driver's own operation log: what was called, by which agent, how long it took, whether focus moved, and why anything failed.",
                 schema: { obj(["limit": num("how many records, default 100"),
                                "agent_filter": str("only records from this agent"),
                                "tool_filter": str("only records for this tool"),
                                "only_failures": bool("only failed operations"),
                                "since_seconds": num("only records newer than this")], []) }),
            Spec(name: "log_stats",
                 description: "Summary of recent operations: latency percentiles per tool, failure counts, per-agent activity, and how often focus or the pointer moved.",
                 schema: { obj(["since_seconds": num("window, default 3600")], []) }),
            Spec(name: "status",
                 description: "The driver's state: bound target, mode, frontmost app, permissions, counters.",
                 schema: { obj(["agent": agent], []) }),
        ]
    }

    /// Every tool this surface advertises, for tests and for the doctor view.
    static var toolNames: [String] { specs().map { $0.name } }

    // MARK: JSON-RPC

    /// Called for every tool call made over MCP, so those operations land in
    /// the log like the HTTP ones do.
    static var operationObserver: ((String, [String: Any], ActionReport, String) -> Void)?

    static func handleHTTP(_ body: String, shared: Shared, pool: WorkerPool, metrics: Metrics) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return jsonString(errorReply(id: NSNull(), code: -32700, message: "empty body"))
        }
        // A batch stays a batch.
        if trimmed.hasPrefix("["), let data = trimmed.data(using: .utf8),
           let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
            let replies = arr.compactMap { handleMessage($0, shared: shared, pool: pool, metrics: metrics) }
            if replies.isEmpty { return "" }
            return jsonString(replies)
        }
        guard let msg = jsonObject(trimmed) else {
            return jsonString(errorReply(id: NSNull(), code: -32700, message: "parse error"))
        }
        if let reply = handleMessage(msg, shared: shared, pool: pool, metrics: metrics) {
            return jsonString(reply)
        }
        return ""
    }

    static func handleMessage(_ message: [String: Any], shared: Shared, pool: WorkerPool, metrics: Metrics) -> [String: Any]? {
        let method = asString(message["method"]) ?? ""
        let id = message["id"]
        let params = message["params"] as? [String: Any] ?? [:]
        let isNotification = id == nil

        var result: [String: Any]?
        var error: (Int, String)?

        switch method {
        case "initialize":
            let requested = asString(params["protocolVersion"]) ?? ""
            let version = supportedVersions.contains(requested) ? requested : protocolVersion
            result = [
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "quiet-driver", "version": appVersion],
                "instructions": instructions,
            ]
        case "notifications/initialized", "initialized":
            result = [:]
        case "ping":
            result = [:]
        case "tools/list":
            result = ["tools": specs().map { spec in
                ["name": spec.name, "description": spec.description, "inputSchema": spec.schema()]
            }]
        case "resources/list":
            result = ["resources": []]
        case "prompts/list":
            result = ["prompts": []]
        case "tools/call":
            let name = asString(params["name"]) ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            switch callTool(name, args, shared: shared, pool: pool, metrics: metrics) {
            case .success(let v): result = v
            case .failure(let e): error = (e.code, e.message)
            }
        case "":
            error = (-32600, "missing method")
        default:
            error = (-32601, "unknown method: \(method)")
        }

        if isNotification { return nil }
        var reply: [String: Any] = ["jsonrpc": "2.0", "id": id ?? NSNull()]
        if let error = error {
            reply["error"] = ["code": error.0, "message": error.1]
        } else {
            reply["result"] = result ?? [:]
        }
        return reply
    }

    private static func errorReply(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    private struct CallFailure: Error {
        let code: Int
        let message: String
    }

    /// Run one tool and shape the result the way MCP wants it.
    private static func callTool(_ name: String, _ args: [String: Any], shared: Shared, pool: WorkerPool, metrics: Metrics) -> Result<[String: Any], CallFailure> {
        guard specs().contains(where: { $0.name == name }) else {
            return .failure(CallFailure(code: -32602, message: "unknown tool: \(name)"))
        }
        var callMode: Mode?
        if let m = asString(args["mode"]) {
            guard let parsed = Mode.parse(m) else {
                return .failure(CallFailure(code: -32602, message: "mode must be \"background\" or \"focused\""))
            }
            callMode = parsed
        }
        let mode = callMode ?? shared.mode
        // The agent id has to reach the tool: it decides which binding the call
        // acts on and which workspace the artefact lands in. Without it every
        // MCP caller shared one binding, which is exactly the bug the first
        // real-world drive exposed.
        let agent = agentId(args)
        shared.noteAgent(agent)

        let started = Date()
        let report = Tools.execute(tool: name, args: args, callMode: callMode,
                                   shared: shared, pool: pool, mode: mode, agent: agent)
        let micros = Date().timeIntervalSince(started) * 1_000_000
        metrics.record("mcp:" + name, micros: micros, ok: report.ok)
        shared.actionsTotal += 1
        if !report.ok { shared.lastError = report.error }
        var stamped = report
        stamped.phases["total_ms"] = round2(micros / 1000.0)
        operationObserver?(name, args, stamped, agent)

        var text = report.detail
        if !report.error.isEmpty { text = "\(report.error): \(report.detail)" }
        // The data has to be in the text block as well as in structuredContent.
        // Not every client renders structuredContent, and a tool that answers
        // "69 windows" without listing them is a tool the model cannot use —
        // which is exactly how the first real-world drives reported it.
        if let rendered = renderText(name, report.payload), !rendered.isEmpty {
            text += "\n" + rendered
        }
        var content: [[String: Any]] = [["type": "text", "text": text]]
        var payload = report.payload ?? [:]

        // A screenshot becomes an image block so the model can look at it.
        if name == "screenshot", let path = asString(payload["path"]),
           let data = FileManager.default.contents(atPath: path) {
            content.append(["type": "image", "data": data.base64EncodedString(), "mimeType": "image/png"])
        }
        if !report.targetLabel.isEmpty { payload["target"] = report.targetLabel }
        payload["agent"] = agent
        payload["mode"] = report.mode
        payload["real_pointer_moved"] = report.pointerMoved
        payload["focus_changed"] = report.focusChanged

        return .success([
            "content": content,
            "isError": !report.ok,
            "structuredContent": payload,
        ])
    }

    /// Render a tool's payload as text an agent can read.
    ///
    /// Kept compact on purpose: enough to act on, not so much that the reply
    /// swamps the context. Anything longer than this is better fetched with a
    /// filter or a limit.
    private static func renderText(_ tool: String, _ payload: [String: Any]?) -> String? {
        guard let payload = payload else { return nil }
        func line(_ parts: [String?]) -> String {
            parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "  ")
        }
        var rows: [String] = []

        switch tool {
        case "get_text":
            if let v = payload["value"] as? String {
                rows.append("text: \(v.count > 2000 ? String(v.prefix(2000)) + "…" : v)")
            }
        case "list_windows", "get_desktop_state":
            if let wins = payload["windows"] as? [[String: Any]] {
                for w in wins.prefix(40) {
                    let b = w["bounds"] as? [String: Any] ?? [:]
                    rows.append(line([w["app"] as? String,
                                      "id \(w["window_id"] as? Int ?? 0)",
                                      "pid \(w["pid"] as? Int ?? 0)",
                                      "\((b["w"] as? Double ?? 0))x\((b["h"] as? Double ?? 0))",
                                      (w["title"] as? String).map { "\"\($0)\"" }]))
                }
                if wins.count > 40 { rows.append("… and \(wins.count - 40) more") }
            }
            if let f = payload["frontmost"] as? [String: Any] {
                rows.append("frontmost: \(f["name"] as? String ?? "")")
            }
        case "get_accessibility_tree":
            if let nodes = payload["nodes"] as? [[String: Any]] {
                for n in nodes.prefix(120) {
                    let indent = String(repeating: " ", count: min(20, n["depth"] as? Int ?? 0))
                    let role = (n["role"] as? String ?? "").replacingOccurrences(of: "AX", with: "")
                    rows.append(line([indent + role,
                                      (n["title"] as? String).map { "\"\($0)\"" },
                                      (n["description"] as? String).map { "\($0)" },
                                      (n["value"] as? String).map { "= \($0.prefix(60))" }]))
                }
                if nodes.count > 120 {
                    rows.append("… \(nodes.count - 120) more nodes; ask for a smaller app or use click_label")
                }
            }
        case "documents":
            if let docs = payload["documents"] as? [String] {
                rows.append(docs.isEmpty ? "no documents" : docs.joined(separator: " | "))
            }
        case "status":
            if let b = payload["bindings"] as? [[String: Any]], !b.isEmpty {
                rows.append("bindings:")
                for row in b {
                    rows.append(line(["  " + (row["agent"] as? String ?? "?"),
                                      (row["label"] as? String) ?? ""]))
                }
            }
            rows.append(line(["mode", payload["mode"] as? String,
                              "watch", (payload["watch_enabled"] as? Bool) == true ? "on" : "off",
                              "actions", "\(payload["actions_total"] as? Int ?? 0)"]))
        case "bind_app":
            for key in ["window_id", "pid", "identity", "label"] {
                if let v = payload[key] { rows.append("\(key): \(v)") }
            }
            if let others = payload["other_windows"] as? [[String: Any]], !others.isEmpty {
                rows.append("other windows you could bind with window_id:")
                for w in others {
                    rows.append(line(["  id \(w["window_id"] as? Int ?? 0)",
                                      "\(w["w"] as? Double ?? 0)x\(w["h"] as? Double ?? 0)",
                                      (w["title"] as? String).map { "\"\($0)\"" }]))
                }
            }
        case "screenshot":
            if let boxes = payload["text_boxes"] as? [[String: Any]], !boxes.isEmpty {
                rows.append("text on screen (click these coordinates):")
                for b in boxes.prefix(40) {
                    rows.append(line([(b["text"] as? String) ?? "",
                                      "@ \(b["x"] as? Double ?? 0),\(b["y"] as? Double ?? 0)"]))
                }
            }
        case "ocr":
            if let boxes = payload["boxes"] as? [[String: Any]] {
                if boxes.isEmpty { rows.append("no text found") }
                for b in boxes.prefix(60) {
                    rows.append(line([(b["text"] as? String) ?? "",
                                      "@ \(b["x"] as? Double ?? 0),\(b["y"] as? Double ?? 0)",
                                      "\(b["w"] as? Double ?? 0)x\(b["h"] as? Double ?? 0)",
                                      "conf \(b["confidence"] as? Double ?? 0)"]))
                }
            }
        case "workspace":
            if let files = payload["files"] as? [[String: Any]] {
                for f in files.prefix(30) {
                    rows.append("\(f["name"] as? String ?? "")  \(f["bytes"] as? Int ?? 0) bytes")
                }
            }
        case "friction_log":
            if let entries = payload["entries"] as? [[String: Any]] {
                for e in entries.suffix(20) {
                    rows.append(line([e["agent"] as? String,
                                      e["source_tool"] as? String,
                                      (e["problem"] as? String).map { String($0.prefix(100)) }]))
                }
            }
        case "op_log":
            if let entries = payload["entries"] as? [[String: Any]] {
                for e in entries.suffix(40) {
                    rows.append(line([e["ts"] as? String,
                                      e["agent"] as? String,
                                      e["tool"] as? String,
                                      e["ok"] as? Bool == false ? "FAILED" : "ok",
                                      "\(e["duration_ms"] as? Double ?? 0) ms",
                                      (e["error"] as? String).map { String($0.prefix(60)) }]))
                }
            }
        case "log_stats":
            if let tools = payload["tools"] as? [String: [String: Any]] {
                let sorted = tools.sorted { ((($0.value["p99_ms"] as? Double) ?? 0) > (($1.value["p99_ms"] as? Double) ?? 0)) }
                for (name, s) in sorted.prefix(10) {
                    rows.append(line([name, "n \(s["count"] as? Int ?? 0)",
                                      "p50 \(s["p50_ms"] as? Double ?? 0) ms",
                                      "p99 \(s["p99_ms"] as? Double ?? 0) ms"]))
                }
            }
            if let f = payload["failures"] as? [String: Int], !f.isEmpty {
                rows.append("failures:")
                for (reason, n) in f.sorted(by: { $0.value > $1.value }).prefix(6) {
                    rows.append("  \(n)x \(reason)")
                }
            }
        default:
            // Tools whose payload is a short set of scalars: show them as pairs.
            for key in payload.keys.sorted() where key != "path" {
                if let v = payload[key], !(v is [String: Any]), !(v is [Any]) {
                    rows.append("\(key): \(v)")
                }
            }
        }
        return rows.isEmpty ? nil : rows.joined(separator: "\n")
    }

    // MARK: stdio bridge

    static var daemonPortFile: String {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? "/tmp"
        return "\(home)/.quiet-driver/port"
    }

    /// The port the daemon published, if something answers on it.
    static func daemonPort() -> UInt16? {
        guard let text = try? String(contentsOfFile: daemonPortFile, encoding: .utf8),
              let first = text.split(separator: "\n").first,
              let port = UInt16(first.trimmingCharacters(in: .whitespaces)), port != 0 else { return nil }
        // A published port only counts if something answers on it.
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let ok = withUnsafePointer(to: &addr) { ptr -> Bool in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        return ok ? port : nil
    }

    /// Start the driver in the background if it is not already running.
    static func spawnDaemon() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
        p.arguments = ["--headless"]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    /// POST a JSON body to the daemon and return the response body.
    static func postJSON(port: UInt16, path: String, body: String) -> String? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var tv = timeval(tv_sec: 90, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &addr) { ptr -> Bool in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        guard connected else { return nil }
        let request = """
        POST \(path) HTTP/1.1\r
        Host: 127.0.0.1\r
        Content-Type: application/json\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        \(body)
        """
        let data = Data(request.utf8)
        data.withUnsafeBytes { ptr in
            var sent = 0
            while sent < data.count {
                let n = write(fd, ptr.baseAddress!.advanced(by: sent), data.count - sent)
                if n <= 0 { break }
                sent += n
            }
        }
        var raw = Data()
        var buffer = [UInt8](repeating: 0, count: 32 * 1024)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            raw.append(contentsOf: buffer[0..<n])
        }
        guard let sep = raw.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        return String(decoding: raw[sep.upperBound...], as: UTF8.self)
    }

    /// Bridge MCP over stdin/stdout to the running daemon.
    ///
    /// The daemon owns the session, so an agent launched this way shares the
    /// bound app, the focus counters, and the action log with the dashboard.
    /// One message per line in, one message per line out.
    /// Bridge MCP over stdin/stdout to the running daemon.
    ///
    /// Requests are dispatched concurrently, and replies are written as they
    /// arrive. The serial version — read a line, wait for the answer, write it —
    /// meant one slow call (a `wait_for` of thirty seconds, a recording) blocked
    /// every other agent using the same bridge, which is exactly what happened
    /// when three agents drove three apps at once. JSON-RPC replies carry their
    /// own id, so out-of-order replies are correct.
    static func bridgeStdio() -> Int32 {
        var port = daemonPort()
        if port == nil {
            spawnDaemon()
            for _ in 0..<60 {
                usleep(250_000)
                if let p = daemonPort() { port = p; break }
            }
        }
        guard let port = port else {
            FileHandle.standardError.write(Data("quiet-driver: could not reach the driver service\n".utf8))
            return 1
        }

        let writeLock = NSLock()
        let queue = DispatchQueue(label: "quiet-driver.bridge", attributes: .concurrent)
        let group = DispatchGroup()

        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            group.enter()
            queue.async {
                defer { group.leave() }
                // A daemon restart must not kill the agent's session. If the
                // call fails to connect, wait for a daemon to come back (it is
                // usually an upgrade) and retry once, rather than returning
                // nothing and looking like a hang to the harness.
                var reply = postJSON(port: port, path: "/mcp", body: trimmed)
                if reply == nil {
                    for _ in 0..<80 {
                        usleep(250_000)
                        if let fresh = daemonPort() {
                            reply = postJSON(port: fresh, path: "/mcp", body: trimmed)
                            if reply != nil { break }
                        }
                    }
                }
                guard let reply = reply else { return }
                let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, let data = (text + "\n").data(using: .utf8) else { return }
                // One writer at a time: two replies interleaving would corrupt
                // the stream for every reader.
                writeLock.lock()
                FileHandle.standardOutput.write(data)
                writeLock.unlock()
            }
        }
        // Let the in-flight calls finish so their replies are not lost.
        group.wait()
        return 0
    }
}
