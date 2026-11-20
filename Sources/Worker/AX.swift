// quiet-driver-helper — all macOS control in one place.
//
// Speaks JSON lines on stdin/stdout with the Rust dashboard. Stateless: every
// request names the pid (and window-local point) it applies to.
//
// Background-safe by construction:
//   * Accessibility reads and AXPress / AXValue writes never move the pointer
//     and never change which app is frontmost.
//   * CGEventPostToPid delivers mouse and keyboard events straight to the
//     target process, so the real cursor stays put.
//   * `activate` is only ever called when the caller asked for focused mode;
//     the caller is responsible for restoring the previous app.

import Cocoa
import ApplicationServices
import AVFoundation
import ScreenCaptureKit

// ScreenCaptureKit asserts unless the process has an AppKit session. Creating
// it is expensive (~20 MB of AppKit), so it is done lazily, the first time a
// recording is asked for — a worker that only presses buttons stays lean.
var qdAppInitialised = false
func ensureAppKit() {
    if !qdAppInitialised {
        qdAppInitialised = true
        _ = NSApplication.shared
    }
}

// MARK: - helpers

/// Read one AX attribute.
///
/// `AXUIElementCopyAttributeValue` returns a +1 reference. Declaring the out
/// parameter as `AnyObject?` lets Swift's ARC own it, so it is released when
/// the temporary goes out of scope — do not take ownership again by hand,
/// which over-releases and crashes.
func axAttr(_ el: AXUIElement, _ name: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
}
func axStr(_ el: AXUIElement, _ name: String) -> String {
    (axAttr(el, name) as? String) ?? ""
}
/// Recently walked control maps, keyed by pid.
///
/// Walking a real app's tree costs 40-100 ms because every node is a
/// synchronous IPC call. Pressing a button changes the UI, so the cache is
/// dropped after each press — but a retry, or a second press on the same
/// window, reuses the walk instead of paying for it again.
var controlCache: [Int32: (controls: [(AXUIElement, String)], frames: [CGRect], at: Date)] = [:]
let controlCacheTTL: TimeInterval = 1.0

/// Symbols an agent is likely to ask for, and the words apps actually use for
/// them. Calculator labels its plus key "Add", so `click_label("+")` failed with
/// a helpful-but-useless list of controls. Only consulted after exact,
/// case-insensitive and word-subset matching all miss, so it can never override
/// a real label.
let symbolAliases: [String: [String]] = [
    "+": ["add", "plus"],
    "-": ["subtract", "minus"],
    "−": ["subtract", "minus"],
    "*": ["multiply", "times"],
    "×": ["multiply", "times"],
    "/": ["divide"],
    "÷": ["divide"],
    "=": ["equals"],
    "±": ["change sign", "negate", "sign"],
    "%": ["percent", "percentage"],
    ".": ["decimal point", "point", "decimal"],
]

