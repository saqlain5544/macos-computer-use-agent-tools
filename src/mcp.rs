//! MCP (Model Context Protocol) surface for the driver.
//!
//! The driver is the MCP server: one process, one port. An agent that speaks
//! MCP talks to `http://127.0.0.1:<port>/mcp` and sees the same tools the HTTP
//! API offers, with the same guarantees — bound app, background delivery, no
//! focus stealing.
//!
//! Transport is Streamable HTTP: JSON-RPC 2.0 messages POSTed to `/mcp`, with
//! the response either as a JSON body or as a single SSE event. `initialize`,
//! `notifications/initialized`, `tools/list`, `tools/call`, `ping` and
//! `resources/list` are implemented, which is the whole surface an agent needs.

use serde_json::{json, Map, Value};

use crate::worker::WorkerPool;
use crate::session::Handle;
use crate::server;

/// The protocol revision we advertise.
pub const PROTOCOL_VERSION: &str = "2025-11-25";

/// The revisions we can speak. The newest we prefer is `PROTOCOL_VERSION`.
const SUPPORTED_PROTOCOL_VERSIONS: &[&str] = &[
    "2025-11-25",
    "2025-06-18",
    "2025-03-26",
    "2024-11-05",
    "2024-10-07",
];

/// Per-call mode. Applies to this call only; the session default is set with
/// set_mode.
fn mode_prop() -> Value {
    json!({
        "type": "string",
        "enum": ["background", "focused"],
        "description": "For this call only. background (default) never disturbs the person; focused raises the target for the action and restores their app afterwards."
    })
}

fn agent_prop() -> Value {
    json!({
        "type": "string",
        "description": "Your agent id. Gives you your own workspace for screenshots and recordings, and names you as the owner when binding an app."
    })
}

/// One MCP tool as advertised to the client.
struct ToolSpec {
    name: &'static str,
    description: &'static str,
    schema: fn() -> Value,
}

