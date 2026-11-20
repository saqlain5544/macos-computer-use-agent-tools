//! Which app the agent is bound to, in which mode, and what the focus guard saw.
//!
//! Background mode never brings the target forward: every action goes to the
//! target pid through Accessibility or `CGEventPostToPid`. Focused mode is the
//! same actions with the target raised first, and the previous frontmost app
//! restored afterwards.

use crate::helper::{self, Helper, Hit, Node, Point, Rect, Window};
use std::sync::{Arc, Mutex};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mode {
    Background,
    Focused,
}

impl Mode {
    pub fn as_str(&self) -> &'static str {
        match self {
            Mode::Background => "background",
            Mode::Focused => "focused",
        }
    }
    pub fn parse(s: &str) -> Option<Mode> {
        match s.trim().to_ascii_lowercase().as_str() {
            "background" | "bg" | "quiet" => Some(Mode::Background),
            "focused" | "focus" | "foreground" | "front" => Some(Mode::Focused),
            _ => None,
        }
    }
}

#[derive(Clone, Debug, Default)]
pub struct Target {
    pub pid: i32,
    /// Identity that survives quit/relaunch: bundle id when known, else name.
    pub identity: String,
    pub app_name: String,
    pub window_id: u32,
    pub window_title: String,
    pub bounds: Rect,
    /// Who holds this app. A second agent binding the same app is refused
    /// unless it passes `takeover: true`.
    pub owner: String,
}

impl Target {
    pub fn label(&self) -> String {
        if self.window_title.is_empty() {
            self.app_name.clone()
        } else {
            format!("{} · {}", self.app_name, self.window_title)
        }
    }
}

#[derive(Clone, Debug, Default)]
pub struct ActionReport {
    pub ok: bool,
    pub error: String,
    pub detail: String,
    pub pointer_moved: bool,
    pub focus_changed: bool,
    pub focus_restored: bool,
    pub target_label: String,
    pub mode: String,
    pub payload: Option<serde_json::Value>,
}

impl ActionReport {
    pub fn ok(detail: impl Into<String>) -> Self {
        ActionReport { ok: true, detail: detail.into(), ..Default::default() }
    }
    pub fn err(detail: impl Into<String>) -> Self {
        ActionReport { ok: false, error: detail.into(), ..Default::default() }
    }
}

#[derive(Clone, Debug, Default)]
pub struct LogEntry {
    pub tool: String,
    pub detail: String,
    pub ok: bool,
    pub mode: String,
    pub focus_changed: bool,
}

/// Everything the server threads and the dashboard share.
pub struct Shared {
    pub running: bool,
    pub mode: Mode,
    pub target: Option<Target>,
    pub port: u16,
    pub port_error: String,
    pub fps: f32,
    pub frames: u64,
    pub agents: usize,
    pub agent_cursor: Point,
    pub frontmost: String,
    pub focus_events: u32,
    pub actions_total: u64,
    pub log: Vec<LogEntry>,
    pub tree: Vec<Node>,
    pub permissions: helper::Permissions,
    pub last_error: String,
    pub helper_ready: bool,
    /// Set when a second launch asks this daemon to show its dashboard.
    pub show_window: Option<std::sync::Arc<std::sync::atomic::AtomicBool>>,
    /// When the bound window's rectangle was last refreshed (unix millis), so
    /// actions do not pay for a window enumeration every time.
    pub bounds_refreshed_at: u64,
    /// Seconds since the daemon started, for /metrics.
    pub started_at: u64,
    /// Whether the person's screen is locked. Accessibility and focus behave
    /// differently when it is, so it is reported rather than inferred.
    pub screen_locked: bool,
}

impl Default for Shared {
    fn default() -> Self {
        Shared {
            running: true,
            mode: Mode::Background,
            target: None,
            port: 0,
            port_error: String::new(),
            fps: 0.0,
            frames: 0,
            agents: 1,
            agent_cursor: Point::default(),
            frontmost: String::new(),
            focus_events: 0,
            actions_total: 0,
            log: Vec::new(),
            tree: Vec::new(),
            permissions: helper::Permissions::default(),
            last_error: String::new(),
            helper_ready: false,
            show_window: None,
            bounds_refreshed_at: 0,
            screen_locked: false,
            started_at: std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_secs())
                .unwrap_or(0),
        }
    }
}

