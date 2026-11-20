//! One worker per bound app.
//!
//! The daemon is a single process: it owns the lock, the state, and the
//! HTTP/MCP surfaces. Talking to an app is a different job, and it should not
//! be shared between apps — a slow call against one app must not block work on
//! another, and a crash in one worker must not take the driver down.
//!
//! So each bound app gets its own worker process (the Swift helper). Workers are
//! created lazily on first use, keyed by the app's identity (its bundle id) so a
//! quit-and-relaunch reuses the same slot, and reaped when the binding is
//! released. The pointer tracker stays in the daemon, because it is a property
//! of the person's session rather than of any one app.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use crate::helper::{Helper, Point};

pub struct WorkerPool {
    script: std::path::PathBuf,
    workers: Mutex<HashMap<String, Arc<Helper>>>,
    /// The agent's virtual cursor. Session state, not app state.
    pointer: Mutex<Point>,
}

impl WorkerPool {
    pub fn new(script: std::path::PathBuf) -> Self {
        WorkerPool {
            script,
            workers: Mutex::new(HashMap::new()),
            pointer: Mutex::new(Point::default()),
        }
    }

    /// The worker for an app, created on first use.
    ///
    /// The map lock is held only to fetch or insert the handle; the actual
    /// spawn happens outside it, so a slow start does not block other apps.
    pub fn for_app(&self, identity: &str) -> Arc<Helper> {
        let key = if identity.is_empty() { "unknown" } else { identity };
        if let Some(existing) = self.workers.lock().unwrap().get(key) {
            return existing.clone();
        }
        let fresh = Arc::new(Helper::new(self.script.clone()));
        let mut guard = self.workers.lock().unwrap();
        // Another thread may have inserted while we were spawning; prefer the
        // one that is already there so both callers share a single worker.
        guard.entry(key.to_string()).or_insert(fresh).clone()
    }

    /// A worker for an app that has no binding yet (the startup probe, the
    /// dashboard's own reads). Keyed separately so it never masquerades as an
    /// app worker.
    pub fn session(&self) -> Arc<Helper> {
        self.for_app("__session__")
    }

    /// Drop a worker: its helper process exits when the handle is released.
    pub fn release(&self, identity: &str) {
        self.workers.lock().unwrap().remove(identity);
    }

    /// How many worker processes exist right now.
    pub fn len(&self) -> usize {
        self.workers.lock().unwrap().len()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// Identities that currently have a worker.
    pub fn identities(&self) -> Vec<String> {
        self.workers.lock().unwrap().keys().cloned().collect()
    }

    pub fn pointer_now(&self) -> Point {
        let helper = self.session();
        let p = helper.pointer_now();
        if p.x != 0.0 || p.y != 0.0 {
            *self.pointer.lock().unwrap() = p;
        }
        *self.pointer.lock().unwrap()
    }

    pub fn pointer_since(&self, before: Point) -> bool {
        let now = self.pointer_now();
        (now.x - before.x).abs() > 0.5 || (now.y - before.y).abs() > 0.5
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pool() -> WorkerPool {
        WorkerPool::new(std::path::PathBuf::from("/nonexistent/helper.swift"))
    }

    #[test]
    fn the_same_app_gets_the_same_worker() {
        let p = pool();
        let a = p.for_app("com.apple.calculator");
        let b = p.for_app("com.apple.calculator");
        assert!(Arc::ptr_eq(&a, &b));
        assert_eq!(p.len(), 1);
    }

    #[test]
    fn different_apps_get_different_workers() {
        let p = pool();
        let a = p.for_app("com.apple.calculator");
        let b = p.for_app("com.apple.TextEdit");
        assert!(!Arc::ptr_eq(&a, &b));
        assert_eq!(p.len(), 2);
    }

    #[test]
    fn releasing_a_worker_lets_it_be_replaced() {
        let p = pool();
        let a = p.for_app("com.apple.calculator");
        p.release("com.apple.calculator");
        assert_eq!(p.len(), 0);
        let b = p.for_app("com.apple.calculator");
        assert!(!Arc::ptr_eq(&a, &b), "a released worker must not come back");
    }

    #[test]
    fn the_session_worker_is_separate() {
        let p = pool();
        let _ = p.for_app("com.apple.calculator");
        let s = p.session();
        let again = p.session();
        assert!(Arc::ptr_eq(&s, &again));
        assert_eq!(p.len(), 2);
        assert!(p.identities().contains(&"__session__".to_string()));
    }
}