/// Every tool the driver exposes over MCP. The names match the HTTP `tool`
/// field so both surfaces behave identically.
fn tool_specs() -> Vec<ToolSpec> {
    fn obj(props: Value, required: Vec<&str>) -> Value {
        json!({
            "type": "object",
            "properties": props,
            "required": required,
            "additionalProperties": false
        })
    }
    fn s(desc: &str) -> Value {
        json!({ "type": "string", "description": desc })
    }
    fn n(desc: &str) -> Value {
        json!({ "type": "number", "description": desc })
    }
    fn b(desc: &str) -> Value {
        json!({ "type": "boolean", "description": desc })
    }
    fn point() -> Value {
        json!({
            "type": "object",
            "description": "A point in the bound window's own coordinates, relative to its top-left corner.",
            "properties": { "x": n("x offset"), "y": n("y offset") },
            "required": ["x", "y"]
        })
    }
    let agent = || s("Your agent id. Gives you your own workspace for screenshots and recordings, and names you as the owner when binding an app.");

    vec![
        ToolSpec {
            name: "bind_app",
            description: "Bind to a running app by name, bundle id, pid, or window title. All later actions go to this app. The binding survives the app being quit and relaunched. If another agent already owns the app, this is refused unless takeover is true.",
            schema: || obj(
                json!({
                    "app": s("App name, bundle id, pid, or window title"),
                    "agent": agent_prop(),
                    "window_id": n("Pick a specific window of that app"),
                    "takeover": b("Take the app over from another agent")
                }),
                vec!["app"],
            ),
        },
        ToolSpec {
            name: "unbind",
            description: "Release the bound app.",
            schema: || obj(json!({}), vec![]),
        },
        ToolSpec {
            name: "rebind",
            description: "Re-resolve the bound app after it was quit and relaunched.",
            schema: || obj(json!({}), vec![]),
        },
        ToolSpec {
            name: "launch_app",
            description: "Launch an app in the background without binding it and without stealing focus.",
            schema: || obj(json!({ "app": s("App name or bundle id") }), vec!["app"]),
        },
        ToolSpec {
            name: "quit_app",
            description: "Quit an app by name or bundle id. Refuses rather than discarding unsaved work; pass force only when the person has agreed to lose it.",
            schema: || obj(
                json!({
                    "app": s("App name or bundle id"),
                    "force": b("Terminate even if the app does not quit on its own (discards unsaved work)")
                }),
                vec!["app"],
            ),
        },
        ToolSpec {
            name: "list_windows",
            description: "List every top-level window on the machine, including windows on other Spaces and minimised windows.",
            schema: || obj(json!({}), vec![]),
        },
        ToolSpec {
            name: "get_accessibility_tree",
            description: "Read the accessibility tree of the bound app. This is how you see a background app: the tree does not depend on what is on screen.",
            schema: || obj(json!({}), vec![]),
        },
        ToolSpec {
            name: "get_desktop_state",
            description: "The frontmost app, the bound target, and the current mode.",
            schema: || obj(json!({}), vec![]),
        },
        ToolSpec {
            name: "click",
            description: "Click a point in the bound window. The point is resolved to the element under it and activated through Accessibility. Runs in background mode unless this call asks for focused.",
            schema: || obj(
                json!({
                    "x": n("x in window coordinates"),
                    "y": n("y in window coordinates"),
                    "mode": mode_prop()
                }),
                vec!["x", "y"],
            ),
        },
        ToolSpec {
            name: "double_click",
            description: "Double-click a point in the bound window.",
            schema: || obj(json!({ "x": n("x"), "y": n("y") }), vec!["x", "y"]),
        },
        ToolSpec {
            name: "right_click",
            description: "Right-click a point in the bound window.",
            schema: || obj(json!({ "x": n("x"), "y": n("y") }), vec!["x", "y"]),
        },
        ToolSpec {
            name: "move_cursor",
            description: "Move the agent's virtual cursor over the bound window. The person's pointer is never moved.",
            schema: || obj(json!({ "x": n("x"), "y": n("y") }), vec!["x", "y"]),
        },
        ToolSpec {
            name: "mouse_drag",
            description: "Drag from one point to another inside the bound window.",
            schema: || obj(
                json!({
                    "x": n("start x"), "y": n("start y"),
                    "to": point()
                }),
                vec!["x", "y", "to"],
            ),
        },
        ToolSpec {
            name: "scroll",
            description: "Scroll at a point in the bound window.",
            schema: || obj(json!({ "x": n("x"), "y": n("y"), "lines": n("scroll lines") }), vec!["x", "y"]),
        },
        ToolSpec {
            name: "type_text",
            description: "Type text into the bound app. Delivered to the app's process, so it works while the app is in the background.",
            schema: || obj(json!({ "text": s("text to type"), "agent": agent_prop() }), vec!["text"]),
        },
        ToolSpec {
            name: "press_key",
            description: "Press one key in the bound app, e.g. \"Return\" or \"Tab\".",
            schema: || obj(json!({ "text": s("key name") }), vec!["text"]),
        },
        ToolSpec {
            name: "hotkey",
            description: "Press a key chord in the bound app, e.g. \"cmd+shift+t\".",
            schema: || obj(json!({ "text": s("chord") }), vec!["text"]),
        },
        ToolSpec {
            name: "set_value",
            description: "Set the bound app's text field directly. More reliable than typing and leaves the person's keyboard alone.",
            schema: || obj(json!({ "text": s("new value") }), vec!["text"]),
        },
        ToolSpec {
            name: "set_caret",
            description: "Move the insertion point in the bound app's text field.",
            schema: || obj(json!({ "location": n("0 = start, 1 = end"), "length": n("length") }), vec![]),
        },
        ToolSpec {
            name: "click_label",
            description: "Press a control in the bound app by its label, e.g. \"Equals\" or \"Save\". Matching is exact first, then case-insensitive, then a unique word subset.",
            schema: || obj(json!({ "label": s("control label") }), vec!["label"]),
        },
        ToolSpec {
            name: "get_text",
            description: "Read the bound app's text field.",
            schema: || obj(json!({}), vec![]),
        },
        ToolSpec {
            name: "screenshot",
            description: "Capture the bound window to a PNG. Works when the app is background, occluded, minimised, on another Space, or hidden. Saved into your workspace unless you give a path.",
            schema: || obj(
                json!({
                    "path": s("Where to save it; absolute or relative to your workspace"),
                    "agent": agent_prop()
                }),
                vec![],
            ),
        },
        ToolSpec {
            name: "record",
            description: "Record the bound window to a .mov for a few seconds. Works in any window state. Saved into your workspace unless you give a path.",
            schema: || obj(
                json!({
                    "seconds": n("how long to record, 0.5 - 60"),
                    "path": s("Where to save it; absolute or relative to your workspace"),
                    "agent": agent_prop()
                }),
                vec![],
            ),
        },
        ToolSpec {
            name: "open_file",
            description: "Open a document in the bound app without showing a file panel and without stealing focus. This is how you open a file without disturbing the person.",
            schema: || obj(
                json!({
                    "path": s("the file to open"),
                    "app": s("which app opens it; defaults to the bound app")
                }),
                vec!["path"],
            ),
        },
        ToolSpec {
            name: "close_file",
            description: "Close one document of the bound app, leaving the app running.",
            schema: || obj(json!({ "name": s("the document; defaults to the frontmost one") }), vec![]),
        },
        ToolSpec {
            name: "documents",
            description: "The documents the bound app has open.",
            schema: || obj(json!({}), vec![]),
        },
        ToolSpec {
            name: "set_mode",
            description: "Switch between background (default; the person is never disturbed) and focused (the target is raised for one action, then restored).",
            schema: || obj(json!({ "mode": s("\"background\" or \"focused\"") }), vec!["mode"]),
        },
        ToolSpec {
            name: "log_friction",
            description: "Record a problem you hit while using the driver, so it can be fixed later. Use this whenever the driver got in your way.",
            schema: || obj(
                json!({
                    "problem": s("what went wrong"),
                    "detail": s("anything that helps reproduce it"),
                    "source_tool": s("which tool you were calling"),
                    "agent": agent_prop()
                }),
                vec!["problem"],
            ),
        },
        ToolSpec {
            name: "friction_log",
            description: "Read back the friction points logged so far.",
            schema: || obj(json!({ "limit": n("how many entries") }), vec![]),
        },
        ToolSpec {
            name: "workspace",
            description: "Your own directory for disposable artefacts, and what is in it.",
            schema: || obj(json!({ "agent": agent_prop() }), vec![]),
        },
        ToolSpec {
            name: "status",
            description: "The driver's state: bound target, owner, mode, permissions, focus counters, recent actions.",
            schema: || obj(json!({}), vec![]),
        },
    ]
}

