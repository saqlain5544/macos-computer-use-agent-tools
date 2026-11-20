import CoreGraphics
import Foundation

// MARK: - shapes shared by the daemon, the tools and the MCP surface

struct Rect: Equatable {
    var x: Double = 0
    var y: Double = 0
    var w: Double = 0
    var h: Double = 0

    var json: [String: Any] { ["x": x, "y": y, "w": w, "h": h] }

    var cgRect: CGRect { CGRect(x: x, y: y, width: w, height: h) }

    static func from(_ d: [String: Any]?) -> Rect {
        guard let d = d else { return Rect() }
        return Rect(
            x: (d["x"] as? Double) ?? Double((d["x"] as? Int) ?? 0),
            y: (d["y"] as? Double) ?? Double((d["y"] as? Int) ?? 0),
            w: (d["w"] as? Double) ?? Double((d["w"] as? Int) ?? 0),
            h: (d["h"] as? Double) ?? Double((d["h"] as? Int) ?? 0)
        )
    }
}

struct WindowInfo {
    var pid: Int32
    var windowId: UInt32
    var owner: String
    var title: String
    var layer: Int
    var onScreen: Bool
    var bounds: Rect

    static func from(_ d: [String: Any]) -> WindowInfo? {
        guard let wid = d["window_id"] as? UInt32 ?? (d["window_id"] as? Int).flatMap({ UInt32(exactly: $0) }) else { return nil }
        return WindowInfo(
            pid: Int32((d["pid"] as? Int) ?? 0),
            windowId: wid,
            owner: (d["owner"] as? String) ?? "",
            title: (d["title"] as? String) ?? "",
            layer: (d["layer"] as? Int) ?? 0,
            onScreen: (d["on_screen"] as? Bool) ?? false,
            bounds: Rect(x: (d["x"] as? Double) ?? 0, y: (d["y"] as? Double) ?? 0,
                         w: (d["w"] as? Double) ?? 0, h: (d["h"] as? Double) ?? 0)
        )
    }
}

enum Mode: String {
    case background
    case focused

    static func parse(_ s: String?) -> Mode? {
        switch (s ?? "").trimmingCharacters(in: .whitespaces).lowercased() {
        case "background", "bg", "quiet": return .background
        case "focused", "focus", "foreground", "front": return .focused
        default: return nil
        }
    }
}

/// Which app an agent is bound to, and who owns it.
struct Target: Equatable {
    var pid: Int32 = 0
    /// Survives quit/relaunch: bundle id when known, else the name.
    var identity: String = ""
    var appName: String = ""
    var windowId: UInt32 = 0
    var windowTitle: String = ""
    var bounds: Rect = Rect()
    var owner: String = ""
    /// Is the window on the Space that is currently showing? Raw mouse and
    /// keyboard events are routed by the window server to visible windows only:
    /// a window on another Space, or a minimised one, never sees them — while
    /// accessibility actions still reach it. That difference decides which tools
    /// can work, so the target carries it.
    var onScreen: Bool = true
    /// Where the window was before the driver staged it onto its own display.
    var originalFrame: Rect? = nil
    /// Was the window fullscreen before staging? A fullscreen window has to be
    /// taken out of fullscreen before it can be moved, and put back afterwards.
    var wasFullscreen = false

    var label: String { windowTitle.isEmpty ? appName : "\(appName) · \(windowTitle)" }

    var json: [String: Any] {
        [
            "label": label,
            "app": appName,
            "identity": identity,
            "pid": Int(pid),
            "window": windowTitle,
            "on_screen": onScreen,
            "window_id": Int(windowId),
            "bounds": bounds.json,
            "owner": owner,
        ]
    }
}

/// What one tool call did, including what it is allowed to claim.
struct ActionReport {
    var ok = false
    var error = ""
    var detail = ""
    var pointerMoved = false
    var focusChanged = false
    var focusRestored = false
    var targetLabel = ""
    var mode = "background"
    /// How the mode was chosen for this call: "session" or the caller asked.
    var modeSource = "session"
    var payload: [String: Any]?
    /// Measured phases in milliseconds, for the operation log. Anything a tool
    /// wants to account for goes here rather than being guessed later.
    var phases: [String: Double] = [:]
    /// Focus detail: which app was in front before, which after, how long the
    /// raise and the restore took, and how many attempts the restore needed.
    var focusDetail: [String: Any] = [:]

    static func ok(_ detail: String) -> ActionReport {
        var r = ActionReport()
        r.ok = true
        r.detail = detail
        return r
    }

    static func err(_ detail: String) -> ActionReport {
        var r = ActionReport()
        r.ok = false
        r.error = detail
        return r
    }

    var json: [String: Any] {
        [
            "ok": ok,
            "error": error.isEmpty ? NSNull() : error,
            "detail": detail,
            "real_pointer_moved": pointerMoved,
            "focus_changed": focusChanged,
            "focus_restored": focusRestored,
            "mode": mode,
            "target": targetLabel,
            "data": payload ?? NSNull(),
        ]
    }
}

// MARK: - json

func jsonString(_ value: Any) -> String {
    guard JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
          let text = String(data: data, encoding: .utf8)
    else { return "{\"ok\":false,\"error\":\"could not encode reply\"}" }
    return text
}

func jsonObject(_ text: String) -> [String: Any]? {
    guard let data = text.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return obj
}

func asDouble(_ v: Any?) -> Double? {
    if let d = v as? Double { return d.isFinite ? d : nil }
    if let i = v as? Int { return Double(i) }
    if let n = v as? NSNumber { let d = n.doubleValue; return d.isFinite ? d : nil }
    if let s = v as? String { return Double(s) }
    return nil
}

/// Convert to Int without ever trapping.
///
/// `NSNumber.intValue` traps on a value outside Int's range, and a JSON body is
/// attacker-shaped by definition: the first version of the wait_for tool killed
/// the daemon this way. `Int(exactly:)` returns nil instead, which becomes an
/// ordinary "that field was not a usable number".
func asInt(_ v: Any?) -> Int? {
    if let i = v as? Int { return i }
    if let d = v as? Double { return Int(exactly: d.rounded()) }
    if let n = v as? NSNumber { return Int(exactly: n.doubleValue.rounded()) }
    if let s = v as? String {
        if let i = Int(s) { return i }
        if let d = Double(s) { return Int(exactly: d.rounded()) }
    }
    return nil
}

func asBool(_ v: Any?) -> Bool? {
    if let b = v as? Bool { return b }
    if let n = v as? NSNumber { return n.boolValue }
    return nil
}

func asString(_ v: Any?) -> String? { v as? String }
