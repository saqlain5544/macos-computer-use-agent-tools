---
name: quiet-driver-diagnostics
description: "Use when a Quiet Driver action fails, lands in the wrong place, steals focus, or a file dialog will not close; before reporting a driver bug."
metadata:
  origin: "skill_stage_create"
  stagedAt: "2026-11-20T01:35:14.032Z"
  reason: "When a driver action fails, the agent needs to tell \"the driver refused\" from \"the app did something else\", and needs the error-to-cause table plus the coordinate and file-dialog pitfalls."
---

# Quiet Driver — when something goes wrong

Use this when a Quiet Driver action failed, produced the wrong effect, or
disturbed the person you were supposed to leave alone.

## First: did it actually fail?

Every reply has `ok` and `error`. `ok: false` means nothing happened and
`error` says why. `ok: true` with an unexpected outcome is a different
problem: the driver did what it was told, and the app did something else.

## The common failures, and what they mean

| Error text | What it means | What to do |
|---|---|---|
| `no app is bound yet` | You skipped `bind_app` | Bind first |
| `no app matched "X"` | The app is not running, or the name is wrong | `list_windows` to see what is running; `launch_app` first |
| `... was not running; relaunch it` | The app quit under you | `launch_app`, then act again — the binding re-resolves |
| `already bound by "agent-x"` | Another agent owns it | Wait, take over with `takeover: true`, or use a second instance |
| `point is outside the bound window` | Your coordinates were screen coordinates | Subtract the window's origin from `bounds` |
| `no control labelled "X"` | No such control | The message lists the labels that do exist |
| `the dialog is still open after every activation route` | A file panel would not commit | See below |
| `driver paused` | Someone paused the driver | Ask them to resume it |

## Coordinates: the most common mistake

`x`, `y` are **window-relative**. If you computed them from a screenshot, the
screenshot is window-relative too, so they match — but if you used screen
coordinates from somewhere else, subtract the window origin:

```
bounds.x, bounds.y  ->  subtract from your screen coordinates
```

If a click lands in the wrong place, read `bounds` from `status` and compare
with what you sent.

## A click that did nothing

1. **Is the point inside the window?** `click` refuses out-of-window points,
   but a point inside the window can still land on nothing.
2. **Look at the tree.** `get_accessibility_tree` shows what is actually there.
   A window that is not on screen still has a tree.
3. **Try the label.** `click_label` finds controls by name, which is far more
   reliable than coordinates when you can see the name.
4. **Is the app busy?** A modal sheet, a busy spinner, or a background
   operation can swallow a press. Wait and retry.

## Focus was stolen

Check the reply's `focus_changed`. If it is true, the action ran in `focused`
mode — either the session was in focused mode, or the action asked for it.

To restore the person's app: run one `focused` action against the app they
were using, or `set_mode` back to `background` and let the next action run in
the background.

`status` reports `focus_events`: the number of times the driver itself moved
focus. If it is not zero and you did not ask for focused mode, that is a bug —
report it with `log_friction`.

## A file dialog will not commit

Some `NSOpenPanel` / `NSSavePanel` dialogs do not respond to accessibility
actions at all. Before fighting it:

1. **Avoid the dialog.** `open -a App /path/to/file` opens a document with no
   panel at all. `quit_app` + `launch_app` with a document argument does the
   same for a rebuild cycle.
2. **Read the panel.** `get_accessibility_tree` shows the panel's controls,
   including the file rows.
3. **Accept the cost.** If the panel must be committed, wrap it in a
   `focused` action and tell the person you are about to borrow their screen.

Do not silently loop on a dialog that will not close.

## The app is not where you think it is

`list_windows` shows every top-level window, including minimised ones and
windows on other Spaces. The driver works regardless — it is not looking at
the screen. If the tree looks empty, the app may have no window yet: wait, or
check `status` for a stale pid.

## Screenshots are blank or wrong

- The image is of the **bound window**, not the screen. If you wanted the whole
  screen, that is a different thing and this driver does not do it on purpose.
- A window that is being resized may be captured mid-resize.
- `record` needs a couple of seconds of setup; ask for at least 2.

## Reporting it

```
log_friction {
  problem: "one sentence: what did not work",
  detail: "what you sent, what came back, and what you tried instead",
  source_tool: "the tool name"
}
```

Include the exact error text. "click_label failed" is not actionable;
`no control labelled "Save" (available: Save As…, Cancel, Delete)` is.

Then read the backlog with `friction_log` to see whether it is a known problem
with a known workaround.

## If the whole driver is unresponsive

```
status     # is the daemon alive, what is bound, what are the permissions
```

If `permissions` shows anything false, the person has to grant it in
**System Settings → Privacy & Security** (Accessibility, Post events, Screen
recording). Nothing works without those, and no agent can grant them.

If the daemon is not running, `launch_app` through the MCP bridge starts it.