/// Handle one JSON-RPC message. Returns the response, or `None` for a
/// notification (which by definition gets no reply).
pub fn handle_message(message: &Value, shared: &Handle, pool: &WorkerPool) -> Option<Value> {
    let method = message.get("method").and_then(|m| m.as_str()).unwrap_or("");
    let id = message.get("id").cloned();
    let params = message.get("params").cloned().unwrap_or(json!({}));

    // A notification carries no id and must not be answered.
    let is_notification = id.is_none();

    let result: Result<Value, (i32, String)> = match method {
        "initialize" => {
            // Negotiate: answer with the client's version when we speak it.
            let requested = params
                .get("protocolVersion")
                .and_then(|v| v.as_str())
                .unwrap_or("");
            let version = if SUPPORTED_PROTOCOL_VERSIONS.contains(&requested) {
                requested
            } else {
                PROTOCOL_VERSION
            };
            Ok(json!({
            "protocolVersion": version,
            "capabilities": {
                "tools": { "listChanged": false }
            },
            "serverInfo": {
                "name": "quiet-driver",
                "version": env!("CARGO_PKG_VERSION")
            },
            "instructions": INSTRUCTIONS
            }))
        }
        "notifications/initialized" | "initialized" => Ok(json!({})),
        "ping" => Ok(json!({})),
        "tools/list" => Ok(json!({
            "tools": tool_specs()
                .iter()
                .map(|t| json!({
                    "name": t.name,
                    "description": t.description,
                    "inputSchema": (t.schema)()
                }))
                .collect::<Vec<_>>()
        })),
        "resources/list" => Ok(json!({ "resources": [] })),
        "prompts/list" => Ok(json!({ "prompts": [] })),
        "tools/call" => {
            let name = params.get("name").and_then(|n| n.as_str()).unwrap_or("");
            let args = params.get("arguments").cloned().unwrap_or(json!({}));
            match call_tool(name, &args, shared, pool) {
                Ok(v) => Ok(v),
                Err((code, msg)) => Err((code, msg)),
            }
        }
        "" => Err((-32600, "missing method".to_string())),
        other => Err((-32601, format!("unknown method: {}", other))),
    };

    if is_notification {
        return None;
    }

    Some(match result {
        Ok(value) => json!({ "jsonrpc": "2.0", "id": id, "result": value }),
        Err((code, message)) => json!({
            "jsonrpc": "2.0",
            "id": id,
            "error": { "code": code, "message": message }
        }),
    })
}