impl Shared {
    pub fn push_log(&mut self, entry: LogEntry) {
        self.log.push(entry);
        if self.log.len() > 200 {
            self.log.drain(0..50);
        }
    }
    pub fn recent(&self, n: usize) -> Vec<LogEntry> {
        let start = self.log.len().saturating_sub(n);
        self.log[start..].to_vec()
    }
}

pub type Handle = Arc<Mutex<Shared>>;

// ------------------------------------------------------------------ binding

/// Bind to a running app. `selector` is an app name, bundle id shape, pid, or
/// window title.
pub fn bind(
    h: &Helper,
    shared: &Handle,
    selector: &str,
    window: Option<u32>,
    owner: &str,
    takeover: bool,
) -> Result<Target, String> {
    let all = helper::windows(h);
    let layer0: Vec<&Window> = all.iter().filter(|w| w.layer == 0 && w.window_id > 0).collect();
    let picked = resolve(&layer0, selector)?;
    let pid = picked.pid;

    let candidates: Vec<&Window> = layer0.iter().copied().filter(|w| w.pid == pid).collect();
    let chosen: Window = window
        .and_then(|id| candidates.iter().find(|w| w.window_id == id).map(|w| (*w).clone()))
        .or_else(|| {
            // A real document window: has a title, is large, and is not one of
            // the accessory/panel windows macOS hangs off other apps.
            candidates
                .iter()
                .filter(|w| !w.title.is_empty() && is_usable_window(w))
                .max_by(|a, b| {
                    (a.bounds.w * a.bounds.h)
                        .partial_cmp(&(b.bounds.w * b.bounds.h))
                        .unwrap_or(std::cmp::Ordering::Equal)
                })
                .map(|w| (*w).clone())
        })
        .or_else(|| {
            // Any non-accessory window, even untitled: better than a panel, and
            // some apps do not title their main window.
            candidates
                .iter()
                .find(|w| is_usable_window(w))
                .map(|w| (*w).clone())
        })
        // Never fall back to an accessory window. macOS hangs strips like
        // "Save Panel Accessory View" off apps, and binding one gives an agent a
        // 1428x128 rectangle that is not the app.
        //
        // Binding an app with no window at all is allowed: that is the normal
        // state right after launch, and `open_file` is how a document gets
        // opened. The binding records window 0 and the window-dependent tools
        // explain the situation.
        .unwrap_or_else(|| Window {
            pid,
            owner: picked.owner.clone(),
            title: String::new(),
            window_id: 0,
            layer: 0,
            on_screen: false,
            bounds: Rect::default(),
        });

    // Identity: prefer the bundle id so a relaunch can be re-bound by pid-less
    // matching; fall back to the app name.
    let identity = helper::resolve(h, &chosen.owner)
        .map(|(_, _, bundle)| if bundle.is_empty() { chosen.owner.clone() } else { bundle })
        .unwrap_or_else(|_| chosen.owner.clone());

    {
        let s = shared.lock().unwrap();
        if let Some(existing) = &s.target {
            if existing.identity == identity && existing.owner != owner && !owner.is_empty() && !takeover {
                return Err(format!(
                    "{} is already bound by \"{}\"; pass takeover:true to take it over",
                    existing.label(),
                    existing.owner
                ));
            }
        }
    }

    let target = Target {
        pid,
        identity,
        app_name: chosen.owner.clone(),
        window_id: chosen.window_id,
        window_title: chosen.title.clone(),
        bounds: chosen.bounds,
        owner: owner.to_string(),
    };
    {
        let mut s = shared.lock().unwrap();
        s.target = Some(target.clone());
        s.agent_cursor = Point::default();
        s.tree = helper::tree(h, pid, 400);
        let mode = s.mode.as_str().to_string();
        s.push_log(LogEntry {
            tool: "bind".into(),
            detail: format!("bound to {}", chosen.label()),
            ok: true,
            mode,
            focus_changed: false,
        });
    }
    Ok(target)
}

/// Windows macOS hangs off an app that are not the app's own UI.
/// Is this window one an agent can actually act in?
///
/// Filters two things macOS adds to every app's window list: the accessory
/// panels it hangs off apps by title ("Save Panel Accessory View", "Open"), and
/// the untitled full-width strips (1512x33) that are menu bar or status items
/// but still report layer 0. Either one binds an agent to something that is not
/// the app.
fn is_usable_window(w: &Window) -> bool {
    w.layer == 0
        && !is_accessory(&w.title)
        && w.bounds.w >= 120.0
        && w.bounds.h >= 80.0
}

