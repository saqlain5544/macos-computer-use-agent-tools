# Performance harness

`harness.py` measures the things that decide whether an agent can work in the
background, and it fails the run when an invariant breaks.

```bash
./perf/harness.py              # full run
./perf/harness.py --quick      # fewer iterations
./perf/harness.py --compare    # diff the last few runs
```

## What it records

| Group | Metrics |
|---|---|
| Latency | p50 / p90 / p99 / max / mean per tool, throughput, failures |
| Memory | daemon RSS before and after, growth, per-worker RSS and count |
| CPU | daemon CPU seconds consumed during the run |
| Invariants | focus transitions, pointer moves, driver-reported focus events |
| Internal | the daemon's own per-tool percentiles from `GET /metrics` |

Every run is written to `perf/<UTC timestamp>.json`, so a regression is a
number in a diff rather than a feeling.

## The invariants are hard failures

A run exits non-zero if focus moved during background work, if the daemon grew
more than 8 MB, or if any call failed. That is deliberate: those are the
promises the driver makes, so a run that breaks one is not "a bit slower", it is
broken.

## Why it measures inside and outside

Outside-in numbers (the harness over loopback) are what an agent experiences.
The daemon's own `/metrics` percentiles are what it thinks it is doing. A gap
between the two means the cost is in the round trip, not the work — which is
exactly how the 128 ms `usleep` in the click path was found.
