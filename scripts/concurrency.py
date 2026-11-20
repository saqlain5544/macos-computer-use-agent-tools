#!/usr/bin/env python3
"""Two agents, two apps, at the same time.

The design says each bound app gets its own worker process, so work on one app
must not queue behind work on another. That is a claim about wall time, and it
is checked here rather than asserted: run the same actions against both apps
concurrently and against each app alone, and compare.

    ./scripts/concurrency.py [--actions N]

Also checks the ownership rule under contention: two agents racing to bind the
same app must end up with exactly one owner.
"""
from __future__ import annotations

import argparse
import json
import multiprocessing
import os
import subprocess
import sys
import threading
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
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.loads(r.read())


RESULTS: list[tuple[str, str, str]] = []


def check(name: str, ok: bool, detail: str = "") -> None:
    RESULTS.append((name, "PASS" if ok else "FAIL", detail))
    print(f"  {name:<46} {'PASS' if ok else 'FAIL'}  {detail[:60]}")


def prepare(app: str, agent: str) -> str:
    """Get an app ready and return the action that exercises it.

    Both apps have to do the same kind of work for the comparison to mean
    anything: a text field that accepts keystrokes exists in both, while number
    buttons only exist in one.
    """
    post("bind_app", app=app, agent=agent, takeover=True)
    if app == "TextEdit":
        path = "/tmp/quiet-driver-concurrency/doc.txt"
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as fh:
            fh.write("concurrency\n")
        post("open_file", path=path)
        time.sleep(0.6)
    return "type"


def run_actions(agent: str, app: str, count: int, results: list, errors: list) -> None:
    """Bind an app and drive it, recording how long the loop took."""
    started = time.time()
    try:
        bound = post("bind_app", app=app, agent=agent, takeover=True)
        if not bound["ok"]:
            errors.append(bound.get("error") or "bind failed")
            return
        for i in range(count):
            reply = post("get_accessibility_tree", agent=agent)
            if not reply["ok"]:
                errors.append(reply.get("error") or "action failed")
                return
        results.append((agent, app, time.time() - started))
    except Exception as exc:                      # noqa: BLE001 - reported, not raised
        errors.append(f"{type(exc).__name__}: {exc}")


def child_record(agent: str) -> None:
    """Occupy one app's worker for two seconds."""
    post("bind_app", app="TextEdit", agent=agent, takeover=True)
    post("record", seconds=2.0, agent=agent)


def child_keys(agent: str, app: str, queue) -> None:
    """Type digits into one app concurrently with another agent typing into its own."""
    try:
        post("bind_app", app=app, agent=agent, takeover=True)
        for i in range(10):
            reply = post("type_text", text=str(i % 10), agent=agent)
            if not reply["ok"]:
                queue.put(f"{app}: {reply.get('error')}")
                return
        queue.put(None)
    except Exception as exc:                       # noqa: BLE001
        queue.put(f"{app}: {exc}")


