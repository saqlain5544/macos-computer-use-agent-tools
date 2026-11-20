//! Loopback control link.
//!
//!   GET  /health     liveness
//!   GET  /status     state, bound target, focus guard counters, recent actions
//!   GET  /observe    alias of /status
//!   GET  /windows    every top-level window (including other Spaces)
//!   GET  /tree       accessibility tree of the bound app
//!   POST /action     run one tool against the bound app
//!
//! Actions are executed against the real app. Requests carrying an `Origin`
//! header (i.e. issued by a web page) are refused, and the listener only binds
//! 127.0.0.1.

use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread;

use serde_json::{json, Map, Value};

use crate::helper::{self, Helper, Point};
use crate::session::{self, ActionReport, Handle, LogEntry, Mode};
use crate::workspace;

static SHUTDOWN: AtomicBool = AtomicBool::new(false);
fn published_port() -> &'static std::sync::Mutex<u16> {
    static PORT: std::sync::Mutex<u16> = std::sync::Mutex::new(0);
    &PORT
}

// ------------------------------------------------------------------ port

fn parse_port_value(raw: &str) -> Result<u16, String> {
    let text = raw.trim();
    let digits = text.strip_prefix('+').or_else(|| text.strip_prefix('-')).unwrap_or(text);
    let negative = text.starts_with('-');
    if digits.is_empty() || !digits.bytes().all(|b| b.is_ascii_digit()) {
        return Err("invalid CUA_DRIVER_ENVELOPE_HTTP_PORT".to_string());
    }
    let magnitude = digits
        .parse::<u32>()
        .map_err(|_| "CUA_DRIVER_ENVELOPE_HTTP_PORT out of range".to_string())?;
    let value = if negative { 0u32.wrapping_sub(magnitude) } else { magnitude };
    if value > u16::MAX as u32 {
        return Err("CUA_DRIVER_ENVELOPE_HTTP_PORT out of range".to_string());
    }
    let port = value as u16;
    if port == 0 {
        return Err("CUA_DRIVER_ENVELOPE_HTTP_PORT must be nonzero".to_string());
    }
    Ok(port)
}

pub fn configured_port() -> Result<u16, String> {
    match std::env::var("CUA_DRIVER_ENVELOPE_HTTP_PORT") {
        Ok(raw) => parse_port_value(&raw),
        Err(_) => Err("environment variable CUA_DRIVER_ENVELOPE_HTTP_PORT not present".to_string()),
    }
}

fn port_path() -> Option<std::path::PathBuf> {
    std::env::var_os("HOME").map(|h| std::path::Path::new(&h).join(".quiet-driver").join("port"))
}

fn publish_port(port: u16) {
    let Some(path) = port_path() else { return };
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    let _ = std::fs::write(&path, format!("{}\nhttp://127.0.0.1:{}\n{}\n", port, port, std::process::id()));
}

fn withdraw_port(port: u16) {
    let Some(path) = port_path() else { return };
    if let Ok(text) = std::fs::read_to_string(&path) {
        if text.lines().next().and_then(|l| l.trim().parse::<u16>().ok()) == Some(port) {
            let _ = std::fs::remove_file(&path);
        }
    }
}

pub fn spawn(shared: Handle, helper: Arc<Helper>) -> Option<u16> {
    let configured = configured_port();
    let bind_port = configured.clone().unwrap_or(0);
    let listener = TcpListener::bind(("127.0.0.1", bind_port)).ok()?;
    let port = listener.local_addr().ok()?.port();
    publish_port(port);
    *published_port().lock().unwrap() = port;
    {
        let mut s = shared.lock().unwrap();
        s.port = port;
        s.port_error = configured.err().unwrap_or_default();
        s.permissions = helper::permissions(&helper);
    }

    // Keep the published port file pointing at us: a screenshot run or a second
    // copy must not leave the agent with a dead link.
    {
        let shared = shared.clone();
        let helper = helper.clone();
        thread::Builder::new()
            .name("quiet-driver-portfile".to_string())
            .spawn(move || loop {
                thread::sleep(std::time::Duration::from_secs(3));
                if SHUTDOWN.load(Ordering::SeqCst) {
                    break;
                }
                let current = std::fs::read_to_string(port_path().unwrap_or_default())
                    .ok()
                    .and_then(|t| t.lines().next().and_then(|l| l.trim().parse::<u16>().ok()));
                if current != Some(port) {
                    publish_port(port);
                }
                // Cheap liveness refresh for the dashboard readout.
                let (pid, name) = helper::frontmost(&helper);
                let mut s = shared.lock().unwrap();
                if pid != 0 && !name.is_empty() {
                    s.frontmost = name;
                }
            })
            .ok();
    }

    thread::Builder::new()
        .name("quiet-driver-http".to_string())
        .spawn(move || {
            for stream in listener.incoming() {
                if SHUTDOWN.load(Ordering::SeqCst) {
                    break;
                }
                match stream {
                    Ok(stream) => {
                        let shared = shared.clone();
                        let helper = helper.clone();
                        // One thread per connection: a slow client can never
                        // stall the control link.
                        let _ = thread::Builder::new()
                            .name("quiet-driver-req".to_string())
                            .spawn(move || handle(stream, &shared, &helper));
                    }
                    Err(_) => break,
                }
            }
        })
        .ok()?;
    Some(port)
}

pub fn shutdown() {
    SHUTDOWN.store(true, Ordering::SeqCst);
    let port = *published_port().lock().unwrap();
    if port != 0 {
        withdraw_port(port);
    }
}

// ------------------------------------------------------------------ http

