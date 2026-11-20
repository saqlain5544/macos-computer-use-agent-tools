import Foundation

/// A window the window server knows about.
struct Window {
    var pid: Int32
    var windowId: UInt32
    var owner: String
    var title: String
    var layer: Int
    var onScreen: Bool
    var bounds: Rect

    var label: String { title.isEmpty ? owner : "\(owner) · \(title)" }
}

/// One node of an accessibility tree.
struct Node {
    var depth: Int
    var role: String
    var title: String
    var description: String
    var value: String
    var rect: Rect

    var json: [String: Any] {
        ["depth": depth, "role": role, "title": title, "description": description,
         "value": value,
         "frame": ["x": rect.x, "y": rect.y, "w": rect.w, "h": rect.h]]
    }

    /// Empty group containers are noise in a tree an agent reads.
    var worthShowing: Bool { (rect.w > 0 && rect.h > 0) || role != "AXGroup" }
}

/// What sits under a point.
struct Hit {
    var role: String
    var title: String
    var description: String
    var rect: Rect

    var label: String {
        if !description.isEmpty { return description }
        if !title.isEmpty { return title }
        return role
    }

    /// Only these can be activated with AXPress; anything else is a container
    /// and needs a synthetic click instead.
    var canPress: Bool {
        ["AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuItem",
         "AXLink", "AXCell", "AXTab"].contains(role)
    }
}

struct Permissions {
    var accessibility = false
    var postEvents = false
    var screenCapture = false

    var allGranted: Bool { accessibility && postEvents && screenCapture }

    var json: [String: Any] {
        ["accessibility": accessibility, "post_events": postEvents, "screen_capture": screenCapture]
    }
}

/// Client for one worker process.
///
/// One long-lived child, one JSON object per line in each direction. All macOS
/// calls live in the worker; the daemon just speaks this small protocol. Both
/// are the same binary: the child is this executable started with `--worker`.
final class Helper {
    private let lock = NSLock()
    private var child: Process?
    private var toWorker: FileHandle?
    private var fromWorker: FileHandle?
    private var buffer = Data()
    private var pointer = (x: 0.0, y: 0.0)
    /// Time spent inside worker calls since the last reset. The operation log
    /// uses this to separate "the driver thought" from "the app was slow".
    private var callCount = 0
    private var callMicros = 0.0
    /// Every worker call this operation made: command and duration. Bounded, and
    /// the reason is attribution — "this click made seven calls" is only useful
    /// if the log says which seven.
    private var callLog: [(String, Double)] = []

    /// Path to a prebuilt worker/helper, when the app was installed with one.
    let helperPath: String

    init(helperPath: String) {
        self.helperPath = helperPath
    }

    deinit { stop() }

    // MARK: process

    private func executablePath() -> String {
        if !helperPath.isEmpty, FileManager.default.isExecutableFile(atPath: helperPath) {
            return helperPath
        }
        // The worker is this same binary.
        if let exe = Bundle.main.executablePath { return exe }
        return CommandLine.arguments[0]
    }

