# How it works

## The shape

One main process, one worker per bound app:

```
                 the person (undisturbed)
                          |
   +---------------------------------------------------+
   |  agent-driver  (MAIN PROCESS — exactly one)        |
   |    lock file, session state, bindings, ownership   |
   |    HTTP :<port>   MCP /mcp   /metrics              |
   +-----------------+------------------+--------------+
                     |                  |
          worker(Calculator)     worker(TextEdit)         <- swift helper, one per bind
                     |                  |
                  [Calculator]       [TextEdit]
```

The main process is the only thing that takes the single-instance lock and the
only thing that holds session state. Talking to an app is isolated: each bound
app gets its own worker process, so a slow call against one app cannot block
work on another, and a wedged worker cannot take the driver down. Workers are
created when an app is bound, reused across a relaunch (keyed by bundle id), and
reaped when the binding is released or moved to a different app.

A worker is lean on purpose: it costs ~13 MB and only loads AppKit (~40 MB) if
it is actually asked to record video.

## Why not one helper for everything

Because two agents driving two different apps should not queue behind each
other, and because the alternative — several copies of the *main* process — is
what produced the port races and the duplicate daemons. One main process, a
worker per bind.

```
        agent                          the person
          |                                |
          |  MCP (stdio or HTTP)            |  using their computer
          v                                v
   +------------------+          (nothing is disturbed)
   | Quiet Driver     |
   |   swift: all     |---- AX / CGEventPostToPid ---> [bound app]
   |   of it          |---- one worker process per app
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

The macOS layer is Swift. Swift talks to it over a JSON-lines pipe. That split
was not aesthetic: a Swift FFI implementation of the Accessibility API crashed
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

## Who decides that an app is visible

Background is the default and the only mode an agent can choose. Watching an app
come to the front is a decision about the person's screen, so it belongs to the
person: the dashboard's **Watch** toggle (or `--watch` / `set_watch` from the
operator surface) enables it, and only then does focused mode exist. Agents
cannot reach `set_mode`, cannot pass `mode` per call, and are instructed not to
ask for it. The invariant is enforced on every call: a session with watching off
runs in background mode whatever state it was left in.

## The operation log

One JSON object per operation, appended to
`~/.quiet-driver/logs/ops-YYYYMMDD.jsonl`, rotated at 32 MB with five kept. The
record is built for analysis rather than for reading:

| Field | Why it is there |
|---|---|
| `tool`, `agent`, `target`, `args` | who did what, where |
| `mode`, `mode_source` | which mode ran it and who chose it |
| `duration_ms`, `phases` | total, `worker_ms`, `driver_ms`, focus raise/restore |
| `worker_calls` | the commands inside the operation and their cost — a click that made seven calls says which seven |
| `focus` | changed/restored, the app before and after, attempts, timing |
| `pointer_moved` | proof the person's pointer was not touched |
| `ok`, `error` | what failed, in the failure's own words |
| `screen_locked` | whether the run is comparable with an unlocked one |

Daemon lifecycle, worker start/stop, permission changes, screen lock changes,
mode changes and watch changes are logged as their own `kind`, so a gap between
operations has an explanation. `scripts/analyze_logs.py` turns the file into
latency percentiles, a phase breakdown, the guarantee counters and the failures
grouped by reason.

## Bindings are per agent

The first version kept one binding for the whole session. Two agents that bound
two apps took the app from each other, and the second bind silently moved the
first agent's work onto the second app — the allocation was session-wide while
the isolation was per app, which is the worst of both.

A binding now belongs to the agent that made it:

- `bind_app(agent: "builder", app: "Calculator")` and
  `bind_app(agent: "reviewer", app: "TextEdit")` coexist.
- A call acts on that agent's app. Another agent's app is invisible to it.
- Ownership is still per app: binding an app another agent holds is refused
  unless the caller passes `takeover: true`, which drops the other agent's
  binding.
- A caller that names no agent gets the app bound most recently, which is what a
  single-agent client means by "the app I am working with".

This is what makes the worker-per-app design pay off. Measured on a recording
that occupied TextEdit's worker for two seconds, a call to Calculator's worker
took **20-41 ms**; with one session-wide binding it took **2081 ms**, because
both agents were talking to the same worker without knowing it.

## The binding

A binding is more than a pid.

```swift
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

## Failure behaviour of a worker

A worker is a child process. If it dies, the main process notices on the next
call and spawns a fresh one; the binding, the lock and the session state are
untouched. That is the reason the split is worth having: a wedged accessibility
connection to one app cannot take down the daemon that other agents are using.

## One language, one binary

The first version split the work between Rust (the control link, MCP, the
dashboard) and Swift (every macOS call), joined by a JSON-lines pipe. It worked,
but it cost a second toolchain, a 12 MB binary, a cross-language protocol to
keep in sync, and a 30-second rebuild for every change to a tool description.

It is now one Swift executable with five modes:

| Mode | What it is |
|---|---|
| (default) or `--show` | the daemon plus its dashboard window |
| `--headless` | the daemon alone |
| `--worker` | one worker process, driven by the daemon over JSON lines |
| `--viewer` | a dashboard window that attaches to a running daemon over HTTP |
| `--mcp-stdio` | the MCP stdio bridge |

The binary is 792 KB, builds in about two seconds, and the external contract did
not move: the same HTTP endpoints, the same MCP tools, the same reply shapes.
That is what let the existing acceptance sweep, tool audit and performance
harness run against the new implementation unchanged and pass.

The worker is still a separate process. That was never about the language: it
isolates one app's accessibility connection from the others and from the daemon,
so a wedged call against one app cannot take the driver down.

A dashboard is now a *viewer*: it reads `/status` and posts actions over HTTP,
so any number of windows can watch the same daemon without competing for the
lock. The daemon itself may be headless forever.

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