/// Run one tool and shape the result the way MCP wants it.
fn call_tool(
    name: &str,
    args: &Value,
    shared: &Handle,
    pool: &WorkerPool,
) -> Result<Value, (i32, String)> {
    let known = tool_specs().iter().any(|t| t.name == name);
    if !known {
        return Err((-32602, format!("unknown tool: {}", name)));
    }
    let mut body = Map::new();
    body.insert("tool".into(), json!(name));
    if let Some(map) = args.as_object() {
        for (k, v) in map {
            body.insert(k.clone(), v.clone());
        }
    }
    // A per-call "mode" argument applies to this call only, exactly as it does
    // over HTTP; it never changes the session.
    let call_mode = args
        .get("mode")
        .and_then(|v| v.as_str())
        .and_then(crate::session::Mode::parse);
    let report = server::execute_public(name, &body, call_mode, shared, pool);

    let payload = report.payload.clone().unwrap_or(Value::Null);
    let mut text = report.detail.clone();
    if !report.error.is_empty() {
        text = format!("{}: {}", report.error, report.detail);
    }

    // A screenshot becomes an image block so the model can look at it.
    let mut content = vec![json!({ "type": "text", "text": text })];
    if let Some(path) = payload.get("path").and_then(|p| p.as_str()) {
        if name == "screenshot" {
            if let Ok(bytes) = std::fs::read(path) {
                if let Some(b64) = base64_encode(&bytes) {
                    content.push(json!({
                        "type": "image",
                        "data": b64,
                        "mimeType": "image/png"
                    }));
                }
            }
        }
    }

    Ok(json!({
        "content": content,
        "isError": !report.ok,
        "structuredContent": payload
    }))
}

/// Minimal base64 encoder (no dependency needed).
fn base64_encode(data: &[u8]) -> Option<String> {
    const ALPHABET: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(data.len().div_ceil(3) * 4);
    for chunk in data.chunks(3) {
        let b0 = chunk[0] as u32;
        let b1 = *chunk.get(1).unwrap_or(&0) as u32;
        let b2 = *chunk.get(2).unwrap_or(&0) as u32;
        let n = (b0 << 16) | (b1 << 8) | b2;
        out.push(ALPHABET[(n >> 18) as usize & 63] as char);
        out.push(ALPHABET[(n >> 12) as usize & 63] as char);
        out.push(if chunk.len() > 1 { ALPHABET[(n >> 6) as usize & 63] as char } else { '=' });
        out.push(if chunk.len() > 2 { ALPHABET[n as usize & 63] as char } else { '=' });
    }
    Some(out)
}