/// Match a requested label against a control list.
///
/// Exact first, then case-insensitive, then a unique control whose words are a
/// subset of the request ("All Clear" -> "Clear"). Nothing looser: pressing the
/// wrong control is worse than failing.
func matchControl(_ controls: [(AXUIElement, String)], _ label: String) -> (element: AXUIElement, name: String, index: Int)? {
    func words(_ s: String) -> Set<String> {
        Set(s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
    }
    let needle = label.lowercased()
    let wanted = words(label)
    if let i = controls.firstIndex(where: { $0.1 == label }) { return (controls[i].0, controls[i].1, i) }
    if let i = controls.firstIndex(where: { $0.1.lowercased() == needle }) { return (controls[i].0, controls[i].1, i) }
    let subset = controls.enumerated().filter { c in
        let w = words(c.element.1)
        return !w.isEmpty && w.isSubset(of: wanted)
    }
    if subset.count == 1 { return (subset[0].element.0, subset[0].element.1, subset[0].offset) }
    if let aliases = symbolAliases[label.trimmingCharacters(in: .whitespaces)] {
        for alias in aliases {
            if let i = controls.firstIndex(where: { $0.1.lowercased() == alias }) {
                return (controls[i].0, controls[i].1, i)
            }
        }
    }
    return nil
}

/// The control whose frame contains a screen point.
///
/// Coordinate clicks must resolve to something pressable. The system hit test
/// can return a container group for a point that is visually over a button, and
/// posting a synthetic event to a background app then does nothing at all. The
/// control map already knows every control's frame, so the smallest frame
/// containing the point is the element a person would have clicked.
func controlAt(pid: Int32, x: Double, y: Double) -> AXUIElement? {
    let point = CGPoint(x: x, y: y)
    func fromCache() -> AXUIElement? {
        guard let cached = controlCache[pid], Date().timeIntervalSince(cached.at) < controlCacheTTL else { return nil }
        var best: (AXUIElement, CGFloat)?
        for (i, frame) in cached.frames.enumerated() where frame.contains(point) {
            if i < cached.controls.count {
                let area = frame.width * frame.height
                if best == nil || area < best!.1 { best = (cached.controls[i].0, area) }
            }
        }
        return best?.0
    }
    if let hit = fromCache() { return hit }
    // Cold: walk once, caching the same way press_label does.
    let ax = appElement(pid)
    let controlRoles = ["AXButton", "AXCheckBox", "AXPopUpButton", "AXMenuItem", "AXRadioButton"]
    var controls: [(AXUIElement, String)] = []
    func scan(_ el: AXUIElement, _ depth: Int) {
        if depth > 30 || controls.count > 4000 { return }
        let attrs = axMulti(el, ["AXRole", "AXDescription", "AXTitle", "AXValue", "AXChildren"])
        let role = attrs["AXRole"] as? String ?? ""
        if controlRoles.contains(role) {
            let name = [attrs["AXDescription"], attrs["AXTitle"], attrs["AXValue"]]
                .compactMap { $0 as? String }.first(where: { !$0.isEmpty }) ?? ""
            controls.append((el, name))
        }
        if role == "AXMenuBar" || role == "AXMenuBarItem" || role == "AXMenu" { return }
        if let kids = attrs["AXChildren"] as? [AXUIElement] { for k in kids { scan(k, depth + 1) } }
    }
    if let mw = axAttr(ax, "AXMainWindow") { scan(mw as! AXUIElement, 0) }
    if let ws = axAttr(ax, "AXWindows") as? [AXUIElement] { for w in ws { scan(w, 0) } }
    controlCache[pid] = (controls, controls.map { axFrame($0.0) }, Date())
    return fromCache()
}

/// The app's editable text element.
///
/// The focused element is the right answer and costs one call. Walking the tree
/// to find a text area costs over a second on a real document, because the walk
/// reads every node in the document across process boundaries.
func textElement(_ ax: AXUIElement) -> AXUIElement? {
    func isText(_ el: AXUIElement) -> Bool {
        let role = axStr(el, "AXRole")
        return role == "AXTextArea" || role == "AXTextField"
    }
    // 1. Whatever has focus.
    if let focused = axAttr(ax, "AXFocusedUIElement") {
        let el = focused as! AXUIElement
        if isText(el) { return el }
        // Some apps focus a container; look one level down.
        if let kids = axAttr(el, "AXChildren") as? [AXUIElement] {
            for k in kids where isText(k) { return k }
        }
    }
    // 2. A shallow search of the window, which is where editors put their text.
    var stack: [(AXUIElement, Int)] = []
    if let w = mainWindow(ax) { stack.append((w, 0)) }
    if let ws = axAttr(ax, "AXWindows") as? [AXUIElement] { for w in ws { stack.append((w, 0)) } }
    while let (el, d) = stack.popLast() {
        if d > 8 { continue }
        if isText(el) { return el }
        if let kids = axAttr(el, "AXChildren") as? [AXUIElement] {
            for k in kids.reversed() { stack.append((k, d + 1)) }
        }
    }
    return nil
}

/// Run a short-lived tool, without Foundation's `Process`.
///
/// `Process.waitUntilExit()` integrates with a run loop that this helper does
/// not have, so it polls: every `screencapture` came back ~65 ms later than the
/// tool itself took. `posix_spawn` + `waitpid` is a direct fork/exec and blocks
/// exactly as long as the child runs.
@discardableResult
func runTool(_ path: String, _ args: [String]) -> Int32 {
    var argv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
    argv.insert(strdup(path), at: 0)
    argv.append(nil)
    defer { for a in argv where a != nil { free(a) } }

    var pid: pid_t = 0
    let rc = posix_spawn(&pid, path, nil, nil, argv, environ)
    guard rc == 0 else { return -1 }
    var status: Int32 = 0
    while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
    return status >> 8
}

/// The element under a screen point, belonging to `pid`.
///
/// `AXUIElementCopyElementAtPosition` is one call into the window server and
/// answers the same question the old tree walk did — that walk cost ~150 ms per
/// click because it read every node's frame. This is the difference between a
/// usable coordinate click and an unusable one.
///
/// The system-wide call can return an element from another app (the point may
/// be over a window that is on top), so the result is checked against the pid.
func hitTest(pid: Int32, x: Double, y: Double) -> (element: AXUIElement, role: String, title: String, description: String)? {
    // Hit-test *inside the bound app*, not system-wide. The system-wide call
    // answers "what is on top at this point", so for a backgrounded app it
    // returns another application's element and we would fall back to the slow
    // tree walk. The app element searches that app's own windows regardless of
    // what is in front, which is exactly the question being asked.
    var found: AXUIElement?
    let rc = AXUIElementCopyElementAtPosition(appElement(pid), Float(x), Float(y), &found)
    if rc == .success, let el = found {
        var owner: pid_t = 0
        AXUIElementGetPid(el, &owner)
        if owner == pid {
            return (el, axStr(el, "AXRole"), axStr(el, "AXTitle"), axStr(el, "AXDescription"))
        }
    }
    // Fall back to the tree walk: the point may be over a child the system-wide
    // call does not resolve, or the app may not publish positions.
    let ax = appElement(pid)
    var best: AXUIElement?
    var bestArea = Double.greatestFiniteMagnitude
    for el in walk(ax) {
        let f = axFrame(el)
        if f.width <= 0 || f.height <= 0 { continue }
        if !f.contains(CGPoint(x: x, y: y)) { continue }
        let area = f.width * f.height
        if area < bestArea { bestArea = area; best = el }
    }
    guard let el = best else { return nil }
    return (el, axStr(el, "AXRole"), axStr(el, "AXTitle"), axStr(el, "AXDescription"))
}

/// Read several attributes in one IPC round trip.
///
/// Each `AXUIElementCopyAttributeValue` is a synchronous call into the target
/// process. Walking a tree one attribute at a time costs ~250 us per attribute,
/// which makes a label search over a 130-node app take ~65 ms. One batched call
/// per node cuts that by roughly the number of attributes we read.
func axMulti(_ el: AXUIElement, _ names: [String]) -> [String: AnyObject] {
    var values: CFArray?
    let rc = AXUIElementCopyMultipleAttributeValues(
        el,
        names as CFArray,
        AXCopyMultipleAttributeOptions(rawValue: 0),
        &values
    )
    guard rc == .success, let values, let array = values as? [AnyObject] else { return [:] }
    var out: [String: AnyObject] = [:]
    for (i, name) in names.enumerated() where i < array.count {
        let value = array[i]
        // NSNull marks an attribute the element does not have.
        if value is NSNull { continue }
        out[name] = value
    }
    return out
}

func axFrame(_ el: AXUIElement) -> CGRect {
    var p = CGPoint.zero
    var s = CGSize.zero
    if let v = axAttr(el, "AXPosition") { AXValueGetValue(v as! AXValue, .cgPoint, &p) }
    if let v = axAttr(el, "AXSize") { AXValueGetValue(v as! AXValue, .cgSize, &s) }
    return CGRect(x: p.x, y: p.y, width: s.width, height: s.height)
}
func axActions(_ el: AXUIElement) -> [String] {
    var names: CFArray?
    AXUIElementCopyActionNames(el, &names)
    return (names as? [String]) ?? []
}
func appElement(_ pid: Int32) -> AXUIElement { AXUIElementCreateApplication(pid) }

func mainWindow(_ ax: AXUIElement) -> AXUIElement? {
    if let w = axAttr(ax, "AXMainWindow") { return (w as! AXUIElement) }
    if let ws = axAttr(ax, "AXWindows") as? [AXUIElement], let w = ws.first { return w }
    return nil
}

/// Depth-first walk of every element under the app's windows.
func walk(_ ax: AXUIElement, max: Int = 4000, depthLimit: Int = 40) -> [AXUIElement] {
    var out: [AXUIElement] = []
    var stack: [(AXUIElement, Int)] = []
    if let w = mainWindow(ax) { stack.append((w, 0)) }
    if let ws = axAttr(ax, "AXWindows") as? [AXUIElement] {
        for w in ws { stack.append((w, 0)) }
    }
    while let (el, d) = stack.popLast() {
        if out.count >= max || d > depthLimit { continue }
        if let kids = axAttr(el, "AXChildren") as? [AXUIElement] {
            for k in kids { stack.append((k, d + 1)) }
        }
        out.append(el)
    }
    return out
}

/// Every top-level window, including off-screen, minimised, and other-Space ones.
///
/// Reads the CFArray and its CFDictionary entries directly instead of bridging
/// them into Swift collections. The helper is a readLine() loop with no run
/// loop, so nothing ever drains an autorelease pool; bridged dictionaries pile
/// up and the process grows by tens of MB over a few thousand actions. Pulling
/// out the handful of fields we need leaves nothing to accumulate.
func windowsList() -> [[String: Any]] {
    var out: [[String: Any]] = []
    guard let raw = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) else { return out }
    // Bridge the keys once. `key as CFString` allocates a new CFString per
    // call, and with ~120 windows × 10 fields that is over a thousand
    // allocations per refresh, several refreshes per action.
    let kNum = kCGWindowNumber as CFString
    let kPid = kCGWindowOwnerPID as CFString
    let kOwner = kCGWindowOwnerName as CFString
    let kName = kCGWindowName as CFString
    let kLayer = kCGWindowLayer as CFString
    let kOnScreen = kCGWindowIsOnscreen as CFString
    let kBounds = kCGWindowBounds as CFString
    let kX = "X" as CFString
    let kY = "Y" as CFString
    let kW = "Width" as CFString
    let kH = "Height" as CFString
    let count = CFArrayGetCount(raw)
    for i in 0..<count {
        guard let ptr = CFArrayGetValueAtIndex(raw, i) else { continue }
        let dict = unsafeBitCast(ptr, to: CFDictionary.self)

        func value(_ key: CFString) -> UnsafeRawPointer? {
            CFDictionaryGetValue(dict, Unmanaged.passUnretained(key).toOpaque())
        }
        func int(_ key: CFString) -> Int {
            guard let v = value(key) else { return 0 }
            var n: Int64 = 0
            CFNumberGetValue(unsafeBitCast(v, to: CFNumber.self), .longLongType, &n)
            return Int(n)
        }
        func str(_ key: CFString) -> String {
            guard let v = value(key) else { return "" }
            return unsafeBitCast(v, to: CFString.self) as String
        }
        func double(_ key: CFString) -> Double {
            guard let v = value(key) else { return 0 }
            var d = 0.0
            CFNumberGetValue(unsafeBitCast(v, to: CFNumber.self), .doubleType, &d)
            return d
        }
        func flag(_ key: CFString) -> Bool {
            guard let v = value(key) else { return false }
            return unsafeBitCast(v, to: CFBoolean.self) == kCFBooleanTrue
        }

        let wid = int(kNum)
        guard wid > 0 else { continue }
        var x = 0.0, y = 0.0, w = 0.0, h = 0.0
        if let bv = value(kBounds) {
            let bdict = unsafeBitCast(bv, to: CFDictionary.self)
            func bdouble(_ key: CFString) -> Double {
                guard let v = CFDictionaryGetValue(bdict, Unmanaged.passUnretained(key).toOpaque()) else { return 0 }
                var d = 0.0
                CFNumberGetValue(unsafeBitCast(v, to: CFNumber.self), .doubleType, &d)
                return d
            }
            x = bdouble(kX); y = bdouble(kY); w = bdouble(kW); h = bdouble(kH)
        }
        out.append([
            "pid": int(kPid),
            "window_id": wid,
            "owner": str(kOwner),
            "title": str(kName),
            "layer": int(kLayer),
            "on_screen": flag(kOnScreen),
            "x": x, "y": y, "w": w, "h": h,
        ])
    }
    return out
}

/// Frontmost app.
///
/// `lsappinfo front` is the LaunchServices answer and is the only signal that
/// stayed truthful here: NSWorkspace lags after an activation performed by a
/// non-GUI process, and the window-server order is full of 1x1 helper windows
/// from other processes. Falls back to NSWorkspace if lsappinfo is missing.
var frontCache: (at: Date, value: [String: Any])? = nil
let frontCacheTTL: TimeInterval = 0.25

