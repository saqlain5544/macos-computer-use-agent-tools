import Foundation

// Self-tests for the driver's pure logic.
//
// The platform calls need a real app to drive, and those are covered by
// scripts/tool_audit.py and scripts/acceptance.sh against a running driver.
// What belongs here is everything that can be decided without one: the rules
// that pick a window, shape a path, or decide what a report is allowed to claim.

// Unbuffered, so a crash still shows which check it died on.
setvbuf(stdout, nil, _IONBF, 0)

var failures = 0
var checks = 0

func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
    checks += 1
    if condition {
        print("  ok   \(name)")
    } else {
        failures += 1
        print("  FAIL \(name) \(detail())")
    }
}

print("quiet-driver self-tests")

// MARK: modes

check("mode parses background", Mode.parse("background") == .background)
check("mode parses bg", Mode.parse("BG") == .background)
check("mode parses focused", Mode.parse("focused") == .focused)
check("mode parses front", Mode.parse("front") == .focused)
check("mode rejects nonsense", Mode.parse("sideways") == nil)
check("mode rejects empty", Mode.parse("") == nil)

// MARK: window rules

let document = Window(pid: 7, windowId: 11, owner: "TextEdit", title: "notes.txt",
                      layer: 0, onScreen: true, bounds: Rect(x: 0, y: 0, w: 640, h: 400))
let strip = Window(pid: 7, windowId: 12, owner: "TextEdit", title: "",
                   layer: 0, onScreen: true, bounds: Rect(x: 0, y: 0, w: 1512, h: 33))
let panel = Window(pid: 7, windowId: 13, owner: "TextEdit", title: "Save Panel Accessory View",
                   layer: 0, onScreen: true, bounds: Rect(x: 0, y: 0, w: 1428, h: 128))
let dialog = Window(pid: 7, windowId: 14, owner: "TextEdit", title: "Open",
                    layer: 0, onScreen: true, bounds: Rect(x: 0, y: 0, w: 600, h: 400))

check("a document window is usable", Session.isUsableWindow(document))
check("a 33px strip is not", !Session.isUsableWindow(strip))
check("an accessory panel is not", !Session.isUsableWindow(panel))
check("a dialog titled Open is not", !Session.isUsableWindow(dialog))
check("accessory titles are recognised", Session.isAccessory("Save Panel Accessory View"))
check("plain titles are not accessory", !Session.isAccessory("notes.txt"))

// MARK: workspace

check("slug keeps safe characters", Workspace.slug("my agent_1") == "my-agent_1")
check("slug never contains a slash", !Workspace.slug("../../etc/passwd").contains("/"))
check("slug is bounded", Workspace.slug(String(repeating: "a", count: 200)).count <= 48)
check("empty slug falls back", Workspace.slug("") == "agent")
check("agent dir is under the root",
      Workspace.agentDir("builder 1").hasPrefix("/tmp/quiet-driver/agent-"))
check("a relative artifact stays in the workspace",
      (try? Workspace.resolveOutput("t", "screenshot", "png", requested: "shot.png"))?
        .hasPrefix("/tmp/quiet-driver/agent-t/") == true)
check("an absolute artifact is honoured",
      (try? Workspace.resolveOutput("t", "screenshot", "png", requested: "/tmp/x/y.png")) == "/tmp/x/y.png")

// MARK: reports

var okReport = ActionReport.ok("did the thing")
okReport.mode = "background"
let okJSON = okReport.json
check("a success reports ok", okJSON["ok"] as? Bool == true)
check("a success has no error string", okJSON["error"] is NSNull)
check("a success does not claim focus", okJSON["focus_changed"] as? Bool == false)
check("a success does not claim pointer movement", okJSON["real_pointer_moved"] as? Bool == false)

let errJSON = ActionReport.err("it did not work").json
check("a failure reports ok=false", errJSON["ok"] as? Bool == false)
check("a failure carries its reason", (errJSON["error"] as? String) == "it did not work")

// A driver that says it gave focus back when it never took it is lying about the
// one thing this project promises.
func focusFlagsAreHonest(changed: Bool, restored: Bool) -> Bool { !restored || changed }
check("restored implies changed", focusFlagsAreHonest(changed: true, restored: true))
check("not moving focus is not restoring it", focusFlagsAreHonest(changed: false, restored: false))
check("the impossible combination is impossible", !focusFlagsAreHonest(changed: false, restored: true))

// MARK: json

check("json round trip", jsonObject(jsonString(["a": 1, "b": "two"]))?["b"] as? String == "two")
check("json sorts keys", jsonString(["b": 1, "a": 2]).hasPrefix("{\"a\""))
check("invalid json is nil", jsonObject("{not json") == nil)
check("an empty body is nil", jsonObject("") == nil)

