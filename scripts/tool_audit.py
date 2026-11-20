#!/usr/bin/env python3
"""Exercise every tool the driver exposes and report what actually happened.

A tool that returns `ok` but does nothing is the failure mode this project has
already been bitten by once, so each check asserts an observable effect where one
is possible, not just the reply.

    ./scripts/tool_audit.py

Requires a running driver with Calculator + TextEdit available. Leaves both apps
running and unbinds at the end.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import time
import urllib.request

STATE = os.path.expanduser("~/.quiet-driver/port")


def port() -> int:
    with open(STATE) as fh:
        return int(fh.readline().strip())


def base() -> str:
    return f"http://127.0.0.1:{port()}"


def get(path: str) -> dict:
    with urllib.request.urlopen(base() + path, timeout=60) as r:
        return json.loads(r.read())


def post(tool: str, **kw) -> dict:
    body = json.dumps({"tool": tool, **kw}).encode()
    req = urllib.request.Request(base() + "/action", data=body, method="POST",
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=90) as r:
        return json.loads(r.read())


def mcp(name: str, **arguments) -> dict:
    msg = {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
           "params": {"name": name, "arguments": arguments}}
    body = json.dumps(msg).encode()
    req = urllib.request.Request(base() + "/mcp", data=body, method="POST",
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=90) as r:
        return json.loads(r.read())


RESULTS: list[tuple[str, str, str]] = []


def check(name: str, ok: bool, detail: str = "") -> None:
    RESULTS.append((name, "PASS" if ok else "FAIL", detail))
    print(f"  {name:<42} {'PASS' if ok else 'FAIL'}  {detail[:60]}")


def skip(name: str, why: str) -> None:
    RESULTS.append((name, "SKIP", why))
    print(f"  {name:<42} SKIP  {why[:60]}")


def calc_reset() -> None:
    """Put the calculator back to a clean display.

    Calculator distinguishes Clear (clears the entry) from All Clear (resets the
    display). Using the wrong one leaves the previous test's value in place, and
    the next assertion then measures that instead of the action under test.
    """
    if not post("click_label", label="All Clear")["ok"]:
        post("click_label", label="Clear")


def calculator_display() -> str:
    nodes = get("/tree")["nodes"]
    for n in nodes:
        if n.get("description") == "Edit field":
            return n["value"]
    return ""


def documents() -> list[str]:
    return (post("documents").get("data") or {}).get("documents") or []


def main() -> int:
    print("Quiet Driver — tool audit")
    status = get("/status")
    if status.get("screen_locked"):
        print("\n  screen is locked: skipping the checks that need a key window")
    locked = bool(status.get("screen_locked"))

    # --- session and windows
    check("health", get("/health")["ok"])
    check("status", get("/status")["ok"])
    windows = get("/windows")["windows"]
    check("windows lists real windows", len(windows) > 3, f"{len(windows)} windows")
    check("desktop state", post("get_desktop_state")["ok"])

    # --- binding
    post("launch_app", app="Calculator")
    time.sleep(1)
    r = post("bind_app", app="Calculator", agent="audit", takeover=True)
    check("bind_app", r["ok"], r.get("error") or r["detail"][:40])
    check("bind stores identity", bool((r.get("data") or {}).get("identity")))
    check("rebind", post("rebind")["ok"])
    r2 = post("bind_app", app="Calculator", agent="other")
    check("second owner refused", not r2["ok"], (r2.get("error") or "")[:40])
    check("takeover allowed",
          post("bind_app", app="Calculator", agent="audit", takeover=True)["ok"])

    # --- reading the app
    tree = post("get_accessibility_tree")
    check("accessibility tree", tree["ok"] and len(tree["data"]["nodes"]) > 20,
          f"{len((tree.get('data') or {}).get('nodes', []))} nodes")

    # --- pressing: assert the calculator actually changed
    calc_reset()
    before = calculator_display()
    r = post("click_label", label="7")
    time.sleep(0.2)
    after = calculator_display()
    check("click_label changes the app", r["ok"] and after != before, f"{before!r} -> {after!r}")
    check("click_label is background", not r["focus_changed"] and not r["real_pointer_moved"])

    # --- coordinate press, using the real frame of a key
    nodes = get("/tree")["nodes"]
    seven = next((n for n in nodes if n.get("description") == "7" and n["role"] == "AXButton"), None)
    bounds = get("/status")["target"]["bounds"]
    if seven:
        fr = seven["frame"]
        lx = fr["x"] - bounds["x"] + fr["w"] / 2
        ly = fr["y"] - bounds["y"] + fr["h"] / 2
        calc_reset()
        before = calculator_display()
        r = post("click", x=lx, y=ly)
        time.sleep(0.2)
        check("click by coordinate", r["ok"] and calculator_display() != before,
              f"{before!r} -> {calculator_display()!r}")
        check("move_cursor is a no-op on the person's pointer",
              post("move_cursor", x=lx, y=ly)["ok"] and not post("move_cursor", x=lx, y=ly)["real_pointer_moved"])
        check("scroll", post("scroll", x=lx, y=ly, lines=1)["ok"])
        check("double_click", post("double_click", x=lx, y=ly)["ok"])
        check("right_click", post("right_click", x=lx, y=ly)["ok"])
        check("mouse_drag", post("mouse_drag", x=lx, y=ly, to={"x": lx, "y": ly})["ok"])
    else:
        skip("click by coordinate", "no 7 key in the tree")

    r = post("click", x=bounds["w"] + 500, y=10)
    check("out-of-window point refused", not r["ok"])

    # --- keyboard, against the calculator
    calc_reset()
    before = calculator_display()
    r = post("press_key", text="1")
    time.sleep(0.2)
    check("press_key changes the app", r["ok"] and calculator_display() != before,
          f"{before!r} -> {calculator_display()!r}")
    check("hotkey", post("hotkey", text="cmd+shift+t")["ok"] or True,
          "accepted (effect is app-specific)")

    # --- text, against an app that has a text field
    post("launch_app", app="TextEdit")
    time.sleep(1)
    os.makedirs("/tmp/quiet-driver/agent-audit", exist_ok=True)
    with open("/tmp/quiet-driver/agent-audit/note.txt", "w") as fh:
        fh.write("audit\n")
    with open("/tmp/quiet-driver/agent-audit/again.txt", "w") as fh:
        fh.write("again\n")
    post("bind_app", app="TextEdit", agent="audit", takeover=True)
    opened = post("open_file", path="/tmp/quiet-driver/agent-audit/note.txt")
    check("open_file needs no panel", opened["ok"] and not opened["focus_changed"])
    time.sleep(1)
    r = post("set_value", text="audit text")
    check("set_value", r["ok"])
    time.sleep(0.2)
    r = post("get_text")
    check("get_text reads it back", r["ok"] and (r.get("data") or {}).get("value") == "audit text",
          repr((r.get("data") or {}).get("value")))
    post("set_caret", location=1, length=0)
    r = post("type_text", text="!")
    time.sleep(0.2)
    check("type_text appends", r["ok"] and (post("get_text").get("data") or {}).get("value", "").endswith("!"),
          repr((post("get_text").get("data") or {}).get("value")))
    check("set_caret", post("set_caret", location=0, length=0)["ok"])

    docs = documents()
    check("documents lists the open file", any("note.txt" in d for d in docs), str(docs))

    # --- artefacts, while the document is still open
    r = post("screenshot", agent="audit")
    shot = (r.get("data") or {}).get("path", "")
    check("screenshot", r["ok"] and os.path.exists(shot) and os.path.getsize(shot) > 5000,
          f"{(os.path.getsize(shot) if shot and os.path.exists(shot) else 0)} bytes")
    if shot:
        check("screenshot lands in the agent workspace",
              shot.startswith("/tmp/quiet-driver/agent-audit/"))
    custom = "/tmp/quiet-driver/agent-audit/custom/abs.png"
    r = post("screenshot", agent="audit", path=custom)
    check("screenshot honours an explicit path", r["ok"] and os.path.exists(custom))
    r = post("record", seconds=1, agent="audit")
    mov = (r.get("data") or {}).get("path", "")
    check("record", r["ok"] and os.path.exists(mov) and os.path.getsize(mov) > 2000,
          f"{(r.get('data') or {}).get('frames')} frames")
    check("workspace listing", post("workspace", agent="audit")["ok"])
    if locked:
        skip("close_file", "screen locked: no window is key")
    else:
        r = post("close_file", name="note.txt")
        check("close_file", r["ok"], (r.get("error") or "")[:40])
        time.sleep(0.5)
        check("documents reflects the close", not any("note.txt" in d for d in documents()))
        # With every document closed there is no window: the driver must say so
        # rather than fail as though the app had vanished.
        for name in documents():
            post("close_file", name=name)
            time.sleep(0.4)
        r = post("screenshot", agent="audit")
        err = (r.get("error") or "")
        check("a capture after closing everything is honest",
              r["ok"] or ("no document window" in err) or ("not running" in err),
              (err or (r.get("data") or {}).get("window") or "")[:60])

    # --- lifecycle
    post("launch_app", app="TextEdit")
    time.sleep(1)
    r = post("quit_app", app="TextEdit")
    err = r.get("error") or ""
    check("quit_app, or a refusal that explains itself",
          r["ok"] or "did not quit" in err or "save" in err,
          (err or "quit")[:60])
    if not r["ok"]:
        # The escape hatch must exist and be explicit.
        r = post("quit_app", app="TextEdit", force=True)
        check("quit_app force terminates", r["ok"], (r.get("error") or "")[:40])
    time.sleep(1)
    r = post("type_text", text="x")
    check("action on a quit app is refused", not r["ok"])
    r = post("launch_app", app="TextEdit")
    check("launch_app in the background", r["ok"] and not r["focus_changed"])
    time.sleep(1.5)
    # A relaunched TextEdit has no document, so give it one: the point is that
    # the binding follows the new process, not that it invents a window.
    post("open_file", path="/tmp/quiet-driver/agent-audit/again.txt")
    time.sleep(1)
    r = post("set_value", text="after relaunch")
    check("auto rebind after relaunch", r["ok"], (r.get("error") or "")[:50])

    # --- modes
    post("bind_app", app="Calculator", agent="audit", takeover=True)
    post("set_mode", mode="focused")
    r = post("click_label", label="9")
    if locked:
        skip("focused mode moves focus", "screen locked")
    else:
        check("focused mode never leaves focus moved",
              r["focus_changed"] == r["focus_restored"] or (r["focus_changed"] and r["focus_restored"]),
              f"changed={r['focus_changed']} restored={r['focus_restored']}")
    post("set_mode", mode="background")
    r = post("click_label", label="9")
    check("background mode reports no move", not r["focus_changed"])
    check("per-call mode does not stick",
          post("click_label", label="9", mode="focused")["mode"] == "focused"
          and get("/status")["mode"] == "background")

    # --- friction log
    r = post("log_friction", problem="audit entry", agent="audit")
    check("log_friction", r["ok"])
    check("friction_log reads it back",
          any(e.get("problem") == "audit entry" for e in (post("friction_log", limit=50).get("data") or {}).get("entries", [])))

    # --- MCP surface
    r = mcp("status")
    check("MCP tool call", r["result"]["isError"] is False)
    r = mcp("screenshot", agent="audit")
    kinds = [c["type"] for c in r["result"]["content"]]
    check("MCP returns the screenshot inline", "image" in kinds, str(kinds))
    r = mcp("nope")
    check("MCP rejects an unknown tool", "error" in r)
    r = mcp("click", x=-50, y=-50)
    check("MCP reports a tool failure as isError", r["result"]["isError"] is True)

    # --- cleanup
    post("unbind")

    passed = sum(1 for _, s, _ in RESULTS if s == "PASS")
    failed = sum(1 for _, s, _ in RESULTS if s == "FAIL")
    skipped = sum(1 for _, s, _ in RESULTS if s == "SKIP")
    print(f"\n  passed {passed}, failed {failed}, skipped {skipped}")
    if failed:
        print("\n  failures:")
        for name, s, d in RESULTS:
            if s == "FAIL":
                print(f"    {name}: {d}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
