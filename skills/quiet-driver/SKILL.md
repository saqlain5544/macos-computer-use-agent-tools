# Quiet Driver — background computer use on macOS

Drive a real macOS app without disturbing the person using the computer. The
app can be frontmost, behind other windows, minimised, on another Space, or
hidden; your pointer never moves and their focus is never taken.

## The one rule

**Bind before you act.** Every action needs a bound app. Without one, the reply
says so and nothing happens.

```
bind_app  { app: "Calculator", agent: "me" }
```

`app` is a name, bundle id, pid, or window title. The reply gives you `pid`,
`window_id`, and `bounds`.

The binding stores the app's *identity* (bundle id), not just its pid. If the
app is quit and relaunched while you work — which is normal when you rebuild
and restart it — the next action re-binds automatically. You can also call
`rebind` yourself.

## Coordinates are window-relative

`x`, `y` are relative to the bound window's **top-left corner**, not the screen.
A point outside the window is refused with a clear message. Get the size from
the bind reply's `bounds`, or from `status`.

## Two modes

- **`background`** (default) — nothing on the person's screen changes. Use this.
- **`focused`** — the target is raised for one action, then the person's app is
  put back. Use only when they asked to watch. The reply reports
  `focus_changed` and `focus_restored` honestly.

Set per action with `"mode": "focused"`, or for the session with `set_mode`.

## Seeing the app

`screenshot` returns the bound window's pixels. It works in every window state
— occluded, minimised, off-Space, or in a hidden app — because it reads the
window's own surface, not the screen. `record` does the same for a few seconds
of video.

Each agent has a workspace, `/tmp/quiet-driver/agent-<id>/`, where these land.
Pass `path` to save anywhere else. The MCP reply returns the image inline, so
you can look at it directly.

## Opening and closing files

Do **not** open a file by clicking File → Open. That shows a modal panel that
takes focus away from the person, and on macOS 15 the panel does not respond to
accessibility actions — so it cannot be driven back to a clean state.

Use the file tools instead. They work entirely in the background:

```
open_file  { path: "/path/to/file" }     # opens it, no panel, no focus change
documents  { }                            # what the app has open
close_file { name: "file.txt" }           # closes that document, app keeps running
```

`open_file` is `open -g`: the document appears in the app and the person's
frontmost app does not change. `close_file` presses the document window's own
close button and verifies the document is gone before reporting success. If the
document has unsaved changes it reports that it is asking, rather than guessing.

If you ever do find a panel open, cancel it with the app — do not leave it
there for the next agent.

## When two agents want the same app

A second `bind_app` for an app another agent owns is **refused**, with the
owner's name in the message. Two agents driving one app would race — one
closing what the other just opened.

Your options:

- **Wait.** The other agent finishes and unbinds; bind again.
- **Take over** with `"takeover": true`, if you know the other agent is done.
- **Use another instance.** If the app supports it (Chrome with a separate
  profile, a second Simulator device, `open -n -a App`), launch one with
  `launch_app` and bind to that instead. Each instance has its own pid, so
  each agent can own one.

## Lifecycle is yours

You own the bound app's lifecycle. `quit_app` and `launch_app` both work in the
background: `launch_app` uses `open -g`, so the app appears without taking
focus, and `quit_app` terminates politely then falls back to SIGTERM.

This is the workflow for "keep working on it while I use my computer":

```
quit_app      { app: "MyEditor" }
launch_app    { app: "MyEditor" }     # background, no focus change
# next action re-binds automatically
```

## Waiting

Do not poll. `wait_for` waits on the driver's side, with one call instead of a
round trip per check:

| What | Call |
|---|---|
| a control appears (a button that enables when work finishes) | `{kind: "label", label: "Export"}` |
| text arrives in the field | `{kind: "text", value: "Done", contains: true}` |
| a document opens | `{kind: "document", name: "report.pdf"}` |
| a window appears | `{kind: "window", name: "Settings"}` |
| anything on screen changed | `{kind: "change"}` |

Default timeout is 5 s, max 30 s. On timeout it tells you what it last saw —
usually that is the answer ("no control labelled Export; 14 controls present").

## When the driver gets in your way

Call `log_friction` with what went wrong. It is written to a file that the
project reads, so the problem gets fixed instead of being rediscovered next
week.

```
log_friction {
  problem: "click_label could not find the Save button in a sheet",
  detail: "the sheet's buttons have no AXTitle, only AXDescription",
  tool: "click_label"
}
```

Read the collected backlog with `friction_log`.

## Tool reference

| Tool | Arguments | Notes |
|---|---|---|
| `bind_app` | `app`, `agent?`, `window_id?`, `takeover?` | required first step |
| `rebind` | | re-resolve after a relaunch |
| `unbind` | | release the app |
| `launch_app` | `app` | background, no focus change, no binding |
| `quit_app` | `app` | by name or bundle id |
| `list_windows` | | every window, all Spaces |
| `get_accessibility_tree` | | the bound app's AX tree |
| `get_desktop_state` | | frontmost app, bound target, mode |
| `click` | `x`, `y` | resolves to the element under the point |
| `double_click` | `x`, `y` | |
| `right_click` | `x`, `y` | |
| `move_cursor` | `x`, `y` | the agent's cursor; the person's never moves |
| `mouse_drag` | `x`, `y`, `to:{x,y}` | |
| `scroll` | `x`, `y`, `lines?` | |
| `type_text` | `text` | delivered to the app's process |
| `press_key` | `text` | `"Return"`, `"Tab"` |
| `hotkey` | `text` | `"cmd+shift+t"` |
| `set_value` | `text` | sets the text field directly; more reliable than typing |
| `set_caret` | `location?`, `length?` | `location` 0 = start, 1 = end |
| `click_label` | `label` | exact, then case-insensitive, then unique word subset, then symbol aliases (`+` finds "Add") |
| `get_text` | | the bound app's text field |
| `open_file` | `path`, `app?` | open a document with no panel, no focus change |
| `documents` | | the documents the app has open |
| `close_file` | `name?` | close one document, leaving the app running |
| `screenshot` | `path?`, `agent?` | PNG of the bound window |
| `wait_for` | `kind`, `label?`/`text?`/`name?`, `timeout_ms?` | wait instead of polling: `label`, `text`, `document`, `window`, `change` |
| `record` | `seconds?`, `path?`, `agent?` | .mov of the bound window |
| `set_mode` | `mode` | `background` or `focused` |
| `log_friction` | `problem`, `detail?`, `tool?`, `agent?` | |
| `friction_log` | `limit?` | read the backlog |
| `workspace` | `agent?` | your directory and its contents |
| `status` | | target, owner, mode, permissions, focus counters, recent actions |

## Reading the reply

Every reply carries `ok`, `error`, `detail`, `target`, `mode`,
`real_pointer_moved`, `focus_changed`, `focus_restored`, and `data`.

`ok: false` is a real failure with a real reason — no app bound, a point
outside the window, a control that does not exist (the message lists the labels
that do), or the app not running. There is no queue: what the reply reports
already happened.

## The HTTP API, if you are not using MCP

```
GET  /health    liveness
GET  /status    state and counters
GET  /windows   every window
GET  /tree      accessibility tree
POST /action    one tool
POST /mcp       MCP JSON-RPC
```

The port is in `~/.quiet-driver/port`: line 1 is the port, line 2 the URL,
line 3 the daemon pid. The listener binds loopback only, and any request with
an `Origin` header is refused so a web page cannot drive the desktop.