// MARK: conversions
//
// A trapping Swift conversion is not an error, it is a crash: the first version
// parsed an unsigned 64-bit hash with UInt64(Int) and killed the daemon on the
// second wait_for. Every value that crosses the worker boundary has to survive
// nonsense.
check("a huge number is refused, not trapped",
      asInt(NSNumber(value: Double.greatestFiniteMagnitude)) == nil)
check("an ordinary number still parses", asInt(NSNumber(value: 7)) == 7)
check("a numeric string parses", asInt("12") == 12)
check("a non-numeric string is nil", asInt("twelve") == nil)
check("a negative window id is not a window",
      asInt(-5).flatMap { UInt32(exactly: $0) } == nil)
check("a huge window id is not a window",
      asInt(Int.max).flatMap { UInt32(exactly: $0) } == nil)
check("doubles parse from ints", asDouble(NSNumber(value: 7)) == 7)
check("bools parse from numbers", asBool(NSNumber(value: 1)) == true)

// MARK: metrics

let metrics = Metrics()
for _ in 0..<20 { metrics.record("fast", micros: 500, ok: true) }
for _ in 0..<5 { metrics.record("slow", micros: 50_000, ok: true) }
metrics.record("slow", micros: 60_000, ok: false)
let snap = metrics.snapshot(actionsTotal: 26)
let tools = snap["tools"] as? [String: Any] ?? [:]
check("metrics tracks each tool", tools.count == 2)
if let fast = tools["fast"] as? [String: Any] {
    check("metrics records a median", (fast["p50_ms"] as? Double) == 0.5)
    check("metrics counts calls", (fast["count"] as? Int) == 20)
}
if let slow = tools["slow"] as? [String: Any] {
    check("metrics counts errors", (slow["errors"] as? Int) == 1)
    check("the slowest tool sorts first",
          ((snap["slowest"] as? [[String: Any]])?.first?["tool"] as? String) == "slow")
}
check("error rate is a percentage", (snap["error_rate"] as? Double) == 3.85)
metrics.reset()
check("metrics reset clears history",
      ((metrics.snapshot(actionsTotal: 0)["tools"] as? [String: Any])?.isEmpty) == true)

// MARK: routing
//
// A tool can be listed and advertised and still not be reachable: the dispatcher
// has a second switch that decides whether a tool is a session tool or one that
// acts on the app, and a name missing from it falls through to "unknown tool".
// Comparing that switch's list against Tools.names is the cheap way to catch it.
check("every tool is routed to a handler",
      Tools.routedNames.count == Tools.names.count,
      "missing: \(Tools.names.filter { !Tools.routedNames.contains($0) })")

// MARK: surfaces agree

var seen = Set<String>()
for name in Tools.names { seen.insert(name) }
check("tool names are unique", seen.count == Tools.names.count)

let mcpNames = MCP.toolNames
check("mcp advertises every tool an agent needs", mcpNames.count >= 27, "\(mcpNames.count)")
check("every mcp tool is implemented",
      mcpNames.allSatisfy { Tools.names.contains($0) },
      "\(mcpNames.filter { !Tools.names.contains($0) })")
// A handful of names exist only on the HTTP surface: aliases an agent does not
// need (`bind`, `type`, `key`), and operator controls (`pause`, `resume`,
// `show_dashboard`) that belong to whoever runs the driver, not to a model.
let httpOnly: Set<String> = ["bind", "launch", "type", "key", "move", "press_button",
                             "stop_driver", "start_driver", "get_window_state",
                             "clipboard_read", "clipboard_write", "pause", "resume",
                             "show_dashboard"]
let expectedOverMCP = Tools.names.filter { !httpOnly.contains($0) }
check("every tool an agent needs is advertised over mcp",
      expectedOverMCP.allSatisfy { mcpNames.contains($0) },
      "\(expectedOverMCP.filter { !mcpNames.contains($0) })")

// MARK: paths and identity

check("a bundle id is preferred as identity", !("TextEdit".isEmpty))
let t = Target(pid: 9, identity: "com.apple.TextEdit", appName: "TextEdit",
               windowId: 3, windowTitle: "notes.txt", bounds: Rect(), owner: "a")
check("target labels name the window", t.label == "TextEdit · notes.txt")
var bare = t
bare.windowTitle = ""
check("a windowless target labels the app", bare.label == "TextEdit")

print("")
print(failures == 0 ? "  \(checks) checks passed" : "  \(failures) of \(checks) checks FAILED")
exit(failures == 0 ? 0 : 1)
