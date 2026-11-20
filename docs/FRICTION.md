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

**Why, precisely.** Programmatically writing the filename field through
Accessibility does **not** run AppKit's validation, so the panel's **Open
button never enables**. `AXPress` on a disabled button reports success and does
nothing — which is exactly the confusing behaviour that took a day to
understand. `Cancel` is enabled, which is why cancelling the panel always
worked while confirming it never did.

The commit route that does exist is `AXOpen` on the file row's `AXCell` — the
double-click equivalent. It reports `attributeUnsupported` even when it
succeeds, so it must be verified by re-polling, and it only takes effect while
the panel's window is actually **on screen** (`kCGWindowIsOnscreen`); an
off-screen panel ignores it. A save panel is easier: its Save button is enabled
by default, so a plain `AXPress` commits.

**The conclusion that matters:** getting a panel on screen means bringing its
app forward, which means borrowing the person's screen. There is no way to
commit an open panel without that. So the driver's answer is to not open one.

**Route around it.** Use `open_file`: it runs `open -g`, opens the document
with no panel at all, and does not change the person's frontmost app. For the
agent's own rebuild cycle, `quit_app` + `launch_app` does the same. For a web
`<input type=file>`, Chrome's DevTools protocol (`DOM.setFileInputFiles`) sets
the file with no panel, if Chrome was launched with `--remote-debugging-port`.

`file_dialog` still exists for reading a panel and for cancelling one, and it
reports `on_screen` plus the visible files so an agent can tell why it cannot
commit.

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

### The screen being locked changes everything, silently

**What happens.** With `CGSSessionScreenIsLocked`, no window is key, the
frontmost application is `loginwindow`, `screencapture` may be refused, and
accessibility calls become much slower. Actions that depend on a key window —
closing a specific document, anything in focused mode — stop working. Ordinary
AX presses on a background app still work.

**Why it matters.** This is not a bug, but it looks exactly like one: calls that
worked a minute ago start failing or take a second each. A person walking away
and the screen locking is a completely normal event.

**What the driver does now.** `status` reports `screen_locked`, refreshed from
`CGSessionCopyCurrentDictionary`. The performance harness **refuses to run** on
a locked screen, because a measurement taken then does not describe real use.
The acceptance sweep marks focus and document checks `SKIP` instead of `FAIL`.

**Route around it.** Nothing to fix: report it to the agent so it can wait, or
keep doing the AX work that does not need a key window.

## Logged by agents

These came from `log_friction` during development, verbatim. The live
log is `/tmp/quiet-driver/friction.jsonl`; `friction_log` reads it back.

- **file_dialog** — NSOpenPanel cannot be committed through accessibility: AXPress on Open/Cancel reports success and the panel stays open
  
  macOS 15, TextEdit. Panel is AXMainWindow of both the host pid and com.apple.appkit.xpc.openAndSavePanelService. AXPress, AXConfirm, posted Return, and a real HID click all leave it open. The filename field does accept a written path. Route around it with open_file.
- **bind_app** — a leftover file panel makes an app report a phantom document window named Open or Save
  
  After an uncommitted NSOpenPanel, TextEdit keeps a zombie Open window in CGWindowList while AXWindows is empty. bind_app can land on it and documents lists it. Cancelling the panel inside the app (cmd+period) clears it.
- **click_label** — click_label costs ~90 ms because it walks the whole accessibility tree one IPC call per node
  
  A 130-node app is ~130 synchronous round trips. Caching with an AXObserver is the fix; not done. set_value avoids the walk entirely and costs 3 ms.
- **status** — binding an app that only exposes an accessory window picks the accessory
  
  macOS hangs windows titled Save Panel Accessory View / Open off apps. bind now filters them and prefers the largest titled non-accessory window, but a second app with only accessory windows would still bind to one.
- **documents** — backgrounded Cocoa apps report AXWindows as empty, so windows are not a reliable document list
  
  TextEdit returns 0 AXWindows while AXMainWindow reports the front document. documents reads the Window menu and filters items whose AXIdentifier is makeKeyAndOrderFront:.