    private func ensureStarted() throws -> (FileHandle, FileHandle) {
        if let c = child, let i = toWorker, let o = fromWorker, c.isRunning {
            return (i, o)
        }
        stopLocked()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executablePath())
        p.arguments = ["--worker"]
        var inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        // A worker must never outlive its daemon: the loop also exits when its
        // parent becomes launchd, but closing stdin on death is faster.
        try p.run()
        child = p
        toWorker = inPipe.fileHandleForWriting
        fromWorker = outPipe.fileHandleForReading
        buffer.removeAll()
        return (inPipe.fileHandleForWriting, outPipe.fileHandleForReading)
    }

    /// Stop the worker. Safe to call from any thread; also used from inside
    /// `call()`, which already holds the lock — NSLock is not recursive, so the
    /// unlocked variant is the one that may be used there.
    func stop() {
        lock.lock()
        defer { lock.unlock() }
        stopLocked()
    }

    /// Read whatever is available, without Foundation's buffering machinery.
    private func readAvailable(_ handle: FileHandle) -> Data {
        var tmp = [UInt8](repeating: 0, count: 16 * 1024)
        let n = read(handle.fileDescriptor, &tmp, tmp.count)
        if n <= 0 { return Data() }
        return Data(tmp[0..<n])
    }

    /// Is the worker's stdout readable within `timeoutMs`?
    private func pollReadable(_ handle: FileHandle, timeoutMs: Int32) -> Bool {
        var pfd = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
        let rc = poll(&pfd, 1, timeoutMs)
        return rc > 0 && (pfd.revents & Int16(POLLIN)) != 0
    }

    private func stopLocked() {
        if let c = child {
            try? toWorker?.close()
            if c.isRunning { c.terminate() }
        }
        child = nil
        toWorker = nil
        fromWorker = nil
    }

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return child?.isRunning ?? false
    }

    // MARK: transport

    /// Reset the per-operation counters.
    func beginOperation() {
        lock.lock()
        callCount = 0
        callMicros = 0
        callLog.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    /// How many worker calls this operation made, how long they took, and which.
    func operationStats() -> (calls: Int, micros: Double, detail: [(String, Double)]) {
        lock.lock()
        defer { lock.unlock() }
        return (callCount, callMicros, callLog)
    }

    func call(_ request: [String: Any]) throws -> [String: Any] {
        lock.lock()
        let started = Date()
        do {
            let reply = try callLocked(request)
            record(request, started)
            lock.unlock()
            return reply
        } catch {
            record(request, started)
            lock.unlock()
            throw error
        }
    }

    private func record(_ request: [String: Any], _ started: Date) {
        let micros = Date().timeIntervalSince(started) * 1_000_000
        callCount += 1
        callMicros += micros
        if callLog.count < 24 {
            callLog.append(((request["cmd"] as? String) ?? "?", micros / 1000.0))
        }
    }

    /// The body of `call`, with the lock already held.
    private func callLocked(_ request: [String: Any]) throws -> [String: Any] {
        let (input, output) = try ensureStarted()
        var line = jsonString(request)
        line += "\n"
        guard let data = line.data(using: .utf8) else {
            throw HelperError.failed("could not encode request")
        }
        do {
            try input.write(contentsOf: data)
        } catch {
            child = nil
            throw HelperError.failed("worker write failed: \(error.localizedDescription)")
        }
        guard let reply = try readLine(from: output) else {
            child = nil
            throw HelperError.failed("worker closed the pipe")
        }
        guard let obj = jsonObject(reply) else {
            throw HelperError.failed("worker sent invalid JSON: \(reply.prefix(120))")
        }
        return obj
    }

    /// How long a single worker call may take before the worker is considered
    /// wedged. A real accessibility call on a large tree is under a second;
    /// fifteen is far past "slow" and well before "the daemon looks hung".
    static let callTimeoutMs = 15_000

    /// Read one newline-terminated message, keeping any surplus in the buffer.
    ///
    /// `availableData` cannot time out, so the descriptor is polled: a worker
    /// that never answers — a wedged accessibility connection, a half-written
    /// pipe — would otherwise block the caller forever, and with it the daemon.
    private func readLine(from handle: FileHandle) throws -> String? {
        let deadline = Date().addingTimeInterval(Double(Helper.callTimeoutMs) / 1000.0)
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                return String(data: lineData, encoding: .utf8)
            }
            guard pollReadable(handle, timeoutMs: 200) else {
                if Date() > deadline {
                    stopLocked()
                    throw HelperError.failed("worker did not answer within \(Helper.callTimeoutMs) ms; it was restarted")
                }
                continue
            }
            let chunk = readAvailable(handle)
            if chunk.isEmpty { return nil }
            buffer.append(chunk)
        }
    }

    @discardableResult
    func ok(_ request: [String: Any]) throws -> [String: Any] {
        let v = try call(request)
        if asBool(v["ok"]) == true { return v }
        throw HelperError.failed(asString(v["error"]) ?? "worker reported failure")
    }

    enum HelperError: Error, CustomStringConvertible {
        case failed(String)
        var description: String {
            switch self {
            case .failed(let s): return s
            }
        }
    }

    // MARK: pointer proof

    /// Remember the pointer position and report whether it has since moved.
    @discardableResult
    func pointerNow() -> (x: Double, y: Double) {
        if let reply = try? call(["cmd": "pointer"]),
           let x = asDouble(reply["x"]), let y = asDouble(reply["y"]) {
            pointer = (x, y)
        }
        return pointer
    }

    func pointerMoved(since before: (x: Double, y: Double)) -> Bool {
        let now = pointerNow()
        return abs(now.x - before.x) > 0.5 || abs(now.y - before.y) > 0.5
    }
}

// MARK: - typed commands

extension Helper {
    func permissions() -> Permissions {
        var p = Permissions()
        if let v = try? call(["cmd": "perms"]) {
            p.accessibility = asBool(v["accessibility"]) ?? false
            p.postEvents = asBool(v["post_events"]) ?? false
            p.screenCapture = asBool(v["screen_capture"]) ?? false
        }
        return p
    }

    func screenLocked() -> Bool {
        guard let v = try? call(["cmd": "session"]) else { return false }
        return asBool(v["screen_locked"]) ?? false
    }

