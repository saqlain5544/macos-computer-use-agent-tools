import AppKit
import SwiftUI

/// One binary, five jobs.
///
///   quiet-driver                 the dashboard, and the daemon behind it
///   quiet-driver --headless      the daemon without a window
///   quiet-driver --worker        one worker process, driven by the daemon
///   quiet-driver --mcp-stdio     an MCP stdio bridge to the daemon
///
/// The daemon owns the single-instance lock, the session and both surfaces. A
/// worker owns one app's accessibility connection. They are separate processes
/// on purpose: a wedged connection to one app must not take the driver down.

let executablePath = Bundle.main.executablePath ?? CommandLine.arguments[0]

func homeDirectory() -> String {
    ProcessInfo.processInfo.environment["HOME"] ?? "/tmp"
}

// MARK: - single instance

/// Take the one-and-only-daemon lock.
///
/// An advisory flock: the kernel drops it when the process dies, so a crash
/// never leaves a stale lock. The file is never deleted while a daemon holds it,
/// because deleting it would let a second daemon lock a different inode and run
/// alongside the first.
func instanceLock() -> Int32? {
    let dir = "\(homeDirectory())/.quiet-driver"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let path = "\(dir)/driver.lock"
    let fd = open(path, O_CREAT | O_RDWR, 0o644)
    guard fd >= 0 else { return nil }
    if flock(fd, LOCK_EX | LOCK_NB) != 0 {
        close(fd)
        return nil
    }
    ftruncate(fd, 0)
    let text = "\(ProcessInfo.processInfo.processIdentifier)\n"
    _ = text.withCString { write(fd, $0, strlen($0)) }
    return fd
}

/// If a daemon is already listening, open a dashboard window on it.
func revealOrView() -> Bool {
    guard MCP.daemonPort() != nil else { return false }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: executablePath)
    p.arguments = ["--viewer"]
    try? p.run()
    return true
}

// MARK: - daemon

final class Driver {
    let shared = Shared()
    let pool: WorkerPool
    let metrics = Metrics()
    let server: Server
    private var probeTimer: Timer?

    init(helperPath: String) {
        pool = WorkerPool(helperPath: helperPath)
        server = Server(shared: shared, pool: pool, metrics: metrics)
    }

    func run(preferredPort: UInt16) -> UInt16? {
        guard let port = server.start(preferredPort: preferredPort) else { return nil }
        probe()
        probeTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.probe()
        }
        RunLoop.main.add(probeTimer!, forMode: .common)
        return port
    }

    /// A cheap periodic read: permissions, the frontmost app, and whether the
    /// screen is locked. Anything expensive stays out of this loop.
    func probe() {
        server.republishIfMissing()
        let helper = pool.session()
        let perms = helper.permissions()
        shared.permissions = perms
        shared.workerReady = perms.allGranted
        let locked = helper.screenLocked()
        shared.screenLocked = locked
        let (pid, name) = helper.frontmost()
        if pid != 0, !name.isEmpty { shared.frontmost = name }
        NotificationCenter.default.post(name: .stateChanged, object: nil)
    }

    func stop() {
        probeTimer?.invalidate()
        server.stop()
        pool.releaseAll()
    }
}

// MARK: - flags

