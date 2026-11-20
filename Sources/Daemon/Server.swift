import Foundation

/// The control surface: a loopback HTTP server.
///
/// Loopback only, and any request carrying an `Origin` header is refused: a web
/// page must not be able to drive the desktop. There is no authentication
/// because there is no network exposure; the defence is the bind address plus
/// the origin check.
final class Server {
    private let shared: Shared
    private let pool: WorkerPool
    private let metrics: Metrics
    private var listenFd: Int32 = -1
    private let queue = DispatchQueue(label: "quiet-driver.http", attributes: .concurrent)
    private var running = true

    init(shared: Shared, pool: WorkerPool, metrics: Metrics) {
        self.shared = shared
        self.pool = pool
        self.metrics = metrics
    }

    // MARK: lifecycle

    static var portFilePath: String {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? "/tmp"
        return "\(home)/.quiet-driver/port"
    }

    /// Bind, publish the port, and start accepting. Returns the port.
    /// Wire the MCP surface's operations into the log.
    /// A filename-safe form of an agent id, for preview files.
    private func sanitise(_ name: String) -> String {
        String(name.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" })
    }

    func start(preferredPort: UInt16) -> UInt16? {
        MCP.operationObserver = { [weak self] tool, args, report, agent in
            guard let self else { return }
            var stamped = report
            stamped.mode = self.shared.mode.rawValue
            stamped.modeSource = "session"
            stamped.targetLabel = self.shared.effectiveTarget(for: agent)?.label ?? ""
            stamped.phases["total_ms"] = 0
            self.logOperation(tool: tool, args: args, report: stamped, agent: agent)
        }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = preferredPort.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)

        let bound = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            close(fd)
            return nil
        }
        guard listen(fd, 128) == 0 else {
            close(fd)
            return nil
        }
        listenFd = fd

