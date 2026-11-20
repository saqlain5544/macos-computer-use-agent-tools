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

## 11. A locked screen is detected, not guessed

**Method.** Lock the machine, then read `/status`.

```
screen_locked: true
click_label on a background app -> ok
close_file on a specific document -> refused
```

Accessibility presses on a background app keep working while the screen is
locked; anything that needs a key window does not, and the calls that used to
take 15 ms can take a second. The harness refuses to measure in that state, and
the sweep marks the affected checks `SKIP` rather than `FAIL`, because a run
there would describe the lock and not the driver.

**Note on the numbers in this document.** They were recorded with the screen
unlocked. A run against a locked screen is not comparable and the harness
rejects it.

## 15. The Swift stack, checked against the same suites

The Rust half was removed after the Swift implementation passed the existing
suites unchanged: **48/48 tool-audit checks**, **27/27 acceptance checks**, and
a clean harness run with zero focus moves and zero pointer moves. The point of
running the same suites rather than writing new ones is that the external
contract is what had to survive.

| | Rust + Swift | Swift only |
|---|---|---|
| binary | 12 MB | 792 KB |
| build | cargo + swiftc, ~30 s | swiftc, ~2 s |
| toolchains | two | one |
| click_label p50 | 2.5 ms | 2.9 ms |
| screenshot p50 | 70 ms | 75 ms |
| daemon RSS | 10.3 MB | 14.6 MB |
| workers | 13-14 MB | 13-14 MB |

The daemon is 4 MB heavier because the Swift runtime is in-process; the workers,
which hold the accessibility connections, cost the same.

## 16. What the port had to fix

Removing Rust was not a mechanical translation. The eleven things it exposed:

| Symptom | Cause |
|---|---|
| daemon deadlocked on the second worker call | `stop()` re-locked a non-recursive `NSLock` already held by `call()` |
| every window parsed as 0x0 | the worker sends rectangles flat, not nested under `bounds` |
| `press_key` silently did nothing | the worker protocol names the key field `key`; the caller sent `text` |
| binding an app with no window failed | that is the normal state after launch, and `open_file` is how it gets one |
| dashboard unreachable after its port file was deleted | the daemon never republished; it now heals on the probe tick |
| `show_dashboard` piled up windows | it spawned a viewer per call; there is one, and asking again raises it |
| harness measured text tools on the wrong app | it opened a document before binding, so the file went to the previous app |
| harness reported Chrome redrawing as a focus move | the invariant now counts app activation and the target climbing to the top |
| focused mode sometimes left focus moved | activation is a request; restore now retries and verifies the frontmost app |
| a capture could retry the same dead window forever | rebind handed back the ghost; the retry now excludes the id that failed |
| `click_label("+")` on Calculator | the key is labelled "Add" — a small symbol alias table fixes it, and real labels always win |

## 17. Waiting, instead of polling

Agents used to poll: one round trip per check, and each one picked its own
backoff. `wait_for` moves the loop into the driver.

| Kind | Waits for | Measured |
|---|---|---|
| `label` | a control with that label exists | 28 ms when it already does |
| `change` | the accessibility tree changed at all | caught a press in 434 ms |
| `text` | a text field equals or contains a value | |
| `document` | a document opens | |
| `window` | a window with that title appears | |

On timeout it reports what it last saw — "waited 600 ms for label and gave up:
no control labelled X" — which is usually the answer the agent needed.

The first version of this crashed the daemon: a 64-bit tree hash was sent as a
JSON number and converted with `UInt64(Int)`, which traps in Swift for any value
outside Int's range. The signature is hex text now, every number that crosses
the worker boundary goes through a non-trapping converter, and the self-tests
assert that a huge number is refused rather than fatal.

## 18. Two agents, two apps

`scripts/concurrency.py` checks the claim that each bound app gets its own
worker rather than trusting the description of the design.

**Isolation.** A recording occupies TextEdit's worker for two seconds; calls to
Calculator's worker are timed throughout.

| | worst call on the other app |
|---|---|
| one session-wide binding (before) | **2081 ms** — the two agents were talking to the same worker |
| per-agent bindings (after) | **20-41 ms** |

