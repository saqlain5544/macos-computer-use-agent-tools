//! Client for the Swift helper (`swift/helper.swift`).
//!
//! One long-lived child process, one JSON object per line in each direction.
//! All macOS calls live in the helper, so the platform code stays in a single
//! readable Swift file and the Rust side just speaks this little protocol.

use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Write};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::sync::Mutex;

pub struct Helper {
    inner: Mutex<Option<Conn>>,
    script: std::path::PathBuf,
    /// Last observed pointer position, used to prove we never moved it.
    pointer: Mutex<Point>,
}

struct Conn {
    child: Child,
    stdin: ChildStdin,
    stdout: BufReader<ChildStdout>,
}

impl Helper {
    pub fn new(script: std::path::PathBuf) -> Self {
        Helper { inner: Mutex::new(None), script, pointer: Mutex::new(Point::default()) }
    }

    fn ensure(&self) -> Result<std::sync::MutexGuard<'_, Option<Conn>>, String> {
        let mut guard = self.inner.lock().unwrap();
        let dead = match guard.as_mut() {
            Some(c) => c.child.try_wait().map(|s| s.is_some()).unwrap_or(true),
            None => true,
        };
        if dead {
            if let Some(mut c) = guard.take() {
                let _ = c.child.kill();
                let _ = c.child.wait();
            }
            // Prefer the compiled helper. It sits next to the binary, but
            // `--helper` may point at a script elsewhere, so check all the
            // places a bundle puts it before falling back to interpreting.
            let mut candidates: Vec<std::path::PathBuf> = Vec::new();
            if let Some(dir) = self.script.parent() {
                candidates.push(dir.join("quiet-driver-helper"));
                candidates.push(dir.join("../MacOS/quiet-driver-helper"));
            }
            if let Ok(exe) = std::env::current_exe() {
                if let Some(dir) = exe.parent() {
                    candidates.push(dir.join("quiet-driver-helper"));
                }
            }
            let compiled = candidates.into_iter().find(|p| p.exists());
            let (program, args): (String, Vec<String>) = match compiled {
                Some(path) => (path.to_string_lossy().into_owned(), Vec::new()),
                None => ("swift".to_string(), vec![self.script.to_string_lossy().into_owned()]),
            };
            let mut child = Command::new(program)
                .args(args)
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .stderr(Stdio::null())
                .spawn()
                .map_err(|e| format!("could not start the swift helper: {}", e))?;
            let stdin = child.stdin.take().ok_or("helper stdin unavailable")?;
            let stdout = child.stdout.take().ok_or("helper stdout unavailable")?;
            *guard = Some(Conn { child, stdin, stdout: BufReader::new(stdout) });
        }
        Ok(guard)
    }

    pub fn call(&self, req: Value) -> Result<Value, String> {
        let mut guard = self.ensure()?;
        let Some(conn) = guard.as_mut() else {
            return Err("helper unavailable".to_string());
        };
        let line = serde_json::to_string(&req).map_err(|e| e.to_string())?;
        conn.stdin
            .write_all(format!("{}\n", line).as_bytes())
            .and_then(|_| conn.stdin.flush())
            .map_err(|e| format!("helper write failed: {}", e))?;
        let mut reply = String::new();
        conn.stdout
            .read_line(&mut reply)
            .map_err(|e| format!("helper read failed: {}", e))?;
        if reply.trim().is_empty() {
            return Err("helper closed the pipe".to_string());
        }
        serde_json::from_str(reply.trim())
            .map_err(|e| format!("helper sent invalid JSON: {} ({})", e, reply.trim()))
    }

    /// Call and turn `ok:false` into an error string.
    pub fn ok(&self, req: Value) -> Result<Value, String> {
        let v = self.call(req)?;
        if v.get("ok").and_then(|b| b.as_bool()).unwrap_or(false) {
            Ok(v)
        } else {
            Err(v
                .get("error")
                .and_then(|e| e.as_str())
                .unwrap_or("helper reported failure")
                .to_string())
        }
    }

    /// Remember the pointer position and report whether it has since moved.
    pub fn pointer_now(&self) -> Point {
        let p = match self.call(json!({"cmd": "pointer"})) {
            Ok(v) => {
                let p = v.get("pointer").cloned().unwrap_or(Value::Null);
                Point {
                    x: p.get("x").and_then(|x| x.as_f64()).unwrap_or(0.0),
                    y: p.get("y").and_then(|x| x.as_f64()).unwrap_or(0.0),
                }
            }
            Err(_) => Point::default(),
        };
        *self.pointer.lock().unwrap() = p;
        p
    }

    pub fn pointer_moved_since(&self, before: Point) -> bool {
        let now = self.pointer_now();
        (now.x - before.x).abs() > 0.5 || (now.y - before.y).abs() > 0.5
    }
}