        var actual = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(fd, sa, &len)
            }
        }
        let port = UInt16(bigEndian: actual.sin_port)
        shared.port = port
        publishPort(port)

        queue.async { [weak self] in self?.acceptLoop() }
        return port
    }

    /// Is the published port file still describing this daemon?
    ///
    /// Anything can delete a file in /tmp-adjacent state — a test cleanup, a
    /// reboot helper, another tool tidying "stale" files. When it happens the
    /// daemon keeps running but becomes unreachable, which looks like a crash.
    /// Rewriting it is cheap, so it is checked on the same slow tick as the
    /// permission probe.
    static func portFileIsCurrent(_ port: UInt16) -> Bool {
        guard let text = try? String(contentsOfFile: portFilePath, encoding: .utf8),
              let first = text.split(separator: "\n").first,
              let published = UInt16(first.trimmingCharacters(in: .whitespaces)) else { return false }
        return published == port
    }

    func republishIfMissing() {
        let port = shared.port
        guard port != 0, !Server.portFileIsCurrent(port) else { return }
        publishPort(port)
    }

    private func publishPort(_ port: UInt16) {
        let path = Server.portFilePath
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let text = "\(port)\nhttp://127.0.0.1:\(port)\n\(ProcessInfo.processInfo.processIdentifier)\n"
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    static func withdrawPort(_ port: UInt16) {
        let path = portFilePath
        guard let text = try? String(contentsOfFile: path, encoding: .utf8),
              let first = text.split(separator: "\n").first,
              UInt16(first.trimmingCharacters(in: .whitespaces)) == port else { return }
        try? FileManager.default.removeItem(atPath: path)
    }

    func stop() {
        running = false
        if listenFd >= 0 {
            close(listenFd)
            listenFd = -1
        }
        let port = shared.port
        if port != 0 { Server.withdrawPort(port) }
    }

    private func acceptLoop() {
        while running {
            let client = accept(listenFd, nil, nil)
            if client < 0 {
                if !running { return }
                continue
            }
            queue.async { [weak self] in self?.handleConnection(client) }
        }
    }

    // MARK: request handling

    private func handleConnection(_ fd: Int32) {
        defer { close(fd) }
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var raw = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        var headerEnd = -1
        var contentLength = 0
        var hasOrigin = false
        var method = "GET"
        var target = "/"

        // Read until the headers are complete, then the body.
        while true {
            // Parse what we have so far, so a body read can be sized.
            if headerEnd < 0 {
                if let range = raw.range(of: Data("\r\n\r\n".utf8)) {
                    headerEnd = raw.distance(from: raw.startIndex, to: range.lowerBound)
                }
            }
            if headerEnd >= 0, raw.count >= headerEnd + 4 + contentLength {
                break
            }
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            raw.append(contentsOf: buffer[0..<n])
            if raw.count > (8 << 20) { break }

            if headerEnd < 0, let range = raw.range(of: Data("\r\n\r\n".utf8)) {
                headerEnd = raw.distance(from: raw.startIndex, to: range.lowerBound)
                let head = String(decoding: raw[raw.startIndex..<range.lowerBound], as: UTF8.self)
                let lines = head.components(separatedBy: "\r\n")
                if let first = lines.first {
                    let parts = first.split(separator: " ")
                    if parts.count >= 2 {
                        method = String(parts[0])
                        target = String(parts[1])
                    }
                }
                for line in lines.dropFirst() {
                    guard let colon = line.firstIndex(of: ":") else { continue }
                    let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                    let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    if name == "content-length" { contentLength = Int(value) ?? 0 }
                    if name == "origin" { hasOrigin = true }
                }
            }
        }

        var body = ""
        if headerEnd >= 0, contentLength > 0 {
            let start = raw.index(raw.startIndex, offsetBy: min(raw.count, headerEnd + 4))
            let end = raw.index(start, offsetBy: min(contentLength, raw.distance(from: start, to: raw.endIndex)))
            body = String(decoding: raw[start..<end], as: UTF8.self)
        }
        let (path, query) = splitTarget(target)
        let (status, reply) = route(method: method, path: path, query: query, body: body,
                                    hasOrigin: hasOrigin, agent: "default")
        writeResponse(fd, status: status, body: reply)
    }

    private func splitTarget(_ target: String) -> (String, String) {
        if let q = target.firstIndex(of: "?") {
            return (String(target[target.startIndex..<q]),
                    String(target[target.index(after: q)...]))
        }
        return (target, "")
    }

    private func writeResponse(_ fd: Int32, status: Int, body: String) {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 403: reason = "Forbidden"
        case 404: reason = "Not Found"
        case 405: reason = "Method Not Allowed"
        default: reason = "Internal Server Error"
        }
        let data = Data(body.utf8)
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: application/json; charset=utf-8\r\n"
        head += "Content-Length: \(data.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(data)
        out.withUnsafeBytes { ptr in
            var sent = 0
            while sent < out.count {
                let n = write(fd, ptr.baseAddress!.advanced(by: sent), out.count - sent)
                if n <= 0 { break }
                sent += n
            }
        }
    }

    // MARK: routing

    func route(method: String, path: String, query: String, body: String, hasOrigin: Bool,
               agent: String = "default") -> (Int, String) {
        let helper = Tools.boundHelper(shared, pool)


        if hasOrigin {
            return (403, jsonString([
                "ok": false,
                "error": "cross_origin_refused",
                "message": "requests carrying an Origin header are refused: a web page must not drive the desktop",
            ]))
        }

        switch (method, path) {
        case ("GET", "/"), ("GET", "/health"):
            return (200, jsonString([
                "ok": true,
                "driver": "quiet-driver",
                "version": appVersion,
                "port": Int(shared.port),
                "endpoints": ["/health", "/status", "/observe", "/windows", "/tree", "/action", "/mcp", "/metrics"],
            ]))

        case ("GET", "/status"), ("GET", "/observe"):
            return (200, statusJSON(agent: queryAgent(query)))

        case ("GET", "/windows"):
            let list = helper.windowsList().filter { $0.layer == 0 }
            return (200, jsonString([
                "ok": true,
                "windows": list.map { w in
                    ["app": w.owner, "pid": Int(w.pid), "window_id": Int(w.windowId),
                     "title": w.title, "on_screen": w.onScreen, "bounds": w.bounds.json]
                },
            ]))

        case ("GET", "/tree"):
            guard let t = shared.effectiveTarget(for: queryAgent(query)) else {
                return (200, jsonString(["ok": false, "error": "no app is bound yet"]))
            }
            let nodes = ((try? helper.tree(pid: t.pid, max: 800)) ?? []).filter { $0.worthShowing }
            return (200, jsonString(["ok": true, "target": t.label, "nodes": nodes.map { $0.json }]))

        case ("GET", "/work"):
            // What each agent is driving, and a thumbnail so the person can look
            // without touching the machine's screen. This is the dashboard's
            // work panel.
            var apps: [[String: Any]] = []
            for binding in shared.allBindings() {
                guard let t = shared.effectiveTarget(for: binding.agent) else { continue }
                let preview = "/tmp/quiet-driver/work-\(sanitise(binding.agent)).png"
                var shot: [String: Any] = [:]
                if t.windowId != 0, let s = try? helper.screenshot(windowId: t.windowId,
                                                                  path: preview, native: false) {
                    shot = ["preview": preview, "width": s.w, "height": s.h]
                }
                var row: [String: Any] = [
                    "agent": binding.agent, "label": t.label, "window_id": Int(t.windowId),
                    "staged": t.originalFrame != nil, "work_display": Int(t.workDisplay),
                    "on_screen": t.onScreen,
                    "bounds": ["x": t.bounds.x, "y": t.bounds.y, "w": t.bounds.w, "h": t.bounds.h],
                ]
                row.merge(shot) { a, _ in a }
                apps.append(row)
            }
            let display: [String: Any] = WorkDisplay.shared.displayID != 0
                ? ["id": Int(WorkDisplay.shared.displayID),
                   "bounds": ["x": WorkDisplay.shared.bounds.minX, "y": WorkDisplay.shared.bounds.minY,
                              "w": WorkDisplay.shared.bounds.width, "h": WorkDisplay.shared.bounds.height]]
                : ["id": 0, "error": WorkDisplay.shared.failure ?? "not created"]
            return (200, jsonString(["ok": true, "work_display": display, "apps": apps]))

        case ("GET", "/metrics"):
            return (200, jsonString(metrics.snapshot(actionsTotal: shared.actionsTotal)))
        case ("POST", "/metrics"):
            metrics.reset()
            return (200, jsonString(["ok": true, "detail": "metrics reset"]))

        case ("POST", "/action"):
            return (200, action(body))
        case ("GET", "/action"):
            let merged = mergeQuery(query, body)
            return (200, action(merged))
        case ("POST", "/mcp"):
            return (200, MCP.handleHTTP(body, shared: shared, pool: pool, metrics: metrics))
        case ("GET", "/mcp"):
            return (405, jsonString([
                "ok": false,
                "error": "the MCP endpoint is POST-only for JSON-RPC over HTTP",
            ]))

        case (_, "/"), (_, "/health"), (_, "/status"), (_, "/observe"), (_, "/windows"),
             (_, "/tree"), (_, "/mcp"), (_, "/metrics"), (_, "/action"):
            return (405, jsonString(["ok": false, "error": "method not allowed"]))

        default:
            return (404, jsonString([
                "ok": false, "error": "no such endpoint",
                "endpoints": ["/health", "/status", "/observe", "/windows", "/tree", "/action", "/mcp", "/metrics"],
            ]))
        }
    }

    /// GET /action?tool=click&x=10&y=20 — a query string is merged under the
    /// body, with the body winning where both name a field.
    private func mergeQuery(_ query: String, _ body: String) -> String {
        var merged: [String: Any] = [:]
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard let key = parts.first else { continue }
            let raw = parts.count > 1 ? String(parts[1]) : ""
            let value = raw.removingPercentEncoding ?? raw
            if let n = Int(value) {
                merged[String(key)] = n
            } else if let d = Double(value), value.contains(".") {
                merged[String(key)] = d
            } else {
                merged[String(key)] = value
            }
        }
        if let bodyObj = jsonObject(body) {
            for (k, v) in bodyObj { merged[k] = v }
        }
        return jsonString(merged)
    }

    /// One tool call over HTTP.
    private func action(_ body: String) -> String {
        guard let obj = jsonObject(body) else {
            return jsonString(ActionReport.err("body must be a JSON object").json)
        }
        let tool = asString(obj["tool"]) ?? ""
        return jsonString(actionReport(tool, obj).json)
    }

    /// Run one tool and record what it did.
    ///
    /// The record is the analysis surface: tool, agent, target, mode and where
    /// that mode came from, total time, time spent waiting on the app, time spent
    /// moving focus, whether focus moved and came back, whether the pointer
    /// moved, and the failure reason. One line per operation, forever.
    func actionReport(_ tool: String, _ obj: [String: Any]) -> ActionReport {
        // A per-call mode applies to this call only. set_mode is the only thing
        // that changes the session: one focused call used to leave the whole
        // session focused, so every later plain action activated the target and
        // gave focus back.
        var callMode: Mode?
        if let requested = asString(obj["mode"]), !requested.isEmpty {
            guard let parsed = Mode.parse(requested) else {
                return ActionReport.err("mode must be \"background\" or \"focused\"")
            }
            callMode = parsed
        }
        // A session that is not allowed to watch cannot be in focused mode. This
        // is belt and braces on top of the refusal in set_mode: whatever history
        // left the mode set, the invariant holds on every call.
        if shared.mode == .focused, !shared.watchEnabled {
            shared.mode = .background
        }

        // Per-call focused is refused for the same reason set_mode focused is:
        // the person decides whether an app comes to the front, not the caller.
        if callMode == .focused, !shared.watchEnabled {
            return ActionReport.err(
                "focused mode is not available: whether an app comes to the front is the person's decision. "
                + "Work in background mode, or ask them to enable Watch in the Quiet Driver dashboard.")
        }
        let mode = callMode ?? shared.mode
        shared.noteAgent(agentId(obj))

        if !shared.running, !["resume", "start_driver", "status", "set_mode"].contains(tool) {
            return ActionReport.err("the driver is paused; call resume first")
        }

        let started = Date()
        let agent = agentId(obj)
        let helper = Tools.boundHelper(shared, pool, agent)
        helper.beginOperation()
        let report = Tools.execute(tool: tool, args: obj, callMode: callMode,
                                   shared: shared, pool: pool, mode: mode, agent: agent)
        let micros = Date().timeIntervalSince(started) * 1_000_000
        metrics.record(tool, micros: micros, ok: report.ok)
        let (workerCalls, workerMicros, workerDetail) = helper.operationStats()

        var final = report
        final.mode = callMode?.rawValue ?? shared.mode.rawValue
        final.modeSource = callMode != nil ? "call" : "session"
        final.targetLabel = shared.effectiveTarget(for: agent)?.label ?? ""
        final.phases["total_ms"] = round2(micros / 1000.0)
        final.phases["worker_ms"] = round2(workerMicros / 1000.0)
        final.phases["worker_calls"] = Double(workerCalls)
        // Focus raise and restore happen through worker calls, so they are part
        // of worker_ms already; adding them again would make driver_ms zero and
        // hide the driver's own cost. The focus numbers are a breakdown *within*
        // the worker time, not on top of it.
        final.phases["driver_ms"] = round2(max(0, final.phases["total_ms"]! - final.phases["worker_ms"]!))
        logOperation(tool: tool, args: obj, report: final, agent: agent,
                     workerDetail: workerDetail)
        shared.actionsTotal += 1
        if !final.ok {
            shared.lastError = final.error
        } else {
            shared.lastError = ""
        }
        if final.focusChanged { shared.focusEvents += 1 }
        shared.record(tool: tool, detail: final.ok ? final.detail : final.error,
                      ok: final.ok, mode: mode, focusChanged: final.focusChanged)
        NotificationCenter.default.post(name: .stateChanged, object: nil)
        return final
    }

    /// `?agent=` lets a viewer or a client name whose binding it wants to see.
    private func queryAgent(_ query: String) -> String {
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            if parts.count == 2, parts[0] == "agent" {
                return String(parts[1]).removingPercentEncoding ?? String(parts[1])
            }
        }
        return "default"
    }

    /// Write one operation record to the operation log.
    private func logOperation(tool: String, args obj: [String: Any], report: ActionReport,
                              agent: String, workerDetail: [(String, Double)] = []) {
        guard let log = OpLog.shared else { return }
        var record: [String: Any] = [
            "kind": "op",
            "agent": agent,
            "tool": tool,
            "args": loggableArguments(obj),
            "mode": report.mode,
            "mode_source": report.modeSource,
            "target": report.targetLabel,
            "ok": report.ok,
            "detail": String(report.detail.prefix(300)),
            "duration_ms": report.phases["total_ms"] ?? 0,
            "phases": report.phases,
            "pointer_moved": report.pointerMoved,
            "focus": report.focusDetail.isEmpty
                ? ["changed": report.focusChanged, "restored": report.focusRestored]
                : report.focusDetail,
            "screen_locked": shared.screenLocked,
            "actions_total": shared.actionsTotal,
        ]
        if !report.ok { record["error"] = String(report.error.prefix(300)) }
        // Which worker commands made up the time, in order. A click that made
        // seven calls should say so, or the number is not actionable.
        record["worker_calls"] = workerDetail.map { ["cmd": $0.0, "ms": round2($0.1)] }
        if let payload = report.payload {
            // A small, useful digest rather than the whole payload.
            var digest: [String: Any] = [:]
            for key in ["path", "bytes", "frames", "width", "height", "label", "window", "elapsed_ms"] {
                if let v = payload[key] { digest[key] = v }
            }
            if !digest.isEmpty { record["result"] = digest }
        }
        log.write(record)
    }

    /// Write a non-tool record: daemon lifecycle, worker start/stop, mode and
    /// watch changes. These explain the gaps between operations.
    static func logEvent(_ kind: String, _ fields: [String: Any] = [:], shared: Shared? = nil) {
        guard let log = OpLog.shared else { return }
        var record = fields
        record["kind"] = kind
        record["ok"] = true
        if let s = shared {
            record["mode"] = s.mode.rawValue
            record["watch_enabled"] = s.watchEnabled
        }
        log.write(record)
    }

    private func statusJSON(agent: String = "default") -> String {
        var snap = shared.snapshot
        snap["target"] = shared.effectiveTarget(for: agent)?.json ?? NSNull()
        snap["ok"] = true
        snap["permissions"] = shared.permissions.json
        snap["uptime_seconds"] = Int(shared.uptime)
        return jsonString(snap)
    }
}

let appVersion = "0.2.0-swift"

extension Notification.Name {
    static let showDashboard = Notification.Name("quiet-driver.show-dashboard")
    static let stateChanged = Notification.Name("quiet-driver.state-changed")
}
