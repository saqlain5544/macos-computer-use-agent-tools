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

// ScreenCaptureKit asserts unless the process has an AppKit session.
let _qdApp = NSApplication.shared

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

func postClick(pid: Int32, point: CGPoint, button: String) {
    let src = CGEventSource(stateID: .hidSystemState)
    let down: CGEventType = button == "right" ? .rightMouseDown : .leftMouseDown
    let up: CGEventType = button == "right" ? .rightMouseUp : .leftMouseUp
    let btn: CGMouseButton = button == "right" ? .right : .left
    if let mv = CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: btn) {
        mv.postToPid(pid)
    }
    usleep(18_000)
    if let d = CGEvent(mouseEventSource: src, mouseType: down, mouseCursorPosition: point, mouseButton: btn) {
        d.postToPid(pid)
    }
    usleep(70_000)
    if let u = CGEvent(mouseEventSource: src, mouseType: up, mouseCursorPosition: point, mouseButton: btn) {
        u.postToPid(pid)
    }
    usleep(40_000)
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
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-x", "-o", "-l", String(wid), path]
    do {
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0, FileManager.default.fileExists(atPath: path) else {
            return ["ok": false, "error": "screencapture exited \(p.terminationStatus) for window \(wid)"]
        }
        let bytes = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int) ?? 0
        var width = 0, height = 0
        if let rep = NSBitmapImageRep(data: (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data()) {
            width = rep.pixelsWide; height = rep.pixelsHigh
        }
        return ["ok": true, "path": path, "bytes": bytes, "width": width, "height": height]
    } catch {
        return ["ok": false, "error": "\(error)"]
    }
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
            return ["ok": false, "error": "\"\(app)\" is not running"]
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
        return [
            "ok": target.isTerminated,
            "requested": asked,
            "terminated": target.isTerminated,
            "waited_ms": waited,
            "name": target.localizedName ?? "",
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
        while let (el, d) = stack.popLast() {
            if rows.count >= max || d > 12 { continue }
            let kids = axAttr(el, "AXChildren") as? [AXUIElement] ?? []
            let f = axFrame(el)
            rows.append([
                "depth": d,
                "role": axStr(el, "AXRole"),
                "title": axStr(el, "AXTitle"),
                "description": axStr(el, "AXDescription"),
                "value": axStr(el, "AXValue"),
                "x": f.origin.x, "y": f.origin.y, "w": f.size.width, "h": f.size.height,
                "actions": axActions(el),
            ])
            for k in kids.reversed() { stack.append((k, d + 1)) }
        }
        return ["ok": true, "nodes": rows]

    case "element_at":
        let ax = appElement(pid)
        let tx = num("x"), ty = num("y")
        var best: AXUIElement?
        var bestArea = Double.greatestFiniteMagnitude
        var bestRole = "", bestDesc = "", bestTitle = ""
        for el in walk(ax) {
            let f = axFrame(el)
            if f.width <= 0 || f.height <= 0 { continue }
            if !f.contains(CGPoint(x: tx, y: ty)) { continue }
            let area = f.width * f.height
            if area < bestArea {
                bestArea = area; best = el
                bestRole = axStr(el, "AXRole")
                bestDesc = axStr(el, "AXDescription")
                bestTitle = axStr(el, "AXTitle")
            }
        }
        guard let el = best else { return ["ok": false, "error": "nothing at (\(tx), \(ty))"] }
        let f = axFrame(el)
        return [
            "ok": true, "role": bestRole, "description": bestDesc, "title": bestTitle,
            "actions": axActions(el),
            "x": f.origin.x, "y": f.origin.y, "w": f.size.width, "h": f.size.height,
        ]

    case "press_at":
        let ax = appElement(pid)
        let tx = num("x"), ty = num("y")
        var best: AXUIElement?
        var bestArea = Double.greatestFiniteMagnitude
        for el in walk(ax) {
            let f = axFrame(el)
            if f.width <= 0 || f.height <= 0 { continue }
            if !f.contains(CGPoint(x: tx, y: ty)) { continue }
            let area = f.width * f.height
            if area < bestArea { bestArea = area; best = el }
        }
        guard let el = best else { return ["ok": false, "error": "nothing at (\(tx), \(ty))"] }
        let rc = AXUIElementPerformAction(el, kAXPressAction as CFString).rawValue
        return [
            "ok": rc == 0, "rc": Int(rc),
            "role": axStr(el, "AXRole"),
            "description": axStr(el, "AXDescription"),
            "title": axStr(el, "AXTitle"),
        ]

    case "press_label":
        let label = req["label"] as? String ?? ""
        let ax = appElement(pid)
        var controls: [(AXUIElement, String)] = []
        for el in walk(ax) {
            let role = axStr(el, "AXRole")
            guard ["AXButton", "AXCheckBox", "AXPopUpButton", "AXMenuItem", "AXRadioButton"].contains(role) else { continue }
            let name = [axStr(el, "AXDescription"), axStr(el, "AXTitle"), axStr(el, "AXValue")]
                .first(where: { !$0.isEmpty }) ?? ""
            if !name.isEmpty { controls.append((el, name)) }
        }

        func words(_ s: String) -> Set<String> {
            Set(s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        }
        let needle = label.lowercased()
        let wanted = words(label)

        // 1. exact, 2. case-insensitive, 3. unique control whose words are a
        // subset of the request's words ("All Clear" -> "Clear", but never
        // "Clear Memory"). Nothing looser: pressing the wrong control is worse
        // than failing.
        var match: (AXUIElement, String)? = controls.first { $0.1 == label }
        if match == nil { match = controls.first { $0.1.lowercased() == needle } }
        if match == nil {
            let subset = controls.filter { c in
                let w = words(c.1)
                return !w.isEmpty && w.isSubset(of: wanted)
            }
            if subset.count == 1 { match = subset[0] }
        }
        guard let (el, name) = match else {
            let sample = controls.prefix(16).map { $0.1 }.joined(separator: ", ")
            return [
                "ok": false,
                "error": "no control labelled \"\(label)\"; available: \(sample)",
                "available": Array(controls.prefix(64).map { $0.1 }),
            ]
        }
        let frame = axFrame(el)
        let rc = AXUIElementPerformAction(el, kAXPressAction as CFString).rawValue
        return [
            "ok": rc == 0, "rc": Int(rc), "label": name, "requested": label,
            "x": frame.origin.x, "y": frame.origin.y, "w": frame.size.width, "h": frame.size.height,
        ]

    case "text_field":
        let ax = appElement(pid)
        for el in walk(ax) {
            let role = axStr(el, "AXRole")
            if role == "AXTextArea" || role == "AXTextField" {
                let v = axStr(el, "AXValue")
                return ["ok": true, "value": v, "role": role, "length": v.count]
            }
        }
        return ["ok": false, "error": "no text field"]

    case "set_value":
        let ax = appElement(pid)
        let value = req["value"] as? String ?? ""
        for el in walk(ax) {
            let role = axStr(el, "AXRole")
            if role == "AXTextArea" || role == "AXTextField" {
                let rc = AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, value as CFString).rawValue
                if rc == 0 {
                    var r = CFRange(location: 0, length: 0)
                    if let av = AXValueCreate(.cfRange, &r) {
                        _ = AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, av)
                    }
                }
                return ["ok": rc == 0, "rc": Int(rc)]
            }
        }
        return ["ok": false, "error": "no text field"]

    case "set_caret":
        let ax = appElement(pid)
        let loc = req["location"] as? Int ?? 0
        let len = req["length"] as? Int ?? 0
        for el in walk(ax) {
            let role = axStr(el, "AXRole")
            if role == "AXTextArea" || role == "AXTextField" {
                var r = CFRange(location: loc, length: len)
                guard let av = AXValueCreate(.cfRange, &r) else { return ["ok": false, "error": "bad range"] }
                let rc = AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, av).rawValue
                r = CFRange(location: 0, length: 0)
                return ["ok": rc == 0, "rc": Int(rc)]
            }
        }
        return ["ok": false, "error": "no text field"]

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
            return ["ok": false, "error": "no window titled " + target]
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
        var names: [String] = []
        if let ws = axAttr(ax, "AXWindows") as? [AXUIElement] {
            for w in ws {
                let sub = axStr(w, "AXSubrole")
                guard axStr(w, "AXRole") == "AXWindow", sub != "AXSystemDialog" else { continue }
                let t = axStr(w, "AXTitle")
                if !t.isEmpty && !t.contains("Accessory") { names.append(t) }
            }
        }
        if names.isEmpty, let mw = axAttr(ax, "AXMainWindow") {
            let t = axStr(mw as! AXUIElement, "AXTitle")
            if !t.isEmpty { names.append(t) }
        }
        if let menuDocs = windowMenuDocuments(ax) {
            for d in menuDocs where !names.contains(d) { names.append(d) }
        }
        return ["ok": true, "documents": names]

    case "file_dialog":
        return driveFileDialog(req)

    case "quit":
        return ["ok": true]

    default:
        return ["ok": false, "error": "unknown command \"\(cmd)\""]
    }
}

// MARK: - main loop

setvbuf(stdout, nil, _IOLBF, 0)

// One message in, one JSON line out, forever.
//
// The whole iteration runs inside an explicit autorelease pool. This process is
// a readLine() loop with no run loop, so no pool is ever drained for us: the
// bridged collections and strings that Foundation creates for each request pile
// up, and the helper grows by several KB per action — tens of MB over a working
// session. Pooling the iteration keeps the working set flat.
while autoreleasepool(invoking: { () -> Bool in
    // If the daemon that spawned us is gone, we are an orphan: exit rather
    // than sit on a 30 MB AX connection for the rest of the session.
    if getppid() == 1 { return false }
    guard let line = readLine(strippingNewline: true) else { return false }
    if line.isEmpty { return true }
    guard let data = line.data(using: .utf8),
          let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else {
        print("{\"ok\":false,\"error\":\"bad json\"}")
        return true
    }
    let reply = handle(obj)
    if let out = try? JSONSerialization.data(withJSONObject: reply),
       let text = String(data: out, encoding: .utf8) {
        print(text)
    } else {
        print("{\"ok\":false,\"error\":\"encode failed\"}")
    }
    return (obj["cmd"] as? String) != "quit"
}) {}