/// Bridge MCP over stdin/stdout to the running daemon.
///
/// The daemon owns the session, so an agent launched this way shares the bound
/// app, the focus counters, and the action log with the dashboard. One
/// message per line in, one message per line out.
pub fn bridge_stdio() -> i32 {
    use std::io::{BufRead, Read, Write};
    use std::net::TcpStream;

    // Make sure a daemon exists to talk to.
    let mut port = daemon_port();
    if port.is_none() {
        let _ = spawn_daemon();
        for _ in 0..60 {
            std::thread::sleep(std::time::Duration::from_millis(250));
            if let Some(p) = daemon_port() {
                port = Some(p);
                break;
            }
        }
    }
    let Some(port) = port else {
        eprintln!("quiet-driver: could not reach the driver service");
        return 1;
    };

    let stdin = std::io::stdin();
    let mut stdout = std::io::stdout();
    for line in stdin.lock().lines() {
        let Ok(line) = line else { break };
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        // A batch stays a batch.
        let reply = post_json(port, "/mcp", trimmed);
        let text = match reply {
            Some(t) if !t.trim().is_empty() => t,
            _ => continue,
        };
        let _ = writeln!(stdout, "{}", text.trim());
        let _ = stdout.flush();
    }
    0
}

/// The port the daemon published, if it is alive.
fn daemon_port() -> Option<u16> {
    let path = std::env::var_os("HOME")
        .map(|h| std::path::Path::new(&h).join(".quiet-driver").join("port"))?;
    let text = std::fs::read_to_string(path).ok()?;
    let port: u16 = text.lines().next()?.trim().parse().ok()?;
    // A published port only counts if something answers on it.
    let address = std::net::SocketAddr::from(([127, 0, 0, 1], port));
    std::net::TcpStream::connect_timeout(&address, std::time::Duration::from_millis(400))
        .ok()
        .map(|_| port)
}

/// Start the driver service in the background, if it is not already running.
fn spawn_daemon() -> std::io::Result<()> {
    let exe = std::env::current_exe()?;
    std::process::Command::new(exe)
        .arg("--headless")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .map(|_| ())
}

/// POST a JSON body to the daemon and return the response body.
fn post_json(port: u16, path: &str, body: &str) -> Option<String> {
    use std::io::{Read, Write};
    let mut stream = std::net::TcpStream::connect(("127.0.0.1", port)).ok()?;
    let _ = stream.set_read_timeout(Some(std::time::Duration::from_secs(90)));
    let request = format!(
        "POST {} HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
        path,
        body.len(),
        body
    );
    stream.write_all(request.as_bytes()).ok()?;
    let mut raw = String::new();
    stream.read_to_string(&mut raw).ok()?;
    let split = raw.find("\r\n\r\n")?;
    Some(raw[split + 4..].to_string())
}

/// Instructions the client shows the model.
const INSTRUCTIONS: &str = "\
Quiet Driver drives real macOS apps in the background. Bind to an app first with \
bind_app; every later tool acts on that app. The app may be frontmost, behind other \
windows, minimised, on another Space, or hidden: control goes through Accessibility \
and per-process events, so the person's pointer, focus, and window order are never \
touched. Coordinates are relative to the bound window's top-left corner. The default \
mode is background; set_mode focused only when the person asks to watch. Each agent has \
a workspace under /tmp/quiet-driver/agent-<id>/ for screenshots and recordings. When \
the driver gets in your way, call log_friction with what went wrong.";

#[cfg(test)]
mod tests {
    use super::*;

    fn empty_shared() -> Handle {
        std::sync::Arc::new(std::sync::Mutex::new(crate::session::Shared::default()))
    }

