# macos-computer-use-agent-tools

Background computer use for AI agents on macOS, plus the tools, skills, and
plugin that put it in front of an agent.

**Quiet Driver** binds an agent to one running macOS app and drives it — the
app may be frontmost, behind other windows, minimised, on another Space, or
hidden. The person's pointer never moves, their focus is never taken, and
their window order never changes.

> Beta. v0.2.0. Expect the edges to be rough; that is what the friction log
> is for.

---

## What is in here

| Path | What it is |
|---|---|
| `Sources/Worker/AX.swift` | the whole macOS layer: Accessibility, per-process events, windows, capture, recording |
| `Sources/Daemon/` | the daemon: HTTP + MCP surfaces, binding, worker pool, metrics, dashboard |
| `Sources/main.swift` | one binary, five jobs: daemon, worker, MCP bridge, dashboard, viewer |
| `skills/` | the two skills an agent loads: how to drive, and what to do when it goes wrong |
| `plugin/` | the DeepSeek Harness plugin: an MCP bundle that exposes the driver to the agent |
| `docs/` | how it works, what was measured, and what is still missing |

## Quick start

```bash
./build.sh                     # self-tests + binary + app bundle
open -a "Quiet Driver"         # starts the service; the window is optional
cat ~/.quiet-driver/port       # port, url, daemon pid
```

Then, from an agent:

```json
{"tool": "bind_app", "app": "Calculator", "agent": "me"}
{"tool": "click_label", "label": "7"}
{"tool": "screenshot"}
```

The person keeps working. The calculator shows `7`.

## Installing it into an agent harness

The driver speaks **MCP** (JSON-RPC 2.0), so anything that speaks MCP can use
it. Two ways in:

**As a subprocess (stdio).** The driver bridges MCP over stdin/stdout and
forwards to the running daemon, so the agent shares the daemon's session:

```yaml
- id: quiet-driver-mcp
  name: '@deepseek-ai/dsh-mcp-client'
  config:
    serverName: quietdriver
    transport: stdio
    command: /Applications/Quiet\ Driver.app/Contents/MacOS/agent-driver
    args: ['--mcp-stdio']
```

**Over HTTP.** The same daemon serves MCP at `POST /mcp`:

```yaml
- id: quiet-driver-mcp
  name: '@deepseek-ai/dsh-mcp-client'
  config:
    serverName: quietdriver
    transport: streamable-http
    url: http://127.0.0.1:<port>/mcp
```

The `plugin/` directory in this repo is a ready-made bundle for DeepSeek
Harness. Install it with **Plugins → Add plugin**, or:

```bash
dsh plugin install ./plugin/quiet-driver-mcp
```

## What the agent gets

28 tools. The ones that matter:

- **Bind and drive** — `bind_app`, `click`, `type_text`, `set_value`,
  `click_label`, `press_key`, `hotkey`, `scroll`, `mouse_drag`.
- **See the app** — `screenshot` and `record` return the bound window's real
  pixels in any window state, occluded or hidden.
- **Read the app** — `get_accessibility_tree` gives the full AX tree without
  depending on what is on screen.
- **Own the lifecycle** — `launch_app` (background, no focus change),
  `quit_app`, `rebind` after a rebuild-and-relaunch.
- **Handle files without dialogs** — `open_file` opens a document with no
  panel and no focus change, `documents` lists what is open, `close_file`
  closes one and verifies it. This matters because a file panel steals focus
  and, on macOS 15, does not respond to accessibility actions.
- **Stay out of the way** — `background` mode by default, `focused` only on
  request, and the reply tells the agent whether it disturbed anything.
- **Report problems** — `log_friction` and `friction_log`.

Everything runs as **one main process** that holds the lock and the session
state, plus **one lean worker per bound app** (~13 MB) so two apps never queue
behind each other. `perf/harness.py` measures latency, memory, CPU and the two
invariants — focus never moves and the pointer never moves — and fails the run
when one breaks.

See `skills/quiet-driver/SKILL.md` for the full guide.

## The idea

A person and an agent want the same machine at the same time. The usual
computer-use tools take the whole screen: they move the pointer, they raise
windows, they steal focus. That is fine when nobody else is using the
computer, and intolerable when someone is.

This driver never moves the OS pointer and never activates the target unless
asked. Control goes two ways:

- **Accessibility** for the app's own controls — press a button, set a text
  field, read the tree. Independent of what is on screen.
- **`CGEventPostToPid`** for keystrokes and clicks, delivered straight to the
  target process. The OS pointer does not move and the target does not become
  frontmost.

That is why an app on another Space, minimised, or in a hidden application is
just as drivable as one in front. Measured, not assumed — see
`docs/VERIFICATION.md`.

## Permissions

The person grants three, once, in **System Settings → Privacy & Security**:

| Permission | Why |
|---|---|
| Accessibility | read the app's controls and press them |
| Post events | deliver keystrokes and clicks to the app's process |
| Screen recording | capture what the app looks like |

`status` reports all three, and the dashboard shows them. Nothing works
without them, and no agent can grant them — that is the right boundary.

## Layout

```
Sources/main.swift          entry point: daemon, worker, bridge, dashboard, viewer
Sources/Worker/AX.swift     every macOS call
Sources/Daemon/Server.swift the loopback HTTP surface
Sources/Daemon/Session.swift the binding, ownership, identity-based rebind
Sources/Daemon/Helper.swift the daemon's side of the worker protocol
Sources/Daemon/Pool.swift   one worker process per bound app
Sources/Daemon/Tools.swift  what each tool does, and what it may claim
Sources/Daemon/MCP.swift    the MCP surface and the stdio bridge
Sources/Daemon/Workspace.swift per-agent artefacts, the friction log, metrics
Sources/Daemon/Dashboard.swift the dashboard (a viewer, not a requirement)
skills/            the agent-facing skills
plugin/            the DeepSeek Harness MCP bundle
docs/              mechanics, verification, friction
```

## Building

Needs macOS and its Swift toolchain (`swiftc`, in Xcode or the Command Line
Tools). No other build system, no package manager, no dependencies.

```bash
./build.sh
```

Four suites, all runnable locally:

| Suite | What it covers |
|---|---|
| `.build/selftest` | 55 checks: window rules, paths, focus honesty, conversions, metrics, surface agreement |
| `scripts/acceptance.sh` | 27 checks against a real app: bind, drive, focus guard, lifecycle, MCP |
| `scripts/tool_audit.py` | all 32 tools, asserting an observable effect where one is possible |
| `scripts/concurrency.py` | two agents on two apps: bindings, ownership races, worker isolation |
| `perf/harness.py` | latency, memory, CPU, and the two invariants that must never break |

That compiles the self-tests, builds the single binary, and refreshes
`Quiet Driver.app`. The whole app is under a megabyte.

## Licence

MIT.
