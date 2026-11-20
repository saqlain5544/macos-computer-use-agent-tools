# How it works

## The shape

```
        agent                          the person
          |                                |
          |  MCP (stdio or HTTP)            |  using their computer
          v                                v
   +------------------+          (nothing is disturbed)
   | Quiet Driver     |
   |  rust: control   |---- AX / CGEventPostToPid ---> [bound app]
   |       link       |
   |  swift: macOS    |
   +------------------+
          |
          v
   loopback HTTP : <port>
```

Two processes, one session:

- **The daemon** owns the state: what is bound, who owns it, the mode, the
  focus counters, the action log. It serves HTTP and MCP.
- **The bridge** (`--mcp-stdio`) is a thin forwarder. An agent harness that
  speaks MCP over stdio launches it; it starts the daemon if needed and
  forwards JSON-RPC. Both surfaces see the same session, so there is one
  owner of an app, not two.

The macOS layer is Swift. Rust talks to it over a JSON-lines pipe. That split
was not aesthetic: a Rust FFI implementation of the Accessibility API crashed
on `kAX*` symbol linkage and took hours to get right, while the Swift version
works in a few hundred lines and is the reference implementation for exactly
this API.

## Why background control is possible

macOS gives two ways to act on an app without touching the user's session:

**Accessibility actions** act on an element directly. `AXPress` on a button
runs the app's own action; the app does not need to be frontmost, on the
current Space, or even visible. This is why a background Calculator can be
driven and a background IDE can be typed into.

**`CGEventPostToPid`** posts a synthetic mouse or keyboard event straight to a
process. The OS pointer does not move, and the target does not become
frontmost. This covers what AX cannot express: typing a character, a drag, a
scroll, a chord.

The driver never calls `CGWarpMouseCursorPosition`, `CGEvent.post(tap:)`, or
`NSRunningApplication.activate` in background mode. That is the whole
guarantee, and it is checkable: sample the pointer and the frontmost app at
20 Hz while the agent works.

## The binding

A binding is more than a pid.

```rust
struct Target {
    pid: i32,
    identity: String,   // bundle id — survives a relaunch
    app_name: String,
    window_id: u32,
    window_title: String,
    bounds: Rect,
    owner: String,      // who may drive it
}
```

**Identity, not pid.** An agent that rebuilds and relaunches an app gets a new
pid. The bundle id is the same, so the next action re-resolves automatically
and the agent never has to notice.

**An owner.** One agent per app. A second `bind_app` is refused with the
owner's name, because two agents driving one app race: one closes what the
other opened. `takeover: true` overrides, for when the other agent is done.

**A window, chosen carefully.** macOS hangs accessory windows off apps
("Save Panel Accessory View", "Open"). Binding picks the largest titled
non-accessory window, so an agent lands in the document, not in a stray
panel.

## Focus guard

Focused mode is the only path that touches the person's session, and it is
built to be reversible:

1. Record the current frontmost app.
2. Activate the target (`open -a` + `NSRunningApplication.activate`, then poll
   `lsappinfo front` until it matches — `activate` alone silently does
   nothing from a background process).
3. Run the one action.
4. Put the previous app back.
5. Report `focus_changed` and `focus_restored` honestly, measured not assumed.

The reply tells the agent exactly what it did to the person's screen, so the
agent can decide whether to keep going.

## Seeing a background app

`screencapture -l <window-id>` reads a window's own surface, so the image is
the app's real content whether it is visible, minimised, occluded, or in a
hidden application. `ScreenCaptureKit` does the same for video, and is used
for `record`.

`CGWindowListCreateImage` is obsoleted on macOS 15, which is why the capture
path shells out to `screencapture` rather than calling the API.

## The dashboard is a viewer

The dashboard draws the bound window's real accessibility nodes, the agent's
cursor, the focus guard's counters, and the live action log. It never
simulates anything.

It is also optional. The control loop lives on the server's own thread, so
minimising or hiding the window changes nothing for an agent, and `--headless`
runs the service with zero windows.

## Per-agent workspaces

```
/tmp/quiet-driver/
  agent-<id>/
    screenshot-1789...png
    recording-1789....mov
  friction.jsonl
```

The agent id is sanitised into the directory name. An explicit absolute path
wins; a relative path resolves inside the agent's own directory, so an agent
cannot scribble into the working directory by accident.

## The friction log

Every `log_friction` call appends one JSON object to `friction.jsonl`: when,
which agent, which tool, what went wrong, and any detail that would help
reproduce it. `friction_log` reads it back.

This exists because the rough edges of a driver like this are only visible
from inside the agent's loop. A log that agents write themselves turns "it
sometimes doesn't work" into a queue of specific, reproducible problems.

## Failure behaviour

Every action reports what actually happened. There is no queue and no replay:
if the reply says `ok: true`, the OS did the thing; if `ok: false`, nothing
happened and `error` says why.

Some errors worth knowing:

| Error | Cause |
|---|---|
| `no app is bound yet` | `bind_app` was skipped |
| `no app matched "X"` | not running, or the wrong name |
| `was not running; relaunch it` | quit and relaunched under the agent |
| `already bound by "agent-x"` | another agent owns it |
| `no control labelled "X"` | no such control; the message lists the ones that exist |
| `the dialog is still open after every activation route` | an `NSOpenPanel` that does not respond to AX |

## Known limits

- **File dialogs.** An `NSOpenPanel` runs in a separate XPC service and does
  not commit through Accessibility on macOS 15. The workaround is to avoid
  the dialog: `open -a App /path/to/file` opens a document with no panel.
- **Menus.** Reachable through the tree, but the app must be frontmost for a
  menu to open.
- **Drag and drop** works within the bound window, not across applications.
- **The clipboard** is deliberately not exposed. It belongs to the person.
- **Linux and Windows** are not implemented.