The first number is why the binding model changed. The allocation was per app
and the isolation was per app, but the *binding* was per session, so both agents
were silently driving the same app's worker.

**No cross-delivery.** Two agents type digits into their own apps at the same
time; both sets of keystrokes land in the right app.

**Ownership under contention.** Four agents race to bind a free app; exactly one
wins and the other three are told who holds it.

**No focus.** Both invariants hold across all of it: zero focus moves, zero
pointer moves.

Run it with `./scripts/concurrency.py`; it takes about ten seconds.

## 19. The operation log

Every operation is one JSON line. What the log has already found:

- **100% of a cold action's time is waiting on the app.** The first click on a
  freshly bound app spent 42 ms enumerating windows and 107 ms walking its
  control tree; the driver itself accounted for under 1 ms.
- **A warm click made two worker calls and took 17 ms.** With the breakdown
  recorded per call, that was two facts: the second call was a cache miss, and
  the pipe round trip cost ~12 ms because Foundation's `availableData` sets up
  its own wait per read. Reading the descriptor directly halved it.

That is the loop this log exists for: measure, attribute, fix, remeasure.

## 20. What the log's first targets were

The log ranked the tools by total time and the worker commands inside them.
Four fixes came straight out of that table:

| Call | Before | After | What it was |
|---|---|---|---|
| `close_file` | 654 ms | **162 ms** | two fixed sleeps (250 ms after the Window menu, 400 ms after the close button) now poll for the effect instead |
| focused `click_label` | 1045 ms | **254 ms** | activation polled `lsappinfo` (two subprocesses) every 40 ms; it polls NSWorkspace and confirms once |
| any tool that reads `frontmost` | ~120 ms | **~10 ms** | `lsappinfo` went through `Process.waitUntilExit()`, which polls without a run loop; it uses the `posix_spawn` helper |
| a capture that failed | "screencapture exited 1" | "could not be captured; its window may be closing" | the retry alternates same-window and different-window attempts, then reports what actually failed |

None of these would have been visible from the outside: every one of them
succeeded, just slowly.

## 21. Watching is the person's decision

| Rule | How it is enforced |
|---|---|
| background is the default and the only mode an agent may choose | `set_mode` is not on the MCP surface |
| a per-call focused mode is refused | the call is rejected with the reason |
| focused requires the person's consent | `set_mode focused` refuses unless Watch is on |
| a session left in focused mode cannot run focused | every call forces background when watching is off |
| watching is a dashboard switch | the viewer's **Watch** toggle calls `set_watch`, which is not on the MCP surface |

The tool audit and the acceptance sweep both check the refusal path, not just
the happy one.

## 22. Apps that are not on the showing Space

The person's desktop here runs the harness fullscreen, so every app an agent binds
lives on a different Space. That turns out to be the single most important
constraint for background computer use, so it was measured rather than assumed.

| Operation | Off the showing Space | Evidence |
|---|---|---|
| accessibility read (`tree`, `get_text`) | **works** | 158 nodes from CADCraft, text from TextEdit |
| accessibility action (`click_label`, AXPress) | **works** | Calculator pressed "7" and showed 7; CADCraft tool buttons responded |
| keyboard (`type_text`, `press_key`) posted to the pid | **works** | TextEdit received "AAAA\nBBBB"; Calculator took "7" |
| raw mouse (`click`, `mouse_drag`, `scroll`) | **does not reach the app** | identical screenshot hashes before and after a drag; a click in a text view does not move the caret |
| screenshot | **works, via ScreenCaptureKit** | 1512x949 real pixels from CADCraft; `screencapture -l` fails with "could not create image from window" |

Why: the window server hit-tests mouse events against windows on the Space that is
showing, so a synthetic click aimed at a window elsewhere is delivered nowhere.
Keyboard events posted to a process go to its key window, which is why they still
land. Accessibility bypasses the window server entirely.

