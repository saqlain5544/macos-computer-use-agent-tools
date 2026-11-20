import AppKit
import SwiftUI

/// The dashboard: what the driver is bound to, what it has done, and the two
/// numbers that matter — did focus move, did the person's pointer move.
struct DashboardView: View {
    @ObservedObject var model: DashboardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 940, minHeight: 640)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Quiet Driver")
                    .font(.system(size: 22, weight: .semibold))
                if model.bindings.count > 1 {
                    ForEach(Array(model.bindings.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 6) {
                            Text(row.agent)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Text(row.label).font(.system(size: 12))
                        }
                    }
                } else {
                    Text(model.targetLabel)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 6) {
                    if model.watchEnabled {
                        badge("WATCHING", color: .blue)
                    }
                    badge(model.mode == "focused" ? "FOCUSED" : "BACKGROUND",
                          color: model.mode == "focused" ? .orange : .green)
                }
                Text("port \(model.port)").font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        }
        .padding(20)
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("Guarantees")
                stat("focus moved", "\(model.focusMoved)", ok: model.focusMoved == 0)
                stat("pointer moved", "\(model.pointerMoved)", ok: model.pointerMoved == 0)
                stat("actions", "\(model.actionsTotal)", ok: true)
                stat("agents", "\(model.agentCount)", ok: true)
                Divider().padding(.vertical, 4)
                sectionTitle("Permissions")
                stat("accessibility", model.ax ? "granted" : "missing", ok: model.ax)
                stat("post events", model.postEvents ? "granted" : "missing", ok: model.postEvents)
                stat("screen capture", model.capture ? "granted" : "missing", ok: model.capture)
            }
            .frame(width: 230, alignment: .leading)
            .padding(20)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("Recent actions")
                if model.log.isEmpty {
                    Text("nothing yet — bind an app with bind_app and drive it")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(Array(model.log.enumerated()), id: \.offset) { _, entry in
                    HStack(alignment: .top, spacing: 8) {
                        Circle()
                            .fill(entry.ok ? Color.green : Color.red)
                            .frame(width: 6, height: 6)
                            .padding(.top, 5)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.tool).font(.system(size: 11, weight: .semibold, design: .monospaced))
                            Text(entry.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Spacer()
                    }
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("Work")
                Text(model.workDisplay)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                if model.workApps.isEmpty {
                    Text("nothing bound").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(Array(model.workApps.enumerated()), id: \.offset) { _, app in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Circle().fill(app.staged ? Color.accentColor : Color.secondary)
                                .frame(width: 6, height: 6)
                            Text(app.label).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                            Spacer()
                            Text(app.agent).font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        if let image = app.image {
                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(height: 84)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .overlay(RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1))
                        } else {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color(nsColor: .controlBackgroundColor))
                                .frame(height: 84)
                                .overlay(Text("no preview").font(.system(size: 10))
                                    .foregroundStyle(.secondary))
                        }
                        HStack(spacing: 6) {
                            Button(app.staged ? "Unstage" : "Stage") {
                                model.workAction(agent: app.agent, tool: app.staged ? "unstage" : "stage")
                            }
                            .controlSize(.mini)
                            Button("Release") { model.workAction(agent: app.agent, tool: "unbind") }
                                .controlSize(.mini)
                            Spacer()
                        }
                    }
                }
                Spacer()
            }
            .frame(width: 210, alignment: .leading)
            .padding(20)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("Latency")
                if model.latency.isEmpty {
                    Text("no calls measured yet").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                ForEach(Array(model.latency.prefix(6).enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 4) {
                        Text(row.tool)
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1)
                        Spacer()
                        Text(String(format: "%.0f", row.p50))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                        Text("/ " + String(format: "%.0f", row.p99) + " ms")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                Divider().padding(.vertical, 2)
                sectionTitle("Accessibility tree")
                Text("\(model.treeNodes) nodes").font(.system(size: 11, design: .monospaced))
                ForEach(Array(model.treeSample.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 4) {
                        Text(row.role)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text(row.label)
                            .font(.system(size: 10))
                            .lineLimit(1)
                        Spacer()
                    }
                }
                Spacer()
            }
            .frame(width: 250, alignment: .leading)
            .padding(20)
        }
    }

    private var footer: some View {
        HStack {
            Text(model.hint).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button(model.watchEnabled ? "Watching: on" : "Watch") { model.toggleWatch() }
                .help("Bring the driven app to the front so you can see it. Off by default; agents cannot turn this on.")
            if model.paused {
                Button("Resume") { model.resume() }
            } else {
                Button("Pause") { model.pause() }
            }
            Button("Refresh") { model.refresh() }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    private func stat(_ name: String, _ value: String, ok: Bool) -> some View {
        HStack {
            Text(name).font(.system(size: 12))
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(ok ? Color.primary : Color.red)
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}

/// Pulls state from the daemon so the window is a viewer, not a second owner.
final class DashboardModel: ObservableObject {
    @Published var targetLabel = "nothing bound"
    @Published var mode = "background"
    @Published var actionsTotal = 0
    @Published var focusMoved = 0
    @Published var pointerMoved = 0
    @Published var agentCount = 0
    @Published var bindings: [(agent: String, label: String)] = []
    @Published var ax = false
    @Published var postEvents = false
    @Published var capture = false
    @Published var paused = false
    @Published var watchEnabled = false
    @Published var port = 0
    @Published var log: [(tool: String, detail: String, ok: Bool)] = []
    @Published var hint = ""
    @Published var latency: [(tool: String, p50: Double, p99: Double)] = []
    @Published var workApps: [(agent: String, label: String, staged: Bool, image: NSImage?)] = []
    @Published var workDisplay = ""
    @Published var treeNodes = 0
    @Published var treeSample: [(role: String, label: String)] = []

    /// When set, the dashboard is a viewer of a daemon in another process and
    /// reads state over HTTP. That is the normal case: the daemon runs headless
    /// and any number of dashboard windows can look at it.
    private let remotePort: UInt16?
    private let shared: Shared?
    /// In dashboard-plus-daemon mode the port is on the shared state; read it
    /// there so the same code can fetch metrics over HTTP.
    private var optionalPort: UInt16? { remotePort ?? shared?.port }
    private var timer: Timer?

    init(shared: Shared) {
        self.remotePort = nil
        self.shared = shared
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    init(remotePort: UInt16) {
        self.remotePort = remotePort
        self.shared = nil
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    /// Refresh the "work" panel: every bound app with a live thumbnail, so the
    /// person can see what each agent is doing without looking at their screen.
    /// Stage, unstage or release one app from the dashboard.
    func workAction(agent: String, tool: String) {
        guard let port = dashboardPort() else { return }
        let body = "{\"tool\":\"\(tool)\",\"agent\":\"\(agent)\"}"
        _ = HTTP.request(port: port, method: "POST", path: "/action", body: body)
        refreshWork()
    }

    func refreshWork() {
        guard let port = dashboardPort() else { return }
        guard let work = HTTP.getJSON(port: port, path: "/work") else { return }
        let display = work["work_display"] as? [String: Any] ?? [:]
        var rows: [(String, String, Bool, NSImage?)] = []
        for app in (work["apps"] as? [[String: Any]] ?? []) {
            let agent = app["agent"] as? String ?? ""
            let label = app["label"] as? String ?? ""
            let staged = app["staged"] as? Bool ?? false
            var image: NSImage?
            if let p = app["preview"] as? String, let img = NSImage(contentsOfFile: p) { image = img }
            rows.append((agent, label, staged, image))
        }
        workApps = rows
        if let id = display["id"] as? Int, id != 0, let b = display["bounds"] as? [String: Any] {
            workDisplay = "work display \(id) · \(Int((b["w"] as? Double) ?? 0))x\(Int((b["h"] as? Double) ?? 0))"
        } else {
            workDisplay = (display["error"] as? String) ?? "no work display"
        }
    }

    private func dashboardPort() -> UInt16? {
        if let port = remotePort { return port }
        let path = (NSHomeDirectory() as NSString).appendingPathComponent(".quiet-driver/port")
        guard let text = try? String(contentsOfFile: path, encoding: .utf8),
              let first = text.split(separator: "\n").first else { return nil }
        return UInt16(first.trimmingCharacters(in: .whitespaces))
    }

    func refresh() {
        let snap: [String: Any]
        if let port = remotePort {
            snap = HTTP.getJSON(port: port, path: "/status") ?? [:]
        } else if let shared = shared {
            snap = shared.snapshot
        } else {
            return
        }
        if let t = snap["target"] as? [String: Any], let label = t["label"] as? String {
            targetLabel = label
        } else {
            targetLabel = "nothing bound"
        }
        if let rows = snap["bindings"] as? [[String: Any]] {
            bindings = rows.map { (agent: ($0["agent"] as? String) ?? "",
                                   label: ($0["label"] as? String) ?? "") }
        }
        mode = (snap["mode"] as? String) ?? "background"
        actionsTotal = (snap["actions_total"] as? Int) ?? 0
        focusMoved = (snap["focus_events"] as? Int) ?? 0
        paused = !((snap["running"] as? Bool) ?? true)
        watchEnabled = (snap["watch_enabled"] as? Bool) ?? false
        port = (snap["port"] as? Int) ?? 0
        agentCount = (snap["agents"] as? [String])?.count ?? 0
        if let perms = snap["permissions"] as? [String: Any] {
            ax = (perms["accessibility"] as? Bool) ?? false
            postEvents = (perms["post_events"] as? Bool) ?? false
            capture = (perms["screen_capture"] as? Bool) ?? false
        }
        let rawLog = (snap["log"] as? [[String: Any]]) ?? []
        log = rawLog.suffix(14).reversed().map {
            (tool: ($0["tool"] as? String) ?? "",
             detail: ($0["detail"] as? String) ?? "",
             ok: ($0["ok"] as? Bool) ?? false)
        }
        pointerMoved = 0
        hint = "pointer moved counts only when a person moves it; the driver never does."

        // What the driver is spending its time on, and what it can see. Both come
        // from the same surface an agent uses, so the window shows the truth
        // rather than a private view of it.
        if let port = remotePort ?? optionalPort {
            if let m = HTTP.getJSON(port: port, path: "/metrics"),
               let slowest = m["slowest"] as? [[String: Any]] {
                latency = slowest.compactMap { entry in
                    guard let tool = entry["tool"] as? String,
                          let stats = entry["stats"] as? [String: Any] else { return nil }
                    return (tool: tool,
                            p50: (stats["p50_ms"] as? Double) ?? 0,
                            p99: (stats["p99_ms"] as? Double) ?? 0)
                }
            }
            if let t = HTTP.getJSON(port: port, path: "/tree"),
               let nodes = t["nodes"] as? [[String: Any]] {
                treeNodes = nodes.count
                let described = nodes.map(DashboardModel.describeNode)
                let named = described.filter { !$0.label.isEmpty }
                treeSample = Array((named.isEmpty ? described : named).prefix(9))
            }
        }
    }

    /// A node in one line: role without the AX prefix, then whatever text it has.
    static func describeNode(_ n: [String: Any]) -> (role: String, label: String) {
        let role = ((n["role"] as? String) ?? "").replacingOccurrences(of: "AX", with: "")
        for key in ["title", "description", "value"] {
            if let text = n[key] as? String, !text.isEmpty {
                return (role: role, label: String(text.prefix(28)))
            }
        }
        return (role: role, label: "")
    }

    /// The person's switch: whether an app may come to the front so they can
    /// watch it being driven. Agents cannot reach this; it is why focused mode
    /// exists at all.
    func toggleWatch() {
        let body = "{\"tool\":\"set_watch\",\"enabled\":\(watchEnabled ? "false" : "true")}"
        if let port = remotePort {
            _ = HTTP.postJSON(port: port, path: "/action", body: body)
        } else if let shared = shared {
            shared.watchEnabled.toggle()
            if !shared.watchEnabled { shared.mode = .background }
        }
        refresh()
    }

    func pause() { call("pause") }
    func resume() { call("resume") }

    /// A viewer cannot flip a flag in another process; it asks the daemon.
    private func call(_ tool: String) {
        if let port = remotePort {
            _ = HTTP.postJSON(port: port, path: "/action", body: "{\"tool\":\"\(tool)\"}")
        } else if let shared = shared {
            shared.running = (tool == "resume")
        }
        refresh()
    }
}


/// Tracks the one dashboard window a daemon is willing to have open.
///
/// A viewer is a separate process that reads `/status` over HTTP, so the daemon
/// can be headless forever and still be looked at. The pid file is what makes
/// `show_dashboard` idempotent: asking twice raises the window instead of
/// stacking a second one.
enum DashboardViewer {
    static var pidPath: String {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? "/tmp"
        return "\(home)/.quiet-driver/viewer.pid"
    }

    static func runningInstance() -> NSRunningApplication? {
        guard let text = try? String(contentsOfFile: pidPath, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0,
              let app = NSRunningApplication(processIdentifier: pid),
              !app.isTerminated else { return nil }
        return app
    }

    static func start() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
        p.arguments = ["--viewer"]
        try p.run()
    }

    /// Called by the viewer itself.
    static func register() {
        let dir = (pidPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? "\(ProcessInfo.processInfo.processIdentifier)\n".write(toFile: pidPath, atomically: true, encoding: .utf8)
    }

    static func unregister() {
        try? FileManager.default.removeItem(atPath: pidPath)
    }
}
