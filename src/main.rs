//! Quiet Driver — background computer use for agents.
//!
//! An agent binds to a running macOS app and drives it through Accessibility
//! and per-pid events. Nothing about the person's desktop changes: the pointer
//! does not move, focus is not stolen, windows keep their order, and the app
//! does not need to be visible or on the current Space.
//!
//! Two modes:
//!   * background (default) — deliver to the target pid and never activate it.
//!   * focused              — bring the target forward for one action and put
//!                            the person's app back afterwards.

mod desktop;
mod helper;
mod mcp;
mod metrics;
mod server;
mod session;
mod worker;
mod workspace;
mod shot;

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Instant;

use worker::WorkerPool;
use session::Handle;

struct Config {
    screenshot: Option<String>,
    screenshot_max_edge: Option<u32>,
    max_image_dimension: u32,
    helper: std::path::PathBuf,
    /// Serve MCP over stdin/stdout (how an agent harness launches it).
    mcp_stdio: bool,
    /// Show the dashboard window at startup.
    show_window: bool,
    /// Never create a window at all.
    headless: bool,
}

fn parse_config() -> Config {
    let args: Vec<String> = std::env::args().collect();
    let mut screenshot = None;
    let mut screenshot_max_edge = None;
    let mut helper_path = None;
    let mut mcp_stdio = false;
    let mut show_window = false;
    let mut headless = false;
    let mut i = 1;
    while i < args.len() {
        let arg = &args[i];
        if arg == "--screenshot" && i + 1 < args.len() {
            screenshot = Some(args[i + 1].clone());
            i += 2;
        } else if let Some(path) = arg.strip_prefix("--screenshot=") {
            screenshot = Some(path.to_string());
            i += 1;
        } else if arg == "--screenshot-max-edge" && i + 1 < args.len() {
            screenshot_max_edge = args[i + 1].parse::<u32>().ok();
            i += 2;
        } else if let Some(n) = arg.strip_prefix("--screenshot-max-edge=") {
            screenshot_max_edge = n.parse::<u32>().ok();
            i += 1;
        } else if arg == "--helper" && i + 1 < args.len() {
            helper_path = Some(std::path::PathBuf::from(&args[i + 1]));
            i += 2;
        } else if let Some(p) = arg.strip_prefix("--helper=") {
            helper_path = Some(std::path::PathBuf::from(p));
            i += 1;
        } else if arg == "--mcp-stdio" {
            mcp_stdio = true;
            i += 1;
        } else if arg == "--show" {
            show_window = true;
            i += 1;
        } else if arg == "--headless" {
            headless = true;
            i += 1;
        } else {
            i += 1;
        }
    }
    let max_image_dimension = std::env::var("CUA_DRIVER_MAX_IMAGE_DIMENSION")
        .ok()
        .and_then(|v| v.parse::<u32>().ok())
        .unwrap_or(0);

    // The helper script ships next to the binary (app bundle) or in swift/ for
    // a plain `cargo run` from the repo.
    let helper = helper_path.unwrap_or_else(|| {
        let exe_dir = std::env::current_exe()
            .ok()
            .and_then(|p| p.parent().map(|d| d.to_path_buf()))
            .unwrap_or_default();
        let candidates = [
            exe_dir.join("helper.swift"),
            exe_dir.join("../Resources/helper.swift"),
            exe_dir.join("../../../swift/helper.swift"),
            std::path::PathBuf::from("swift/helper.swift"),
        ];
        candidates
            .iter()
            .find(|p| p.exists())
            .cloned()
            .unwrap_or_else(|| std::path::PathBuf::from("swift/helper.swift"))
    });

    // Launched through LaunchServices (double-clicked, or `open -a`) the person
    // asked to see the dashboard. Launched directly from a terminal or by an
    // agent harness, it runs as a silent service.
    let launched_by_launchservices = std::env::var_os("QD_SHOW_DASHBOARD").is_some();
    let show_window = show_window || launched_by_launchservices;

    Config {
        screenshot,
        screenshot_max_edge,
        max_image_dimension,
        helper,
        mcp_stdio,
        show_window,
        headless,
    }
}

struct DriverApp {
    shared: Handle,
    pool: Arc<WorkerPool>,
    screenshot: Option<String>,
    screenshot_max_edge: Option<u32>,
    max_image_dimension: u32,
    port: u16,
    last: Instant,
    fps: f32,
    frames: u32,
    shot_requested: bool,
    shot_done: Arc<AtomicBool>,
    last_tree: Instant,
    /// Set when the person closes the dashboard: the daemon keeps serving, the
    /// window can be reopened from the tray icon.
    hide_window: Arc<AtomicBool>,
}