func flagValue(_ name: String) -> String? {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

let args = CommandLine.arguments
let isWorker = args.contains("--worker")
/// Capture the dashboard's own window to a PNG, then exit. Used to regenerate
/// the plugin preview from a real render rather than a mock-up.
let screenshotPath = flagValue("--screenshot")
let screenshotMaxEdge = flagValue("--screenshot-max-edge").flatMap { Int($0) }
let isBridge = args.contains("--mcp-stdio")
let isHeadless = args.contains("--headless")
// A screenshot is a viewer that leaves: it attaches to the running daemon,
// draws one frame, captures it, and exits.
let isViewer = args.contains("--viewer") || screenshotPath != nil
let wantsShow = args.contains("--show")

// A worker is spawned by the daemon with the same binary. It must never touch
// the lock, the port file, or a window: it is a pipe with accessibility access.
if isWorker {
    runWorkerLoop()
}

if isBridge {
    exit(MCP.bridgeStdio())
}

// MARK: - daemon startup

// A viewer never owns the device: it is a window onto whatever daemon is running.
if isViewer {
    // A screenshot needs a fresh window, so it does not reuse an open one.
    if screenshotPath == nil,
       let existing = DashboardViewer.runningInstance(),
       existing.processIdentifier != ProcessInfo.processInfo.processIdentifier {
        // A window is already open; raising it is the whole job.
        existing.activate(options: [.activateAllWindows])
        exit(0)
    }
    var daemonPort = MCP.daemonPort()
    if daemonPort == nil {
        // Nothing is running yet: start one, then view it. A screenshot of a
        // dashboard with no daemon behind it would be a mock-up.
        MCP.spawnDaemon()
        for _ in 0..<40 {
            usleep(250_000)
            if let p = MCP.daemonPort() { daemonPort = p; break }
        }
    }
    guard let port = daemonPort else {
        FileHandle.standardError.write(Data("quiet-driver: no daemon is running\n".utf8))
        exit(4)
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let model = DashboardModel(remotePort: port)
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
        styleMask: [.titled, .closable, .miniaturizable, .resizable],
        backing: .buffered, defer: false)
    window.title = "Quiet Driver"
    window.center()
    window.contentView = NSHostingView(rootView: DashboardView(model: model))
    window.makeKeyAndOrderFront(nil)
    app.activate(ignoringOtherApps: true)
    DashboardViewer.register()
    NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
        DashboardViewer.unregister()
    }
    if let path = screenshotPath {
        // One frame has to be laid out before the view can draw itself.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            captureOwnWindow(window, to: path, maxEdge: screenshotMaxEdge)
            DashboardViewer.unregister()
            exit(0)
        }
    }
    app.run()
    DashboardViewer.unregister()
    exit(0)
}

guard let lockFd = instanceLock() else {
    // Another daemon owns the device. `open -a` is a "show me the dashboard"
    // gesture, so show one, and let it talk to the running daemon.
    if revealOrView() {
        exit(0)
    }
    FileHandle.standardError.write(Data("quiet-driver: another instance is running\n".utf8))
    exit(2)
}

let helperPath = flagValue("--helper") ?? ""
let preferredPort = UInt16(flagValue("--port") ?? ProcessInfo.processInfo.environment["QD_PORT"] ?? "") ?? 0

let driver = Driver(helperPath: helperPath)

func shutdownAndExit(_ code: Int32) -> Never {
    driver.stop()
    exit(code)
}

signal(SIGTERM) { _ in
    driver.stop()
    exit(0)
}
signal(SIGINT) { _ in
    driver.stop()
    exit(0)
}

/// The dashboard needs an app; the daemon does not. Both run the same driver.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let port = driver.run(preferredPort: preferredPort) else {
            FileHandle.standardError.write(Data("quiet-driver: could not bind the control port\n".utf8))
            exit(3)
        }
        let model = DashboardModel(shared: driver.shared)
        let view = DashboardView(model: model)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Quiet Driver"
        window.center()
        window.contentView = NSHostingView(rootView: view)
        window.makeKeyAndOrderFront(nil)
        window.isReleasedWhenClosed = false
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        FileHandle.standardError.write(Data("quiet-driver: dashboard on http://127.0.0.1:\(port)\n".utf8))

    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { driver.stop() }
}

/// Capture the dashboard window by id, then scale so the long edge matches the
/// documented ceiling.
/// Write the dashboard window to a PNG by drawing its own content.
///
/// Going through `screencapture` needs the window to be on screen, composited,
/// and front — which is exactly what a background dashboard is not. Asking the
/// view to draw itself needs none of that and renders the same pixels.
func captureOwnWindow(_ window: NSWindow, to path: String, maxEdge: Int?) {
    guard let view = window.contentView else { return }
    let bounds = view.bounds
    guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
    view.cacheDisplay(in: bounds, to: rep)
    guard let png = rep.representation(using: .png, properties: [:]) else { return }
    do {
        try png.write(to: URL(fileURLWithPath: path))
    } catch {
        FileHandle.standardError.write(Data("quiet-driver: could not write \(path): \(error)\n".utf8))
        return
    }
    if let edge = maxEdge, edge > 0 {
        let s = Process()
        s.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
        s.arguments = ["-Z", String(edge), path]
        try? s.run()
        s.waitUntilExit()
    }
    FileHandle.standardError.write(Data("quiet-driver: wrote \(path) (\(png.count) bytes)\n".utf8))
}

if isHeadless || !wantsShow && ProcessInfo.processInfo.environment["QD_HEADLESS"] == "1" {
    guard driver.run(preferredPort: preferredPort) != nil else {
        FileHandle.standardError.write(Data("quiet-driver: could not bind the control port\n".utf8))
        exit(3)
    }
    FileHandle.standardError.write(Data("quiet-driver: control surface on http://127.0.0.1:\(driver.shared.port)\n".utf8))
    RunLoop.main.run()
    shutdownAndExit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