func frontmostInfo(force: Bool = false) -> [String: Any] {
    if !force, let c = frontCache, Date().timeIntervalSince(c.at) < frontCacheTTL {
        return c.value
    }
    func run(_ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/lsappinfo")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            return ""
        }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    let asn = run(["front"]).trimmingCharacters(in: .whitespacesAndNewlines)
    if !asn.isEmpty {
        let info = run(["info", "-only", "pid,name", asn])
        var pid = 0
        var name = ""
        for raw in info.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("\""), let close = line.dropFirst().firstIndex(of: "\"") {
                name = String(line[line.index(after: line.startIndex)..<close])
            }
            if line.hasPrefix("pid = ") {
                let digits = line.dropFirst("pid = ".count).prefix { $0.isNumber }
                pid = Int(digits) ?? 0
            }
        }
        if pid != 0 {
            let v: [String: Any] = ["pid": pid, "name": name, "source": "lsappinfo"]
            frontCache = (Date(), v)
            return v
        }
    }

    let app = NSWorkspace.shared.frontmostApplication
    let v: [String: Any] = [
        "pid": Int(app?.processIdentifier ?? 0),
        "name": app?.localizedName ?? "",
        "source": "nsworkspace",
    ]
    frontCache = (Date(), v)
    return v
}

func pointer() -> [String: Any] {
    let p = CGEvent(source: nil)?.location ?? .zero
    return ["x": p.x, "y": p.y]
}

let keyCodes: [String: CGKeyCode] = [
    "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51,
    "escape": 53, "esc": 53, "left": 123, "arrowleft": 123, "right": 124, "arrowright": 124,
    "down": 125, "arrowdown": 125, "up": 126, "arrowup": 126, "home": 115, "end": 119,
    "pageup": 116, "pagedown": 121,
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
    "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
    "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
    "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
    "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45,
    "m": 46, ".": 47, "`": 50,
]

func parseChord(_ chord: String) -> (CGKeyCode, CGEventFlags, String)? {
    var flags: CGEventFlags = []
    var key = ""
    for raw in chord.split(separator: "+") {
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "cmd", "command", "meta": flags.insert(.maskCommand)
        case "shift": flags.insert(.maskShift)
        case "alt", "option", "opt": flags.insert(.maskAlternate)
        case "ctrl", "control": flags.insert(.maskControl)
        case let other: key = other
        }
    }
    guard let code = keyCodes[key] else { return nil }
    return (code, flags, key)
}

/// Post a click to one process.
///
/// The gaps are the minimum that reliably separates the events for the target
/// app's event loop, not a generous guess: at 8/14/0 ms the app still receives
/// a distinct move, press and release, and the call costs ~22 ms instead of the
/// 128 ms that 18/70/40 ms of sleeping did. Nothing after the release is needed —
/// the event is already queued when `postToPid` returns.
func postClick(pid: Int32, point: CGPoint, button: String) {
    let src = CGEventSource(stateID: .hidSystemState)
    let down: CGEventType = button == "right" ? .rightMouseDown : .leftMouseDown
    let up: CGEventType = button == "right" ? .rightMouseUp : .leftMouseUp
    let btn: CGMouseButton = button == "right" ? .right : .left
    if let mv = CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: btn) {
        mv.postToPid(pid)
    }
    usleep(8_000)
    if let d = CGEvent(mouseEventSource: src, mouseType: down, mouseCursorPosition: point, mouseButton: btn) {
        d.postToPid(pid)
    }
    usleep(14_000)
    if let u = CGEvent(mouseEventSource: src, mouseType: up, mouseCursorPosition: point, mouseButton: btn) {
        u.postToPid(pid)
    }
}


// MARK: - window recording

final class WindowRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var firstPTS: CMTime?
    private(set) var frames = 0
    private(set) var lastError: String?

    init(url: URL, width: Int, height: Int) throws {
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        super.init()
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
    }

    func attach(_ filter: SCContentFilter, width: Int, height: Int) throws {
        let cfg = SCStreamConfiguration()
        cfg.width = width
        cfg.height = height
        cfg.showsCursor = false
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 15)
        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "qd.record"))
        stream = s
    }

    func start() async throws { try await stream?.startCapture() }

    func stop() async -> Int {
        try? await stream?.stopCapture()
        input.markAsFinished()
        await writer.finishWriting()
        return frames
    }

    func stream(_ s: SCStream, didOutputSampleBuffer b: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, b.isValid, let px = CMSampleBufferGetImageBuffer(b) else { return }
        // ScreenCaptureKit timestamps are absolute host time; rebase on frame 0.
        let abs = CMSampleBufferGetPresentationTimeStamp(b)
        let base = firstPTS ?? abs
        firstPTS = base
        let t = CMTimeSubtract(abs, base)
        if CMTimeGetSeconds(t) < 0 || !t.isValid { return }
        if adaptor.assetWriterInput.isReadyForMoreMediaData {
            if adaptor.append(px, withPresentationTime: t) { frames += 1 }
        }
    }

    func stream(_ s: SCStream, didStopWithError error: Error) {
        lastError = "\(error)"
    }
}

/// Record one window for `seconds`. Works on the window's own surface, so the
/// app may be background, occluded, minimised, or on another Space.
func recordWindow(_ req: [String: Any]) -> [String: Any] {
    ensureAppKit()
    let appName = req["app"] as? String ?? ""
    let pid = req["pid"] as? Int ?? 0
    let seconds = min(max((req["seconds"] as? Double) ?? Double(req["seconds"] as? Int ?? 3), 0.5), 60.0)
    let path = req["path"] as? String ?? "/tmp/quiet-driver-recording.mov"
    let sem = DispatchSemaphore(value: 0)
    var reply: [String: Any] = ["ok": false, "error": "recording did not start"]

    Task {
        defer { sem.signal() }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            let candidates = content.windows.filter { w in
                guard w.frame.width > 120, w.frame.height > 80 else { return false }
                if pid != 0 { return w.owningApplication?.processID == pid_t(pid) }
                return w.owningApplication?.applicationName == appName
            }
            guard let win = candidates.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
                reply = ["ok": false, "error": "no capturable window for \(appName.isEmpty ? "pid \(pid)" : appName)"]
                return
            }
            let width = Int(win.frame.width * 2), height = Int(win.frame.height * 2)
            let rec = try WindowRecorder(url: URL(fileURLWithPath: path), width: width, height: height)
            try rec.attach(SCContentFilter(desktopIndependentWindow: win), width: width, height: height)
            try await rec.start()
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            let frames = await rec.stop()
            let bytes = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int) ?? 0
            reply = [
                "ok": frames > 0,
                "path": path,
                "width": width,
                "height": height,
                "seconds": seconds,
                "frames": frames,
                "bytes": bytes,
                "error": frames > 0 ? "" : (rec.lastError ?? "no frames were produced"),
            ]
        } catch {
            reply = ["ok": false, "error": "\(error)"]
        }
    }
    _ = sem.wait(timeout: .now() + seconds + 20)
    return reply
}

// MARK: - screenshot

func handleScreenshot(_ req: [String: Any]) -> [String: Any] {
    let wid = req["window_id"] as? Int ?? 0
    let path = req["path"] as? String ?? "/tmp/quiet-driver-window.png"
    guard wid != 0 else { return ["ok": false, "error": "screenshot needs a window_id"] }
    let code = runTool("/usr/sbin/screencapture", ["-x", "-o", "-l", String(wid), path])
    guard code == 0, FileManager.default.fileExists(atPath: path) else {
        return ["ok": false, "error": "screencapture exited \(code) for window \(wid)"]
    }
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let bytes = (attrs?[.size] as? Int) ?? 0
        // Read the image's dimensions from its header. Decoding the whole PNG
        // just to learn its size doubled the cost of a screenshot (65 ms of
        // capture plus ~50 ms of decode for a 1348x816 window).
        var width = 0, height = 0
        if let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            width = (props[kCGImagePropertyPixelWidth] as? Int) ?? 0
            height = (props[kCGImagePropertyPixelHeight] as? Int) ?? 0
        }
    return ["ok": true, "path": path, "bytes": bytes, "width": width, "height": height]
}

// MARK: - file dialogs

/// Drive an NSOpenPanel / NSSavePanel attached to `pid`.
///
/// File dialogs are usually *sheets* (inside `AXSheets` of the parent window,
/// not in `AXWindows`), and the filename field has no title or description, so
/// both are found structurally rather than by label.
/// The documents an app has open, read from its Window menu.
func windowMenuDocuments(_ ax: AXUIElement) -> [String]? {
    guard let bar = axAttr(ax, "AXMenuBar") else { return nil }
    var windowItem: AXUIElement?
    func findBar(_ e: AXUIElement, _ d: Int) {
        if d > 4 || windowItem != nil { return }
        if axStr(e, "AXRole") == "AXMenuBarItem" && axStr(e, "AXTitle") == "Window" { windowItem = e; return }
        if let kids = axAttr(e, "AXChildren") as? [AXUIElement] { for c in kids { findBar(c, d + 1) } }
    }
    findBar(bar as! AXUIElement, 0)
    guard let wi = windowItem else { return nil }

    // A document's entry in the Window menu carries the selector
    // "makeKeyAndOrderFront:"; the standard window-management items carry
    // their own selectors. That identifier is the reliable discriminator.
    var items: [AXUIElement] = []
    func collect(_ e: AXUIElement, _ d: Int) {
        if d > 6 { return }
        if axStr(e, "AXRole") == "AXMenuItem" { items.append(e) }
        if let kids = axAttr(e, "AXChildren") as? [AXUIElement] { for c in kids { collect(c, d + 1) } }
    }
    collect(wi, 0)
    let titles: [String] = items
        .filter { axStr($0, "AXIdentifier").contains("makeKeyAndOrderFront") }
        .map { axStr($0, "AXTitle") }
    return titles.filter { !$0.isEmpty }
}