impl eframe::App for DriverApp {
    fn ui(&mut self, ui: &mut egui::Ui, _frame: &mut eframe::Frame) {
        let ctx = ui.ctx().clone();
        let now = Instant::now();
        let dt = (now - self.last).as_secs_f32().clamp(0.0, 0.1);
        self.last = now;
        if dt > 0.0005 {
            self.fps = self.fps * 0.85 + (1.0 / dt) * 0.15;
        }
        self.frames = self.frames.wrapping_add(1);

        {
            let mut s = self.shared.lock().unwrap();
            s.fps = self.fps;
            s.frames = self.frames as u64;
            s.port = self.port;
            // A second `open -a` asked for the dashboard: reveal it.
            if s.show_window.take().is_some() {
                self.hide_window.store(false, Ordering::SeqCst);
                ctx.send_viewport_cmd(egui::ViewportCommand::Visible(true));
                ctx.send_viewport_cmd(egui::ViewportCommand::Focus);
            }
        }

        // Keep the picture of the bound app fresh, but at a calm rate.
        if now.duration_since(self.last_tree).as_millis() > 700 {
            self.last_tree = now;
            desktop::refresh_tree(self.pool.session().as_ref(), &self.shared);
        }

        // The window is a viewer. Closing it hides the dashboard; the control
        // loop keeps running on the server threads.
        if ui.ctx().input(|i| i.viewport().close_requested()) && self.screenshot.is_none() {
            self.hide_window.store(true, Ordering::SeqCst);
            ui.ctx().send_viewport_cmd(egui::ViewportCommand::CancelClose);
            ui.ctx().send_viewport_cmd(egui::ViewportCommand::Visible(false));
        }

        desktop::draw(ui, &self.shared, self.fps);

        if self.screenshot.is_some() {
            ctx.send_viewport_cmd(egui::ViewportCommand::RequestPaintWhileHidden);
            if !self.shot_requested && self.frames >= 90 {
                self.shot_requested = true;
                let path = self.screenshot.clone().unwrap();
                let done = self.shot_done.clone();
                let ceiling = self.max_image_dimension;
                let override_edge = self.screenshot_max_edge;
                ctx.request_screenshot(move |image| {
                    match shot::save_png(&path, &image, ceiling, override_edge) {
                        Ok(()) => println!("screenshot saved to {}", path),
                        Err(error) => eprintln!("screenshot failed: {}", error),
                    }
                    done.store(true, Ordering::SeqCst);
                });
            }
            if self.shot_done.load(Ordering::SeqCst) {
                ctx.send_viewport_cmd(egui::ViewportCommand::Close);
            }
        }
        ctx.request_repaint();
    }
}

fn main() -> eframe::Result<()> {
    let config = parse_config();

    // The MCP-over-stdio mode is a bridge, not a second driver: the daemon
    // owns the session (what is bound, what the person is doing), and this
    // process forwards JSON-RPC to it. One session, one owner.
    if config.mcp_stdio {
        std::process::exit(mcp::bridge_stdio());
    }

    // Single instance. Two guards, because both are needed:
    //   1. an exclusive lock file, which settles the race when several launches
    //      start at once (they would all pass a port check before any of them
    //      published a port);
    //   2. the published-port check, which asks a live daemon to show its
    //      window instead of starting a second one.
    let _lock = match instance_lock() {
        Some(lock) => lock,
        None => {
            // Another daemon owns the session. Ask it for the dashboard and leave.
            let _ = reveal_running_instance(&config);
            return Ok(());
        }
    };
    if reveal_running_instance(&config) {
        return Ok(());
    }

    let pool = Arc::new(worker::WorkerPool::new(config.helper.clone()));
    let shared: Handle = Arc::new(Mutex::new(session::Shared::default()));
    let hide_window = Arc::new(AtomicBool::new(false));
    {
        let session = pool.session();
        let perms = helper::permissions(&session);
        let mut s = shared.lock().unwrap();
        s.permissions = perms;
        s.helper_ready = perms.accessibility;
        s.frontmost = helper::frontmost(&session).1;
    }

    // Ctrl-C / SIGTERM should remove the published port file.
    ctrlc_shutdown();

    let port = match server::spawn(shared.clone(), pool.clone()) {
        Some(port) => port,
        None => {
            // Another process already serves the session. Do not linger as a
            // second daemon with a dead control link: exit, and let the caller
            // talk to the one that owns the port.
            eprintln!("quiet-driver: another instance owns the control port; exiting");
            return Ok(());
        }
    };

    let mut options = eframe::NativeOptions::default();
    let mut viewport = egui::ViewportBuilder::default()
        .with_title("Quiet Driver — Background Computer Use")
        .with_inner_size([1180.0, 800.0])
        .with_min_inner_size([880.0, 560.0]);
    if config.screenshot.is_some() {
        viewport = viewport.with_active(false);
    }
    // The dashboard is a viewer, not a requirement: the daemon serves agents
    // whether or not anyone is looking at it.
    if !config.show_window {
        viewport = viewport.with_visible(false);
    }
    options.viewport = viewport;

    #[cfg(target_os = "macos")]
    if config.screenshot.is_some() {
        options.event_loop_builder = Some(Box::new(|builder| {
            use winit::platform::macos::EventLoopBuilderExtMacOS;
            builder.with_activate_ignoring_other_apps(false);
        }));
    }

    {
        // Let show_dashboard reveal this window.
        let mut s = shared.lock().unwrap();
        s.show_window = Some(hide_window.clone());
    }

    if config.headless {
        // Service mode: serve agents, show nothing. Runs until terminated.
        loop {
            std::thread::sleep(std::time::Duration::from_secs(3600));
        }
    }

    let app = DriverApp {
        shared,
        pool: pool.clone(),
        screenshot: config.screenshot,
        screenshot_max_edge: config.screenshot_max_edge,
        max_image_dimension: config.max_image_dimension,
        port,
        last: Instant::now(),
        fps: 0.0,
        frames: 0,
        shot_requested: false,
        shot_done: Arc::new(AtomicBool::new(false)),
        last_tree: Instant::now(),
        hide_window,
    };

    let result = eframe::run_native(
        "Quiet Driver",
        options,
        Box::new(move |_cc| Ok(Box::new(app))),
    );
    server::shutdown();
    result
}