    func windowsList() -> [Window] {
        guard let v = try? call(["cmd": "windows"]),
              let rows = v["windows"] as? [[String: Any]] else { return [] }
        return rows.compactMap { d in
            guard let wid = asInt(d["window_id"]).flatMap({ UInt32(exactly: $0) }) else { return nil }
            return Window(
                pid: Int32(asInt(d["pid"]) ?? 0),
                windowId: wid,
                owner: asString(d["owner"]) ?? "",
                title: asString(d["title"]) ?? "",
                layer: asInt(d["layer"]) ?? 0,
                onScreen: asBool(d["on_screen"]) ?? false,
                bounds: Rect(x: asDouble(d["x"]) ?? 0, y: asDouble(d["y"]) ?? 0,
                             w: asDouble(d["w"]) ?? 0, h: asDouble(d["h"]) ?? 0))
        }
    }

    func frontmost() -> (pid: Int32, name: String) {
        guard let v = try? call(["cmd": "frontmost"]),
              let f = v["front"] as? [String: Any] else { return (0, "") }
        return (Int32(asInt(f["pid"]) ?? 0), asString(f["name"]) ?? "")
    }

    /// pid, bundle id, display name for an app selector.
    func resolve(_ app: String) throws -> (pid: Int32, bundleId: String, name: String) {
        let v = try ok(["cmd": "resolve", "app": app])
        return (Int32(asInt(v["pid"]) ?? 0), asString(v["bundle_id"]) ?? "", asString(v["name"]) ?? "")
    }

    func launch(_ app: String) throws -> (pid: Int32, name: String) {
        let v = try ok(["cmd": "launch", "app": app])
        return (Int32(asInt(v["pid"]) ?? 0), asString(v["name"]) ?? "")
    }

    func quitApp(_ app: String, force: Bool) throws -> String {
        let v = try ok(["cmd": "quit_app", "app": app, "force": force])
        return asString(v["name"]) ?? app
    }

    func ocr(windowId: UInt32) throws -> (lines: [String], boxes: [[String: Any]], count: Int) {
        let v = try ok(["cmd": "ocr", "window_id": Int(windowId)])
        let boxes = (v["boxes"] as? [[String: Any]]) ?? []
        let lines = (v["lines"] as? [String]) ?? []
        return (lines, boxes, (v["count"] as? Int) ?? boxes.count)
    }

    /// Move and resize a window through accessibility: no activation, no Space
    /// change, the window is just told where to be.
    @discardableResult
    func moveWindow(windowId: UInt32, pid: Int32,
                    x: Double, y: Double, w: Double, h: Double) throws -> Bool {
        let v = try ok(["cmd": "move_window", "pid": Int(pid), "window_id": Int(windowId),
                        "x": x, "y": y, "w": w, "h": h])
        return asBool(v["ok"]) ?? false
    }

    /// Read a window's frame. Never moves it: a frame request must not have
    /// side effects (the first version of this reused move_window and quietly
    /// moved every window it measured to (-1,-1)).
    func windowFrame(windowId: UInt32, pid: Int32) throws -> Rect {
        let v = try ok(["cmd": "window_frame", "pid": Int(pid), "window_id": Int(windowId)])
        return Rect(x: asDouble(v["x"]) ?? 0, y: asDouble(v["y"]) ?? 0,
                    w: asDouble(v["w"]) ?? 0, h: asDouble(v["h"]) ?? 0)
    }

    func screenshot(windowId: UInt32, path: String, native: Bool = false) throws -> (w: Int, h: Int, bytes: Int, scale: Double) {
        let v = try ok(["cmd": "screenshot", "window_id": Int(windowId), "path": path, "native": native])
        return (asInt(v["width"]) ?? 0, asInt(v["height"]) ?? 0, asInt(v["bytes"]) ?? 0,
                asDouble(v["native_scale"]) ?? 1.0)
    }

    func record(pid: Int32, seconds: Double, path: String) throws -> [String: Any] {
        try ok(["cmd": "record", "pid": Int(pid), "seconds": seconds, "path": path])
    }

    func fileDialog(pid: Int32, request: [String: Any]) throws -> [String: Any] {
        var req = request
        req["cmd"] = "file_dialog"
        req["pid"] = Int(pid)
        return try ok(req)
    }

    func openFile(app: String, path: String) throws {
        _ = try ok(["cmd": "open_file", "app": app, "path": path])
    }

    func closeFile(pid: Int32, name: String) throws -> String {
        let v = try ok(["cmd": "close_file", "pid": Int(pid), "name": name])
        return asString(v["closed"]) ?? name
    }