/// Press a document's entry in the app's Window menu, making it the front
/// document without activating the app.
func pressWindowMenuItem(_ ax: AXUIElement, _ title: String) -> Bool {
    guard let bar = axAttr(ax, "AXMenuBar") else { return false }
    var windowItem: AXUIElement?
    func findBar(_ e: AXUIElement, _ d: Int) {
        if d > 4 || windowItem != nil { return }
        if axStr(e, "AXRole") == "AXMenuBarItem" && axStr(e, "AXTitle") == "Window" { windowItem = e; return }
        if let kids = axAttr(e, "AXChildren") as? [AXUIElement] { for c in kids { findBar(c, d + 1) } }
    }
    findBar(bar as! AXUIElement, 0)
    guard let wi = windowItem else { return false }
    var target: AXUIElement?
    func collect(_ e: AXUIElement, _ d: Int) {
        if d > 6 || target != nil { return }
        if axStr(e, "AXRole") == "AXMenuItem",
           axStr(e, "AXTitle") == title,
           axStr(e, "AXIdentifier").contains("makeKeyAndOrderFront") {
            target = e; return
        }
        if let kids = axAttr(e, "AXChildren") as? [AXUIElement] { for c in kids { collect(c, d + 1) } }
    }
    collect(wi, 0)
    guard let t = target else { return false }
    return AXUIElementPerformAction(t, "AXPress" as CFString).rawValue == 0
}

/// Close a document by making it the app's front document and sending
/// cmd+w to the app's process. The event never reaches the screen and the
/// app is never activated, so the person is not disturbed.
func closeViaWindowMenu(_ ax: AXUIElement, _ name: String, pid: Int) -> String? {
    guard !name.isEmpty else { return nil }
    // The document's own menu item in the Window menu can be AXPressed, which
    // makes it the front document without activating the app.
    if let bar = axAttr(ax, "AXMenuBar") {
        var windowItem: AXUIElement?
        func findBar(_ e: AXUIElement, _ d: Int) {
            if d > 4 || windowItem != nil { return }
            if axStr(e, "AXRole") == "AXMenuBarItem" && axStr(e, "AXTitle") == "Window" { windowItem = e; return }
            if let kids = axAttr(e, "AXChildren") as? [AXUIElement] { for c in kids { findBar(c, d + 1) } }
        }
        findBar(bar as! AXUIElement, 0)
        if let wi = windowItem {
            var target: AXUIElement?
            func collect(_ e: AXUIElement, _ d: Int) {
                if d > 6 || target != nil { return }
                if axStr(e, "AXRole") == "AXMenuItem",
                   axStr(e, "AXTitle") == name,
                   axStr(e, "AXIdentifier").contains("makeKeyAndOrderFront") {
                    target = e; return
                }
                if let kids = axAttr(e, "AXChildren") as? [AXUIElement] { for c in kids { collect(c, d + 1) } }
            }
            collect(wi, 0)
            if let t = target {
                _ = AXUIElementPerformAction(t, "AXPress" as CFString)
                usleep(200_000)
            }
        }
    }
    // cmd+w to the app's process: closes its front document, in the background.
    let src = CGEventSource(stateID: .hidSystemState)
    let down = CGEvent(keyboardEventSource: src, virtualKey: 13, keyDown: true)!
    down.flags = .maskCommand
    down.postToPid(pid_t(pid))
    let up = CGEvent(keyboardEventSource: src, virtualKey: 13, keyDown: false)!
    up.flags = .maskCommand
    up.postToPid(pid_t(pid))
    usleep(500_000)

    // Verify: the document must be gone from the Window menu. Reporting
    // success without checking would be the one thing this driver must not do.
    if let remaining = windowMenuDocuments(ax), !remaining.contains(name) {
        return name
    }
    return nil
}

/// Pids of the AppKit open/save panel services (the dialog's real window owner).
func panelServicePids() -> [pid_t] {
    NSWorkspace.shared.runningApplications
        .filter { $0.bundleIdentifier == "com.apple.appkit.xpc.openAndSavePanelService" }
        .map { $0.processIdentifier }
}

/// The file names currently listed in the panel's file list.
func fileRowNames(_ panel: AXUIElement) -> [String] {
    var names: [String] = []
    func walk(_ e: AXUIElement, _ depth: Int) {
        if depth > 26 || names.count > 200 { return }
        if axStr(e, "AXRole") == "AXCell" {
            var label = ""
            func inner(_ x: AXUIElement, _ d: Int) {
                if d > 4 || !label.isEmpty { return }
                if axStr(x, "AXRole") == "AXStaticText" { label = axStr(x, "AXValue") }
                if let kids = axAttr(x, "AXChildren") as? [AXUIElement] { for k in kids { inner(k, d + 1) } }
            }
            inner(e, 0)
            if !label.isEmpty && !names.contains(label) { names.append(label) }
        }
        if let kids = axAttr(e, "AXChildren") as? [AXUIElement] { for k in kids { walk(k, depth + 1) } }
    }
    walk(panel, 0)
    return names
}

/// Find the file row whose name matches, in the panel's file list.
func fileRow(_ panel: AXUIElement, _ name: String) -> AXUIElement? {
    var found: AXUIElement?
    func walk(_ e: AXUIElement, _ depth: Int) {
        if depth > 26 || found != nil { return }
        if axStr(e, "AXRole") == "AXCell" {
            var label = ""
            func inner(_ x: AXUIElement, _ d: Int) {
                if d > 4 || !label.isEmpty { return }
                if axStr(x, "AXRole") == "AXStaticText" { label = axStr(x, "AXValue") }
                if let kids = axAttr(x, "AXChildren") as? [AXUIElement] { for k in kids { inner(k, d + 1) } }
            }
            inner(e, 0)
            if label == name {
                // The cell carries AXOpen; the row may not.
                if axActions(e).contains("AXOpen") { found = e; return }
                if let pv = axAttr(e, "AXParent") {
                    let parent = pv as! AXUIElement
                    if axActions(parent).contains("AXOpen") { found = parent; return }
                }
            }
        }
        if let kids = axAttr(e, "AXChildren") as? [AXUIElement] { for k in kids { walk(k, depth + 1) } }
    }
    walk(panel, 0)
    return found
}

/// Whether the panel's window is actually on screen. An off-screen panel
/// ignores AXOpen entirely, so this decides which route can work.
func panelIsOnScreen(_ title: String) -> Bool {
    guard let list: CFArray = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) else { return false }
    var onScreen = false
    let count = CFArrayGetCount(list)
    for i in 0..<count {
        guard let ptr = CFArrayGetValueAtIndex(list, i) else { continue }
        let dict = unsafeBitCast(ptr, to: CFDictionary.self)
        func str(_ key: String) -> String {
            let cf = key as CFString
            guard let v = CFDictionaryGetValue(dict, Unmanaged.passUnretained(cf).toOpaque()) else { return "" }
            return unsafeBitCast(v, to: CFString.self) as String
        }
        if str(kCGWindowName as String) == title {
            let cf = kCGWindowIsOnscreen as CFString
            if let v = CFDictionaryGetValue(dict, Unmanaged.passUnretained(cf).toOpaque()),
               unsafeBitCast(v, to: CFBoolean.self) == kCFBooleanTrue {
                onScreen = true
                break
            }
        }
    }
    return onScreen
}

/// Is any file dialog still attached to this pid?
func fileDialogGone(_ pid: Int) -> Bool {
    let app = appElement(Int32(pid))
    guard let main = axAttr(app, "AXMainWindow") else { return true }
    let title = axStr(main as! AXUIElement, "AXTitle")
    if title == "Open" || title == "Save" { return false }
    if let sheets = axAttr(main as! AXUIElement, "AXSheets") as? [AXUIElement], !sheets.isEmpty { return false }
    return true
}