/// Take the single-instance lock, or return None when another daemon holds it.
///
/// An advisory `flock` on a file in the state directory: it is released when
/// the process exits, so a crash cannot leave a stale lock behind.
fn instance_lock() -> Option<std::fs::File> {
    use std::os::unix::io::AsRawFd;
    extern "C" {
        fn flock(fd: i32, operation: i32) -> i32;
    }
    const LOCK_EX: i32 = 2;
    const LOCK_NB: i32 = 4;

    let dir = std::env::var_os("HOME")
        .map(|h| std::path::Path::new(&h).join(".quiet-driver"))
        .unwrap_or_else(|| std::path::PathBuf::from("/tmp/quiet-driver"));
    let _ = std::fs::create_dir_all(&dir);
    let path = dir.join("driver.lock");
    let file = std::fs::OpenOptions::new()
        .create(true)
        .read(true)
        .write(true)
        .open(&path)
        .ok()?;
    let rc = unsafe { flock(file.as_raw_fd(), LOCK_EX | LOCK_NB) };
    if std::env::var_os("QD_DEBUG_LOCK").is_some() {
        eprintln!("quiet-driver: flock({}) -> {} errno {:?}", path.display(), rc, std::io::Error::last_os_error().raw_os_error());
    }
    if rc == 0 {
        let _ = std::fs::write(&path, format!("{}\n", std::process::id()));
        Some(file)
    } else {
        None
    }
}

/// If a daemon is already listening on the published port, ask it to show its
/// window and return true. Keeps `open -a "Quiet Driver"` a "show the dashboard"
/// gesture rather than a second daemon.
fn reveal_running_instance(config: &Config) -> bool {
    let _ = config;
    let Ok(text) = std::fs::read_to_string(
        std::env::var_os("HOME")
            .map(|h| std::path::Path::new(&h).join(".quiet-driver").join("port"))
            .unwrap_or_default(),
    ) else {
        return false;
    };
    let Some(port) = text.lines().next().and_then(|l| l.trim().parse::<u16>().ok()) else {
        return false;
    };
    let body = "{\"tool\":\"show_dashboard\"}";
    let request = format!(
        "POST /action HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
        body.len(),
        body
    );
    use std::io::{Read, Write};
    let Ok(mut stream) = std::net::TcpStream::connect(("127.0.0.1", port)) else {
        return false;
    };
    let _ = stream.set_read_timeout(Some(std::time::Duration::from_millis(1500)));
    let _ = stream.set_write_timeout(Some(std::time::Duration::from_millis(1500)));
    if stream.write_all(request.as_bytes()).is_err() {
        return false;
    }
    let mut reply = String::new();
    let _ = stream.read_to_string(&mut reply);
    reply.contains("\"show_dashboard\"") || reply.contains("dashboard shown")
}

/// Best-effort clean-up on the usual termination signals.
fn ctrlc_shutdown() {
    use std::sync::Once;
    static ONCE: Once = Once::new();
    ONCE.call_once(|| {
        #[cfg(unix)]
        unsafe {
            extern "C" {
                fn signal(signum: i32, handler: usize) -> usize;
            }
            extern "C" fn on_signal(_sig: i32) {
                server::shutdown();
                std::process::exit(0);
            }
            const SIGINT: i32 = 2;
            const SIGTERM: i32 = 15;
            const SIGHUP: i32 = 1;
            signal(SIGINT, on_signal as extern "C" fn(i32) as usize);
            signal(SIGTERM, on_signal as extern "C" fn(i32) as usize);
            signal(SIGHUP, on_signal as extern "C" fn(i32) as usize);
        }
    });
}