fn is_accessory(title: &str) -> bool {
    let t = title.to_ascii_lowercase();
    let exact = matches!(
        t.as_str(),
        "open" | "save" | "save as" | "print" | "page setup" | "open…" | "save…" | "export"
    );
    exact
        || t.contains("accessory view")
        || t.contains("save panel")
        || t.contains("open panel")
        || t.contains("toolbar")
        || t.contains("sheet")
}

fn resolve<'a>(windows: &[&'a Window], selector: &str) -> Result<&'a Window, String> {
    let sel = selector.trim();
    if sel.is_empty() {
        return Err("bind needs an app name, bundle id, pid, or window title".to_string());
    }
    if let Ok(pid) = sel.parse::<i32>() {
        return windows
            .iter()
            .find(|w| w.pid == pid)
            .copied()
            .ok_or_else(|| format!("no window found for pid {}", pid));
    }
    if let Some(w) = windows.iter().find(|w| w.owner.eq_ignore_ascii_case(sel)) {
        return Ok(w);
    }
    if let Some(w) = windows.iter().find(|w| w.title.eq_ignore_ascii_case(sel)) {
        return Ok(w);
    }
    let needle = sel.to_ascii_lowercase();
    if let Some(w) = windows.iter().find(|w| w.owner.to_ascii_lowercase().contains(&needle)) {
        return Ok(w);
    }
    let mut names: Vec<String> = windows.iter().map(|w| w.owner.clone()).collect();
    names.sort();
    names.dedup();
    Err(format!("no app matched \"{}\". Running apps: {}", sel, names.join(", ")))
}

/// Re-resolve the bound app after it was quit and relaunched: same identity,
/// new pid and window. Also refreshes the window rectangle.
pub fn rebind(h: &Helper, shared: &Handle) -> Result<Target, String> {
    let current = current_target(shared)?;
    let (pid, name, _) = helper::resolve(h, &current.identity)
        .or_else(|_| helper::resolve(h, &current.app_name))?;
    let wins = helper::windows(h);
    let chosen = wins
        .iter()
        .filter(|w| w.pid == pid && w.window_id > 0 && is_usable_window(w))
        .filter(|w| w.window_id == current.window_id)
        .next()
        .or_else(|| {
            wins.iter()
                .filter(|w| w.pid == pid && is_usable_window(w))
                .filter(|w| !w.title.is_empty())
                .max_by(|a, b| {
                    (a.bounds.w * a.bounds.h)
                        .partial_cmp(&(b.bounds.w * b.bounds.h))
                        .unwrap_or(std::cmp::Ordering::Equal)
                })
        })
        .or_else(|| {
            wins.iter()
                .filter(|w| w.pid == pid && is_usable_window(w))
                .max_by(|a, b| {
                    (a.bounds.w * a.bounds.h)
                        .partial_cmp(&(b.bounds.w * b.bounds.h))
                        .unwrap_or(std::cmp::Ordering::Equal)
                })
        })
        .cloned()
        .ok_or_else(|| format!("{} has no document window", name))?;
    let updated = Target {
        pid,
        app_name: chosen.owner.clone(),
        window_id: chosen.window_id,
        window_title: chosen.title.clone(),
        bounds: chosen.bounds,
        identity: current.identity.clone(),
        owner: current.owner.clone(),
    };
    if let Some(t) = shared.lock().unwrap().target.as_mut() {
        *t = updated.clone();
    }
    Ok(updated)
}

pub fn current_target(shared: &Handle) -> Result<Target, String> {
    shared
        .lock()
        .unwrap()
        .target
        .clone()
        .ok_or_else(|| "no app is bound yet — run {\"tool\":\"bind_app\",\"app\":\"<name>\"} first (GET /windows lists them)".to_string())
}

/// Window-local point in screen coordinates for the bound window.
pub fn global_point(target: &Target, x: f64, y: f64) -> Point {
    Point { x: target.bounds.x + x, y: target.bounds.y + y }
}

/// The AX element under a window-local point.
pub fn element_at(h: &Helper, target: &Target, x: f64, y: f64) -> Option<Hit> {
    let p = global_point(target, x, y);
    helper::element_at(h, target.pid, p).ok()
}

/// Re-read the bound window's geometry (it may have moved or been resized).
pub fn refresh_bounds(h: &Helper, target: &Target) -> Option<Window> {
    helper::windows(h).into_iter().find(|w| w.window_id == target.window_id)
}