// ------------------------------------------------------------------ types

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Point {
    pub x: f64,
    pub y: f64,
}

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
}

impl Rect {
    pub fn contains(&self, p: Point) -> bool {
        p.x >= self.x && p.y >= self.y && p.x <= self.x + self.w && p.y <= self.y + self.h
    }
    pub fn is_empty(&self) -> bool {
        self.w <= 0.0 || self.h <= 0.0
    }

    /// True when the rectangle has no area (used to skip empty AX frames).
    pub fn has_area(&self) -> bool {
        !self.is_empty()
    }
}

#[derive(Clone, Debug, Default)]
pub struct Window {
    pub pid: i32,
    pub window_id: u32,
    pub owner: String,
    pub title: String,
    pub layer: i32,
    pub on_screen: bool,
    pub bounds: Rect,
}

impl Window {
    pub fn label(&self) -> String {
        if self.title.is_empty() {
            format!("{} · window {}", self.owner, self.window_id)
        } else {
            format!("{} · {}", self.owner, self.title)
        }
    }

    fn from_json(v: &Value) -> Self {
        let f = |k: &str| v.get(k).and_then(|x| x.as_f64()).unwrap_or(0.0);
        Window {
            pid: v.get("pid").and_then(|x| x.as_i64()).unwrap_or(0) as i32,
            window_id: v.get("window_id").and_then(|x| x.as_i64()).unwrap_or(0) as u32,
            owner: v.get("owner").and_then(|x| x.as_str()).unwrap_or("").to_string(),
            title: v.get("title").and_then(|x| x.as_str()).unwrap_or("").to_string(),
            layer: v.get("layer").and_then(|x| x.as_i64()).unwrap_or(0) as i32,
            on_screen: v.get("on_screen").and_then(|x| x.as_bool()).unwrap_or(false),
            bounds: Rect { x: f("x"), y: f("y"), w: f("w"), h: f("h") },
        }
    }
}

#[derive(Clone, Debug, Default)]
pub struct Node {
    pub depth: usize,
    pub role: String,
    pub title: String,
    pub description: String,
    pub value: String,
    pub frame: Rect,
}

#[derive(Clone, Debug, Default)]
pub struct Hit {
    pub role: String,
    pub title: String,
    pub description: String,
    pub actions: Vec<String>,
    pub frame: Rect,
}

impl Hit {
    pub fn label(&self) -> String {
        if !self.description.is_empty() {
            self.description.clone()
        } else if !self.title.is_empty() {
            self.title.clone()
        } else {
            self.role.clone()
        }
    }
    pub fn can_press(&self) -> bool {
        self.actions.iter().any(|a| a == "AXPress")
    }
}

#[derive(Clone, Copy, Debug, Default)]
pub struct Permissions {
    pub accessibility: bool,
    pub post_events: bool,
    pub screen_capture: bool,
}

// ------------------------------------------------------------------ calls

/// Re-resolve a running app by identity (bundle id or name), so the binding
/// survives the app being quit and relaunched.
pub fn resolve(h: &Helper, app: &str) -> Result<(i32, String, String), String> {
    let v = h.ok(json!({"cmd": "resolve", "app": app}))?;
    let name = v.get("name").and_then(|x| x.as_str()).unwrap_or("").to_string();
    let bundle = v.get("bundle_id").and_then(|x| x.as_str()).unwrap_or("").to_string();
    let pid = v.get("pid").and_then(|x| x.as_i64()).unwrap_or(0) as i32;
    if pid == 0 {
        return Err(format!("\"{}\" is not running", app));
    }
    Ok((pid, name, bundle))
}

/// Launch an app in the background (no focus change) and return its pid/name.
pub fn launch(h: &Helper, app: &str) -> Result<(i32, String), String> {
    let v = h.ok(json!({"cmd": "launch", "app": app}))?;
    let pid = v.get("pid").and_then(|x| x.as_i64()).unwrap_or(0) as i32;
    let name = v.get("name").and_then(|x| x.as_str()).unwrap_or(app).to_string();
    Ok((pid, name))
}

