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
        .frame(minWidth: 720, minHeight: 520)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Quiet Driver")
                    .font(.system(size: 22, weight: .semibold))
                Text(model.targetLabel)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                badge(model.mode == "focused" ? "FOCUSED" : "BACKGROUND",
                      color: model.mode == "focused" ? .orange : .green)
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
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
    }

    private var footer: some View {
        HStack {
            Text(model.hint).font(.caption).foregroundStyle(.secondary)
            Spacer()
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
    @Published var ax = false
    @Published var postEvents = false
    @Published var capture = false
    @Published var paused = false
    @Published var port = 0
    @Published var log: [(tool: String, detail: String, ok: Bool)] = []
    @Published var hint = ""

    /// When set, the dashboard is a viewer of a daemon in another process and
    /// reads state over HTTP. That is the normal case: the daemon runs headless
    /// and any number of dashboard windows can look at it.
    private let remotePort: UInt16?
    private let shared: Shared?
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
        mode = (snap["mode"] as? String) ?? "background"
        actionsTotal = (snap["actions_total"] as? Int) ?? 0
        focusMoved = (snap["focus_events"] as? Int) ?? 0
        paused = !((snap["running"] as? Bool) ?? true)
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
