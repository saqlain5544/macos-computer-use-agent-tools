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

Measured over loopback on the same machine.

| Operation | Time |
|---|---|
| `/health` | 5 ms |
| `/status` | <1 ms |
| helper cold start (compiled) | 47 ms |
| helper cold start (interpreted) | 530 ms |
| AX tree of Calculator (132 nodes) | ~90 ms |
| screenshot of a 1348×816 window | ~180 ms |
| `click_label` on Calculator | ~40 ms |
| focus guard (activate + restore) | ~600 ms |

The driver ships a compiled helper next to the binary and falls back to
interpreting the script when it is absent, so a source checkout works without
a build step.

---

## 9. Files open and close in the background

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

## 10. What is *not* verified

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