/// Quit an app by identity. Tries terminate, Apple Events, then SIGTERM.
///
/// Fails with the app's own reason when it does not quit — most often a modal
/// "save changes?" sheet, which the driver must not answer on the person's
/// behalf.
pub fn quit_app(h: &Helper, app: &str, force: bool) -> Result<String, String> {
    let v = h.ok(json!({"cmd": "quit_app", "app": app, "force": force}))?;
    Ok(v.get("name").and_then(|x| x.as_str()).unwrap_or(app).to_string())
}


/// Screenshot of the bound window. Works for an occluded, minimised, off-Space,
/// or hidden app: the capture reads the window's own surface.
pub fn screenshot(h: &Helper, window_id: u32, path: &str) -> Result<(u32, u32, u64), String> {
    let v = h.ok(json!({"cmd": "screenshot", "window_id": window_id, "path": path}))?;
    let f = |k: &str| v.get(k).and_then(|x| x.as_u64()).unwrap_or(0);
    Ok((f("width") as u32, f("height") as u32, f("bytes")))
}

/// Record the bound window for `seconds` into a .mov.
pub fn record(
    h: &Helper,
    pid: i32,
    seconds: f64,
    path: &str,
) -> Result<(u32, u32, u32, u64), String> {
    let v = h.ok(json!({
        "cmd": "record", "pid": pid, "seconds": seconds, "path": path
    }))?;
    let f = |k: &str| v.get(k).and_then(|x| x.as_u64()).unwrap_or(0);
    Ok((f("width") as u32, f("height") as u32, f("frames") as u32, f("bytes")))
}

/// Inspect / drive an NSOpenPanel or NSSavePanel belonging to `pid`.
pub fn file_dialog(h: &Helper, pid: i32, req: serde_json::Value) -> Result<serde_json::Value, String> {
    let mut body = req;
    if let Some(o) = body.as_object_mut() {
        o.insert("cmd".into(), serde_json::json!("file_dialog"));
        o.insert("pid".into(), serde_json::json!(pid));
    }
    h.ok(body)
}

/// Open a document in an app without a file panel and without focus change.
pub fn open_file(h: &Helper, app: &str, path: &str) -> Result<(), String> {
    h.ok(json!({"cmd": "open_file", "app": app, "path": path})).map(|_| ())
}

/// Close one document of the bound app, leaving the app running.
pub fn close_file(h: &Helper, pid: i32, name: &str) -> Result<String, String> {
    let v = h.ok(json!({"cmd": "close_file", "pid": pid, "name": name}))?;
    Ok(v.get("closed").and_then(|x| x.as_str()).unwrap_or("").to_string())
}

/// The documents the app has open.
pub fn documents(h: &Helper, pid: i32) -> Vec<String> {
    h.ok(json!({"cmd": "documents", "pid": pid}))
        .ok()
        .and_then(|v| v.get("documents").and_then(|d| d.as_array()).cloned())
        .unwrap_or_default()
        .into_iter()
        .filter_map(|d| d.as_str().map(String::from))
        .collect()
}

/// Whether the person's screen is locked.
pub fn screen_locked(h: &Helper) -> bool {
    h.ok(json!({"cmd": "session"}))
        .ok()
        .and_then(|v| v.get("screen_locked").and_then(|b| b.as_bool()))
        .unwrap_or(false)
}

pub fn permissions(h: &Helper) -> Permissions {
    match h.call(json!({"cmd": "perms"})) {
        Ok(v) => Permissions {
            accessibility: v.get("accessibility").and_then(|b| b.as_bool()).unwrap_or(false),
            post_events: v.get("post_events").and_then(|b| b.as_bool()).unwrap_or(false),
            screen_capture: v.get("screen_capture").and_then(|b| b.as_bool()).unwrap_or(false),
        },
        Err(_) => Permissions::default(),
    }
}

pub fn windows(h: &Helper) -> Vec<Window> {
    match h.call(json!({"cmd": "windows"})) {
        Ok(v) => v
            .get("windows")
            .and_then(|w| w.as_array())
            .map(|arr| arr.iter().map(Window::from_json).collect())
            .unwrap_or_default(),
        Err(_) => Vec::new(),
    }
}

