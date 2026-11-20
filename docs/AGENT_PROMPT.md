# Starter prompt for your agent

Copy everything inside the block below and paste it to your agent. It tells the
agent to use **Quiet Driver** instead of Cua Driver, and nothing in it requires
you to code.

---

## Paste this to your agent

> You are now using **Quiet Driver** for all computer-use work. Stop using Cua
> Driver.
>
> Quiet Driver drives a real macOS app through the Accessibility API and
> per-process events. It **binds** to one app and keeps driving it whether that
> app is frontmost, in the background, behind other windows, minimised, or on
> another Space / Mission Control desktop. Your pointer is never moved and you
> are never pulled out of what you are doing.
>
> ### 1. Start it
>
> Launch the installed app named **Quiet Driver** (on macOS: `open -a "Quiet
> Driver"`). It runs as a background service; the window is only a dashboard, so
> closing it does not stop the driver. Running `open -a "Quiet Driver"` again
> just brings the dashboard back.
>
> Then read `~/.quiet-driver/port`: its first line is the port, the second is the
> full control URL, the third is the daemon pid. The same address is on the
> dashboard's "LOCAL LINK" line. It binds loopback only.
>
> If you want a fixed port, set `CUA_DRIVER_ENVELOPE_HTTP_PORT` (a nonzero 16-bit
> number) before starting it.
>
> ### 2. Two ways in

**MCP (preferred).** The driver speaks MCP over stdio or Streamable HTTP. In
an agent harness that supports MCP servers, register it once:

```yaml
- id: quiet-driver-mcp
  name: '@deepseek-ai/dsh-mcp-client'
  config:
    serverName: quietdriver
    transport: stdio
    command: /Applications/Quiet Driver.app/Contents/MacOS/agent-driver
    args: ['--mcp-stdio']
```

The tools arrive as `mcp__quietdriver__bind_app` and so on. The same names
are used over HTTP.