fn handle(mut stream: TcpStream, shared: &Handle, helper: &Helper) {
    let _ = stream.set_read_timeout(Some(std::time::Duration::from_secs(10)));
    let mut reader = BufReader::new(&stream);
    let mut request_line = String::new();
    if reader.read_line(&mut request_line).is_err() {
        return;
    }
    let parts: Vec<&str> = request_line.split_whitespace().collect();
    let method = parts.first().copied().unwrap_or("GET");
    let target = parts.get(1).copied().unwrap_or("/");

    let mut length = 0usize;
    let mut origin = false;
    loop {
        let mut line = String::new();
        if reader.read_line(&mut line).is_err() || line == "\r\n" || line.is_empty() {
            break;
        }
        if let Some((name, value)) = line.split_once(':') {
            let name = name.trim();
            if name.eq_ignore_ascii_case("content-length") {
                length = value.trim().parse().unwrap_or(0);
            } else if name.eq_ignore_ascii_case("origin") {
                origin = true;
            }
        }
    }
    let mut bytes = vec![0u8; length.min(8 << 20)];
    if !bytes.is_empty() {
        let _ = reader.read_exact(&mut bytes);
    }
    let body = String::from_utf8_lossy(&bytes).into_owned();
    let (path, query) = target.split_once('?').unwrap_or((target, ""));

    let (status, reply) = route(method, path, query, &body, origin, shared, helper);

    let response = format!(
        "HTTP/1.1 {} {}\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: {}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n",
        status,
        reason(status),
        reply.len()
    );
    let _ = stream.write_all(response.as_bytes());
    let _ = stream.write_all(reply.as_bytes());
    let _ = stream.flush();
}

fn reason(status: u16) -> &'static str {
    match status {
        200 => "OK",
        400 => "Bad Request",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        _ => "Internal Server Error",
    }
}

fn route(
    method: &str,
    path: &str,
    query: &str,
    body: &str,
    has_origin: bool,
    shared: &Handle,
    helper: &Helper,
) -> (u16, String) {
    if has_origin {
        return (
            403,
            json(&json!({
                "ok": false,
                "error": "cross_origin_refused",
                "message": "requests carrying an Origin header are refused: a web page must not drive the desktop"
            })),
        );
    }
    match (method, path) {
        ("GET", "/") | ("GET", "/health") => (
            200,
            json(&json!({
                "ok": true,
                "name": "quiet driver",
                "endpoints": ["/health", "/status", "/observe", "/windows", "/tree", "/action", "/mcp"],
                "running": shared.lock().unwrap().running
            })),
        ),
        ("GET", "/status") | ("GET", "/observe") => (200, status_json(shared)),
        ("GET", "/windows") => (200, windows_json(helper)),
        ("GET", "/tree") => (200, tree_json(shared, helper)),
        ("POST", "/action") => (200, action(body, shared, helper)),
        ("POST", "/mcp") => (200, mcp_body(body, shared, helper)),
        ("GET", "/mcp") => (
            200,
            json(&json!({
                "ok": true,
                "name": "quiet-driver-mcp",
                "transport": "streamable-http",
                "protocolVersion": crate::mcp::PROTOCOL_VERSION,
                "note": "POST JSON-RPC 2.0 messages here"
            })),
        ),
        ("GET", "/action") => {
            let merged = merge_query(query, body);
            (200, action(&merged, shared, helper))
        }
        (_, "/") | (_, "/health") | (_, "/status") | (_, "/observe") | (_, "/windows") | (_, "/tree")
        | (_, "/mcp") => {
            (405, json(&json!({"ok": false, "error": "method not allowed"})))
        }
        _ => (404, json(&json!({"ok": false, "error": "not found"}))),
    }
}

/// One JSON-RPC message in, one JSON-RPC message out. A batch is answered
/// with a batch; a notification is answered with nothing.
fn mcp_body(body: &str, shared: &Handle, helper: &Helper) -> String {
    let parsed: Result<Value, _> = serde_json::from_str(body);
    let Ok(value) = parsed else {
        return json(&json!({
            "jsonrpc": "2.0",
            "id": Value::Null,
            "error": { "code": -32700, "message": "parse error" }
        }));
    };
    if let Some(items) = value.as_array() {
        let replies: Vec<Value> = items
            .iter()
            .filter_map(|m| crate::mcp::handle_message(m, shared, helper))
            .collect();
        if replies.is_empty() {
            return String::new();
        }
        return json(&Value::Array(replies));
    }
    match crate::mcp::handle_message(&value, shared, helper) {
        Some(reply) => json(&reply),
        None => String::new(),
    }
}

fn merge_query(query: &str, body: &str) -> String {
    let mut map = Map::new();
    for pair in query.split('&') {
        let Some((k, v)) = pair.split_once('=') else { continue };
        let v = urldecode(v);
        let parsed = serde_json::from_str(&v).unwrap_or(Value::String(v));
        map.insert(k.to_string(), parsed);
    }
    if let Ok(Value::Object(o)) = serde_json::from_str(body) {
        for (k, v) in o {
            map.insert(k, v);
        }
    }
    Value::Object(map).to_string()
}

