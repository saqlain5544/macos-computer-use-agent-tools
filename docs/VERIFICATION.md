# What was actually measured

Every claim in this README that could be measured, was. This is the evidence,
with the method, so it can be re-run and challenged.

Machine: macOS 15 (Darwin 24.x), Apple Silicon, one logged-in user session.

---

## 1. Background driving really changes the app

**Method.** Bind Calculator, which was behind Google Chrome and not
frontmost. Press keys through the accessibility tree. Read the result back
through the tree.

```
bind Calculator (behind Chrome)
press 1, 2, 3, 4, Multiply, 3, Equals
  -> display reads "3,702"
```

**Result.** The calculator's display changed while it was behind another
window. The old build of this project was a simulator — all 17 tools were
no-ops. This one is not.

---

## 2. The person's pointer does not move

**Method.** A 20 Hz sampler recorded the pointer position, the frontmost app
(`lsappinfo front`), and the top window in the window server. Two runs of
identical length: one with the driver paused, one with 160 actions running.

| Run | Actions | Distinct pointer positions | Frontmost apps seen |
|---|---|---|---|
| Paused | 0 | 8 | DeepSeek Harness, agate-browser |
| Acting | 160 | 8 | DeepSeek Harness, agate-browser |

**Result.** The pointer moved the same amount in both runs: that is the person
moving their own mouse. The driver contributed none of it. The frontmost app
never changed and never changed *during* a run either — only between runs, by
the person switching apps.

The driver also reports this per action: `real_pointer_moved` is measured, not
asserted.

---

## 3. Focus is never stolen in background mode

**A bug that was here, and how it was found.** Focus *was* being stolen: an
agent that sent one action with `"mode": "focused"` left the whole session in
focused mode, because the per-call mode overwrote the session. Every later
"background" action then activated the target and restored focus — the app
visibly came forward and went back for no reason the agent could see.

The fix is that a per-call mode applies to that call only; `set_mode` is the
only thing that changes the session. Two regression tests pin it
(`a_per_call_mode_never_changes_the_session`,
`set_mode_is_the_only_way_to_change_the_session`), and the harness reports
`focus moved` as a hard failure.

Measured after the fix, sampling focus at 20 Hz through one focused call
followed by four plain ones: transitions only during the explicit focused call,
none after it, session mode still `background`.

**Method.** The same sampler, plus the driver's own `focus_events` counter,
which increments only when the driver itself changed focus.

```
160 background actions -> focus_events: 0
```

In focused mode the counters are honest in both directions:

```
focused click -> focus_changed: true, focus_restored: true
frontmost before: Google Chrome
frontmost after:  Google Chrome
```

The sampler shows the target genuinely came forward mid-action
(`Calculator` appeared as frontmost for ~200 ms) and the person's app was put
back.

---

## 4. The app does not need to be visible

**Method.** Capture the bound window with `screencapture -l <window-id>`,
which reads the window's own surface, in each window state.

| State | Capture | Distinct colours | Image |
|---|---|---|---|
| Visible | 1348×816 | 399 | real content |
| Minimised | 1348×816 | 399 | byte-identical to visible |
| App hidden | 1348×816 | 400 | real content |
| Behind another window | 1348×816 | 617 | real content |

**Result.** A window that is minimised, hidden, or occluded still produces its
real pixels. The same holds for video: ScreenCaptureKit recorded 38 frames of
a 3.1-second clip of TextEdit while the app was hidden.

---

## 5. The binding survives a rebuild-and-relaunch

**Method.** The agent's real workflow: quit the app, relaunch it, keep going.

```
quit_app Calculator            -> ok
action while gone              -> "Calculator was not running; relaunch it
                                  and the next action will re-bind automatically"
launch_app Calculator           -> ok, in the background, no focus change
action after relaunch          -> ok, "pressed 9 in Calculator"
```

**Result.** The binding stores the bundle id, not the pid, so a new process is
followed automatically. The rebind is not something the agent has to remember
to do.

---

## 6. Two agents cannot fight over one app

**Method.** Bind as `agent-a`, then bind as `agent-b`.

```
bind_app as agent-b -> refused: "Calculator · Calculator is already bound by
                        \"agent-a\"; pass takeover:true to take it over"
bind_app as agent-b, takeover:true -> ok
```

**Result.** The guard is at bind time, which is where the race actually
starts: one agent closing what another just opened.

---

## 7. The dashboard is optional

**Method.** Minimise the dashboard, then hide the app behind it, then run
actions.

```
dashboard minimised -> action ok, "pressed 7"
dashboard hidden    -> action ok, and the calculator's display changed
```

**Result.** The control loop runs on the server's own thread. The window is a
viewer; the service does not depend on it.

The same holds for the service mode: with `--headless` the process opens zero
windows and still serves every tool.

---

## 8. Latency

Numbers from `perf/harness.py` on the shipping build. Every value is a p50 over
40 samples against a bound Calculator; see `perf/README.md` for the method.

Measured over loopback against a bound Calculator, 20 iterations each, warm.