    func documents(pid: Int32) -> [String] {
        guard let v = try? call(["cmd": "documents", "pid": Int(pid)]),
              let names = v["documents"] as? [String] else { return [] }
        return names
    }

    func tree(pid: Int32, max: Int = 600) throws -> [Node] {
        let v = try ok(["cmd": "tree", "pid": Int(pid), "max": max])
        let rows = v["nodes"] as? [[String: Any]] ?? []
        return rows.map { d in
            Node(
                depth: asInt(d["depth"]) ?? 0,
                role: asString(d["role"]) ?? "",
                title: asString(d["title"]) ?? "",
                description: asString(d["description"]) ?? "",
                value: asString(d["value"]) ?? "",
                rect: Rect(x: asDouble(d["x"]) ?? 0, y: asDouble(d["y"]) ?? 0,
                           w: asDouble(d["w"]) ?? 0, h: asDouble(d["h"]) ?? 0))
        }
    }

    private func hit(_ cmd: String, pid: Int32, x: Double, y: Double) throws -> Hit {
        let v = try ok(["cmd": cmd, "pid": Int(pid), "x": x, "y": y])
        return Hit(
            role: asString(v["role"]) ?? "",
            title: asString(v["title"]) ?? "",
            description: asString(v["description"]) ?? "",
            rect: Rect(x: asDouble(v["x"]) ?? 0, y: asDouble(v["y"]) ?? 0,
                       w: asDouble(v["w"]) ?? 0, h: asDouble(v["h"]) ?? 0))
    }

    func elementAt(pid: Int32, x: Double, y: Double) throws -> Hit {
        try hit("element_at", pid: pid, x: x, y: y)
    }

    func pressAt(pid: Int32, x: Double, y: Double) throws -> Hit {
        try hit("press_at", pid: pid, x: x, y: y)
    }

    func pressLabel(pid: Int32, label: String) throws -> (name: String, rect: Rect) {
        let v = try ok(["cmd": "press_label", "pid": Int(pid), "label": label])
        return (asString(v["label"]) ?? label,
                Rect(x: asDouble(v["x"]) ?? 0, y: asDouble(v["y"]) ?? 0,
                     w: asDouble(v["w"]) ?? 0, h: asDouble(v["h"]) ?? 0))
    }

    func hasLabel(pid: Int32, label: String) throws -> Bool {
        let v = try ok(["cmd": "has_label", "pid": Int(pid), "label": label])
        return asBool(v["present"]) ?? false
    }

    /// A stable signature of the app's accessibility tree, as hex text.
    func treeSignature(pid: Int32) throws -> String {
        let v = try ok(["cmd": "tree_sig", "pid": Int(pid)])
        return asString(v["sig"]) ?? ""
    }

    func textField(pid: Int32) throws -> String {
        let v = try ok(["cmd": "text_field", "pid": Int(pid)])
        return asString(v["value"]) ?? ""
    }

    func setValue(pid: Int32, value: String) throws {
        _ = try ok(["cmd": "set_value", "pid": Int(pid), "value": value])
    }

    func setCaret(pid: Int32, location: Int, length: Int) throws -> (location: Int, length: Int) {
        let v = try ok(["cmd": "set_caret", "pid": Int(pid),
                        "location": location, "length": length])
        return (asInt(v["location"]) ?? location, asInt(v["length"]) ?? length)
    }

    func activate(pid: Int32) throws { _ = try ok(["cmd": "activate", "pid": Int(pid)]) }
    func raiseWindow(pid: Int32) throws { _ = try ok(["cmd": "raise_window", "pid": Int(pid)]) }

    func click(pid: Int32, x: Double, y: Double, how: String) throws {
        _ = try ok(["cmd": "click", "pid": Int(pid), "x": x, "y": y, "button": how])
    }

    func drag(pid: Int32, from: (Double, Double), to: (Double, Double)) throws {
        _ = try ok(["cmd": "drag", "pid": Int(pid),
                    "x": from.0, "y": from.1, "to_x": to.0, "to_y": to.1])
    }

    func scroll(pid: Int32, x: Double, y: Double, lines: Int) throws {
        _ = try ok(["cmd": "scroll", "pid": Int(pid), "x": x, "y": y, "lines": lines])
    }

    func typeText(pid: Int32, text: String) throws -> Int {
        let v = try ok(["cmd": "type", "pid": Int(pid), "text": text])
        return asInt(v["sent"]) ?? asInt(v["characters"]) ?? text.count
    }

    func key(pid: Int32, chord: String) throws {
        _ = try ok(["cmd": "key", "pid": Int(pid), "key": chord])
    }
}
