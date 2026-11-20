#!/usr/bin/env python3
"""Analyse the driver's operation log.

The daemon writes one JSON object per operation to
`~/.quiet-driver/logs/ops-YYYYMMDD.jsonl`: tool, agent, target, mode, total time,
time waiting on the app, time moving focus, whether focus moved and came back,
and why anything failed. This reads that file and answers the questions worth
asking.

    ./scripts/analyze_logs.py                 # last hour
    ./scripts/analyze_logs.py --since 6h
    ./scripts/analyze_logs.py --tool click_label --show 20
    ./scripts/analyze_logs.py --failures
    ./scripts/analyze_logs.py --csv > ops.csv
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import sys
from collections import Counter, defaultdict

LOG_DIR = os.path.expanduser("~/.quiet-driver/logs")


def load(since_seconds: int | None) -> list[dict]:
    files = sorted(glob.glob(os.path.join(LOG_DIR, "ops-*.jsonl")))
    if not files:
        raise SystemExit(f"no operation log in {LOG_DIR} (is QD_OP_LOG=0 set?)")
    rows: list[dict] = []
    cutoff = None
    if since_seconds:
        import time
        cutoff = (time.time() - since_seconds) * 1000
    for path in files:
        with open(path) as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    row = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if cutoff and (row.get("epoch_ms") or 0) < cutoff:
                    continue
                rows.append(row)
    return rows


def pct(values: list[float], p: float) -> float:
    if not values:
        return 0.0
    s = sorted(values)
    i = min(len(s) - 1, max(0, int(round(p / 100 * (len(s) - 1)))))
    return s[i]


def fmt(ms: float) -> str:
    if ms >= 1000:
        return f"{ms / 1000:.2f}s"
    return f"{ms:.1f}ms"


def section(title: str) -> None:
    print(f"\n{title}")
    print("-" * len(title))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--since", default="1h", help="1h, 30m, 6h, or 'all'")
    ap.add_argument("--tool", help="only this tool")
    ap.add_argument("--agent", help="only this agent")
    ap.add_argument("--failures", action="store_true", help="list failures only")
    ap.add_argument("--show", type=int, default=10, help="how many rows to list")
    ap.add_argument("--csv", action="store_true", help="emit operations as CSV")
    args = ap.parse_args()

    since = None
    if args.since != "all":
        unit = args.since[-1].lower()
        number = float(args.since[:-1] or 1)
        mult = {"m": 60, "h": 3600, "d": 86400}.get(unit)
        if mult is None:
            raise SystemExit("--since wants a value like 30m, 6h or all")
        since = int(number * mult)

    rows = load(since)
    if args.tool:
        rows = [r for r in rows if r.get("tool") == args.tool]
    if args.agent:
        rows = [r for r in rows if r.get("agent") == args.agent]
    ops = [r for r in rows if r.get("kind") == "op"]

    if args.csv:
        keys = ["ts", "agent", "tool", "ok", "duration_ms", "error", "target", "mode"]
        print(",".join(keys))
        for r in ops:
            print(",".join(json.dumps(str(r.get(k, "")))[1:-1] if k == "error" else
                           json.dumps(r.get(k, "")).strip('"') for k in keys))
        return 0

    print(f"Quiet Driver — operation log")
    print(f"  {LOG_DIR}")
    print(f"  {len(rows)} records ({len(ops)} operations) over the last {args.since}")

    if not ops:
        return 0

    if args.failures:
        section("Failures")
        for r in [r for r in ops if r.get("ok") is False][-args.show:]:
            print(f"  {r.get('ts')}  {r.get('agent', ''):10} {r.get('tool', ''):14} "
                  f"{r.get('duration_ms', 0):8.1f}ms  {str(r.get('error', ''))[:90]}")
        return 0

    section("By tool")
    by_tool: dict[str, list[dict]] = defaultdict(list)
    for r in ops:
        by_tool[r.get("tool", "?")].append(r)
    print(f"  {'tool':<16}{'n':>6}{'p50':>9}{'p95':>9}{'p99':>9}{'max':>9}  {'worker':>8}  fails")
    for tool, group in sorted(by_tool.items(), key=lambda kv: -pct([g.get("duration_ms", 0) for g in kv[1]], 95)):
        durs = [g.get("duration_ms", 0) for g in group]
        worker = [sum((g.get("phases") or {}).get("worker_ms", 0) for _ in [0]) for g in group]
        fails = sum(1 for g in group if g.get("ok") is False)
        print(f"  {tool:<16}{len(group):>6}{fmt(pct(durs, 50)):>9}{fmt(pct(durs, 95)):>9}"
              f"{fmt(pct(durs, 99)):>9}{fmt(max(durs)):>9}  {fmt(pct(worker, 50)):>8}  {fails}")

    section("Where the time went")
    totals = [r.get("duration_ms", 0) for r in ops]
    worker = [max(0.0, (r.get("phases") or {}).get("worker_ms", 0)) for r in ops]
    driver = [max(0.0, (r.get("phases") or {}).get("driver_ms", 0)) for r in ops]
    focus = [(r.get("phases") or {}).get("focus_raise_ms", 0) + (r.get("phases") or {}).get("focus_restore_ms", 0)
             for r in ops]
    grand = sum(totals)
    print(f"  total operation time   {fmt(grand)}")
    print(f"  waiting on the app     {fmt(sum(worker))}  ({sum(worker) / grand * 100:.0f}%)")
    print(f"  driver overhead        {fmt(sum(driver))}  ({sum(driver) / grand * 100:.0f}%)")
    print(f"  moving focus           {fmt(sum(focus))}  ({sum(focus) / grand * 100:.0f}%)")

    section("Guarantees")
    focus_changed = sum(1 for r in ops if (r.get("focus") or {}).get("changed") is True)
    focus_restored = sum(1 for r in ops if (r.get("focus") or {}).get("restored") is True)
    pointer = sum(1 for r in ops if r.get("pointer_moved") is True)
    print(f"  focus changed          {focus_changed} operation(s)")
    print(f"  focus restored         {focus_restored} time(s)")
    print(f"  pointer moved          {pointer} time(s)")
    if focus_changed:
        bad = [r for r in ops if (r.get("focus") or {}).get("changed") is True
               and (r.get("focus") or {}).get("restored") is not True]
        if bad:
            print(f"  focus left moved       {len(bad)} time(s)  <-- investigate")
            for r in bad[:5]:
                print(f"    {r.get('ts')} {r.get('tool')} {r.get('agent')} "
                      f"before={(r.get('focus') or {}).get('before_app')} "
                      f"after={(r.get('focus') or {}).get('after_app')}")

    slowest = sorted(ops, key=lambda r: r.get("duration_ms", 0), reverse=True)[:args.show]
    section(f"Slowest {len(slowest)} operation(s)")
    for r in slowest:
        phases = r.get("phases") or {}
        print(f"  {fmt(r.get('duration_ms', 0)):>9}  {r.get('tool', ''):14} {r.get('agent', ''):10} "
              f"worker={fmt(phases.get('worker_ms', 0)):>8} driver={fmt(phases.get('driver_ms', 0)):>8}  "
              f"{str(r.get('target', ''))[:40]}")

    failures = [r for r in ops if r.get("ok") is False]
    if failures:
        section(f"Failures ({len(failures)})")
        for reason, count in Counter(str(f.get("error", "?"))[:80] for f in failures).most_common(8):
            print(f"  {count:>4}x  {reason}")

    section("Agents")
    for agent, count in Counter(r.get("agent", "?") for r in ops).most_common():
        tools = Counter(r.get("tool", "?") for r in ops if r.get("agent") == agent)
        print(f"  {agent:14} {count:>5} ops   {', '.join(f'{t}×{c}' for t, c in tools.most_common(4))}")

    section("Activity")
    buckets: Counter = Counter()
    for r in ops:
        ts = r.get("ts", "")
        buckets[ts[:16]] += 1          # per minute
    for minute, count in sorted(buckets.items())[-20:]:
        print(f"  {minute}  {'#' * min(count, 60)} {count}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