**HTTP.** The raw endpoints:
>
> - `GET /health` — liveness.
> - `GET /status` — bound target, owner, mode, permissions, focus counters, recent actions.
> - `GET /windows` — every top-level window, including other Spaces.
> - `GET /tree` — accessibility tree of the bound app.
> - `POST /action` — run one tool.
>
> Requests carrying an `Origin` header are refused, so a web page can never drive
> the desktop.
>
> ### 3. Bind first
>
> Every action needs a bound app:
>
> ```json
> {"tool": "bind_app", "app": "Calculator", "agent": "my-agent"}
> ```
>
> `app` is a name, bundle id, pid, or window title. The reply gives you `pid`,
> `window_id`, and `bounds`. **All coordinates are relative to that window's
> top-left corner**, not the screen.
>
> The binding stores the app's *identity* (bundle id), not just its pid, so you
> can quit the app, rebuild it, relaunch it, and keep driving it: the next action
> re-binds automatically, or call `{"tool":"rebind"}` yourself.
>
> The binding also has an `owner`. A second agent that binds the same app is
> refused with a message naming the current owner, unless it passes
> `"takeover": true`. Do not take over an app another agent is mid-way through
> driving.
>
> ### 4. Tools
>
> | Tool | Body | What it does |
> |---|---|---|
> | `list_windows` | | every window, all Spaces |
> | `bind_app` / `bind` | `app`, `agent?`, `window_id?`, `takeover?` | bind |
> | `rebind` | | re-resolve after a relaunch |
> | `unbind` | | drop the binding |
> | `launch_app` | `app` | launch in the background, no focus change, no binding |
> | `quit_app` | `app` | quit by identity |
> | `get_accessibility_tree` / `get_window_state` | | AX tree of the bound app |
> | `get_desktop_state` | | frontmost app + window list |
> | `click` / `double_click` / `right_click` | `x`, `y` | press the element under the point |
> | `move_cursor` | `x`, `y` | hover only |
> | `mouse_drag` | `x`, `y`, `to:{x,y}` | drag |
> | `scroll` | `x`, `y`, `lines` | scroll wheel at a point |
> | `type_text` | `text` | type into the bound app |
> | `press_key` | `text` (`"Return"`) | one key |
> | `hotkey` | `text` (`"cmd+shift+t"`) | chord |
> | `set_value` | `text` | set a text field directly (reliable, no keystrokes) |
> | `set_caret` | `location`, `length` | move the insertion point |
> | `click_label` | `label` | press a control by its label (`"Equals"`, `"Save"`) |
> | `get_text` | | read the bound app's text field |
> | `screenshot` | `path?`, `agent?` | PNG of the bound window, any window state |
| `record` | `seconds?`, `path?`, `agent?` | .mov of the bound window |
| `log_friction` | `problem`, `detail?`, `source_tool?`, `agent?` | report a rough edge |
| `friction_log` | `limit?` | read the backlog |
| `workspace` | `agent?` | your artefact directory |
| `set_mode` | `mode` | `background` or `focused` |
> | `pause` / `resume` | | stop/resume delivering actions |
>
> ### 5. Two modes — pick per the person's request
>
> - **`background` (default)** — nothing on the person's screen changes: no
>   pointer move, no focus change, no window reordering. This is the mode to use
>   unless asked otherwise.
> - **`focused`** — the target is brought to the front for the action and the
>   person's app is put back afterwards. Use it only when the person asked you to
>   drive the app on their screen. The reply reports `focus_changed` and
>   `focus_restored` honestly, so you can confirm the person got their app back.
>
> Set it per action with `"mode": "focused"`, or switch for the session with
> `set_mode`.
>
> ### 6. Reading replies
>
> Every reply is JSON with `ok`, `error`, `detail`, `target`, `mode`,
> `real_pointer_moved`, `focus_changed`, `focus_restored`, and `data`. `detail`
> is a sentence describing what the OS actually did — read it. `data` carries the
> payload: the AX tree, the pressed element's frame, the field value, the action
> point.
>
> `ok: false` is a real failure with a real reason: `no app is bound yet`, a
> point outside the window, a control that does not exist (the message lists the
> labels that do), or the app not running. There is no queue and no replay — what
> the reply reports already happened.
>
> ### 7. Safety rules — never break these
>
> - Work in `background` unless the person asked for `focused`.
> - Never `takeover` an app another agent owns. If you need the same app, wait,
  or launch a second instance and bind to that.
- Each agent has a workspace at `/tmp/quiet-driver/agent-<id>/` for
  screenshots and recordings; pass `path` to save elsewhere.
- When the driver gets in your way, call `log_friction` with what went wrong.
> - Never move the pointer, change focus, or reorder the person's windows by any
>   other means.
> - The clipboard belongs to the person: `clipboard_read` / `clipboard_write`
>   are not implemented and will refuse.
> - Do not launch-and-bind something you were not asked to touch.
>
> ### 8. Example
>
> ```bash
> PORT=$(head -1 ~/.quiet-driver/port)
> curl -s -X POST http://127.0.0.1:$PORT/action -H 'Content-Type: application/json' \
>      -d '{"tool":"bind_app","app":"Calculator","agent":"me"}'
> curl -s -X POST http://127.0.0.1:$PORT/action -H 'Content-Type: application/json' \
>      -d '{"tool":"click_label","label":"7"}'
> curl -s http://127.0.0.1:$PORT/status
> ```
>
> ---

## Why it is worded this way

- The address is loopback-only and published to a file, so an agent can find it
  without looking at a screen.
- Binding is explicit and identity-based: agents that keep working across a
  rebuild-and-relaunch cycle need a binding that survives the pid changing.
- Coordinates are window-relative because that is the only frame that stays
  meaningful when the person moves, resizes, or re-Spaces the window.
- `background` is the default because the promise is that the person keeps their
  computer; `focused` is opt-in because it necessarily borrows their screen.
- The reply fields (`real_pointer_moved`, `focus_changed`, `focus_restored`) are
  measured, not asserted, so an agent can tell whether it disturbed anything.
