# Mechanics sheet — Cua Driver (rebuild reference)

What the original program actually does, read from its files and its machine code — not guesses. This is a working sheet for the rebuild. Items marked **estimated** are choices for the rebuild that were NOT found in the original code.

For this turn I re-opened the original's main program (`/Applications/CuaDriver.app/Contents/MacOS/cua-driver`, sha256 `bbab72a49086…84c1`) in **Deep mode**, searched its strings with `native_strings_find` for names, settings and messages, followed the string references to the functions, and read every function with `native_function_pseudocode`, waiting for and reading each result. Fresh evidence this turn: port rule `ev_8703c25f…` / `ev_78f8be08…`; screenshot/capture strings `ev_79452c20…`; delivery mode `ev_9a90f791…`; seven function pseudocodes `ev_e6f549a5…`, `ev_a7daf3d5…`, `ev_d36964cd…`, `ev_9f45c08e…`, `ev_a6cd3827…`, `ev_f4231a45…`, `ev_516514e7…`; cursor-motion constants `ev_44c474eb…`, `ev_63a78aed…`, `ev_7c9cfa4b…`, `ev_21430fca…`, `ev_4811fb3b…`. Addresses are **canonical function entry addresses** (resolved by `native_function_pseudocode`), not the inner instruction addresses where a string happened to be referenced.

Evidence: Ghidra's decompiler cannot run on this Mac (`deep_engine_unavailable`: its public download ships no decompiler for this architecture), so all pseudocode came from Craft Anything's built-in lifter. It is register-level and partly unstructured; the string literals, environment variable names, lengths, defaults and quoted rules below are **observed** in the original binary, while the algebraic form of the screenshot and port rules is **derived** from that decompiled code and the tool descriptions.

## What the original is

| Fact | Value | Source |
|---|---|---|
| Bundle name / id | Cua Driver 0.38.0, `com.trycua.driver` | `Contents/Info.plist` |
| Kind | arm64 macOS Mach-O, Rust, not symbol-stripped | `core_target_triage` |
| Entry point | `0x10018dcb0` | `core_target_triage` |
| Main function | `0x100182af8` (`cua_driver::main`) | `ev_4f74c813…` |
| UI presence | `LSUIElement = true` — menu-bar/daemon app, no dock tile | `Contents/Info.plist` |
| Minimum macOS | 13.0 | `Contents/Info.plist` |

## Function map (decompiled this turn)

| Function | Entry | What it decides | Evidence |
|---|---|---|---|
| `cua_driver::main` | `0x100182af8` | Startup: build info, telemetry, permissions gate, PiP, serve thread | `ev_4f74c813…` |
| `serve::run_serve` | `0x1000c8ffc` | Private Unix socket + HTTP envelope on 127.0.0.1 | `ev_71c3c02…` |
| `driver_service_http::configured_port` | `0x10024036c` | Port setting, decimal parse, zero rejection | `ev_e6f549a…` |
| `cli::run_config_cmd` | `0x10002b83c` | Config keys; `capture_scope` retired message | `ev_f4231a4…` |
| `get_window_state::def` | `0x10059b558` | Screenshot long-edge override, AX read budget | `ev_a7daf3d…` |
| `get_desktop_state::def` | `0x100596ae4` | Full-display capture, `max_image_dimension` ceiling | `ev_d36964c…` |
| `move_cursor::def` | `0x100590c28` | `scope` / `delivery_mode` safety defaults | `ev_9f45c08…` |
| `desktop_pointer_guard::refusal_for` | `0x100569dc0` | Exact background-pointer refusal + retry hint | `ev_a6cd382…` |
| `LaunchAppTool::invoke` | `0x100640440` | Background launch, focus demotion, error codes | `ev_516514e…` |
| `perception_cli::run` | `0x1001b68d0` | Capture identity rules (`display_id:"primary"`) | `ev_3934a4e…` |
| `list_windows::def` | `0x1005947a0` | Window discovery: z-order, layer, on-screen flags | `ev_798db5c…` |
| `get_accessibility_tree::def` | `0x1005978a0` | Source of the "fast discovery read that needs no TCC grants" text | `ev_d7460c3…` |
| `cursor_overlay::motion::MotionConfig::with_motion_args` | `0x1007e7bac` | Real cursor-motion defaults and clamps | `ev_21430fca…` |
| `SetAgentCursorMotionTool::invoke` | `0x1005f5fe8` | Applies the same motion fields | `ev_4811fb3b…` |

