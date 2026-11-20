# The friction log

Every rough edge the driver hits should end up here, not in a chat transcript
that nobody re-reads.

## How entries get in

The agent calls `log_friction` when the driver got in its way:

```json
{
  "tool": "log_friction",
  "arguments": {
    "problem": "click_label could not find the Save button in a sheet",
    "detail": "the sheet's buttons have no AXTitle, only AXDescription",
    "source_tool": "click_label"
  }
}
```

Entries land in `/tmp/quiet-driver/friction.jsonl`, one JSON object per line:

```json
{"at":1789000000,"agent":"builder-1","source_tool":"click_label","problem":"…","detail":"…","target":"…","mode":"background"}
```

`friction_log` reads the backlog back. This file is the raw material for
fixing the driver: each entry is a specific, reproducible problem with the
context needed to reproduce it.

## What makes a good entry

| Weak | Strong |
|---|---|
| "click_label failed" | "no control labelled \"Save\" (available: Save As…, Cancel, Delete) — the button is inside a sheet with no AXTitle" |
| "screenshot is broken" | "screenshot of a minimised window returned the pre-minimise frame, not the current one" |
| "typing does not work" | "type_text into a SwiftUI TextField inserts at the caret instead of appending; set_value works" |

Include the exact error text, what you sent, and what you tried instead.

## Known friction, as of v0.1.0

These are the ones already understood. They are listed here so an agent can
route around them, and so nobody re-investigates them.

### `NSOpenPanel` / `NSSavePanel` will not commit

> **Resolved for the common case.** Use `open_file` to open a document: it
> runs `open -g`, shows no panel, and does not move the person's focus.
> `close_file` closes a document through its window's close button and
> verifies it. This entry remains for the case where an app itself insists on
> a save/open sheet.

**What happens.** The panel opens (and takes focus — a file panel is a real
window). Its filename field can be read and written. Pressing **Open**,
pressing **Cancel**, `AXConfirm` on the field, a posted Return key, and a real
HID click all leave the panel open.

**Why.** The panel's window is owned by a separate XPC process
(`com.apple.appkit.xpc.openAndSavePanelService`), and on macOS 15 it does not
act on accessibility actions sent to the host application or to the service.

**Route around it.**
- `open -a App /path/to/file` opens a document with no panel at all. This is
  the best answer for "open this file".
- `quit_app` + `launch_app` is the best answer for a rebuild cycle.
- If the panel must be committed, do it in a `focused` action and say so.

**Status.** Unresolved. Needs either a working activation route for the panel
service, or a documented decision that panels are the app's job, not the
driver's.

### Menu bar items need a frontmost app

**What happens.** A menu item is in the accessibility tree, but pressing it
does nothing unless the app is frontmost, because the menu has to open first.

**Route around it.** Use `focused` mode for the one action, or avoid the menu
and drive the control the menu would have activated.

**Status.** Probably unavoidable — it is how menus work.

### The clipboard is not exposed

**What happens.** `clipboard_read` and `clipboard_write` return an explicit
error.

**Why.** The clipboard belongs to the person, not the agent. Copying the
person's clipboard into a model's context is a privacy leak that no tool
call asked for.

**Status.** Deliberate. Not planned.

### Drag and drop stops at the window boundary

**What happens.** `mouse_drag` works inside the bound window.

**Why.** Dragging into another application needs the other application to
accept the drop, which means the other application has to know about the drag.

**Status.** Not implemented.

## Adding to this list

When a `log_friction` entry turns out to be a real, reproducible problem
rather than a one-off, add it here with the same shape: what happens, why, the
route around it, and the status. That way the next agent hits the knowledge
instead of the wall.
