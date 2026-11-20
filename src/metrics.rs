//! Per-tool timing and process metrics.
//!
//! The driver is only useful if it is quiet and quick. This module keeps the
//! numbers the performance harness reads: a latency distribution per tool, how
//! much work each surface has done, and the resource footprint of the process
//! tree.
//!
//! Percentiles come from a fixed-size reservoir per tool, so memory stays flat
//! no matter how long the session runs.

use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};

/// Samples kept per tool. Enough for a stable p99, small enough to be free.
const RESERVOIR: usize = 512;

#[derive(Default, Clone)]
struct ToolStats {
    count: u64,
    errors: u64,
    total_us: u64,
    samples: Vec<u32>,
    next_slot: usize,
}

impl ToolStats {
    fn record(&mut self, micros: u64, ok: bool) {
        let us = micros.min(u32::MAX as u64) as u32;
        self.count += 1;
        self.total_us += micros;
        if !ok {
            self.errors += 1;
        }
        if self.samples.len() < RESERVOIR {
            self.samples.push(us);
        } else {
            // Deterministic round-robin replacement keeps an unbiased sample
            // without a random number generator.
            self.samples[self.next_slot] = us;
            self.next_slot = (self.next_slot + 1) % RESERVOIR;
        }
    }

    fn percentiles(&self) -> (u32, u32, u32, u32) {
        if self.samples.is_empty() {
            return (0, 0, 0, 0);
        }
        let mut v = self.samples.clone();
        v.sort_unstable();
        let at = |p: f64| v[((v.len() - 1) as f64 * p).round() as usize];
        (at(0.50), at(0.90), at(0.99), *v.last().unwrap())
    }

    fn to_json(&self) -> Value {
        let (p50, p90, p99, max) = self.percentiles();
        json!({
            "count": self.count,
            "errors": self.errors,
            "p50_ms": round2(p50 as f64 / 1000.0),
            "p90_ms": round2(p90 as f64 / 1000.0),
            "p99_ms": round2(p99 as f64 / 1000.0),
            "max_ms": round2(max as f64 / 1000.0),
            "mean_ms": round2(if self.count == 0 { 0.0 } else { self.total_us as f64 / self.count as f64 / 1000.0 }),
            "samples": self.samples.len(),
        })
    }
}

fn round2(v: f64) -> f64 {
    (v * 100.0).round() / 100.0
}

static STATS: OnceLock<Mutex<HashMap<String, ToolStats>>> = OnceLock::new();

fn stats() -> &'static Mutex<HashMap<String, ToolStats>> {
    STATS.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Record one tool call. Called by the action dispatcher.
pub fn record(tool: &str, micros: u64, ok: bool) {
    let mut g = stats().lock().unwrap();
    // Keep the map bounded: a typo'd tool name must not grow it forever.
    if g.len() > 256 && !g.contains_key(tool) {
        return;
    }
    g.entry(tool.to_string()).or_default().record(micros, ok);
}

/// Reset the distributions, so a harness run measures only its own work.
pub fn reset() {
    stats().lock().unwrap().clear();
}

/// This process and its children, as far as the OS will tell us without a
/// helper: resident size, CPU time, thread count, live child count.
fn process_footprint() -> Value {
    let pid = std::process::id();
    let mut rss_kb = 0u64;
    let mut cpu_ticks = 0u64;
    let mut threads = 0u64;

    // `/proc` does not exist on macOS; use `ps` for ourselves. One short-lived
    // process, only when metrics are asked for.
    if let Ok(out) = std::process::Command::new("/bin/ps")
        .args(["-o", "rss=,time=,nlwp=", "-p", &pid.to_string()])
        .output()
    {
        let text = String::from_utf8_lossy(&out.stdout);
        let fields: Vec<&str> = text.split_whitespace().collect();
        if let Some(rss) = fields.first().and_then(|f| f.parse::<u64>().ok()) {
            rss_kb = rss;
        }
        if let Some(t) = fields.get(1) {
            // "MM:SS" or "H:MM:SS"
            let secs: u64 = t
                .split(':')
                .filter_map(|p| p.parse::<u64>().ok())
                .fold(0, |acc, p| acc * 60 + p);
            cpu_ticks = secs;
        }
        if let Some(n) = fields.get(2).and_then(|f| f.parse::<u64>().ok()) {
            threads = n;
        }
    }

    // Children: the per-bind workers.
    let mut children: Vec<Value> = Vec::new();
    if let Ok(out) = std::process::Command::new("/bin/ps")
        .args(["-o", "pid=,rss=,command=", "--ppid", &pid.to_string()])
        .output()
    {
        for line in String::from_utf8_lossy(&out.stdout).lines() {
            let mut parts = line.split_whitespace();
            let (Some(cpid), Some(crss)) = (parts.next(), parts.next()) else { continue };
            let command: Vec<&str> = parts.collect();
            children.push(json!({
                "pid": cpid.parse::<u64>().unwrap_or(0),
                "rss_kb": crss.parse::<u64>().unwrap_or(0),
                "command": command.join(" "),
            }));
        }
    }

    json!({
        "pid": pid,
        "rss_mb": round2(rss_kb as f64 / 1024.0),
        "cpu_seconds": cpu_ticks,
        "threads": threads,
        "children": children,
        "children_rss_mb": round2(children.iter().filter_map(|c| c["rss_kb"].as_u64()).sum::<u64>() as f64 / 1024.0),
    })
}