fn urldecode(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        match b[i] {
            b'%' if i + 2 < b.len() => match u8::from_str_radix(&s[i + 1..i + 3], 16) {
                Ok(v) => {
                    out.push(v);
                    i += 3;
                }
                Err(_) => {
                    out.push(b[i]);
                    i += 1;
                }
            },
            b'+' => {
                out.push(b' ');
                i += 1;
            }
            c => {
                out.push(c);
                i += 1;
            }
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn json(v: &Value) -> String {
    serde_json::to_string(v).unwrap_or_else(|_| "{\"ok\":false}".to_string())
}

// ------------------------------------------------------------------ status

fn status_json(shared: &Handle) -> String {
    let s = shared.lock().unwrap();
    let target = s.target.as_ref().map(|t| {
        json!({
            "app": t.app_name,
            "identity": t.identity,
            "owner": t.owner,
            "pid": t.pid,
            "window_id": t.window_id,
            "window": t.window_title,
            "label": t.label(),
            "bounds": {"x": t.bounds.x, "y": t.bounds.y, "w": t.bounds.w, "h": t.bounds.h}
        })
    });
    let actions: Vec<Value> = s
        .recent(12)
        .into_iter()
        .map(|e| {
            json!({
                "tool": e.tool,
                "detail": e.detail,
                "ok": e.ok,
                "mode": e.mode,
                "focus_changed": e.focus_changed
            })
        })
        .collect();
    let value = json!({
        "ok": true,
        "driver": s.running,
        "mode": s.mode.as_str(),
        "port": s.port,
        "port_error": s.port_error,
        "agents": s.agents,
        "fps": (s.fps * 10.0).round() / 10.0,
        "frames": s.frames,
        "target": target,
        "frontmost": s.frontmost,
        "focus_events": s.focus_events,
        "actions_total": s.actions_total,
        "agent_cursor": [s.agent_cursor.x, s.agent_cursor.y],
        "permissions": {
            "accessibility": s.permissions.accessibility,
            "post_events": s.permissions.post_events,
            "screen_capture": s.permissions.screen_capture
        },
        "helper_ready": s.helper_ready,
        "last_error": s.last_error,
        "actions": actions
    });
    json(&value)
}

fn windows_json(helper: &Helper) -> String {
    let list: Vec<Value> = helper::windows(helper)
        .into_iter()
        .filter(|w| w.layer == 0 && w.window_id > 0)
        .map(|w| {
            json!({
                "app": w.owner,
                "pid": w.pid,
                "window_id": w.window_id,
                "title": w.title,
                "on_screen": w.on_screen,
                "bounds": {"x": w.bounds.x, "y": w.bounds.y, "w": w.bounds.w, "h": w.bounds.h}
            })
        })
        .collect();
    json(&json!({"ok": true, "windows": list}))
}

fn tree_json(shared: &Handle, helper: &Helper) -> String {
    let target = shared.lock().unwrap().target.clone();
    let Some(t) = target else {
        return json(&json!({"ok": false, "error": "no app is bound yet"}));
    };
    let nodes: Vec<Value> = helper::tree(helper, t.pid, 800)
        .into_iter()
        .filter(|n| n.frame.has_area() || n.role != "AXGroup")
        .map(|n| {
            json!({
                "depth": n.depth,
                "role": n.role,
                "title": n.title,
                "description": n.description,
                "value": n.value,
                "frame": {"x": n.frame.x, "y": n.frame.y, "w": n.frame.w, "h": n.frame.h}
            })
        })
        .collect();
    json(&json!({"ok": true, "target": t.label(), "nodes": nodes}))
}

// ------------------------------------------------------------------ actions

fn action(body: &str, shared: &Handle, helper: &Helper) -> String {
    let payload: Value = if body.trim().is_empty() {
        Value::Object(Map::new())
    } else {
        match serde_json::from_str(body) {
            Ok(v) => v,
            Err(e) => {
                return json(&json!({
                    "ok": false,
                    "error": "bad_json",
                    "message": format!("request body must be a JSON object: {}", e)
                }))
            }
        }
    };
    let Some(obj) = payload.as_object() else {
        return json(&json!({"ok": false, "error": "bad_json", "message": "body must be a JSON object"}));
    };
    let tool = obj.get("tool").and_then(|v| v.as_str()).unwrap_or("").trim().to_string();
    if tool.is_empty() {
        return json(&json!({"ok": false, "error": "missing_tool"}));
    }
    if let Some(m) = obj.get("mode").and_then(|v| v.as_str()) {
        match Mode::parse(m) {
            Some(mode) => shared.lock().unwrap().mode = mode,
            None => {
                return json(&json!({
                    "ok": false,
                    "error": "bad_mode",
                    "message": format!("mode must be \"background\" or \"focused\", got \"{}\"", m)
                }))
            }
        }
    }
    {
        let s = shared.lock().unwrap();
        if !s.running && !matches!(tool.as_str(), "start_driver" | "resume" | "status") {
            return json(&json!({"ok": false, "error": "driver paused — POST {\"tool\":\"resume\"} first"}));
        }
    }

    let report = execute(&tool, obj, shared, helper);
    {
        let mut s = shared.lock().unwrap();
        s.actions_total += 1;
        if report.focus_changed {
            s.focus_events += 1;
        }
        s.push_log(LogEntry {
            tool: tool.clone(),
            detail: report.detail.clone(),
            ok: report.ok,
            mode: report.mode.clone(),
            focus_changed: report.focus_changed,
        });
        if !report.ok {
            s.last_error = report.error.clone();
        }
    }
    json(&json!({
        "ok": report.ok,
        "error": if report.ok { Value::Null } else { Value::String(report.error.clone()) },
        "detail": report.detail,
        "target": report.target_label,
        "mode": report.mode,
        "real_pointer_moved": report.pointer_moved,
        "focus_changed": report.focus_changed,
        "focus_restored": report.focus_restored,
        "data": report.payload
    }))
}

fn execute(tool: &str, obj: &Map<String, Value>, shared: &Handle, helper: &Helper) -> ActionReport {
    let mode = shared.lock().unwrap().mode;
    let mut report = run_tool(tool, obj, shared, helper);
    report.mode = mode.as_str().to_string();
    if let Some(t) = shared.lock().unwrap().target.clone() {
        report.target_label = t.label();
    }
    report
}

fn target_json(t: &session::Target) -> Value {
    json!({
        "app": t.app_name,
        "identity": t.identity,
        "owner": t.owner,
        "pid": t.pid,
        "window_id": t.window_id,
        "window": t.window_title,
        "bounds": {"x": t.bounds.x, "y": t.bounds.y, "w": t.bounds.w, "h": t.bounds.h}
    })
}

/// Which agent is speaking. Defaults to "default" so an agent that bound an
/// app still gets a workspace of its own.
fn agent_id(obj: &Map<String, Value>) -> String {
    obj.get("agent")
        .and_then(|v| v.as_str())
        .map(|s| s.to_string())
        .unwrap_or_else(|| "default".to_string())
}

fn num(obj: &Map<String, Value>, key: &str) -> Option<f64> {
    obj.get(key).and_then(|v| v.as_f64()).or_else(|| {
        obj.get(key).and_then(|v| v.as_str()).and_then(|s| s.trim().parse::<f64>().ok())
    })
}

fn text_of(obj: &Map<String, Value>) -> String {
    obj.get("text")
        .or_else(|| obj.get("value"))
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string()
}

const TOOLS: &[&str] = &[
    "bind_app", "bind", "rebind", "launch_app", "launch", "quit_app", "unbind", "list_windows",
    "get_desktop_state",
    "get_window_state", "get_accessibility_tree", "click", "double_click", "right_click",
    "move_cursor", "move", "mouse_drag", "scroll", "type_text", "type", "press_key", "key",
    "hotkey", "set_value", "set_caret", "click_label", "press_button", "get_text", "set_mode",
    "pause", "resume", "stop_driver", "start_driver", "status", "show_dashboard",
    "clipboard_read", "clipboard_write", "screenshot", "record", "log_friction",
    "friction_log", "workspace", "open_file", "close_file", "documents",
];

/// Run one tool. Public so the MCP surface can reuse the exact same behaviour
/// as the HTTP API: one implementation, one set of guarantees.
pub fn execute_public(
    tool: &str,
    obj: &Map<String, Value>,
    shared: &Handle,
    helper: &Helper,
) -> ActionReport {
    run_tool(tool, obj, shared, helper)
}

fn run_tool(tool: &str, obj: &Map<String, Value>, shared: &Handle, helper: &Helper) -> ActionReport {
    let mode = shared.lock().unwrap().mode;

    if !TOOLS.contains(&tool) {
        return ActionReport::err(format!(
            "unknown tool \"{}\". Tools: bind_app, list_windows, get_accessibility_tree, click, double_click, right_click, move_cursor, mouse_drag, scroll, type_text, press_key, hotkey, set_value, click_label, get_text, set_mode, pause, resume",
            tool
        ));
    }

    match tool {
        "show_dashboard" => {
            if let Some(flag) = shared.lock().unwrap().show_window.take() {
                flag.store(false, std::sync::atomic::Ordering::SeqCst);
            }
            return ActionReport::ok("dashboard shown");
        }
        "start_driver" | "resume" => {
            shared.lock().unwrap().running = true;
            return ActionReport::ok("driver resumed");
        }
        "stop_driver" | "pause" => {
            shared.lock().unwrap().running = false;
            return ActionReport::ok("driver paused; actions are refused until resume");
        }
        "set_mode" => {
            let m = obj.get("mode").and_then(|v| v.as_str()).unwrap_or("");
            return match Mode::parse(m) {
                Some(mode) => {
                    shared.lock().unwrap().mode = mode;
                    ActionReport::ok(format!("mode is now {}", mode.as_str()))
                }
                None => ActionReport::err("mode must be \"background\" or \"focused\""),
            };
        }
        "list_windows" | "get_desktop_state" => {
            let wins = helper::windows(helper);
            let layer0: Vec<&helper::Window> = wins.iter().filter(|w| w.layer == 0).collect();
            let (fpid, fname) = helper::frontmost(helper);
            let mut r = ActionReport::ok(format!("{} windows; frontmost {}", layer0.len(), fname));
            r.payload = Some(json!({
                "frontmost": {"pid": fpid, "name": fname},
                "windows": layer0.iter().map(|w| json!({
                    "app": w.owner, "pid": w.pid, "window_id": w.window_id,
                    "title": w.title, "on_screen": w.on_screen,
                    "bounds": {"x": w.bounds.x, "y": w.bounds.y, "w": w.bounds.w, "h": w.bounds.h}
                })).collect::<Vec<_>>()
            }));
            return r;
        }
        "bind_app" | "bind" => {
            let selector = obj
                .get("app")
                .or_else(|| obj.get("bundle_id"))
                .or_else(|| obj.get("name"))
                .and_then(|v| v.as_str().map(String::from).or_else(|| v.as_i64().map(|n| n.to_string())))
                .unwrap_or_else(|| text_of(obj));
            let window = num(obj, "window_id").map(|n| n as u32);
            let owner = obj.get("agent").and_then(|v| v.as_str()).unwrap_or("default").to_string();
            let takeover = obj.get("takeover").and_then(|v| v.as_bool()).unwrap_or(false);
            return match session::bind(helper, shared, &selector, window, &owner, takeover) {
                Ok(t) => {
                    let mut r = ActionReport::ok(format!("bound to {} as \"{}\"", t.label(), t.owner));
                    r.payload = Some(target_json(&t));
                    r
                }
                Err(e) => ActionReport::err(e),
            };
        }
        "rebind" => {
            return match session::rebind(helper, shared) {
                Ok(t) => {
                    let mut r = ActionReport::ok(format!("re-bound to {} (pid {})", t.label(), t.pid));
                    r.payload = Some(target_json(&t));
                    r
                }
                Err(e) => ActionReport::err(e),
            };
        }
        "launch_app" | "launch" => {
            // Launch an app without binding and without stealing focus.
            let name = obj
                .get("app")
                .or_else(|| obj.get("bundle_id"))
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();
            if name.is_empty() {
                return ActionReport::err("launch_app needs an \"app\" name or bundle id");
            }
            return match helper::launch(helper, &name) {
                Ok((pid, launched)) => {
                    let mut r = ActionReport::ok(format!(
                        "launched {} in the background{}",
                        launched,
                        if pid != 0 { format!(" (pid {})", pid) } else { String::new() }
                    ));
                    r.payload = Some(json!({"app": launched, "pid": pid}));
                    r
                }
                Err(e) => ActionReport::err(e),
            };
        }
        "quit_app" => {
            let name = obj
                .get("app")
                .or_else(|| obj.get("bundle_id"))
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();
            if name.is_empty() {
                return ActionReport::err("quit_app needs an \"app\" name or bundle id");
            }
            // If this is the bound app, drop the binding: the next rebind will
            // re-resolve by identity once the agent relaunches it.
            let was_bound = shared
                .lock()
                .unwrap()
                .target
                .as_ref()
                .map(|t| t.identity.eq_ignore_ascii_case(&name) || t.app_name.eq_ignore_ascii_case(&name))
                .unwrap_or(false);
            let result = helper::quit_app(helper, &name);
            if was_bound {
                if let Some(t) = shared.lock().unwrap().target.as_mut() {
                    t.pid = 0;
                    t.window_id = 0;
                }
            }
            return match result {
                Ok(n) => ActionReport::ok(format!("quit {}", n)),
                Err(e) => ActionReport::err(e),
            };
        }
        "unbind" => {
            let mut s = shared.lock().unwrap();
            s.target = None;
            s.tree.clear();
            return ActionReport::ok("unbound");
        }
        "get_window_state" | "get_accessibility_tree" => {
            let t = match session::current_target(shared) {
                Ok(t) => t,
                Err(e) => return ActionReport::err(e),
            };
            let nodes = helper::tree(helper, t.pid, 800);
            {
                let mut s = shared.lock().unwrap();
                s.tree = nodes.clone();
            }
            let count = nodes.len();
            let mut r = ActionReport::ok(format!("{} accessibility nodes from {}", count, t.label()));
            r.payload = Some(json!({
                "nodes": nodes.iter().map(|n| json!({
                    "depth": n.depth, "role": n.role, "title": n.title,
                    "description": n.description, "value": n.value
                })).collect::<Vec<_>>()
            }));
            return r;
        }
        "screenshot" => {
            let t = match session::current_target(shared) {
                Ok(t) => t,
                Err(e) => return ActionReport::err(e),
            };
            let agent = agent_id(obj);
            let path = match workspace::resolve_output(
                &agent, "screenshot", "png", obj.get("path").and_then(|v| v.as_str()),
            ) {
                Ok(p) => p,
                Err(e) => return ActionReport::err(e),
            };
            let path_str = path.to_string_lossy().into_owned();
            return match helper::screenshot(helper, t.window_id, &path_str) {
                Ok((w, h, bytes)) => {
                    let mut r = ActionReport::ok(format!(
                        "captured {}x{} of {} ({} bytes) to {}", w, h, t.label(), bytes, path.display()
                    ));
                    r.payload = Some(json!({
                        "path": path_str, "width": w, "height": h, "bytes": bytes,
                        "window": t.label()
                    }));
                    r
                }
                Err(e) => ActionReport::err(e),
            };
        }
        "record" => {
            let t = match session::current_target(shared) {
                Ok(t) => t,
                Err(e) => return ActionReport::err(e),
            };
            let agent = agent_id(obj);
            let path = match workspace::resolve_output(
                &agent, "recording", "mov", obj.get("path").and_then(|v| v.as_str()),
            ) {
                Ok(p) => p,
                Err(e) => return ActionReport::err(e),
            };
            let seconds = num(obj, "seconds").unwrap_or(3.0).clamp(0.5, 60.0);
            let path_str = path.to_string_lossy().into_owned();
            return match helper::record(helper, t.pid, seconds, &path_str) {
                Ok((w, h, frames, bytes)) => {
                    let mut r = ActionReport::ok(format!(
                        "recorded {} frames of {} ({}x{}) to {}",
                        frames, t.label(), w, h, path.display()
                    ));
                    r.payload = Some(json!({
                        "path": path_str, "frames": frames, "bytes": bytes,
                        "seconds": seconds, "width": w, "height": h
                    }));
                    r
                }
                Err(e) => ActionReport::err(e),
            };
        }
        "open_file" => {
            // Open a document in the bound app: no file panel, no focus change.
            let t = match session::current_target(shared) {
                Ok(t) => t,
                Err(e) => return ActionReport::err(e),
            };
            let path = obj.get("path").and_then(|v| v.as_str()).unwrap_or("");
            if path.trim().is_empty() {
                return ActionReport::err("open_file needs a \"path\"");
            }
            let app = obj
                .get("app")
                .and_then(|v| v.as_str())
                .map(|s| s.to_string())
                .unwrap_or_else(|| t.app_name.clone());
            return match helper::open_file(helper, &app, path) {
                Ok(()) => {
                    let mut r = ActionReport::ok(format!("opened {} in {} (no panel, no focus change)", path, app));
                    r.payload = Some(json!({"path": path, "app": app}));
                    r
                }
                Err(e) => ActionReport::err(e),
            };
        }
        "close_file" => {
            let t = match session::current_target(shared) {
                Ok(t) => t,
                Err(e) => return ActionReport::err(e),
            };
            let name = obj.get("name").and_then(|v| v.as_str()).unwrap_or("");
            let target = if name.trim().is_empty() {
                helper::documents(helper, t.pid).into_iter().next().unwrap_or_default()
            } else {
                name.to_string()
            };
            if target.trim().is_empty() {
                return ActionReport::err("no document to close");
            }
            return match helper::close_file(helper, t.pid, &target) {
                Ok(closed) => {
                    let mut r = ActionReport::ok(format!("closed {}", closed));
                    r.payload = Some(json!({"closed": closed}));
                    r
                }
                Err(e) => ActionReport::err(e),
            };
        }
        "documents" => {
            let t = match session::current_target(shared) {
                Ok(t) => t,
                Err(e) => return ActionReport::err(e),
            };
            let docs = helper::documents(helper, t.pid);
            let mut r = ActionReport::ok(format!("{} open document(s)", docs.len()));
            r.payload = Some(json!({"documents": docs}));
            return r;
        }
        "log_friction" => {
            let agent = agent_id(obj);
            let problem = obj
                .get("problem")
                .or_else(|| obj.get("text"))
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();
            if problem.trim().is_empty() {
                return ActionReport::err("log_friction needs a \"problem\" describing what went wrong");
            }
            let (target_label, mode) = {
                let g = shared.lock().unwrap();
                (
                    g.target.as_ref().map(|t| t.label()).unwrap_or_default(),
                    g.mode.as_str(),
                )
            };
            let entry = json!({
                "at": std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map(|d| d.as_secs()).unwrap_or(0),
                "agent": agent,
                // "tool" names the action itself, so the tool that misbehaved
                // arrives under its own key.
                "source_tool": obj
                    .get("source_tool")
                    .or_else(|| obj.get("related_tool"))
                    .and_then(|v| v.as_str())
                    .unwrap_or(""),
                "problem": problem,
                "detail": obj.get("detail").and_then(|v| v.as_str()).unwrap_or(""),
                "target": target_label,
                "mode": mode,
            });
            return match workspace::log_friction(&entry) {
                Ok(path) => {
                    let mut r = ActionReport::ok(format!("logged a friction point to {}", path.display()));
                    r.payload = Some(entry);
                    r
                }
                Err(e) => ActionReport::err(e),
            };
        }
        "friction_log" => {
            let limit = num(obj, "limit").unwrap_or(50.0).max(1.0) as usize;
            let entries = workspace::read_friction(limit);
            let mut r = ActionReport::ok(format!("{} friction entries logged", entries.len()));
            r.payload = Some(json!({
                "entries": entries,
                "path": workspace::friction_log_path().to_string_lossy(),
            }));
            return r;
        }
        "workspace" => {
            let agent = agent_id(obj);
            let dir = match workspace::ensure_agent_dir(&agent) {
                Ok(d) => d,
                Err(e) => return ActionReport::err(e),
            };
            let files: Vec<Value> = std::fs::read_dir(&dir)
                .map(|rd| {
                    rd.filter_map(|e| e.ok())
                        .map(|e| {
                            let meta = e.metadata().ok();
                            json!({
                                "name": e.file_name().to_string_lossy(),
                                "bytes": meta.as_ref().map(|m| m.len()).unwrap_or(0),
                            })
                        })
                        .collect()
                })
                .unwrap_or_default();
            let mut r = ActionReport::ok(format!("workspace {}", dir.display()));
            r.payload = Some(json!({
                "dir": dir.to_string_lossy(),
                "files": files,
                "friction_log": workspace::friction_log_path().to_string_lossy(),
            }));
            return r;
        }
        _ => {}
    }

    let mut target = match session::current_target(shared) {
        Ok(t) => t,
        Err(e) => return ActionReport::err(e),
    };
    // The app may have been quit and relaunched under us; follow its identity
    // instead of failing on a stale pid.
    if target.pid == 0 || session::refresh_bounds(helper, &target).is_none() {
        match session::rebind(helper, shared) {
            Ok(t) => target = t,
            Err(e) => {
                return ActionReport::err(format!(
                    "{} was not running ({}); relaunch it and the next action will re-bind automatically",
                    target.label(),
                    e
                ))
            }
        }
    }
    // The window may have moved or been resized since bind: keep coordinates
    // honest instead of acting on a stale rectangle.
    if let Some(w) = session::refresh_bounds(helper, &target) {
        if w.bounds != target.bounds {
            target.bounds = w.bounds;
            if let Some(t) = shared.lock().unwrap().target.as_mut() {
                t.bounds = w.bounds;
            }
        }
    }

    let in_window = |x: f64, y: f64| -> Result<(), String> {
        let local = helper::Rect { x: 0.0, y: 0.0, w: target.bounds.w, h: target.bounds.h };
        if local.contains(Point { x, y }) {
            Ok(())
        } else {
            Err(format!(
                "point ({}, {}) is outside the bound window ({}x{}); coordinates are relative to the window's top-left corner",
                x, y, target.bounds.w, target.bounds.h
            ))
        }
    };

    // Every delivered action runs through here so focused mode raises the
    // target for the duration and puts the person's app back afterwards.
    let deliver = |f: &dyn Fn() -> ActionReport| -> ActionReport {
        if mode == Mode::Focused {
            let (mut r, changed, restored) = session::with_focus(helper, &target, f);
            r.focus_changed = changed;
            r.focus_restored = restored;
            r
        } else {
            f()
        }
    };

    match tool {
        "click" | "double_click" | "right_click" | "move_cursor" | "move" | "mouse_drag" | "scroll" => {
            let x = num(obj, "x").unwrap_or(0.0);
            let y = num(obj, "y").unwrap_or(0.0);
            if let Err(e) = in_window(x, y) {
                return ActionReport::err(e);
            }
            let before = helper.pointer_now();
            let g = session::global_point(&target, x, y);
            shared.lock().unwrap().agent_cursor = Point { x, y };

            // AX first: pressing the element under the point works even when the
            // window is on another Space or fully occluded.
            let hit = session::element_at(helper, &target, x, y);
            if let Some(h) = &hit {
                let label = h.label();
                if matches!(tool, "move" | "move_cursor") {
                    let mut r = ActionReport::ok(format!(
                        "hovering {} \"{}\" at ({}, {}) — pointer and focus untouched",
                        h.role, label, x, y
                    ));
                    r.pointer_moved = helper.pointer_moved_since(before);
                    return r;
                }
                if h.can_press() && !matches!(tool, "right_click" | "mouse_drag" | "scroll") {
                    let press = || helper::press_at(helper, target.pid, g);
                    let (result, focused) = if mode == Mode::Focused {
                        let (res, changed, restored) = session::with_focus(helper, &target, press);
                        (res, Some((changed, restored)))
                    } else {
                        (press(), None)
                    };
                    let mut r = match result {
                        Ok(mut pressed) => {
                            if pressed.frame.w == 0.0 {
                                pressed.frame = h.frame;
                            }
                            let mut r = ActionReport::ok(format!(
                                "{} {} \"{}\" at ({}, {}) in {}",
                                if tool == "double_click" { "double-pressed" } else { "pressed" },
                                pressed.role,
                                pressed.label(),
                                x,
                                y,
                                target.label()
                            ));
                            r.payload = Some(json!({
                                "role": pressed.role,
                                "label": pressed.label(),
                                "frame": {"x": pressed.frame.x, "y": pressed.frame.y,
                                          "w": pressed.frame.w, "h": pressed.frame.h},
                                "window_local": {"x": x, "y": y}
                            }));
                            r
                        }
                        Err(e) => ActionReport::err(format!("AXPress at ({}, {}) failed: {}", x, y, e)),
                    };
                    if let Some((changed, restored)) = focused {
                        r.focus_changed = changed;
                        r.focus_restored = restored;
                    }
                    r.pointer_moved = helper.pointer_moved_since(before);
                    return r;
                }
            }

            let how = match tool {
                "double_click" => "double",
                "right_click" => "right",
                "move" | "move_cursor" => "move",
                _ => "click",
            };
            let start = helper.pointer_now();
            let action = |helper: &Helper| -> Result<(), String> {
                match tool {
                    "mouse_drag" => {
                        let to = obj
                            .get("to")
                            .and_then(|v| v.as_object())
                            .map(|o| Point {
                                x: num(o, "x").unwrap_or(x),
                                y: num(o, "y").unwrap_or(y),
                            })
                            .unwrap_or(Point { x, y });
                        helper::drag(helper, target.pid, g, session::global_point(&target, to.x, to.y))
                    }
                    "scroll" => {
                        let lines = num(obj, "lines").unwrap_or(3.0) as i32;
                        helper::scroll(helper, target.pid, g, lines)
                    }
                    _ => helper::click(helper, target.pid, g, how),
                }
            };
            let mut r = match (action(helper), mode) {
                (Err(e), _) => ActionReport::err(e),
                (Ok(()), Mode::Background) => ActionReport::ok(format!(
                    "{} delivered to {} at ({}, {}) via CGEventPostToPid",
                    tool,
                    target.label(),
                    x,
                    y
                )),
                (Ok(()), Mode::Focused) => ActionReport::ok(format!(
                    "{} delivered to {} at ({}, {})",
                    tool,
                    target.label(),
                    x,
                    y
                )),
            };
            r.pointer_moved = helper.pointer_moved_since(start);
            if mode == Mode::Focused {
                let (changed, restored) = (false, false);
                r.focus_changed = changed;
                r.focus_restored = restored;
            }
            r
        }
        "type_text" | "type" => {
            let content = text_of(obj);
            if content.is_empty() {
                return ActionReport::err("type_text needs a non-empty \"text\" field");
            }
            let before = helper.pointer_now();
            let pid = target.pid;
            let text = content.clone();
            let (result, focused) = if mode == Mode::Focused {
                let (r, changed, restored) =
                    session::with_focus(helper, &target, || helper::type_text(helper, pid, &text));
                (r, Some((changed, restored)))
            } else {
                (helper::type_text(helper, pid, &text), None)
            };
            let mut r = match result {
                Ok(n) => {
                    let after = helper::text_field(helper, pid).unwrap_or_default();
                    ActionReport::ok(format!(
                        "typed {} characters into {}; its text field now holds {} characters",
                        n,
                        target.label(),
                        after.chars().count()
                    ))
                }
                Err(e) => ActionReport::err(format!("typing failed: {}", e)),
            };
            if let Some((changed, restored)) = focused {
                r.focus_changed = changed;
                r.focus_restored = restored;
            }
            r.pointer_moved = helper.pointer_moved_since(before);
            r
        }
        "press_key" | "key" | "hotkey" => {
            let spec = text_of(obj);
            if spec.is_empty() {
                return ActionReport::err("press_key/hotkey needs a \"text\" field, e.g. \"Return\" or \"cmd+shift+t\"");
            }
            let pid = target.pid;
            let chord = spec.clone();
            let (result, focused) = if mode == Mode::Focused {
                let (r, changed, restored) =
                    session::with_focus(helper, &target, || helper::key(helper, pid, &chord));
                (r, Some((changed, restored)))
            } else {
                (helper::key(helper, pid, &chord), None)
            };
            let mut r = match result {
                Ok(()) => match helper::chord_key(&spec) {
                    Some(key) => ActionReport::ok(format!("sent {} (key {}) to {}", spec, key, target.label())),
                    None => ActionReport::ok(format!("sent {} to {}", spec, target.label())),
                },
                Err(e) => ActionReport::err(e),
            };
            if let Some((changed, restored)) = focused {
                r.focus_changed = changed;
                r.focus_restored = restored;
            }
            r.pointer_moved = false;
            r
        }
        "set_value" => {
            let content = obj
                .get("text")
                .or_else(|| obj.get("value"))
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();
            let pid = target.pid;
            let value = content.clone();
            let (result, focused) = if mode == Mode::Focused {
                let (r, changed, restored) =
                    session::with_focus(helper, &target, || helper::set_value(helper, pid, &value));
                (r, Some((changed, restored)))
            } else {
                (helper::set_value(helper, pid, &value), None)
            };
            let mut r = match result {
                Ok(()) => ActionReport::ok(format!(
                    "set the text field of {} to {} characters",
                    target.label(),
                    content.chars().count()
                )),
                Err(e) => ActionReport::err(e),
            };
            if let Some((changed, restored)) = focused {
                r.focus_changed = changed;
                r.focus_restored = restored;
            }
            r
        }
        "set_caret" => {
            let location = num(obj, "location").unwrap_or(0.0) as i64;
            let length = num(obj, "length").unwrap_or(0.0) as i64;
            let pid = target.pid;
            deliver(&|| match helper::set_caret(helper, pid, location, length) {
                Ok(()) => ActionReport::ok(format!(
                    "moved the insertion point in {} to {} ({} selected)",
                    target.label(),
                    location,
                    length
                )),
                Err(e) => ActionReport::err(e),
            })
        }
        "click_label" | "press_button" => {
            let label = obj.get("label").and_then(|v| v.as_str()).unwrap_or("").to_string();
            if label.is_empty() {
                return ActionReport::err("click_label needs a \"label\" field");
            }
            let pid = target.pid;
            let wanted = label.clone();
            let bounds = target.bounds;
            deliver(&|| match helper::press_label(helper, pid, &wanted) {
                Ok((name, frame)) => {
                    // Show the cursor where the control actually is.
                    if frame.w > 0.0 {
                        shared.lock().unwrap().agent_cursor = Point {
                            x: frame.x - bounds.x + frame.w / 2.0,
                            y: frame.y - bounds.y + frame.h / 2.0,
                        };
                    }
                    let mut r = ActionReport::ok(format!("pressed \"{}\" in {}", name, target.label()));
                    r.payload = Some(json!({
                        "label": name,
                        "frame": {"x": frame.x, "y": frame.y, "w": frame.w, "h": frame.h}
                    }));
                    r
                }
                Err(e) => ActionReport::err(e),
            })
        }
        "get_text" => {
            let pid = target.pid;
            deliver(&|| match helper::text_field(helper, pid) {
                Ok(v) => {
                    let mut r = ActionReport::ok(format!("{} characters in the text field", v.chars().count()));
                    r.payload = Some(json!({"value": v}));
                    r
                }
                Err(e) => ActionReport::err(e),
            })
        }
        "clipboard_read" | "clipboard_write" => ActionReport::err(format!(
            "{} is not implemented: the clipboard belongs to the person, not the agent",
            tool
        )),
        other => ActionReport::err(format!(
            "unknown tool \"{}\". Tools: bind_app, list_windows, get_accessibility_tree, click, double_click, right_click, move_cursor, mouse_drag, scroll, type_text, press_key, hotkey, set_value, click_label, get_text, set_mode, pause, resume",
            other
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::session::Shared;

    fn test_shared() -> Handle {
        Arc::new(std::sync::Mutex::new(Shared::default()))
    }

    #[test]
    fn decimal_port_parses() {
        assert_eq!(parse_port_value("8080"), Ok(8080));
        assert_eq!(parse_port_value("+443"), Ok(443));
    }

    #[test]
    fn zero_is_rejected_with_the_original_message() {
        assert_eq!(parse_port_value("0"), Err("CUA_DRIVER_ENVELOPE_HTTP_PORT must be nonzero".to_string()));
    }

    #[test]
    fn out_of_range_and_garbage_are_errors() {
        assert!(parse_port_value("65536").is_err());
        assert!(parse_port_value("-1").is_err());
        assert!(parse_port_value("12x").is_err());
        assert!(parse_port_value("").is_err());
    }

    #[test]
    fn query_merges_into_json() {
        let v: Value = serde_json::from_str(&merge_query("tool=click&x=10&y=20", "")).unwrap();
        assert_eq!(v["tool"], "click");
        assert_eq!(v["x"], 10);
        let v: Value = serde_json::from_str(&merge_query("tool=type_text&text=hello%20world", "")).unwrap();
        assert_eq!(v["text"], "hello world");
    }

    #[test]
    fn origin_is_refused() {
        let shared = test_shared();
        let helper = Helper::new("unused".into());
        let (status, body) = route("POST", "/action", "", "{\"tool\":\"click\"}", true, &shared, &helper);
        assert_eq!(status, 403);
        assert!(body.contains("cross_origin_refused"));
    }

    #[test]
    fn unknown_tool_is_reported() {
        let shared = test_shared();
        let helper = Helper::new("unused".into());
        let (_, body) = route("POST", "/action", "", "{\"tool\":\"nope\"}", false, &shared, &helper);
        let v: Value = serde_json::from_str(&body).unwrap();
        assert_eq!(v["ok"], false);
        assert!(v["error"].as_str().unwrap().contains("unknown tool"));
    }

    #[test]
    fn action_without_binding_says_so() {
        let shared = test_shared();
        let helper = Helper::new("unused".into());
        let (_, body) = route("POST", "/action", "", "{\"tool\":\"click\",\"x\":1,\"y\":1}", false, &shared, &helper);
        let v: Value = serde_json::from_str(&body).unwrap();
        assert_eq!(v["ok"], false);
        assert!(v["error"].as_str().unwrap().contains("no app is bound"));
    }

    #[test]
    fn missing_tool_and_bad_json_are_rejected() {
        let shared = test_shared();
        let helper = Helper::new("unused".into());
        let (_, body) = route("POST", "/action", "", "{}", false, &shared, &helper);
        assert_eq!(serde_json::from_str::<Value>(&body).unwrap()["error"], "missing_tool");
        let (_, body) = route("POST", "/action", "", "{not json", false, &shared, &helper);
        assert_eq!(serde_json::from_str::<Value>(&body).unwrap()["error"], "bad_json");
    }

    #[test]
    fn bad_mode_is_rejected() {
        let shared = test_shared();
        let helper = Helper::new("unused".into());
        let (_, body) = route("POST", "/action", "", "{\"tool\":\"click\",\"mode\":\"sideways\"}", false, &shared, &helper);
        let v: Value = serde_json::from_str(&body).unwrap();
        assert_eq!(v["error"], "bad_mode");
    }

    #[test]
    fn paused_driver_refuses_actions() {
        let shared = test_shared();
        let helper = Helper::new("unused".into());
        shared.lock().unwrap().running = false;
        let (_, body) = route("POST", "/action", "", "{\"tool\":\"click\"}", false, &shared, &helper);
        let v: Value = serde_json::from_str(&body).unwrap();
        assert!(v["error"].as_str().unwrap().contains("paused"));
        // resume works and is reported
        let (_, body) = route("POST", "/action", "", "{\"tool\":\"resume\"}", false, &shared, &helper);
        assert_eq!(serde_json::from_str::<Value>(&body).unwrap()["ok"], true);
        assert!(shared.lock().unwrap().running);
    }

    #[test]
    fn status_is_valid_json_and_lists_newest_actions() {
        let shared = test_shared();
        {
            let mut s = shared.lock().unwrap();
            for i in 0..40 {
                s.log.push(LogEntry { tool: "t".into(), detail: format!("action {}", i), ok: true, mode: "background".into(), focus_changed: false });
            }
        }
        let v: Value = serde_json::from_str(&status_json(&shared)).unwrap();
        let actions = v["actions"].as_array().unwrap();
        assert_eq!(actions.len(), 12);
        // newest first-in-list must be the newest action, not the oldest
        assert_eq!(actions.last().unwrap()["detail"], "action 39");
    }

    #[test]
    fn control_chars_in_detail_keep_json_valid() {
        let shared = test_shared();
        {
            let mut s = shared.lock().unwrap();
            s.log.push(LogEntry { tool: "t".into(), detail: "tab\there\u{7}quote\"".into(), ok: true, mode: "background".into(), focus_changed: false });
            s.last_error = "esc\u{1b}".into();
        }
        let body = status_json(&shared);
        let v: Value = serde_json::from_str(&body).expect("status must stay valid JSON");
        assert!(v["actions"][0]["detail"].as_str().unwrap().contains("tab"));
    }

    #[test]
    fn method_and_path_errors() {
        let shared = test_shared();
        let helper = Helper::new("unused".into());
        assert_eq!(route("POST", "/status", "", "", false, &shared, &helper).0, 405);
        assert_eq!(route("GET", "/nope", "", "", false, &shared, &helper).0, 404);
        assert_eq!(route("GET", "/health", "", "", false, &shared, &helper).0, 200);
    }
}