pub fn frontmost(h: &Helper) -> (i32, String) {
    match h.call(json!({"cmd": "frontmost"})) {
        Ok(v) => {
            let f = v.get("front").cloned().unwrap_or(Value::Null);
            (
                f.get("pid").and_then(|x| x.as_i64()).unwrap_or(0) as i32,
                f.get("name").and_then(|x| x.as_str()).unwrap_or("").to_string(),
            )
        }
        Err(_) => (0, String::new()),
    }
}

pub fn tree(h: &Helper, pid: i32, max: usize) -> Vec<Node> {
    match h.call(json!({"cmd": "tree", "pid": pid, "max": max})) {
        Ok(v) => v
            .get("nodes")
            .and_then(|n| n.as_array())
            .map(|arr| {
                arr.iter()
                    .map(|n| {
                        let f = |k: &str| n.get(k).and_then(|x| x.as_f64()).unwrap_or(0.0);
                        Node {
                            depth: n.get("depth").and_then(|x| x.as_i64()).unwrap_or(0) as usize,
                            role: n.get("role").and_then(|x| x.as_str()).unwrap_or("").to_string(),
                            title: n.get("title").and_then(|x| x.as_str()).unwrap_or("").to_string(),
                            description: n
                                .get("description")
                                .and_then(|x| x.as_str())
                                .unwrap_or("")
                                .to_string(),
                            value: n.get("value").and_then(|x| x.as_str()).unwrap_or("").to_string(),
                            frame: Rect { x: f("x"), y: f("y"), w: f("w"), h: f("h") },
                        }
                    })
                    .collect()
            })
            .unwrap_or_default(),
        Err(_) => Vec::new(),
    }
}

fn hit_from(v: &Value) -> Hit {
    Hit {
        role: v.get("role").and_then(|x| x.as_str()).unwrap_or("").to_string(),
        title: v.get("title").and_then(|x| x.as_str()).unwrap_or("").to_string(),
        description: v.get("description").and_then(|x| x.as_str()).unwrap_or("").to_string(),
        actions: v
            .get("actions")
            .and_then(|a| a.as_array())
            .map(|a| a.iter().filter_map(|s| s.as_str().map(String::from)).collect())
            .unwrap_or_default(),
        frame: Rect {
            x: v.get("x").and_then(|x| x.as_f64()).unwrap_or(0.0),
            y: v.get("y").and_then(|x| x.as_f64()).unwrap_or(0.0),
            w: v.get("w").and_then(|x| x.as_f64()).unwrap_or(0.0),
            h: v.get("h").and_then(|x| x.as_f64()).unwrap_or(0.0),
        },
    }
}

pub fn element_at(h: &Helper, pid: i32, p: Point) -> Result<Hit, String> {
    let v = h.call(json!({"cmd": "element_at", "pid": pid, "x": p.x, "y": p.y}))?;
    if !v.get("ok").and_then(|b| b.as_bool()).unwrap_or(false) {
        return Err(v.get("error").and_then(|e| e.as_str()).unwrap_or("nothing there").to_string());
    }
    Ok(hit_from(&v))
}

pub fn press_at(h: &Helper, pid: i32, p: Point) -> Result<Hit, String> {
    h.ok(json!({"cmd": "press_at", "pid": pid, "x": p.x, "y": p.y}))
        .map(|v| hit_from(&v))
}

/// Press a control by its label. Returns the pressed control's screen frame so
/// the caller can show where the agent acted.
pub fn press_label(h: &Helper, pid: i32, label: &str) -> Result<(String, Rect), String> {
    let v = h.ok(json!({"cmd": "press_label", "pid": pid, "label": label}))?;
    let name = v.get("label").and_then(|x| x.as_str()).unwrap_or(label).to_string();
    let f = |k: &str| v.get(k).and_then(|x| x.as_f64()).unwrap_or(0.0);
    Ok((name, Rect { x: f("x"), y: f("y"), w: f("w"), h: f("h") }))
}

pub fn text_field(h: &Helper, pid: i32) -> Result<String, String> {
    let v = h.ok(json!({"cmd": "text_field", "pid": pid}))?;
    Ok(v.get("value").and_then(|x| x.as_str()).unwrap_or("").to_string())
}

pub fn set_value(h: &Helper, pid: i32, value: &str) -> Result<(), String> {
    h.ok(json!({"cmd": "set_value", "pid": pid, "value": value})).map(|_| ())
}

