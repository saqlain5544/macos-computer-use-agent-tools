#!/usr/bin/env python3
"""Quiet Driver performance harness.

Measures the things that decide whether an agent can actually work in the
background: latency per tool, throughput, memory, CPU, and the two invariants
that must never break — the person's pointer does not move, and their frontmost
app does not change.

It records every run to `perf/<timestamp>.json` and compares against the
previous run, so a regression shows up as a number rather than a feeling.

    ./perf/harness.py                 # full run against the running daemon
    ./perf/harness.py --quick         # fewer iterations
    ./perf/harness.py --compare       # summarise the last few runs

Requires a running driver and a bound app; it binds Calculator itself if needed.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import statistics
import subprocess
import sys
import time
import urllib.request
from datetime import datetime, timezone

PERF_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)))
STATE = os.path.expanduser("~/.quiet-driver/port")


# ----------------------------------------------------------------- plumbing

def daemon_port() -> int:
    with open(STATE) as fh:
        return int(fh.readline().strip())


def base() -> str:
    return f"http://127.0.0.1:{daemon_port()}"


def get(path: str) -> dict:
    with urllib.request.urlopen(base() + path, timeout=30) as r:
        return json.loads(r.read())


def post(tool: str, **kw) -> dict:
    body = json.dumps({"tool": tool, **kw}).encode()
    req = urllib.request.Request(
        base() + "/action", data=body, method="POST",
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read())


def ps_rss_mb(pid: int) -> float:
    out = subprocess.run(["ps", "-o", "rss=", "-p", str(pid)],
                         capture_output=True, text=True).stdout.strip()
    return round(int(out or 0) / 1024, 1)


def ps_cpu_seconds(pid: int) -> float:
    out = subprocess.run(["ps", "-o", "time=", "-p", str(pid)],
                         capture_output=True, text=True).stdout.strip()
    if not out:
        return 0.0
    total = 0.0
    for i, part in enumerate(reversed(out.split(":"))):
        total += float(part) * (60 ** i)
    return total


def daemon_pid() -> int:
    with open(STATE) as fh:
        lines = fh.read().split("\n")
    return int(lines[2]) if len(lines) > 2 and lines[2].strip() else 0


def child_pids(pid: int) -> list[int]:
    out = subprocess.run(["pgrep", "-P", str(pid)], capture_output=True, text=True).stdout
    return [int(x) for x in out.split() if x.strip()]


# ------------------------------------------------------- invariant monitor

MONITOR_SRC = r'''
import Cocoa
let path = CommandLine.arguments[1]
FileManager.default.createFile(atPath: path, contents: nil)
let fh = FileHandle(forWritingAtPath: path)!
var last = ""
var pointerMoves = 0
var lastPointer = CGPoint(x: -1, y: -1)
while true {
    let front = NSWorkspace.shared.frontmostApplication
    var top = ""
    if let l = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] {
        for w in l where (w[kCGWindowLayer as String] as? Int ?? -1) == 0 {
            let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
            if (b["Width"] as? Double ?? 0) < 300 { continue }
            top = w[kCGWindowOwnerName as String] as? String ?? ""
            break
        }
    }
    let p = CGEvent(source: nil)?.location ?? .zero
    if lastPointer.x >= 0 && (abs(p.x - lastPointer.x) > 0.01 || abs(p.y - lastPointer.y) > 0.01) {
        pointerMoves += 1
    }
    lastPointer = p
    let key = "\(front?.localizedName ?? "")|\(top)"
    if key != last {
        let rec = "{\"t\":\(Date().timeIntervalSince1970),\"front\":\"\(front?.localizedName ?? "")\",\"top\":\"\(top)\",\"pointerMoves\":\(pointerMoves)}\n"
        fh.write(rec.data(using: .utf8)!)
        last = key
    }
    usleep(50_000)
}
'''


class Monitor:
    """Samples focus and pointer at 20 Hz in a child process."""

    def __init__(self, workdir: str):
        self.path = os.path.join(workdir, "trace.jsonl")
        self.src = os.path.join(workdir, "monitor.swift")
        self.exe = os.path.join(workdir, "monitor")
        os.makedirs(workdir, exist_ok=True)
        with open(self.src, "w") as fh:
            fh.write(MONITOR_SRC)
        if not os.path.exists(self.exe) or os.path.getmtime(self.exe) < os.path.getmtime(self.src):
            subprocess.run(["swiftc", "-O", self.src, "-o", self.exe],
                           check=True, capture_output=True)
        self.proc: subprocess.Popen | None = None

    def __enter__(self):
        open(self.path, "w").close()
        self.proc = subprocess.Popen([self.exe, self.path],
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(0.8)
        return self

    def __exit__(self, *exc):
        if self.proc:
            self.proc.terminate()
            self.proc.wait(timeout=5)

    def transitions(self) -> tuple[int, int, list[dict]]:
        rows = []
        with open(self.path) as fh:
            for line in fh:
                line = line.strip()
                if line:
                    try:
                        rows.append(json.loads(line))
                    except json.JSONDecodeError:
                        pass
        focus_moves = max(0, len(rows) - 1)
        pointer_moves = rows[-1]["pointerMoves"] if rows else 0
        return focus_moves, pointer_moves, rows


# --------------------------------------------------------------- the suite

def bench(label: str, fn, n: int) -> dict:
    # one warm-up
    try:
        fn()
    except Exception:
        pass
    times = []
    failures = 0
    t0 = time.time()
    for _ in range(n):
        s = time.perf_counter()
        try:
            r = fn()
            if isinstance(r, dict) and not r.get("ok", True):
                failures += 1
        except Exception:
            failures += 1
        times.append((time.perf_counter() - s) * 1000)
    elapsed = time.time() - t0
    times.sort()

    def at(p):
        return round(times[min(len(times) - 1, int(len(times) * p))], 2)

    return {
        "label": label,
        "n": n,
        "p50_ms": at(0.50),
        "p90_ms": at(0.90),
        "p99_ms": at(0.99),
        "max_ms": round(times[-1], 2),
        "mean_ms": round(statistics.fmean(times), 2),
        "throughput_per_s": round(n / elapsed, 1) if elapsed else 0,
        "failures": failures,
        "elapsed_s": round(elapsed, 2),
    }


def run_suite(quick: bool) -> dict:
    n = 8 if quick else 40
    n_heavy = 4 if quick else 12

    # Bind Calculator, launching it in the background if it is not running.
    bind = post("bind_app", app="Calculator", agent="perf", takeover=True)
    if not bind.get("ok"):
        post("launch_app", app="Calculator")
        time.sleep(2)
        bind = post("bind_app", app="Calculator", agent="perf", takeover=True)
    if not bind.get("ok"):
        raise SystemExit(f"cannot bind Calculator: {bind.get('error')}")

    post("set_mode", mode="background")
    status = get("/status")
    win = status["target"]["bounds"]

    results = []
    results.append(bench("status", lambda: get("/status"), n * 4))
    results.append(bench("windows", lambda: get("/windows"), n))
    results.append(bench("click_label", lambda: post("click_label", label="7"), n))
    results.append(bench("click (coordinate)", lambda: post("click", x=win["w"] * 0.5, y=win["h"] * 0.75), n))
    results.append(bench("press_key", lambda: post("press_key", text="1"), n))
    results.append(bench("accessibility_tree", lambda: post("get_accessibility_tree"), n_heavy))
    results.append(bench("screenshot", lambda: post("screenshot", agent="perf"), n_heavy))
    results.append(bench("mcp tools/list", lambda: mcp({"jsonrpc": "2.0", "id": 1, "method": "tools/list"}), n))

    # Text tools need an app that has a text field; Calculator has none, and
    # benchmarking them there would measure a correct refusal.
    text = bench_text_tools(n, n_heavy)
    results.extend(text["benchmarks"])

    return {
        "tool_benchmarks": results,
        "window": win,
    }


def bench_text_tools(n: int, n_heavy: int) -> dict:
    """Type and set text in a real text field, using TextEdit."""
    post("launch_app", app="TextEdit")
    time.sleep(1)
    opened = post("open_file", path="/tmp/quiet-driver-perf/doc.txt")
    if not opened.get("ok"):
        # Make sure the file exists, then open it.
        os.makedirs("/tmp/quiet-driver-perf", exist_ok=True)
        with open("/tmp/quiet-driver-perf/doc.txt", "w") as fh:
            fh.write("performance harness\n")
        post("bind_app", app="TextEdit", agent="perf", takeover=True)
        post("open_file", path="/tmp/quiet-driver-perf/doc.txt")
    bind = post("bind_app", app="TextEdit", agent="perf", takeover=True)
    if not bind.get("ok"):
        return {"benchmarks": [], "skipped": bind.get("error")}
    out = [
        bench("type_text", lambda: post("type_text", text="x"), n),
        bench("set_value", lambda: post("set_value", text="harness"), n),
        bench("get_text", lambda: post("get_text"), n),
    ]
    # Back to Calculator so the footprint run is comparable.
    post("bind_app", app="Calculator", agent="perf", takeover=True)
    return {"benchmarks": out}


def mcp(msg: dict) -> dict:
    body = json.dumps(msg).encode()
    req = urllib.request.Request(base() + "/mcp", data=body, method="POST",
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read())


def measure_footprint(action_count: int) -> dict:
    """Run `action_count` actions and watch memory, CPU and invariants."""
    pid = daemon_pid()
    before = {
        "daemon_rss_mb": ps_rss_mb(pid),
        "daemon_cpu_s": ps_cpu_seconds(pid),
        "workers": {c: ps_rss_mb(c) for c in child_pids(pid)},
    }
    t0 = time.time()
    with Monitor("/tmp/quiet-driver-perf") as mon:
        for i in range(action_count):
            post("click_label", label=str(i % 10))
        time.sleep(0.4)
        focus_moves, pointer_moves, rows = mon.transitions()
    elapsed = time.time() - t0

    after = {
        "daemon_rss_mb": ps_rss_mb(pid),
        "daemon_cpu_s": ps_cpu_seconds(pid),
        "workers": {c: ps_rss_mb(c) for c in child_pids(pid)},
    }
    status = get("/status")
    return {
        "actions": action_count,
        "elapsed_s": round(elapsed, 2),
        "actions_per_s": round(action_count / elapsed, 1),
        "daemon_rss_before_mb": before["daemon_rss_mb"],
        "daemon_rss_after_mb": after["daemon_rss_mb"],
        "daemon_rss_growth_mb": round(after["daemon_rss_mb"] - before["daemon_rss_mb"], 2),
        "daemon_cpu_seconds": round(after["daemon_cpu_s"] - before["daemon_cpu_s"], 2),
        "worker_rss_mb": after["workers"],
        "worker_count": len(after["workers"]),
        "focus_transitions": focus_moves,
        "pointer_moves": pointer_moves,
        "driver_reported_focus_events": status["focus_events"],
        "mode": status["mode"],
        "trace": rows[:20],
    }


def compare_runs(runs: list[dict]) -> str:
    if len(runs) < 2:
        return "need at least two runs to compare"
    prev, cur = runs[-2], runs[-1]
    lines = ["metric                                  previous      current      change"]
    lines.append("-" * 74)

    def row(name, a, b, unit=""):
        if a is None or b is None:
            return
        delta = b - a
        pct = (delta / a * 100) if a else 0.0
        flag = ""
        if abs(pct) >= 10:
            flag = "  <-- " + ("slower" if delta > 0 else "faster")
        lines.append(f"{name:<38} {a:>9.2f}{unit} {b:>11.2f}{unit} {pct:>+8.1f}%{flag}")

    row("daemon RSS (MB)", prev["footprint"]["daemon_rss_after_mb"], cur["footprint"]["daemon_rss_after_mb"])
    row("throughput (actions/s)", prev["footprint"]["actions_per_s"], cur["footprint"]["actions_per_s"])
    for label in ("click_label", "type_text", "screenshot", "accessibility_tree"):
        a = next((b["p50_ms"] for b in prev["bench"]["tool_benchmarks"] if b["label"] == label), None)
        b = next((x["p50_ms"] for x in cur["bench"]["tool_benchmarks"] if x["label"] == label), None)
        row(f"{label} p50 (ms)", a, b)
    return "\n".join(lines)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--quick", action="store_true")
    ap.add_argument("--actions", type=int, default=300,
                    help="actions for the memory/invariant run")
    ap.add_argument("--compare", action="store_true")
    args = ap.parse_args()

    os.makedirs(PERF_DIR, exist_ok=True)

    if args.compare:
        runs = sorted(f for f in os.listdir(PERF_DIR) if re.fullmatch(r"\d{8}T\d{6}Z\.json", f))
        loaded = [json.load(open(os.path.join(PERF_DIR, f))) for f in runs[-4:]]
        print(compare_runs(loaded))
        return 0

    print("Quiet Driver — performance harness")
    print(f"  daemon: {base()} (pid {daemon_pid()})")

    status = get("/status")
    if status.get("screen_locked"):
        print("\n  REFUSING TO MEASURE: the screen is locked.")
        print("  Accessibility and focus behave differently when the screen is")
        print("  locked (no window is key, capture may be refused, calls are")
        print("  slower), so a run now would not describe real use.")
        return 2

    # Fresh distributions: measure this run only.
    try:
        req = urllib.request.Request(base() + "/metrics", data=b"{}", method="POST",
                                     headers={"Content-Type": "application/json"})
        urllib.request.urlopen(req, timeout=10).read()
    except Exception:
        pass

    bench = run_suite(args.quick)
    print("\n  latency (ms)")
    print(f"  {'tool':<22}{'p50':>8}{'p90':>8}{'p99':>8}{'max':>8}{'fail':>6}")
    for b in bench["tool_benchmarks"]:
        print(f"  {b['label']:<22}{b['p50_ms']:>8.2f}{b['p90_ms']:>8.2f}"
              f"{b['p99_ms']:>8.2f}{b['max_ms']:>8.2f}{b['failures']:>6}")

    footprint = measure_footprint(20 if args.quick else args.actions)
    print("\n  memory, CPU and invariants")
    print(f"    {footprint['actions']} actions in {footprint['elapsed_s']}s "
          f"({footprint['actions_per_s']}/s)")
    print(f"    daemon RSS       {footprint['daemon_rss_before_mb']} -> "
          f"{footprint['daemon_rss_after_mb']} MB "
          f"(growth {footprint['daemon_rss_growth_mb']:+.1f})")
    print(f"    worker RSS       {footprint['worker_rss_mb']} MB "
          f"({footprint['worker_count']} process(es))")
    print(f"    daemon CPU       {footprint['daemon_cpu_seconds']}s")
    print(f"    focus moved      {footprint['focus_transitions']} time(s)   "
          f"{'OK' if footprint['focus_transitions'] == 0 else 'VIOLATION'}")
    print(f"    pointer moved    {footprint['pointer_moves']} time(s)   (person's own movement also counts)")

    try:
        internal = get("/metrics")
    except Exception:
        internal = {}

    doc = {
        "at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "quick": args.quick,
        "bench": bench,
        "footprint": footprint,
        "internal_metrics": internal,
    }
    name = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + ".json"
    out = os.path.join(PERF_DIR, name)
    with open(out, "w") as fh:
        json.dump(doc, fh, indent=2)

    print("\n  internal metrics (measured inside the daemon)")
    if internal.get("slowest"):
        for entry in internal["slowest"][:5]:
            st = entry["stats"]
            print(f"    {entry['tool']:<22} n={st['count']:<5} "
                  f"p50={st['p50_ms']}ms p99={st['p99_ms']}ms")

    problems = []
    if footprint["focus_transitions"] > 0:
        problems.append("focus moved during background work")
    if footprint["daemon_rss_growth_mb"] > 8:
        problems.append(f"daemon grew {footprint['daemon_rss_growth_mb']} MB")
    if any(b["failures"] for b in bench["tool_benchmarks"]):
        problems.append("some calls failed")

    print(f"\n  run recorded: perf/{name}")
    if problems:
        print("  PROBLEMS: " + "; ".join(problems))
        return 1
    print("  all invariants held")
    return 0


if __name__ == "__main__":
    sys.exit(main())