    #[test]
    fn initialize_advertises_tools() {
        let shared = empty_shared();
        let pool = WorkerPool::new(std::path::PathBuf::from("/nonexistent/helper.swift"));
        let reply = handle_message(&json!({"jsonrpc":"2.0","id":1,"method":"initialize"}), &shared, &pool).unwrap();
        assert_eq!(reply["result"]["protocolVersion"], PROTOCOL_VERSION);
        assert!(reply["result"]["capabilities"]["tools"].is_object());
        assert!(reply["result"]["instructions"].as_str().unwrap().contains("bind_app"));
    }

    #[test]
    fn tools_list_has_schemas() {
        let shared = empty_shared();
        let pool = WorkerPool::new(std::path::PathBuf::from("/nonexistent/helper.swift"));
        let reply = handle_message(&json!({"jsonrpc":"2.0","id":2,"method":"tools/list"}), &shared, &pool).unwrap();
        let tools = reply["result"]["tools"].as_array().unwrap();
        assert!(tools.len() > 15);
        let click = tools.iter().find(|t| t["name"] == "click").unwrap();
        assert_eq!(click["inputSchema"]["type"], "object");
        assert!(click["inputSchema"]["properties"]["x"].is_object());
    }

    #[test]
    fn protocol_version_is_negotiated() {
        let shared = empty_shared();
        let pool = WorkerPool::new(std::path::PathBuf::from("/nonexistent/helper.swift"));
        // A version we speak is echoed back.
        let reply = handle_message(
            &json!({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}),
            &shared,
            &pool,
        )
        .unwrap();
        assert_eq!(reply["result"]["protocolVersion"], "2025-06-18");
        // One we do not gets our newest.
        let reply = handle_message(
            &json!({"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}),
            &shared,
            &pool,
        )
        .unwrap();
        assert_eq!(reply["result"]["protocolVersion"], PROTOCOL_VERSION);
    }

    #[test]
    fn notifications_get_no_reply() {
        let shared = empty_shared();
        let pool = WorkerPool::new(std::path::PathBuf::from("/nonexistent/helper.swift"));
        let reply = handle_message(&json!({"jsonrpc":"2.0","method":"notifications/initialized"}), &shared, &pool);
        assert!(reply.is_none());
    }

    #[test]
    fn unknown_method_is_an_error() {
        let shared = empty_shared();
        let pool = WorkerPool::new(std::path::PathBuf::from("/nonexistent/helper.swift"));
        let reply = handle_message(&json!({"jsonrpc":"2.0","id":3,"method":"nope"}), &shared, &pool).unwrap();
        assert_eq!(reply["error"]["code"], -32601);
    }

    #[test]
    fn unknown_tool_is_rejected() {
        let shared = empty_shared();
        let pool = WorkerPool::new(std::path::PathBuf::from("/nonexistent/helper.swift"));
        let reply = handle_message(
            &json!({"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"nope"}}),
            &shared,
            &pool,
        )
        .unwrap();
        assert_eq!(reply["error"]["code"], -32602);
    }

    #[test]
    fn tool_call_without_binding_reports_the_error() {
        let shared = empty_shared();
        let pool = WorkerPool::new(std::path::PathBuf::from("/nonexistent/helper.swift"));
        let reply = handle_message(
            &json!({"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"click","arguments":{"x":1,"y":2}}}),
            &shared,
            &pool,
        )
        .unwrap();
        assert_eq!(reply["result"]["isError"], true);
        let text = reply["result"]["content"][0]["text"].as_str().unwrap();
        assert!(text.contains("bind"), "the agent needs to be told to bind: {}", text);
    }

    #[test]
    fn base64_matches_known_vectors() {
        assert_eq!(base64_encode(b"").unwrap(), "");
        assert_eq!(base64_encode(b"f").unwrap(), "Zg==");
        assert_eq!(base64_encode(b"fo").unwrap(), "Zm8=");
        assert_eq!(base64_encode(b"foo").unwrap(), "Zm9v");
        assert_eq!(base64_encode(b"foobar").unwrap(), "Zm9vYmFy");
    }
}