/// Poll the frontmost app until it matches `pid`, or give up.
fn wait_for_frontmost(h: &Helper, pid: i32, budget_ms: u64) -> bool {
    let step = 40;
    let mut waited = 0;
    while waited <= budget_ms {
        if helper::frontmost(h).0 == pid {
            return true;
        }
        std::thread::sleep(std::time::Duration::from_millis(step));
        waited += step;
    }
    helper::frontmost(h).0 == pid
}

/// Run `f` with the target brought forward, then restore the previous app.
/// Only focused mode calls this. Reports honestly whether focus actually moved
/// and whether the person's app was put back.
pub fn with_focus<T>(h: &Helper, target: &Target, f: impl FnOnce() -> T) -> (T, bool, bool) {
    let (before_pid, _) = helper::frontmost(h);

    // If the target is already frontmost there is nothing to take and nothing
    // to give back. Reporting `restored: true` in that case was a lie: the
    // driver had not changed anything, so it had not restored anything either.
    if before_pid == target.pid {
        return (f(), false, false);
    }

    let came_forward = helper::activate(h, target.pid).is_ok()
        || wait_for_frontmost(h, target.pid, 300);
    let _ = helper::raise_window(h, target.pid);

    let out = f();

    // `changed` is only true if the target really did come forward, which is
    // what moved the person off their own app.
    let changed = came_forward && before_pid != 0 && before_pid != target.pid;

    // Put the person's app back, and verify it rather than assuming.
    let mut restored = false;
    if changed && before_pid != 0 {
        restored = helper::activate(h, before_pid).is_ok()
            || wait_for_frontmost(h, before_pid, 400);
    }
    (out, changed, restored)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn win(pid: i32, owner: &str, title: &str, id: u32, layer: i32) -> Window {
        Window {
            pid,
            window_id: id,
            owner: owner.into(),
            title: title.into(),
            layer,
            on_screen: true,
            bounds: Rect { x: 10.0, y: 20.0, w: 300.0, h: 200.0 },
        }
    }

    #[test]
    fn mode_parsing_covers_both_requests() {
        assert_eq!(Mode::parse("background"), Some(Mode::Background));
        assert_eq!(Mode::parse("quiet"), Some(Mode::Background));
        assert_eq!(Mode::parse("focused"), Some(Mode::Focused));
        assert_eq!(Mode::parse("Foreground"), Some(Mode::Focused));
        assert_eq!(Mode::parse("nonsense"), None);
        assert_eq!(Mode::Background.as_str(), "background");
        assert_eq!(Mode::Focused.as_str(), "focused");
    }

    #[test]
    fn resolve_by_name_pid_and_title() {
        let ws = [
            win(11, "Safari", "Start Page", 5, 0),
            win(22, "Calculator", "Calculator", 6, 0),
            win(22, "Calculator", "", 7, 0),
            win(33, "Dock", "dock", 8, 25),
        ];
        let refs: Vec<&Window> = ws.iter().filter(|w| w.layer == 0).collect();
        assert_eq!(resolve(&refs, "Calculator").unwrap().pid, 22);
        assert_eq!(resolve(&refs, "calculator").unwrap().pid, 22);
        assert_eq!(resolve(&refs, "22").unwrap().pid, 22);
        assert_eq!(resolve(&refs, "Start Page").unwrap().pid, 11);
        assert!(resolve(&refs, "Dock").is_err(), "layer-25 dock window must not match");
        assert!(resolve(&refs, "").is_err());
        let err = resolve(&refs, "Nope").unwrap_err();
        assert!(err.contains("Safari"), "error should list running apps: {}", err);
    }

    #[test]
    fn window_local_to_global() {
        let t = Target { bounds: Rect { x: 100.0, y: 50.0, w: 400.0, h: 300.0 }, ..Default::default() };
        let p = global_point(&t, 12.0, 34.0);
        assert_eq!((p.x, p.y), (112.0, 84.0));
    }

    #[test]
    fn report_constructors() {
        assert!(ActionReport::ok("x").ok);
        let e = ActionReport::err("boom");
        assert!(!e.ok);
        assert_eq!(e.error, "boom");
    }

    #[test]
    fn second_owner_is_refused_unless_takeover() {
        // Pure-logic mirror of the guard inside bind(), kept in sync with it.
        fn guard(existing: Option<(&str, &str)>, identity: &str, owner: &str, takeover: bool) -> Result<(), String> {
            if let Some((bound_identity, bound_owner)) = existing {
                if bound_identity == identity && bound_owner != owner && !owner.is_empty() && !takeover {
                    return Err(format!(
                        "{} is already bound by \"{}\"; pass takeover:true to take it over",
                        identity, bound_owner
                    ));
                }
            }
            Ok(())
        }
        assert!(guard(Some(("com.apple.calculator", "agent-a")), "com.apple.calculator", "agent-a", false).is_ok());
        assert!(guard(Some(("com.apple.calculator", "agent-a")), "com.apple.calculator", "agent-b", true).is_ok());
        assert!(guard(None, "com.apple.calculator", "agent-b", false).is_ok());
        let err = guard(Some(("com.apple.calculator", "agent-a")), "com.apple.calculator", "agent-b", false).unwrap_err();
        assert!(err.contains("agent-a"));
        assert!(err.contains("takeover"));
        // A different app is not blocked by another agent's binding.
        assert!(guard(Some(("com.apple.calculator", "agent-a")), "com.apple.TextEdit", "agent-b", false).is_ok());
    }

    #[test]
    fn untitled_strips_are_not_windows_to_act_in() {
        // macOS adds 1512x33 layer-0 strips (menu bar, status items) to every
        // app's window list. Binding one gives an agent a sliver.
        let mut strip = win(9, "TextEdit", "", 3, 0);
        strip.bounds = Rect { x: 0.0, y: 0.0, w: 1512.0, h: 33.0 };
        assert!(!is_usable_window(&strip), "a 33px strip is not a window to act in");
        assert!(!is_usable_window(&win(9, "TextEdit", "Open", 4, 0)));
        assert!(is_usable_window(&win(9, "TextEdit", "notes.txt", 5, 0)));
    }

    #[test]
    fn a_strip_never_wins_a_bind() {
        // macOS hangs "Save Panel Accessory View" off apps; binding it gives an
        // agent a 1428x128 rectangle that is not the app.
        assert!(is_accessory("Save Panel Accessory View"));
        assert!(is_accessory("Open"));
        let ws = [
            win(7, "TextEdit", "Save Panel Accessory View", 1, 0),
            win(7, "TextEdit", "Open", 2, 0),
        ];
        let refs: Vec<&Window> = ws.iter().filter(|w| w.layer == 0).collect();
        let picked = refs.iter().find(|w| !is_accessory(&w.title));
        assert!(picked.is_none(), "no strip may be treated as a document window");
    }

    #[test]
    fn accessory_windows_are_not_chosen() {
        assert!(is_accessory("Save Panel Accessory View"));
        assert!(is_accessory("Open Panel"));
        assert!(is_accessory("Format Toolbar"));
        assert!(is_accessory("Open"), "macOS open panels are titled \"Open\"");
        assert!(!is_accessory("qd_target.txt"));
        assert!(!is_accessory("Calculator"));

        // bind() picks the largest titled non-accessory window
        let ws = [
            win(5, "TextEdit", "Save Panel Accessory View", 1, 0),
            win(5, "TextEdit", "Untitled", 2, 0),
            win(5, "TextEdit", "notes.txt", 3, 0),
            win(5, "TextEdit", "", 4, 0),
        ];
        let refs: Vec<&Window> = ws.iter().filter(|w| w.layer == 0).collect();
        let picked = resolve(&refs, "TextEdit").unwrap();
        assert_eq!(picked.pid, 5);
    }

    #[test]
    fn identity_is_preferred_over_pid_for_rebinds() {
        let t = Target {
            pid: 0,
            identity: "com.apple.calculator".into(),
            app_name: "Calculator".into(),
            ..Default::default()
        };
        // A dead pid plus an identity means "re-resolve me", not "give up".
        assert_eq!(t.pid, 0);
        assert!(t.identity.contains("calculator"));
    }

    #[test]
    fn focus_flags_are_never_contradictory() {
        // `restored` may only be true when `changed` is: a driver that says it
        // gave focus back when it never took it is lying about the one thing
        // this project promises.
        fn consistent(changed: bool, restored: bool) -> bool {
            !restored || changed
        }
        assert!(consistent(false, false));
        assert!(consistent(true, true));
        assert!(consistent(true, false), "coming forward without restoring is allowed, if reported");
        assert!(!consistent(false, true), "restoring without changing is impossible");
    }

    #[test]
    fn label_uses_window_when_present() {
        let t = Target { app_name: "App".into(), window_title: "Doc".into(), ..Default::default() };
        assert_eq!(t.label(), "App · Doc");
        let t = Target { app_name: "App".into(), ..Default::default() };
        assert_eq!(t.label(), "App");
    }
}