/// The whole metrics document.
pub fn snapshot(actions_total: u64, started_at: u64) -> Value {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let uptime_secs = now.saturating_sub(started_at);
    let g = stats().lock().unwrap();
    let mut tools: Vec<(String, Value)> = g.iter().map(|(k, v)| (k.clone(), v.to_json())).collect();
    tools.sort_by(|a, b| {
        let ap = a.1["p99_ms"].as_f64().unwrap_or(0.0);
        let bp = b.1["p99_ms"].as_f64().unwrap_or(0.0);
        bp.partial_cmp(&ap).unwrap_or(std::cmp::Ordering::Equal)
    });
    let slowest: Vec<Value> = tools.iter().take(8).map(|(k, v)| json!({"tool": k, "stats": v})).collect();
    let per_tool: Value = {
        let mut map = serde_json::Map::new();
        for (k, v) in &tools {
            map.insert(k.clone(), v.clone());
        }
        Value::Object(map)
    };
    let total_count: u64 = g.values().map(|v| v.count).sum();
    let total_errors: u64 = g.values().map(|v| v.errors).sum();
    drop(g);

    json!({
        "uptime_seconds": uptime_secs,
        "actions_total": actions_total,
        "measured_calls": total_count,
        "errors": total_errors,
        "error_rate": if total_count == 0 { 0.0 } else { round2(total_errors as f64 * 100.0 / total_count as f64) },
        "tools": per_tool,
        "slowest": slowest,
        "process": process_footprint(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn percentiles_are_sane() {
        let mut s = ToolStats::default();
        for i in 1..=100u64 {
            s.record(i * 1000, true);
        }
        let (p50, p90, p99, max) = s.percentiles();
        assert!(p50 >= 49_000 && p50 <= 51_000, "p50 was {}", p50);
        assert!(p90 >= 89_000 && p90 <= 91_000, "p90 was {}", p90);
        assert!(p99 >= 98_000, "p99 was {}", p99);
        assert_eq!(max, 100_000);
    }

    #[test]
    fn reservoir_is_bounded() {
        let mut s = ToolStats::default();
        for i in 0..5000u64 {
            s.record(i, true);
        }
        assert_eq!(s.samples.len(), RESERVOIR);
        assert_eq!(s.count, 5000);
    }

    #[test]
    fn errors_are_counted_separately() {
        let mut s = ToolStats::default();
        s.record(100, true);
        s.record(200, false);
        let j = s.to_json();
        assert_eq!(j["count"], 2);
        assert_eq!(j["errors"], 1);
    }

    #[test]
    fn record_and_reset_round_trip() {
        reset();
        record("click", 1500, true);
        record("click", 2500, true);
        let snap = snapshot(2, 10);
        assert_eq!(snap["tools"]["click"]["count"], 2);
        assert_eq!(snap["tools"]["click"]["mean_ms"], 2.0);
        reset();
        let snap = snapshot(0, 0);
        assert!(snap["tools"].as_object().unwrap().is_empty());
    }

    #[test]
    fn snapshot_reports_this_process() {
        let snap = snapshot(0, 0);
        assert!(snap["process"]["rss_mb"].as_f64().unwrap() > 0.0);
        assert_eq!(snap["process"]["pid"], std::process::id());
    }
}