Two corrections to the earlier sheet: `list_windows::def` really enters at `0x1005947a0` (not `0x100597914`), and the "fast discovery read that needs no TCC grants" sentence is decompiled from **`get_accessibility_tree::def` at `0x1005978a0`** (the older sheet used the inner reference address and the wrong tool name). The actual `list_windows` description is "List top-level windows known to WindowServer, including off-screen ones (minimized, other Space, hidden)… Use it to find a `pid` and `window_id` for get_window_state".

## Real values, formulas and rules

### 1. Local control port — `configured_port`, `0x10024036c`

- Reads environment variable **`CUA_DRIVER_ENVELOPE_HTTP_PORT`** (length `0x1d` = 29, at `0x10148f81e`).
- Parses a **decimal integer** digit by digit (`result = result * 10 + digit`, optional `+`/`-`, overflow checked — the lifter keeps the low 16 bits and checks the high bits are zero) into a **u16**.
- Parsed value **0** returns the exact error text **"CUA_DRIVER_ENVELOPE_HTTP_PORT must be nonzero"** (length `0x2d` = 45, at `0x10148f83b`).
- Variable **absent** → `VarError` converted by `From<VarError>` — there is **no fixed default port** in the original.
- `run_serve` (`0x1000c8ffc`) binds the private HTTP envelope on **127.0.0.1** ("Private Driver envelope HTTP listening on 127.0.0.1:"), rejects peers before request parsing, and prints "Cua Driver daemon shutting down." / "Cua Driver embedded host closed its lifetime pipe; shutting down."

### 2. Screenshot long edge — `get_window_state::def` `0x10059b558`, `get_desktop_state::def` `0x100596ae4`

Two verbatim properties:

- `max_image_dimension`: "Optional cap on the returned screenshot's long edge, in pixels (aspect ratio preserved) — the cheap path for a small preview / thumbnail. **Applied on top of the session/global `max_image_dimension` ceiling; the tighter of the two wins.** Omit for the configured default."
- Per-call long-edge override: "Per-call override for the returned screenshot's long edge in pixels. **An explicit value wins over the session/global setting; 0 returns native resolution.** Omit…"

**Effective rule (implemented in `app/src/shot.rs`):**

```
cap = explicit_override == 0 ? none
    : explicit_override > 0  ? explicit_override
    : session_global_max_image_dimension
if cap is none or max(w,h) <= cap -> keep native (w,h)
scale = cap / max(w,h)
out_w = round(w * scale), out_h = round(h * scale)   # aspect ratio preserved
```

The desktop definition adds: "Capture the full display. The long edge is capped at `max_image_dimension` (the configured default unless given)… Returns the true screen size and backing scale factor. **Vision-only: no AX tree walk.**" Window capture writes the PNG to `screenshot_out_file` instead of embedding base64.

### 3. Pointer and focus safety — `move_cursor::def` `0x100590c28`, `refusal_for` `0x100569dc0`

From the decompiled tool definition (verbatim rules):

- `scope` default **`"window"`**: "moves only the agent cursor overlay"; x/y are window screenshot pixels; in a background app it also hovers through a route that leaves the real pointer alone (AXShowAlternateUI or an Electron page).
- `scope="desktop"`: "moves the user's real OS pointer in native `get_desktop_state` screenshot coordinates; over a window of an app that is not in front it **refuses unless `delivery_mode` is `"foreground"`**."
- `delivery_mode` default **`"background"`**: "refuses, **before moving anything**, when the point is over a window of an app that is not in front, since that would move the user's pointer. `"foreground"`: move the real pointer anyway; only when nobody is using this screen or the user agreed."
- Refusal text (`0x101529ff4`): **"the desktop point is over a background app; a desktop-target pointer action would move the user's pointer"**. Retry hint from `refusal_for`: **"Retry this action with delivery_mode:\"foreground\"."** (`0x101529ca4`). The refusal function also offers `suggestion: pass scope="desktop"`, a browser-tools route for browser pages, and `event_kind` values `pointer_move`, `click`, `scroll`, `drag`.

### 4. Tool set, config and read budget