/// Move the insertion point; used by `set_caret` so an agent can edit at a
/// known offset instead of clicking blind.
pub fn set_caret(h: &Helper, pid: i32, location: i64, length: i64) -> Result<(), String> {
    h.ok(json!({"cmd": "set_caret", "pid": pid, "location": location, "length": length}))
        .map(|_| ())
}

pub fn activate(h: &Helper, pid: i32) -> Result<(), String> {
    h.ok(json!({"cmd": "activate", "pid": pid})).map(|_| ())
}

pub fn raise_window(h: &Helper, pid: i32) -> Result<(), String> {
    h.ok(json!({"cmd": "raise_window", "pid": pid})).map(|_| ())
}

pub fn click(h: &Helper, pid: i32, p: Point, how: &str) -> Result<(), String> {
    let cmd = match how {
        "double" => "double_click",
        "right" => "right_click",
        "move" => "move",
        _ => "click",
    };
    h.ok(json!({"cmd": cmd, "pid": pid, "x": p.x, "y": p.y})).map(|_| ())
}

pub fn drag(h: &Helper, pid: i32, from: Point, to: Point) -> Result<(), String> {
    h.ok(json!({"cmd": "drag", "pid": pid, "x1": from.x, "y1": from.y, "x2": to.x, "y2": to.y}))
        .map(|_| ())
}

pub fn scroll(h: &Helper, pid: i32, p: Point, lines: i32) -> Result<(), String> {
    h.ok(json!({"cmd": "scroll", "pid": pid, "x": p.x, "y": p.y, "lines": lines}))
        .map(|_| ())
}

pub fn type_text(h: &Helper, pid: i32, text: &str) -> Result<usize, String> {
    let v = h.ok(json!({"cmd": "type", "pid": pid, "text": text}))?;
    Ok(v.get("sent").and_then(|x| x.as_u64()).unwrap_or(0) as usize)
}

pub fn key(h: &Helper, pid: i32, chord: &str) -> Result<(), String> {
    h.ok(json!({"cmd": "key", "pid": pid, "key": chord})).map(|_| ())
}

/// The pressing part of a chord, for error messages.
pub fn chord_key(chord: &str) -> Option<String> {
    let mut key = String::new();
    for part in chord.split('+') {
        let word = part.trim().to_ascii_lowercase();
        if matches!(
            word.as_str(),
            "cmd" | "command" | "meta" | "shift" | "alt" | "option" | "opt" | "ctrl" | "control"
        ) {
            continue;
        }
        if !word.is_empty() {
            key = word;
        }
    }
    if key.is_empty() {
        None
    } else {
        Some(key)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn window_json_parses_and_labels() {
        let v = json!({
            "pid": 42, "window_id": 7, "owner": "Calculator", "title": "Calculator",
            "layer": 0, "on_screen": true, "x": 10.0, "y": 20.0, "w": 300.0, "h": 200.0
        });
        let w = Window::from_json(&v);
        assert_eq!(w.pid, 42);
        assert_eq!(w.window_id, 7);
        assert_eq!(w.label(), "Calculator · Calculator");
        assert!(w.bounds.contains(Point { x: 15.0, y: 25.0 }));
        assert!(!w.bounds.contains(Point { x: 9.0, y: 25.0 }));

        let untitled = Window::from_json(&json!({
            "pid": 1, "window_id": 2, "owner": "App", "title": "", "layer": 0, "on_screen": true,
            "x": 0, "y": 0, "w": 1, "h": 1
        }));
        assert_eq!(untitled.label(), "App · window 2");
    }

    #[test]
    fn chord_key_extraction() {
        assert_eq!(chord_key("cmd+shift+t").as_deref(), Some("t"));
        assert_eq!(chord_key("Return").as_deref(), Some("return"));
        assert_eq!(chord_key("cmd+"), None);
    }

    #[test]
    fn hit_label_prefers_description_and_press_detection() {
        let h = Hit {
            role: "AXButton".into(),
            description: "7".into(),
            title: "seven".into(),
            actions: vec!["AXPress".into()],
            ..Default::default()
        };
        assert_eq!(h.label(), "7");
        assert!(h.can_press());
        let plain = Hit { role: "AXGroup".into(), ..Default::default() };
        assert_eq!(plain.label(), "AXGroup");
        assert!(!plain.can_press());
    }

    #[test]
    fn empty_rect_is_empty() {
        assert!(Rect::default().is_empty());
        assert!(!Rect { x: 0.0, y: 0.0, w: 4.0, h: 5.0 }.is_empty());
    }
}