func driveFileDialog(_ req: [String: Any]) -> [String: Any] {
    let pid = req["pid"] as? Int ?? 0
    let action = req["action"] as? String ?? "inspect"
    let path = req["path"] as? String ?? ""
    let app = appElement(Int32(pid))

    func children(_ e: AXUIElement, role: String) -> [AXUIElement] {
        var out: [AXUIElement] = []
        func walk(_ e: AXUIElement, _ d: Int) {
            if d > 18 { return }
            if axStr(e, "AXRole") == role { out.append(e) }
            if let kids = axAttr(e, "AXChildren") as? [AXUIElement] { for k in kids { walk(k, d + 1) } }
        }
        walk(e, 0)
        return out
    }

    var windows: [AXUIElement] = []
    if let w = axAttr(app, "AXMainWindow") { windows.append(w as! AXUIElement) }
    if let ws = axAttr(app, "AXWindows") as? [AXUIElement] { windows.append(contentsOf: ws) }
    if let fw = axAttr(app, "AXFocusedWindow"), !windows.isEmpty {
        let f = fw as! AXUIElement
        if CFEqual(f, windows[0]) == false { windows.append(f) }
    }

    // Is a panel currently up? A sheet may live on the main window, on a window,
    // or be reported as a top-level window of its own.
    var panels: [AXUIElement] = []
    for w in windows {
        let titles = [axStr(w, "AXTitle")]
        if titles.contains("Open") || titles.contains("Save") { panels.append(w) }
        if let sheets = axAttr(w, "AXSheets") as? [AXUIElement] {
            for s in sheets {
                let sub = axStr(s, "AXSubrole")
                if sub.contains("Dialog") || sub.contains("SystemDialog") || !axStr(s, "AXTitle").isEmpty {
                    panels.append(s)
                }
            }
        }
        // A sheet can also show up as a child window.
        for child in children(w, role: "AXWindow") { panels.append(child) }
    }

    if panels.isEmpty {
        return ["ok": false, "error": "no file dialog is open for this app"]
    }
    let panel = panels[0]

    let allFields = children(panel, role: "AXTextField")
    let searchFields = allFields.filter { axStr($0, "AXSubrole") == "AXSearchField" }
    let plainFields = allFields.filter { axStr($0, "AXSubrole") != "AXSearchField" }
    let buttons = children(panel, role: "AXButton")
    func title(_ b: AXUIElement) -> String {
        let t = axStr(b, "AXTitle")
        return t.isEmpty ? axStr(b, "AXDescription") : t
    }

    // A file panel contains hundreds of text fields: one per file row, and the
    // filename field itself is unlabelled. File rows reject a path; the
    // filename field accepts one, so write to each candidate and keep the field
    // that reads the value back.
    let panelFrame = axFrame(panel)
    let candidates = plainFields.filter { field in
        let f = axFrame(field)
        return panelFrame.contains(CGPoint(x: f.midX, y: f.midY))
    }
    func setFilename(_ value: String) -> AXUIElement? {
        for field in candidates {
            if AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, value as CFString).rawValue != 0 { continue }
            usleep(60_000)
            if axStr(field, "AXValue") == value { return field }
        }
        return nil
    }
    func findButton(_ want: String) -> AXUIElement? {
        buttons.first { title($0).caseInsensitiveCompare(want) == .orderedSame }
    }

    switch action {
    case "inspect":
        return [
            "ok": true,
            "dialog": axStr(panel, "AXTitle"),
            "on_screen": panelIsOnScreen(axStr(panel, "AXTitle")),
            "hint": panelIsOnScreen(axStr(panel, "AXTitle"))
                ? ""
                : "the panel is not on screen, so it cannot be committed; an off-screen AXOpen does nothing",
            "text_fields": plainFields.count,
            "search_fields": searchFields.count,
            "filename": plainFields.first(where: { axActions($0).contains("AXConfirm") && !axStr($0, "AXValue").isEmpty })
                .map { axStr($0, "AXValue") } ?? "",
            "buttons": buttons.map(title).filter { !$0.isEmpty },
        ]

    case "set_path":
        guard !path.isEmpty else { return ["ok": false, "error": "set_path needs a \"path\""] }
        if let field = setFilename(path) {
            return ["ok": true, "value": axStr(field, "AXValue")]
        }
        return ["ok": false, "error": "the dialog did not accept the path in any text field"]

    case "open_row", "confirm", "open", "save":
        let wanted = req["button"] as? String ?? (action == "save" ? "Save" : "Open")
        var field: AXUIElement? = nil
        if !path.isEmpty {
            field = setFilename(path)
            guard field != nil else {
                return ["ok": false, "error": "the dialog did not accept the path \"\(path)\""]
            }
        }
        // 1. Return in the filename field: this is how a person activates the
        //    path they just typed, and the panel honours it.
        if let f = field {
            _ = AXUIElementSetAttributeValue(f, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            usleep(80_000)
            for action in ["AXConfirm", "AXPress"] {
                let rc = AXUIElementPerformAction(f, action as CFString).rawValue
                usleep(350_000)
                if fileDialogGone(pid) {
                    return ["ok": true, "via": "field \(action)"]
                }
                _ = rc
            }
        }
        // 2. AXOpen on the row of the requested file: the double-click
        //    equivalent. This is the only route that works, because the Open
        //    button stays disabled — writing the filename field through AX does
        //    not run AppKit's validation, so the button never enables.
        //
        //    AXOpen reports `attributeUnsupported` even when it succeeds, so the
        //    only way to know is to look afterwards.
        if !path.isEmpty, let row = fileRow(panel, (path as NSString).lastPathComponent) {
            _ = AXUIElementPerformAction(row, "AXOpen" as CFString)
            usleep(900_000)
            if fileDialogGone(pid) { return ["ok": true, "via": "AXOpen on the file row"] }
        }
        // 3. The default button. It is usually disabled for the reason above,
        //    but a save panel's Save button is enabled by default.
        if let b = findButton(wanted) {
            for action in ["AXPress"] {
                let rc = AXUIElementPerformAction(b, action as CFString).rawValue
                usleep(350_000)
                if fileDialogGone(pid) {
                    return ["ok": true, "via": "button \(wanted)", "rc": Int(rc)]
                }
            }
        }
        // 3. A click posted to the panel service, which owns the dialog window.
        if let b = findButton(wanted) {
            let f = axFrame(b)
            let p = CGPoint(x: f.midX, y: f.midY)
            let src = CGEventSource(stateID: .hidSystemState)
            for target in panelServicePids() {
                CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.postToPid(target)
                usleep(40_000)
                CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)?.postToPid(target)
                usleep(50_000)
                CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)?.postToPid(target)
                usleep(400_000)
                if fileDialogGone(pid) { return ["ok": true, "via": "click in panel service"] }
            }
        }
        // 4. Return key posted to the app.
        let src = CGEventSource(stateID: .hidSystemState)
        let d = CGEvent(keyboardEventSource: src, virtualKey: 36, keyDown: true)!
        d.postToPid(pid_t(pid))
        let u = CGEvent(keyboardEventSource: src, virtualKey: 36, keyDown: false)!
        u.postToPid(pid_t(pid))
        usleep(450_000)
        if fileDialogGone(pid) { return ["ok": true, "via": "return key"] }
        return [
            "ok": false,
            "error": "the dialog is still open after every activation route",
            "visible_files": fileRowNames(panel).prefix(40).map { $0 },
            "hint": "an NSOpenPanel's Open button stays disabled when the filename is written through AX, "
                + "and AXOpen on a file row only works while the panel is on screen. "
                + "Use open_file instead: it opens the document with no panel and no focus change.",
        ]

    case "cancel":
        guard let b = findButton("Cancel") else { return ["ok": false, "error": "no Cancel button"] }
        return ["ok": AXUIElementPerformAction(b, kAXPressAction as CFString).rawValue == 0, "pressed": "Cancel"]

    default:
        return ["ok": false, "error": "unknown dialog action " + action]
    }
}


// MARK: - command handling