- Tool names observed in strings: `list_windows`, `get_desktop_state`, `get_window_state`, `get_accessibility_tree`, `click`, `double_click`, `right_click`, `move_cursor`, `mouse_drag`, `press_key`, `hotkey`, `type_text`, `set_value`, `launch_app`, `set_config`, `clipboard_read`, `clipboard_write`, browser and recording tools.
- `get_window_state::def`: AX walk capped at **250 nodes by default**, **2 000 with `full_output:true`**; `query` is a case-insensitive substring filter; `since:"latest"` gives diff reads (`+` added, `~` changed, `-` removed); `tree_format` is `markdown` / `elements` / `both`.
- `cli::run_config_cmd` (`0x10002b83c`): valid keys include `capture_mode`, `max_image_dimension`, `version`, `platform`, `agent_cursor.enabled`, `cursor.motion.*`, `cursor.badges`; the stored `capture_scope` key is retired: **"config key 'capture_scope' is retired; select a window or desktop target on each action"** (`0x10147956c`). `start_session.capture_scope` must be one of `auto`, `window`, `desktop`.
- `perception_cli::run` (`0x1001b68d0`): desktop capture metadata supports only **`display_id:"primary"`**; window capture requires a **positive pid and window_id**; `captured_at` must be an RFC3339 timestamp; PNG images up to `0x4000000` bytes, capture metadata up to `0x100000` bytes.
- `list_windows::def` (`0x1005947a0`): for the frontmost window take the **maximum integer z_index** (null = stacking unavailable; do not infer from array order); layer-0 only without `pid`, every layer with `pid`.

### 5. Background launch — `LaunchAppTool::invoke` `0x100640440`

- "Launch a macOS app in the background — the target does NOT come to the foreground." `bundle_id` wins over `name`.
- `webkit_inspector_port` sets **`WEBKIT_INSPECTOR_SERVER=127.0.0.1:N`** plus **`TAURI_WEBVIEW_AUTOMATION=1`**. DevTools flags moved to `browser_prepare` so DevTools is never enabled on an unproven profile.
- `creates_new_application_instance` passes **`-n`** to `open` for a fresh pid/window so sessions do not fight over one instance.
- Focus-steal prevention: prior frontmost pid read, re-demotion, retry message "belt-and-braces demotion iteration failed: launched app remained frontmost after re-activating prior — will retry", response field `self_activation_suppressed`.
- Refuses the protected permission host: "launch_app cannot launch Cua Driver's protected host; operating-system permission UI must originate outside the agent tool stream."
- Error codes: `APP_NOT_INSTALLED`, `NSWORKSPACE_LAUNCH_FAILED`, `LAUNCH_FAILED`, `LAUNCH_CALLBACK_TIMEOUT`, `LAUNCH_RESULT_MISSING`, `APP_URL_INVALID`.

### 6. Startup — `main` `0x100182af8`

`build_info::init("85e2b1318bd77ccf3cfa88ccdf875a4bb7eaed19", 0x28)`; `CUA_LOG` / telemetry (`CUA_DRIVER_CLI_TELEMETRY_CHILD`); permissions gate message "[cua-driver] desktop tool calls remain gated; grant Accessibility and Screen Recording permissions, then restart the daemon."; experimental PiP preview (`CUA_DRIVER_HOST_BUNDLE_ID`); spawns `cua_driver_serve` / `cua-serve` on a dedicated thread.

### 7. Speed

`list_windows` is deliberately a cheap discovery read; the full AX tree is the heavy tool. **No frames-per-second target or screenshot interval constant exists in the original** (a string search for "frame rate" returned 0 matches). The rebuild's 120-frame screenshot run and continuous repaint are **estimated**.

### 8. Cursor-motion timing — `MotionConfig::with_motion_args` `0x1007e7bac`, `SetAgentCursorMotionTool::invoke` `0x1005f5fe8`

Decompiled this turn from the motion-config functions (schema text at `ev_44c474eb…`, `ev_63a78aed…`, `ev_7c9cfa4b…`). These are **real values in the original**, not estimates:

| Setting | Real default / rule | Clamp | Field name |
|---|---|---|---|
| `timing` | `steady` (default): every move takes **at least 600 ms**, gentler ease | — | `timing` |
| `relaxed` / `calm` floors | **450 ms** / **750 ms** | — | `timing` |
| `native` | style's own timing; `fitts` scales with distance and target size; `deliberate` is a slower Fitts curve (**450..1300 ms**) | — | `timing` |
| `fixed` glide | `glide_duration_ms`, **1430 ms when 0** | **0..5000** | `glide_duration_ms` |
| Arc start/end handle | **0.3** (fraction of distance) | **0..1** | `start_handle`, `end_handle` |
| Arc size | **0.25** (0 = straight, 0.5 = double); applies to `signature_arc`, `spring_settle`, `comet_swoop` | **0..1** | `arc_size` |
| Arc flow | **0** (positive shifts apex toward destination) | **-1..1** | `arc_flow` |
| Arrival spring (classic) | **0.72** (1 = critically damped, 0.3 = bouncy) | **0.3..1** | `spring` |
| Dwell after click | **80 ms** | **0..5000** | `dwell_after_click_ms` |
| Idle hide | **15000 ms** (0 = never hide) | **0..60000** | `idle_hide_ms` |
| Turn radius (classic) | **80 points** | **1..1000** | `turn_radius` |

