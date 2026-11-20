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

## A file dialog is open and will not commit

`NSOpenPanel` and `NSSavePanel` do not respond to accessibility actions on
macOS 15 — the panel's buttons report success and nothing happens. **Do not
loop on one.** If you opened a panel by clicking File → Open, you should not
have: use `open_file` instead, which shows no panel at all.

If a panel is open and you need it gone:

1. **Cancel it inside the app.** The panel belongs to the app; sending the
   app cmd+period (`.` with command) dismisses it, as does its Cancel button
   when the app is frontmost.
2. **Check it is gone** with `get_accessibility_tree` or `documents`. A stale
   panel window leaves the app reporting a phantom "Open" window, and the next
   bind can land on it.
3. **Never leave a panel open** for the next agent. It will look like a
   document window and it cannot be driven.

The right answer for "open this file" is `open_file`. The right answer for
"this app needs a save dialog" is to say so to the person.

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
  tool: "the tool name"
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