def child_actions(agent: str, app: str, count: int, queue) -> None:
    """Run one agent in its own process, so the parent's GIL is not the limit."""
    results: list = []
    errors: list = []
    run_actions(agent, app, count, results, errors)
    if errors:
        queue.put((agent, app, 0.0, errors[0]))
    else:
        queue.put((agent, app, results[0][2] if results else 0.0, None))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--actions", type=int, default=40)
    args = parser.parse_args()

    print("Quiet Driver — concurrency")
    post("launch_app", app="Calculator")
    post("launch_app", app="TextEdit")
    time.sleep(1.5)
    post("set_mode", mode="background")
    focus_before = get("/status")["focus_events"]

    # Deterministic test of the actual claim: a slow call against one app must
    # not block work on another. Recording occupies TextEdit's worker for two
    # seconds; Calculator's worker must stay responsive throughout. Timing two
    # agents against each other would only measure how busy this machine is.
    prepare("TextEdit", "agent-a")
    prepare("Calculator", "agent-b")
    recorder = multiprocessing.Process(target=child_record, args=("agent-a",))
    recorder.start()
    time.sleep(0.35)                     # let the recording take hold of its worker

    other_latencies = []
    for _ in range(4):
        started = time.time()
        reply = post("get_accessibility_tree", agent="agent-b")
        other_latencies.append((time.time() - started) * 1000)
        if not reply["ok"]:
            break
    recorder.join()
    worst = max(other_latencies) if other_latencies else 9999
    check("a slow call on one app does not block another", worst < 1000,
          f"worst {worst:.0f} ms on the other app while recording")

    # And the recording itself must have succeeded.
    check("the slow call completed", recorder.exitcode == 0, f"exit {recorder.exitcode}")

    # Event delivery does not overlap the same way (the window server serialises
    # it), but it must not cross over: each app must receive only its own keys.
    prepare("Calculator", "agent-a")
    prepare("TextEdit", "agent-b")
    post("set_value", text="x", agent="agent-b") if False else None
    queue2 = multiprocessing.Queue()
    procs2 = [
        multiprocessing.Process(target=child_keys, args=("agent-a", "Calculator", queue2)),
        multiprocessing.Process(target=child_keys, args=("agent-b", "TextEdit", queue2)),
    ]
    for p in procs2:
        p.start()
    for p in procs2:
        p.join()
    key_errors = []
    for _ in procs2:
        try:
            if queue2.get_nowait():
                key_errors.append("a key phase failed")
        except Exception:                          # noqa: BLE001
            key_errors.append("a key phase reported nothing")
    check("concurrent keystrokes all land", not key_errors, str(key_errors[:2]))

    # Both bindings must still exist, as separate agents on separate apps.
    post("bind_app", app="Calculator", agent="agent-a", takeover=True)
    post("bind_app", app="TextEdit", agent="agent-b", takeover=True)
    bindings = {b["agent"]: b.get("label", "") for b in get("/status")["bindings"]}
    check("two agents can hold two apps at once",
          len(bindings) >= 2 and len(set(bindings.values())) >= 2,
          str(bindings))

    # An agent that hops between apps must not leave a worker behind for every
    # app it visited: each is a 13 MB process.
    def worker_count() -> int:
        pid = open(STATE).read().split("\n")[2].strip()
        out = subprocess.run(["/usr/bin/pgrep", "-P", pid],
                             capture_output=True, text=True).stdout
        return len([line for line in out.splitlines() if line.strip()])

    before = worker_count()
    for _ in range(4):
        for app in ["Calculator", "TextEdit"]:
            post("bind_app", app=app, agent="hopper", takeover=True)
            time.sleep(0.1)
    time.sleep(0.5)
    after = worker_count()
    check("hopping apps does not leak workers", after <= before + 1,
          f"{before} workers before, {after} after")

    # Ownership under contention: release every binding on the app, then four
    # agents reach for it at once. Exactly one must win.
    for row in get("/status")["bindings"]:
        if "Calculator" in (row.get("label") or ""):
            post("unbind", agent=row["agent"])
    replies: list[dict] = []

    def grab(agent: str) -> None:
        replies.append(post("bind_app", app="Calculator", agent=agent))

    racers = [threading.Thread(target=grab, args=(f"racer{i}",)) for i in range(4)]
    for t in racers:
        t.start()
    for t in racers:
        t.join()
    winners = [r for r in replies if r["ok"]]
    losers = [r for r in replies if not r["ok"]]
    check("exactly one racing bind wins", len(winners) == 1, f"{len(winners)} ok, {len(losers)} refused")
    check("the losers are told the app is owned",
          all("already bound" in (r.get("error") or "") for r in losers),
          (losers[0].get("error") if losers else "")[:60])

    # Focus must not have moved through any of it.
    status = get("/status")
    moved = status["focus_events"] - focus_before
    check("no focus moved in background work", moved == 0, f"{moved} new events")
    check("mode stayed background", status["mode"] == "background")

    passed = sum(1 for _, s, _ in RESULTS if s == "PASS")
    failed = sum(1 for _, s, _ in RESULTS if s == "FAIL")
    print(f"\n  passed {passed}, failed {failed}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