Default style is `signature_arc`; when the theme's reduced-motion option is on, every move becomes a short straight glide with no effects. These fields are written to `~/.cua-driver/config.json` and seed later sessions; `reduced_motion` always wins.

## How the rebuild uses these rules

- `app/src/shot.rs`: implements the long-edge formula above — explicit override wins, `0` = native, aspect ratio preserved, nearest-neighbour resample, no new image dependency, with four self-tests. Driven by `--screenshot-max-edge N` and `CUA_DRIVER_MAX_IMAGE_DIMENSION` (the original's configured ceiling, not a binary literal).
- `app/src/server.rs`: `configured_port()` mirrors the original's decimal-u16 parse and returns the exact "must be nonzero" error; the loopback listener accepts the original's tool names, defaults to `scope="window"` / `delivery_mode="background"`, and refuses a desktop pointer action over a background window with the original's refusal text and retry hint before anything moves. `/status` now exposes the real motion defaults and their clamps, and `set_config` / `set_agent_cursor_motion` validate motion fields with the original's clamps (`0x1007e7bac`) and report the effective value.
- `app/src/desktop.rs`: logs each action's scope and delivery mode; the drawn desktop is replayed locally and **no OS pointer or focus API is ever called**. Its `motion` constants and `motion_interval_s()` now use the original's real timing floors (steady **600 ms**, relaxed 450 ms, calm **750 ms**, fixed 1430 ms) and the real per-field clamps from `0x1007e7bac` / `0x1005f5fe8`; the old guessed 0.62 s / 1.05 s cadence is gone.

## Still estimated in the rebuild

- 120 frames before the verification screenshot is taken; "blazing-fast repaint" is an uncapped loop. (The agent's move cadence is **no longer estimated** — it now uses the original's steady/calm floors from `0x1007e7bac`.)
- When `CUA_DRIVER_ENVELOPE_HTTP_PORT` is absent or invalid, this rebuild binds an OS-assigned loopback port so the local link stays usable, and reports the original's error text in `/status`; the original errors out instead.
- The dashboard UI is new: the original is a headless `LSUIElement` daemon with no window picture to copy.
- The isolated desktop is drawn inside this window rather than capturing a real second display.
- Publishing the bound port to `~/.quiet-driver/port` so an agent can find the loopback link without looking at the screen is a rebuild convenience, not a behaviour found in the original code.

## What the rebuild actually does now (v0.39, measured)

The earlier sections are the decompiled *original*. This section is what this
rebuild implements and what was measured on the machine, so the two are not
confused.

### Control path

| Concern | Implementation | Evidence |
|---|---|---|
| App identity | `bind_app` resolves a name/bundle id/pid/title to a pid and window; the binding stores the **bundle id** so it survives quit + relaunch | lifecycle sweep: quit → action refused → relaunch → auto-rebind → action OK |
| Background input | AX (`AXPress`, `AXValue`, `AXSelectedTextRange`) and `CGEventPostToPid` | Calculator driven to `1234 × 3 = 3,702` with the app behind Chrome |
| Focus | `background` never activates; `focused` activates around one action and restores | 160 actions: frontmost constant; focused: `focus_changed:true`, `focus_restored:true` |
| Pointer | never moved by the driver | 12 s A/B trace: 8 distinct pointer positions both while paused and while acting (the person's own movement); `real_pointer_moved` measured per action |
| Spaces / behind windows | AX tree is read from the app, not from a screenshot, so a window on another Space or fully occluded is still drivable | pressed controls with the target behind Chrome and behind the dashboard |
| Quit / relaunch | `quit_app` (terminate → Apple Events → SIGTERM), `launch_app` (`open -g`, no focus change) | automated in the build script's acceptance run |
| Multi-agent | one owner per bound app; a second `bind_app` is refused unless `takeover:true` | owner guard test + live refusal message |
| Dashboard | a viewer; closing it hides the window, the daemon keeps serving | actions succeeded with the dashboard minimised/hidden |
| Cross-origin | any request with an `Origin` header is refused (403) | browser probe from a page on another port |

### Deliberately not implemented

- `clipboard_read` / `clipboard_write` refuse: the clipboard belongs to the person.
- Screen capture of the bound window is available in the helper (`capture`) but
  is not yet exposed as a tool; the dashboard draws the AX tree instead.
- No synthetic `scope`/`delivery_mode` semantics from the original: this rebuild
  delivers to a *bound app*, so `scope` is no longer a per-action choice.

### What is measured, not claimed

`/status` reports `focus_events` (incremented only when the driver itself moved
focus), `actions_total`, live permissions, and per-action `real_pointer_moved`,
`focus_changed`, `focus_restored`.