func handle(_ req: [String: Any]) -> [String: Any] {
    let cmd = req["cmd"] as? String ?? ""
    let pid = Int32(req["pid"] as? Int ?? 0)
    func num(_ k: String) -> Double { (req[k] as? Double) ?? Double(req[k] as? Int ?? 0) }

    switch cmd {
    case "session":
        // Is the person's screen locked? Everything about accessibility and
        // window focus changes when it is: no window is key, capture may be
        // refused, and calls are slower. Report it rather than letting an agent
        // misread the symptoms.
        var locked = false
        if let d = CGSessionCopyCurrentDictionary() as? [String: Any] {
            locked = (d["CGSSessionScreenIsLocked"] as? Bool) ?? false
        }
        return ["ok": true, "screen_locked": locked]

    case "perms":
        return [
            "ok": true,
            "accessibility": AXIsProcessTrusted(),
            "post_events": CGPreflightPostEventAccess(),
            "screen_capture": CGPreflightScreenCaptureAccess(),
        ]

    case "windows":
        return ["ok": true, "windows": windowsList()]

    case "frontmost":
        return ["ok": true, "front": frontmostInfo()]

    case "pointer":
        return ["ok": true, "pointer": pointer()]

    case "pid_for_window":
        let wid = req["window_id"] as? Int ?? 0
        for w in windowsList() where (w["window_id"] as? Int) == wid {
            return ["ok": true, "pid": w["pid"] ?? 0]
        }
        return ["ok": false, "error": "no window \(wid)"]

    case "resolve":
        // Re-resolve by identity instead of a stale pid: an app the agent bound
        // to can be quit, rebuilt and relaunched while the agent keeps working.
        let wanted = req["app"] as? String ?? ""
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        let match = apps.first { ($0.bundleIdentifier ?? "").caseInsensitiveCompare(wanted) == .orderedSame }
            ?? apps.first { ($0.localizedName ?? "").caseInsensitiveCompare(wanted) == .orderedSame }
            ?? apps.first { ($0.bundleIdentifier ?? "").lowercased().contains(wanted.lowercased()) && !wanted.isEmpty }
            ?? apps.first { ($0.localizedName ?? "").lowercased().contains(wanted.lowercased()) && !wanted.isEmpty }
        guard let app = match else {
            return ["ok": false, "error": "\"\(wanted)\" is not running",
                    "running": apps.compactMap { $0.localizedName }]
        }
        return [
            "ok": true,
            "pid": Int(app.processIdentifier),
            "name": app.localizedName ?? "",
            "bundle_id": app.bundleIdentifier ?? "",
        ]

    case "launch":
        // Launch without binding and without stealing focus (-g): the person
        // keeps whatever they were doing.
        let bundleOrName = req["app"] as? String ?? ""
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        var args = ["-g"]
        if bundleOrName.contains("/") { args += ["-a", bundleOrName] } else { args += ["-a", bundleOrName] }
        p.arguments = args
        do {
            try p.run(); p.waitUntilExit()
        } catch {
            return ["ok": false, "error": "\(error)"]
        }
        // Give it a moment to appear, then report the pid if we can find it.
        var pid = 0
        var name = ""
        for _ in 0..<25 {
            let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
            if let app = apps.first(where: {
                ($0.bundleIdentifier ?? "").caseInsensitiveCompare(bundleOrName) == .orderedSame
                    || ($0.localizedName ?? "").caseInsensitiveCompare(bundleOrName) == .orderedSame
            }) {
                pid = Int(app.processIdentifier)
                name = app.localizedName ?? ""
                break
            }
            usleep(80_000)
        }
        return ["ok": p.terminationStatus == 0, "open_exit": Int(p.terminationStatus), "pid": pid, "name": name]

    case "quit_app":
        let app = req["app"] as? String ?? ""
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        guard let target = apps.first(where: {
            ($0.bundleIdentifier ?? "").caseInsensitiveCompare(app) == .orderedSame
                || ($0.localizedName ?? "").caseInsensitiveCompare(app) == .orderedSame
        }) else {
            // Quitting something that is already not running has achieved the
            // goal, and an agent retrying a quit should not see a failure.
            return ["ok": true, "already_gone": true, "name": app]
        }
        // NSRunningApplication.terminate() is the polite request; app sandbox
        // and "confirm on quit" dialogs can ignore it, so fall back to asking
        // the app itself over Apple Events, then to SIGTERM.
        var asked = target.terminate()
        var waited = 0
        while !target.isTerminated && waited < 1200 {
            usleep(100_000)
            waited += 100
        }
        if !target.isTerminated, let bundle = target.bundleIdentifier {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", "tell application id \"\(bundle)\" to quit"]
            try? p.run()
            p.waitUntilExit()
            while !target.isTerminated && waited < 2500 {
                usleep(100_000)
                waited += 100
            }
        }
        if !target.isTerminated {
            asked = kill(target.processIdentifier, SIGTERM) == 0
            while !target.isTerminated && waited < 4000 {
                usleep(100_000)
                waited += 100
            }
        }
        if target.isTerminated {
            return ["ok": true, "requested": asked, "terminated": true,
                    "waited_ms": waited, "name": target.localizedName ?? ""]
        }
        // Not terminated. The usual reason is a modal "save changes?" sheet:
        // the app is waiting for an answer and will not quit until it gets one.
        // Say that, rather than reporting a bare failure — the answer belongs to
        // whoever owns the work, not to the driver.
        let sheet = appElement(target.processIdentifier)
        var sheetTitle = ""
        if let mw = axAttr(sheet, "AXMainWindow") {
            let w = mw as! AXUIElement
            if let sheets = axAttr(w, "AXSheets") as? [AXUIElement], !sheets.isEmpty {
                sheetTitle = axStr(sheets[0], "AXTitle")
            }
        }
        let pid = target.processIdentifier
        let docs = windowMenuDocuments(appElement(pid)) ?? []
        // Whether there is work to lose is decided by the window server, not by
        // the Window menu: a backgrounded app often reports no menu documents
        // while still showing a document window, and force-terminating then
        // would throw away the person's unsaved work.
        let usableWindows: [[String: Any]] = windowsList().filter { w in
            let ownerPid = (w["pid"] as? Int) ?? 0
            let layer = (w["layer"] as? Int) ?? -1
            let width = (w["w"] as? Double) ?? 0
            let height = (w["h"] as? Double) ?? 0
            return ownerPid == Int(pid) && layer == 0 && width >= 120 && height >= 80
        }
        if !sheetTitle.isEmpty || !docs.isEmpty || !usableWindows.isEmpty {
            return [
                "ok": false,
                "requested": asked,
                "terminated": false,
                "name": target.localizedName ?? "",
                "error": sheetTitle.isEmpty
                    ? "\(target.localizedName ?? "the app") has unsaved documents and did not quit; save or close them first"
                    : "\(target.localizedName ?? "the app") is asking whether to save (\(sheetTitle)) and did not quit",
                "sheets": sheetTitle.isEmpty ? [] : [sheetTitle],
                "documents": docs,
            ]
        }
        // Still running. A forced terminate is the only thing left, but it can
        // throw away work the driver cannot see (an app may auto-save on quit,
        // or hold state in memory). Never do that on the agent's behalf: only
        // when the caller explicitly asked for force.
        let force = req["force"] as? Bool ?? false
        if !force {
            return [
                "ok": false,
                "requested": asked,
                "terminated": false,
                "name": target.localizedName ?? "",
                "error": "\(target.localizedName ?? "the app") did not quit; pass force:true to terminate it anyway, or close its documents first",
                "hint": "force:true discards anything the app has not saved",
            ]
        }
        _ = target.forceTerminate()
        let hardDeadline = Date().addingTimeInterval(3.0)
        while !target.isTerminated && Date() < hardDeadline { usleep(100_000) }
        if target.isTerminated {
            return ["ok": true, "requested": true, "terminated": true,
                    "forced": true, "name": target.localizedName ?? ""]
        }
        return [
            "ok": false,
            "requested": asked,
            "terminated": false,
            "waited_ms": waited,
            "name": target.localizedName ?? "",
            "error": "\(target.localizedName ?? "the app") did not quit within \(waited) ms",
        ]

    case "activate":
        // NSRunningApplication.activate() silently does nothing for an
        // accessory/agent process. Ask the app to activate itself instead —
        // the same path `open -a` takes.
        guard let app = NSRunningApplication(processIdentifier: pid) else {
            return ["ok": false, "error": "no such pid"]
        }
        guard let bundle = app.bundleURL else {
            let ok = app.activate(options: [.activateAllWindows])
            return ["ok": ok]
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-a", bundle.path]
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            return ["ok": false, "error": "\(error)"]
        }
        _ = app.activate(options: [.activateAllWindows])
        // Wait for the window server to actually put it in front; `open -a`
        // returns before the transition finishes.
        var waited = 0
        while waited < 1500 {
            if frontmostInfo(force: true)["pid"] as? Int == Int(pid) { break }
            usleep(40_000)
            waited += 40
        }
        return [
            "ok": frontmostInfo(force: true)["pid"] as? Int == Int(pid),
            "open_exit": Int(p.terminationStatus),
            "front": frontmostInfo(force: true)["name"] as? String ?? "",
            "waited_ms": waited,
        ]

    case "raise_window":
        let ax = appElement(pid)
        guard let w = mainWindow(ax) else { return ["ok": false, "error": "no window"] }
        _ = AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        let rc = AXUIElementPerformAction(w, kAXRaiseAction as CFString).rawValue
        return ["ok": rc == 0, "rc": Int(rc)]

    case "tree":
        let ax = appElement(pid)
        let max = req["max"] as? Int ?? 600
        var rows: [[String: Any]] = []
        var stack: [(AXUIElement, Int)] = []
        if let w = mainWindow(ax) { stack.append((w, 0)) }
        if let ws = axAttr(ax, "AXWindows") as? [AXUIElement] { for w in ws { stack.append((w, 0)) } }
        // One batched attribute read per node. Reading role, title, description,
        // value and size separately is five synchronous calls into the target
        // app; on a 600-node document that is the difference between 950 ms and
        // a fraction of it.
        let names = ["AXRole", "AXTitle", "AXDescription", "AXValue", "AXPosition", "AXSize", "AXChildren"]
        while let (el, d) = stack.popLast() {
            if rows.count >= max || d > 12 { continue }
            let attrs = axMulti(el, names)
            var x = 0.0, y = 0.0, w = 0.0, h = 0.0
            if let pv = attrs["AXPosition"] {
                var p = CGPoint.zero
                AXValueGetValue(pv as! AXValue, .cgPoint, &p); x = p.x; y = p.y
            }
            if let sv = attrs["AXSize"] {
                var sz = CGSize.zero
                AXValueGetValue(sv as! AXValue, .cgSize, &sz); w = sz.width; h = sz.height
            }
            let value = attrs["AXValue"] as? String ?? ""
            rows.append([
                "depth": d,
                "role": attrs["AXRole"] as? String ?? "",
                "title": attrs["AXTitle"] as? String ?? "",
                "description": attrs["AXDescription"] as? String ?? "",
                // A document's whole text is its value: truncate it, since an
                // agent needs to know there is text far more than it needs all
                // of it shipped over the pipe on every tree read.
                "value": value.count > 200 ? String(value.prefix(200)) + "…" : value,
                "x": x, "y": y, "w": w, "h": h,
            ])
            let kids = attrs["AXChildren"] as? [AXUIElement] ?? []
            for k in kids.reversed() { stack.append((k, d + 1)) }
        }
        return ["ok": true, "nodes": rows]

    case "element_at":
        if let control = controlAt(pid: Int32(pid), x: num("x"), y: num("y")) {
            let f = axFrame(control)
            return [
                "ok": true, "role": axStr(control, "AXRole"),
                "description": axStr(control, "AXDescription"),
                "title": axStr(control, "AXTitle"),
                "actions": axActions(control),
                "x": f.origin.x, "y": f.origin.y, "w": f.size.width, "h": f.size.height,
            ]
        }
        guard let hit = hitTest(pid: Int32(pid), x: num("x"), y: num("y")) else {
            return ["ok": false, "error": "nothing at (\(num("x")), \(num("y")))"]
        }
        let f = axFrame(hit.element)
        return [
            "ok": true, "role": hit.role, "description": hit.description, "title": hit.title,
            "actions": axActions(hit.element),
            "x": f.origin.x, "y": f.origin.y, "w": f.size.width, "h": f.size.height,
        ]

    case "press_at":
        let tx = num("x"), ty = num("y")
        // The control whose frame contains the point, if there is one: that is
        // what a person would have clicked, and it is pressable.
        if let control = controlAt(pid: Int32(pid), x: tx, y: ty) {
            let f = axFrame(control)
            let rc = AXUIElementPerformAction(control, kAXPressAction as CFString).rawValue
            if rc == 0 {
                return [
                    "ok": true, "rc": 0, "via": "control",
                    "role": axStr(control, "AXRole"),
                    "description": axStr(control, "AXDescription"),
                    "title": axStr(control, "AXTitle"),
                    "x": f.origin.x, "y": f.origin.y, "w": f.size.width, "h": f.size.height,
                ]
            }
        }
        guard let hit = hitTest(pid: Int32(pid), x: tx, y: ty) else {
            return ["ok": false, "error": "nothing at (\(tx), \(ty))"]
        }
        let f = axFrame(hit.element)
        let rc = AXUIElementPerformAction(hit.element, kAXPressAction as CFString).rawValue
        return [
            "ok": rc == 0, "rc": Int(rc), "via": "hit test",
            "role": hit.role, "description": hit.description, "title": hit.title,
            "x": f.origin.x, "y": f.origin.y, "w": f.size.width, "h": f.size.height,
        ]

    case "press_label":
        let label = req["label"] as? String ?? ""
        let ax = appElement(pid)
        let controlRoles = ["AXButton", "AXCheckBox", "AXPopUpButton", "AXMenuItem", "AXRadioButton"]

        // Fast path: a control map walked moments ago. Most presses do not
        // restructure the tree, and re-walking on every click is what made a
        // click cost ~100 ms. A stale element fails its press, which drops the
        // cache and falls through to a fresh walk.
        if let cached = controlCache[pid], Date().timeIntervalSince(cached.at) < controlCacheTTL,
           let hit = matchControl(cached.controls, label) {
            let frame = hit.index < cached.frames.count ? cached.frames[hit.index] : axFrame(hit.element)
            let rc = AXUIElementPerformAction(hit.element, kAXPressAction as CFString).rawValue
            if rc == 0 {
                return [
                    "ok": true, "rc": 0, "label": hit.name, "requested": label,
                    "path": "cache",
                    "x": frame.origin.x, "y": frame.origin.y,
                    "w": frame.size.width, "h": frame.size.height,
                ]
            }
            controlCache[pid] = nil
        }

        // Slow path: walk the app's windows, skipping the menu bar (which is
        // large and holds nothing an action should be pressing). One batched
        // attribute read per node instead of four separate IPC calls.
        var controls: [(AXUIElement, String)] = []
        func scan(_ el: AXUIElement, _ depth: Int) {
            if depth > 30 || controls.count > 4000 { return }
            let attrs = axMulti(el, ["AXRole", "AXDescription", "AXTitle", "AXValue", "AXChildren"])
            let role = attrs["AXRole"] as? String ?? ""
            if controlRoles.contains(role) {
                let name = [attrs["AXDescription"], attrs["AXTitle"], attrs["AXValue"]]
                    .compactMap { $0 as? String }
                    .first(where: { !$0.isEmpty }) ?? ""
                if !name.isEmpty { controls.append((el, name)) }
            }
            if role == "AXMenuBar" || role == "AXMenuBarItem" || role == "AXMenu" { return }
            if let kids = attrs["AXChildren"] as? [AXUIElement] {
                for k in kids { scan(k, depth + 1) }
            }
        }
        var roots: [AXUIElement] = []
        if let mw = axAttr(ax, "AXMainWindow") { roots.append(mw as! AXUIElement) }
        if let ws = axAttr(ax, "AXWindows") as? [AXUIElement] { roots.append(contentsOf: ws) }
        for w in roots {
            scan(w, 0)
            // A modal sheet ("Save changes?" and friends) lives in AXSheets of
            // the window it is attached to, not in the window's own children.
            if let sheets = axAttr(w, "AXSheets") as? [AXUIElement] {
                for sheet in sheets { scan(sheet, 0) }
            }
        }
        if controls.isEmpty { scan(ax, 0) }

        controlCache[pid] = (controls, controls.map { axFrame($0.0) }, Date())
        guard let hit = matchControl(controls, label) else {
            let sample = controls.prefix(16).map { $0.1 }.joined(separator: ", ")
            return [
                "ok": false,
                "error": "no control labelled \"\(label)\"; available: \(sample)",
                "available": Array(controls.prefix(64).map { $0.1 }),
            ]
        }
        let frame = axFrame(hit.element)
        let rc = AXUIElementPerformAction(hit.element, kAXPressAction as CFString).rawValue
        return [
            "ok": rc == 0, "rc": Int(rc), "label": hit.name, "requested": label, "path": "walk",
            "x": frame.origin.x, "y": frame.origin.y,
            "w": frame.size.width, "h": frame.size.height,
        ]

    case "text_field":
        guard let el = textElement(appElement(pid)) else { return ["ok": false, "error": "no text field"] }
        let role = axStr(el, "AXRole")
        let v = axStr(el, "AXValue")
        return ["ok": true, "value": v, "role": role, "length": v.count]

    case "set_value":
        let value = req["value"] as? String ?? ""
        guard let el = textElement(appElement(pid)) else { return ["ok": false, "error": "no text field"] }
        let rc = AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, value as CFString).rawValue
        if rc == 0 {
            var r = CFRange(location: 0, length: 0)
            if let av = AXValueCreate(.cfRange, &r) {
                _ = AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, av)
            }
        }
        return ["ok": rc == 0, "rc": Int(rc)]

    case "set_caret":
        // location 0 = start, 1 = end, anything else is an absolute offset.
        // length 0 = no selection, -1 or 1 = to the end.
        let rawLoc = req["location"] as? Int ?? 0
        let rawLen = req["length"] as? Int ?? 0
        guard let el = textElement(appElement(pid)) else { return ["ok": false, "error": "no text field"] }
        let length = (axAttr(el, "AXNumberOfCharacters") as? Int) ?? (axStr(el, "AXValue").count)
        let loc = rawLoc == 1 ? length : rawLoc
        let len = rawLen < 0 ? max(0, length - loc) : rawLen
        var r = CFRange(location: loc, length: len)
        guard let av = AXValueCreate(.cfRange, &r) else { return ["ok": false, "error": "bad range"] }
        let rc = AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, av).rawValue
        return ["ok": rc == 0, "rc": Int(rc), "location": loc, "length": len]

    case "click", "double_click", "right_click", "move":
        let p = CGPoint(x: num("x"), y: num("y"))
        let button = cmd == "right_click" ? "right" : "left"
        if cmd == "double_click" {
            postClick(pid: pid, point: p, button: "left")
            usleep(60_000)
            postClick(pid: pid, point: p, button: "left")
        } else if cmd == "move" {
            let src = CGEventSource(stateID: .hidSystemState)
            if let mv = CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left) {
                mv.postToPid(pid)
            }
        } else {
            postClick(pid: pid, point: p, button: button)
        }
        return ["ok": true]

    case "drag":
        let a = CGPoint(x: num("x1"), y: num("y1"))
        let b = CGPoint(x: num("x2"), y: num("y2"))
        let src = CGEventSource(stateID: .hidSystemState)
        if let mv = CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: a, mouseButton: .left) { mv.postToPid(pid) }
        usleep(20_000)
        if let d = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: a, mouseButton: .left) { d.postToPid(pid) }
        for i in 1...12 {
            let t = Double(i) / 12.0
            let p = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            if let e = CGEvent(mouseEventSource: src, mouseType: .leftMouseDragged, mouseCursorPosition: p, mouseButton: .left) { e.postToPid(pid) }
            usleep(12_000)
        }
        if let u = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: b, mouseButton: .left) { u.postToPid(pid) }
        return ["ok": true]

    case "scroll":
        let p = CGPoint(x: num("x"), y: num("y"))
        let lines = Int32(req["lines"] as? Int ?? 3)
        let src = CGEventSource(stateID: .hidSystemState)
        if let mv = CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left) { mv.postToPid(pid) }
        if let e = CGEvent(scrollWheelEvent2Source: src, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0) {
            e.postToPid(pid)
            return ["ok": true]
        }
        return ["ok": false, "error": "scroll event creation failed"]

    case "type":
        let text = req["text"] as? String ?? ""
        let src = CGEventSource(stateID: .hidSystemState)
        var sent = 0
        for unit in text.utf16 {
            var c = unit
            if let d = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true) {
                d.keyboardSetUnicodeString(stringLength: 1, unicodeString: &c)
                d.postToPid(pid)
            }
            if let u = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) {
                u.keyboardSetUnicodeString(stringLength: 1, unicodeString: &c)
                u.postToPid(pid)
            }
            sent += 1
            usleep(6_000)
        }
        return ["ok": true, "sent": sent]

    case "key", "hotkey":
        let spec = req["key"] as? String ?? ""
        guard let (code, flags, name) = parseChord(spec) else {
            return ["ok": false, "error": "unknown key chord \"\(spec)\""]
        }
        let src = CGEventSource(stateID: .hidSystemState)
        if let d = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true) {
            d.flags = flags
            d.postToPid(pid)
        }
        usleep(12_000)
        if let u = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false) {
            u.flags = flags
            u.postToPid(pid)
        }
        return ["ok": true, "key": name, "flags": Int(flags.rawValue)]

    case "screenshot", "capture":
        var r = req
        r["cmd"] = "screenshot"
        return handleScreenshot(r)

    case "record":
        return recordWindow(req)

    case "open_file":
        // Open a document without showing a file panel and without bringing
        // the app forward. `open -g` is the whole trick.
        let path = req["path"] as? String ?? ""
        let app = req["app"] as? String ?? ""
        guard !path.isEmpty else { return ["ok": false, "error": "open_file needs a path"] }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = app.isEmpty ? ["-g", path] : ["-g", "-a", app, path]
        do {
            try p.run(); p.waitUntilExit()
            return ["ok": p.terminationStatus == 0, "exit": Int(p.terminationStatus),
                    "path": path, "app": app]
        } catch {
            return ["ok": false, "error": "\(error)"]
        }

    case "close_file":
        // Close one document without quitting the app.
        //
        // The reliable route is the window's own AXCloseButton: AXClose on the
        // window returns success but does nothing, and cmd+w posted to the pid
        // does not reach the app's key window while the app is in the
        // background. The close button works in every state we tested.
        let pid = req["pid"] as? Int ?? 0
        let name = req["name"] as? String ?? ""
        let ax = appElement(Int32(pid))

        func documentsNow() -> [String] { windowMenuDocuments(ax) ?? [] }
        let before = documentsNow()
        guard !before.isEmpty else { return ["ok": false, "error": "the app has no open documents"] }
        let target = name.isEmpty ? (before.first ?? "") : name
        guard before.contains(target) else {
            return ["ok": false, "error": "no open document named " + target, "available": before]
        }

        // A backgrounded Cocoa app usually exposes only its main window, so
        // bring the target document forward through the Window menu first.
        // That is a document-level focus change inside the app, never an
        // app-level activation, so the person's frontmost app does not move.
        if (axAttr(ax, "AXMainWindow").map { axStr($0 as! AXUIElement, "AXTitle") } ?? "") != target {
            _ = pressWindowMenuItem(ax, target)
            usleep(250_000)
        }

        var windows: [AXUIElement] = []
        if let ws = axAttr(ax, "AXWindows") as? [AXUIElement] { windows = ws }
        if let mw = axAttr(ax, "AXMainWindow") { windows.append(mw as! AXUIElement) }
        guard let w = windows.first(where: { axStr($0, "AXTitle") == target }) else {
            // A background app can only expose its front document, and it
            // cannot make another one key without being activated. Say that
            // plainly instead of failing with no explanation.
            let front = windows.first.map { axStr($0, "AXTitle") } ?? ""
            return [
                "ok": false,
                "error": "only the document that is in front can be closed while the app is in the background",
                "front_document": front,
                "requested": target,
                "hint": "close the front one first, or quit_app to close the whole app",
            ]
        }
        guard let closeButton = axAttr(w, "AXCloseButton") else {
            return ["ok": false, "error": "the window has no close button"]
        }
        let rc = AXUIElementPerformAction(closeButton as! AXUIElement, "AXPress" as CFString).rawValue
        usleep(400_000)

        if let sheets = axAttr(w, "AXSheets") as? [AXUIElement], !sheets.isEmpty {
            return [
                "ok": false,
                "error": "the document has unsaved changes and is asking whether to save; answer it or leave it",
                "sheet": axStr(sheets[0], "AXTitle"),
            ]
        }

        let after = documentsNow()
        if !after.contains(target) {
            return ["ok": true, "rc": Int(rc), "closed": target]
        }
        return ["ok": false, "error": "the close button was pressed but the document is still open"]

    case "documents":
        // The open documents of an app.
        //
        // AXWindows is often empty for a backgrounded Cocoa app (TextEdit
        // reports 0 while AXMainWindow reports the front document), so the
        // Window menu is the reliable enumeration: every open document is a
        // menu item in it.
        let pid = req["pid"] as? Int ?? 0
        let ax = appElement(Int32(pid))
        // The Window menu is the only reliable list. A backgrounded Cocoa app
        // reports no AXWindows, and AXMainWindow may be a window that is not a
        // document at all (TextEdit has one titled "TextEdit").
        if let docs = windowMenuDocuments(ax) {
            return ["ok": true, "documents": docs, "source": "window menu"]
        }
        // No Window menu: fall back to the windows, minus accessory/panel ones.
        var names: [String] = []
        if let ws = axAttr(ax, "AXWindows") as? [AXUIElement] {
            for w in ws {
                let sub = axStr(w, "AXSubrole")
                guard axStr(w, "AXRole") == "AXWindow", sub != "AXSystemDialog" else { continue }
                let t = axStr(w, "AXTitle")
                if !t.isEmpty && !t.contains("Accessory") { names.append(t) }
            }
        }
        return ["ok": true, "documents": names, "source": "windows"]

    case "file_dialog":
        return driveFileDialog(req)

    case "quit":
        return ["ok": true]

    default:
        return ["ok": false, "error": "unknown command \"\(cmd)\""]
    }
}
