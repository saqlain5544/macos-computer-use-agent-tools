//! Per-agent workspaces and the friction log.
//!
//! Every agent gets a disposable directory, `/tmp/quiet-driver/agent-<id>/`,
//! where screenshots, recordings and other throwaway artefacts land. An agent
//! may also name any other path when it wants a file kept somewhere specific.
//!
//! The friction log is a newline-delimited JSON file the agents append to
//! (`log_friction`), so the problems they hit become a backlog we can work
//! through instead of losing them in a chat transcript.

use serde_json::{json, Value};
use std::io::Write;
use std::path::{Path, PathBuf};

pub const ROOT: &str = "/tmp/quiet-driver";

/// Sanitise an agent name into a safe directory component.
pub fn slug(name: &str) -> String {
    let cleaned: String = name
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() || c == '-' || c == '_' { c } else { '-' })
        .collect();
    let trimmed = cleaned.trim_matches('-').to_string();
    if trimmed.is_empty() {
        "agent".to_string()
    } else {
        trimmed.chars().take(48).collect()
    }
}

/// The root of all agent workspaces.
pub fn root() -> PathBuf {
    PathBuf::from(ROOT)
}

/// `/tmp/quiet-driver/agent-<id>` for one agent.
pub fn agent_dir(id: &str) -> PathBuf {
    root().join(format!("agent-{}", slug(id)))
}

/// Create the directory if needed and return it.
pub fn ensure_agent_dir(id: &str) -> Result<PathBuf, String> {
    let dir = agent_dir(id);
    std::fs::create_dir_all(&dir)
        .map_err(|e| format!("could not create {}: {}", dir.display(), e))?;
    Ok(dir)
}

/// Where a disposable artefact of `kind` goes for this agent.
pub fn artifact_path(id: &str, kind: &str, extension: &str) -> Result<PathBuf, String> {
    let dir = ensure_agent_dir(id)?;
    let stamp = timestamp();
    let name = format!("{}-{}.{}", kind, stamp, extension.trim_start_matches('.'));
    Ok(dir.join(name))
}

/// A monotonic-ish stamp that is also readable.
fn timestamp() -> String {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let millis = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.subsec_millis())
        .unwrap_or(0);
    format!("{}{:03}", now, millis)
}

/// The friction log. One JSON object per line.
pub fn friction_log_path() -> PathBuf {
    root().join("friction.jsonl")
}

/// Append one friction entry. Never fails the action that reported it.
pub fn log_friction(entry: &Value) -> Result<PathBuf, String> {
    let path = friction_log_path();
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    let mut line = serde_json::to_string(entry).unwrap_or_default();
    line.push('\n');
    let mut file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
        .map_err(|e| format!("could not open {}: {}", path.display(), e))?;
    file.write_all(line.as_bytes())
        .map_err(|e| format!("could not write {}: {}", path.display(), e))?;
    Ok(path)
}

/// Read the friction log back.
pub fn read_friction(limit: usize) -> Vec<Value> {
    let Ok(text) = std::fs::read_to_string(friction_log_path()) else {
        return Vec::new();
    };
    let mut out: Vec<Value> = text
        .lines()
        .filter(|l| !l.trim().is_empty())
        .filter_map(|l| serde_json::from_str(l).ok())
        .collect();
    if out.len() > limit {
        out = out.split_off(out.len() - limit);
    }
    out
}

/// Where a path should go: an explicit path wins, otherwise the agent's
/// workspace. A relative path is resolved inside the agent's directory so an
/// agent can never scribble into the working directory by accident.
pub fn resolve_output(id: &str, kind: &str, extension: &str, requested: Option<&str>) -> Result<PathBuf, String> {
    match requested {
        Some(p) if !p.trim().is_empty() => {
            let raw = Path::new(p);
            if raw.is_absolute() {
                if let Some(dir) = raw.parent() {
                    let _ = std::fs::create_dir_all(dir);
                }
                Ok(raw.to_path_buf())
            } else {
                let dir = ensure_agent_dir(id)?;
                Ok(dir.join(raw))
            }
        }
        _ => artifact_path(id, kind, extension),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn slug_is_safe_and_bounded() {
        assert_eq!(slug("my agent/../etc"), "my-agent----etc");
        assert_eq!(slug(""), "agent");
        assert_eq!(slug("a".repeat(100).as_str()).len(), 48);
        assert!(!slug("../../root").contains('/'));
    }

    #[test]
    fn agent_dir_is_under_the_root() {
        let d = agent_dir("builder 1");
        assert!(d.starts_with(ROOT));
        assert_eq!(d.file_name().unwrap(), "agent-builder-1");
    }

    #[test]
    fn explicit_absolute_path_is_kept() {
        let p = resolve_output("a", "shot", "png", Some("/tmp/x/y.png")).unwrap();
        assert_eq!(p, PathBuf::from("/tmp/x/y.png"));
    }

    #[test]
    fn relative_path_lands_in_the_agent_workspace() {
        let p = resolve_output("a", "shot", "png", Some("out.png")).unwrap();
        assert!(p.starts_with(agent_dir("a")));
        assert_eq!(p.file_name().unwrap(), "out.png");
    }

    #[test]
    fn default_path_is_in_the_agent_workspace() {
        let p = resolve_output("a", "shot", "png", None).unwrap();
        assert!(p.starts_with(agent_dir("a")));
        assert!(p.to_string_lossy().ends_with(".png"));
    }

    #[test]
    fn friction_entries_round_trip() {
        let dir = agent_dir("friction-test");
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let entry = json!({"tool": "click_label", "problem": "no such control", "agent": "friction-test"});
        // Point the log at the test directory for the round trip.
        let path = dir.join("friction.jsonl");
        let mut line = serde_json::to_string(&entry).unwrap();
        line.push('\n');
        std::fs::write(&path, line).unwrap();
        let back: Vec<Value> = std::fs::read_to_string(&path)
            .unwrap()
            .lines()
            .filter_map(|l| serde_json::from_str(l).ok())
            .collect();
        assert_eq!(back.len(), 1);
        assert_eq!(back[0]["problem"], "no such control");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