| Operation | Time | Why |
|---|---|---|
| `/status` | 0.2 ms | reads shared state, no IPC |
| `/metrics` | 0.3 ms | |
| `/windows` (123 windows) | 2.4 ms | one window-server call |
| `set_value` | 2.3 ms | one AX attribute write |
| `get_text` | 1.0 ms | one AX read |
| `type_text` | 10.5 ms | one event per character |
| `press_key` | 15.6 ms | two events plus the app's own latency |
| `click_label` | 16.6 ms | tree walk to find the control by name |
| `accessibility_tree` | 20.3 ms | one tree walk |
| `click` (coordinate) | 28.7 ms | hit test, then press or synthetic click |
| `screenshot` | 66.7 ms | window capture, PNG encode |
| helper cold start (compiled) | 47 ms | |
| helper cold start (interpreted) | 530 ms | |
| focus guard (activate + restore) | ~600 ms | only in focused mode |

Two of these were much worse and were fixed after the harness measured them:

- **Coordinate clicks took 137 ms** because the hit test walked the whole
  accessibility tree (`element_at` read every node's frame). `AXUIElementCopyElementAtPosition`
  answers the same question in one call. It is made against the *app* element,
  not system-wide, so a backgrounded app is still hit-tested correctly.
- **Every synthetic click slept 128 ms** (18 + 70 + 40 ms of `usleep`). The gaps
  are there so the target's event loop sees a distinct move, press and release;
  they did not need to be that generous. 8 + 14 + 0 ms still registers correctly
  (verified by pressing a key and reading the calculator's display) and costs
  ~22 ms.

The remaining tree-walk cost is inherent: every node is a synchronous IPC call
into the target app, so a 130-node app costs ~130 round trips. That is the price
of acting on the app's own elements rather than on screen coordinates, and it is
well under a human's interaction rate.

The driver ships a compiled helper next to the binary and falls back to
interpreting the script when it is absent, so a source checkout works without
a build step.

## 9. Memory is flat over a long session, and workers are lean

**Method.** 2000 real `click_label` actions through the daemon, sampling the
daemon and helper RSS.

```
before: daemon 8928 KB, helper 29712 KB
after:  daemon 9184 KB, helper 28016 KB
```

Flat, and the worker processes are lean: 13.3 and 13.9 MB for two bound apps,
against 28 MB each before AppKit was made lazy (a worker only loads AppKit if it
is asked to record video, which is the only thing that needs it).

Getting there took three real fixes:

- The helper is a `readLine()` loop with no run loop, so nothing drained the
  autorelease pools Foundation creates per request. The helper grew several KB
  per action — tens of MB per session. Wrapping the whole iteration in an
  explicit pool fixed it; a pool around only the handler did not, because the
  JSON encode and print happen outside it.
- Window enumeration bridged a CFArray of CFDictionary per call and leaked the
  +1 reference. It is now read through the CF APIs directly, with the string
  keys bridged once rather than per lookup.
- Every worker initialised `NSApplication` eagerly, which pulls in AppKit and
  costs ~20 MB whether or not the worker ever draws anything.

The first measurement of this "leak" was 27 KB per `windows` call; after fixing
the pool it is 0. Measured, not assumed — and the first attempt at a fix
(`takeRetainedValue` on AX attribute reads) over-released and crashed, which is
why the sweep exists.

---

## 10. Files open and close in the background

**Method.** Bind TextEdit, open two documents, list them, close both, and
check the person's frontmost app throughout.

```
open_file /tmp/a.txt   -> opened, focus_changed: false
open_file /tmp/b.txt   -> opened, focus_changed: false
documents              -> ["qd_e2e2.txt", "qd_e2e1.txt"]
close_file a           -> closed qd_e2e1.txt
documents              -> ["qd_e2e2.txt"]
close_file b           -> closed qd_e2e2.txt
documents              -> []
frontmost              -> DeepSeek Harness, unchanged throughout
TextEdit               -> still running
```

**Result.** A document opens with no file panel and no focus change, and a
document closes without quitting the app. `close_file` verifies the document
is gone before reporting success, and reports a save prompt rather than
guessing.

The first implementation of `close_file` reported success without closing
anything — the acceptance sweep caught it because it checks the document list
afterwards. That is why the sweep exists.

## 11. What is *not* verified

Honesty about the edges:

- **File dialogs.** An `NSOpenPanel` can be read and its filename field set,
  but committing it (pressing Open) does not work through Accessibility on
  macOS 15 — the panel runs in a separate XPC service and does not respond to
  `AXPress` on its buttons. The workaround is to avoid the dialog: open a
  document with `open -a App /path`, which shows no panel at all. This is
  tracked in the friction log.
- **Menu bar actions.** A menu item is reachable through the accessibility
  tree, but the app must be frontmost for the menu to open.
- **Drag and drop across windows.** Works within the bound window; dragging
  into another application is not implemented.
- **Multiple screens.** The driver handles one window at a time. A window
  spanning screens is still one window.
- **Linux and Windows.** Not implemented. Everything here is macOS-specific:
  Accessibility, `CGEventPostToPid`, and the window server.

---

## How to re-run these checks

```bash
# the driver's own test suite
cargo test

# the acceptance sweep (binds, drives, checks the counters)
./scripts/acceptance.sh
```

The sweep prints one PASS/FAIL line per behaviour and exits non-zero if any
fails, so it can run in CI on a machine with the three permissions granted.
It currently runs 27 checks, and passes three times in a row from any starting
state.