What this means for an agent: on a window off the current Space, drive it by
accessibility and keyboard; screenshots still show what it looks like. To drive it
by mouse it has to be on the showing Space, which is the person's decision — the
driver says exactly that instead of reporting "click delivered" while nothing
happens. `screenshot` falls back to a ScreenCaptureKit stream, which captures
windows on other Spaces and Metal-backed canvases that `screencapture` cannot see.

## 23. The work display: full mouse control without touching the person's screen

The measured limit in section 22 is that mouse events do not reach a window off
the showing Space. The fix is to give the driver a display of its own.

A virtual display (the private CGVirtualDisplay API that BetterDisplay, DeskPad
and the headless-agent tools use) is a real display to the window server with no
physical output. A window moved onto it is ordinary "on screen", so the window
server routes mouse events to it, and nothing appears on the person's monitor.

Measured end to end, on the machine where the person is working in another Space:

| Step | Result |
|---|---|
| Calculator bound while off the showing Space | `on_screen: false`, clicks refused |
| `stage` | window moves 603,70 → 1532,20, `on_screen: true` |
| click on the staged window | lands (display shows the digit), `pointer_moved: false`, `focus_changed: false` |
| raw CAD canvas clicks on a staged window | the drawing changes |
| `unstage` | window back at 603,70 |
| person's frontmost app throughout | unchanged (Chrome, then CADCraft, never moved by the driver) |

The daemon creates the display lazily on the first stage, and `QD_WORK_DISPLAY=0`
turns the feature off. Unbinding a staged app puts it back.

Two things this cost, both found by testing rather than reading: the descriptor's
vendor/product/serial values decide whether the display activates at all (an
invented triple was accepted but never came up), and reading a window's frame by
reusing the move command quietly moved every window it measured to (-1,-1).

## 24. What is *not* verified

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

## 13. Latency, after the second pass

Measured through the daemon against a real Calculator window (p50):

| Tool | Before | After | Why it was slow |
|---|---|---|---|
| `click_label` | 81 ms | **2.5 ms** | re-walked the whole tree per press; now one cached IPC call |
| `get_text` | 1350 ms | **0.5 ms** | walked the tree to find the text area; now one focused-element read |
| `set_value` | 1339 ms | **0.9 ms** | same |
| `type_text` | 1391 ms | **8.3 ms** | same |
| `accessibility_tree` | 950 ms | **13 ms** | five IPC calls per node; now one batched read |
| `screenshot` | 137 ms | **70 ms** | `Process.waitUntilExit()` polls without a run loop; now `posix_spawn` |
| `click (coordinate)` | 137 ms | **45 ms** | tree walk for the hit test |
| `press_key` | 16 ms | **15.6 ms** | already bound by the app's own handling |

300 actions run at ~124/s, the daemon stays at 10.3 MB with zero growth, and
workers are 13-14 MB each.

## 14. Every tool, checked for effect

A tool that returns `ok` but does nothing is the failure mode this project was
bitten by in its first build, so `scripts/tool_audit.py` drives all 31 tools and
asserts an observable effect where one exists — the calculator display changes,
the text field reads back what was written, the screenshot file is a real image.

It found seven bugs, all fixed:

| Bug | What it looked like |
|---|---|
| coordinate click did nothing | hit test returned a container, so the fallback synthetic event was ignored |
| `set_caret` off by semantics | `location: 1` ("end") put the caret after one character |
| `status` needed a binding | the first call an agent makes over MCP failed |
| stale window after closing | capture tools reported the capture tool's error instead of "no window" |
| captures on a ghost window | the window server lists a closed window for a moment |
| untitled strips won a bind | an agent bound to a 1512x33 menu-bar strip |
| focus flags lied | `restored: true` when focus was never moved |

It now passes 48/48 repeatedly from any starting state.

## How to re-run these checks

```bash
./.build/selftest           # unit tests
./scripts/acceptance.sh     # real app: bind, drive, focus guard, lifecycle
./scripts/tool_audit.py     # every tool, asserting an effect
./perf/harness.py           # latency, memory, invariants
```

The sweep prints one PASS/FAIL line per behaviour and exits non-zero if any
fails, so it can run in CI on a machine with the three permissions granted.
It currently runs 27 checks, and passes three times in a row from any starting
state.
