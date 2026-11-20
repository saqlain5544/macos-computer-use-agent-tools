import Foundation

/// Append-only record of everything the driver does.
///
/// The point is analysis: which tool is slow, which agent does what, where focus
/// moved and whether it came back, and what failed and why. One JSON object per
/// line, so the file is greppable, `jq`-able and streamable, and a crash can
/// never leave a half-written record behind.
///
/// Records are written from the daemon only. A worker is deliberately quiet: it
/// is a pipe with accessibility access, and its time is accounted for in the
/// "worker_ms" phase of the operation that called it.
final class OpLog {
    private let lock = NSLock()
    private var handle: FileHandle?
    private var currentDay = ""
    private var bytesWritten = 0
    private var writesSinceCheck = 0

    /// Rotate at 32 MB: a busy agent day is a few MB, and a runaway loop must not
    /// fill the disk.
    static let maxBytes = 32 * 1024 * 1024
    /// How many rotated files to keep.
    static let keep = 5

    /// The daemon's log. Nil in tests and in any process that is not the daemon,
    /// which makes every call site a no-op rather than a branch.
    static var shared: OpLog?

    let directory: String
    let enabled: Bool

    init(directory: String, enabled: Bool = true) {
        self.directory = directory
        self.enabled = enabled
    }

    // MARK: paths

    static func defaultDirectory() -> String {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? "/tmp"
        return "\(home)/.quiet-driver/logs"
    }

    static var isEnabledByEnvironment: Bool {
        let env = ProcessInfo.processInfo.environment
        if let v = env["QD_OP_LOG"] { return !["0", "false", "off", "no"].contains(v.lowercased()) }
        return true
    }

    private func dayStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd"
        return f.string(from: date)
    }

    private func path(for day: String) -> String {
        "\(directory)/ops-\(day).jsonl"
    }

    // MARK: writing

    /// Write one record. Never throws: a logging failure must not fail the action
    /// it was describing.
    func write(_ record: [String: Any]) {
        guard enabled else { return }
        let now = Date()
        var row = record
        row["ts"] = isoTimestamp(now)
        row["epoch_ms"] = Int(now.timeIntervalSince1970 * 1000)
        let line = jsonString(row) + "\n"
        guard let data = line.data(using: .utf8) else { return }

        lock.lock()
        defer { lock.unlock() }

        let day = dayStamp(now)
        // Every so often, check the file is still there. A handle to a deleted
        // file stays valid, so without this a cleanup would silently swallow the
        // rest of the session's records.
        writesSinceCheck += 1
        // Stat every 16 writes: one stat per 16 records is nothing, and it means
        // a deleted log comes back within a second of activity rather than after
        // a long gap with the records quietly going nowhere.
        let needsCheck = writesSinceCheck >= 16
        if needsCheck { writesSinceCheck = 0 }
        let missing = needsCheck && !FileManager.default.fileExists(atPath: path(for: day))
        if handle == nil || day != currentDay || missing {
            if missing { try? handle?.close(); handle = nil }
            rotateIfNeeded(day: day)
            openLocked(day: day)
        }
        guard let h = handle else { return }
        h.write(data)
        bytesWritten += data.count
    }

    private func openLocked(day: String) {
        try? handle?.close()
        handle = nil
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let file = path(for: day)
        if !FileManager.default.fileExists(atPath: file) {
            FileManager.default.createFile(atPath: file, contents: nil)
        }
        handle = FileHandle(forWritingAtPath: file)
        handle?.seekToEndOfFile()
        bytesWritten = (try? FileManager.default.attributesOfItem(atPath: file))?[.size] as? Int ?? 0
        currentDay = day
    }

    /// Rotate the day's file when it gets too big, keeping a bounded number.
    private func rotateIfNeeded(day: String) {
        let file = path(for: day)
        guard let size = (try? FileManager.default.attributesOfItem(atPath: file))?[.size] as? Int,
              size >= OpLog.maxBytes else { return }
        try? handle?.close()
        handle = nil
        let stamp = Int(Date().timeIntervalSince1970)
        let rotated = "\(directory)/ops-\(day)-\(stamp).jsonl"
        try? FileManager.default.moveItem(atPath: file, toPath: rotated)
        prune()
    }

    private func prune() {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return }
        let files = names.filter { $0.hasPrefix("ops-") && $0.hasSuffix(".jsonl") }.sorted()
        for name in files.dropLast(OpLog.keep) {
            try? FileManager.default.removeItem(atPath: "\(directory)/\(name)")
        }
    }

    func close() {
        lock.lock()
        try? handle?.close()
        handle = nil
        lock.unlock()
    }

    // MARK: reading

    /// The most recent records, newest last. `limit` caps the work, and the
    /// filters are cheap predicates rather than a query language.
    func read(limit: Int = 200, agent: String? = nil, tool: String? = nil,
              onlyFailures: Bool = false, sinceSeconds: Int? = nil) -> [[String: Any]] {
        let cutoff = sinceSeconds.map { Date().addingTimeInterval(-Double($0)) }
        var out: [[String: Any]] = []
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return [] }
        for name in names.filter({ $0.hasPrefix("ops-") && $0.hasSuffix(".jsonl") }).sorted() {
            guard let text = try? String(contentsOfFile: "\(directory)/\(name)", encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                guard let obj = jsonObject(String(line)) else { continue }
                if let a = agent, (obj["agent"] as? String) != a { continue }
                if let t = tool, (obj["tool"] as? String) != t { continue }
                if onlyFailures, (obj["ok"] as? Bool) != false { continue }
                if let cut = cutoff {
                    let ts = (obj["epoch_ms"] as? Int).map { Date(timeIntervalSince1970: Double($0) / 1000) }
                    if let ts = ts, ts < cut { continue }
                }
                out.append(obj)
            }
        }
        if out.count > limit { out = Array(out.suffix(limit)) }
        return out
    }

    /// A summary of recent activity: what is slow, what fails, who is working.
    func summary(sinceSeconds: Int = 3600) -> [String: Any] {
        let rows = read(limit: 50_000, sinceSeconds: sinceSeconds)
        var byTool: [String: [Double]] = [:]
        var failures: [String: Int] = [:]
        var byAgent: [String: Int] = [:]
        var focusEvents = 0
        var pointerMoves = 0
        var totalMs = 0.0
        var events: [String: Int] = [:]

        for row in rows {
            // Lifecycle records (worker start, screen lock, mode change) are not
            // operations: counting them as tools made "worker_start" show up in
            // the latency table with a 0 ms p99.
            guard (row["kind"] as? String) == "op" else {
                events[(row["kind"] as? String) ?? "event", default: 0] += 1
                continue
            }
            let tool = (row["tool"] as? String) ?? "?"
            let ms = (row["duration_ms"] as? Double) ?? 0
            byTool[tool, default: []].append(ms)
            totalMs += ms
            if (row["ok"] as? Bool) == false {
                let err = (row["error"] as? String) ?? "?"
                failures[String(err.prefix(80)), default: 0] += 1
            }
            if let a = row["agent"] as? String, !a.isEmpty { byAgent[a, default: 0] += 1 }
            if let focus = row["focus"] as? [String: Any], (focus["changed"] as? Bool) == true { focusEvents += 1 }
            if (row["pointer_moved"] as? Bool) == true { pointerMoves += 1 }
        }

        func percentiles(_ values: [Double]) -> [String: Any] {
            guard !values.isEmpty else { return ["count": 0] }
            let sorted = values.sorted()
            func at(_ p: Double) -> Double {
                let i = min(sorted.count - 1, max(0, Int((p / 100 * Double(sorted.count)).rounded(.down))))
                return round2(sorted[i])
            }
            return ["count": sorted.count, "p50_ms": at(50), "p95_ms": at(95),
                    "p99_ms": at(99), "max_ms": round2(sorted.last ?? 0),
                    "mean_ms": round2(sorted.reduce(0, +) / Double(sorted.count))]
        }

        let tools = byTool.mapValues(percentiles)
        let slowest = tools.sorted { a, b in
            ((a.value["p99_ms"] as? Double) ?? 0) > ((b.value["p99_ms"] as? Double) ?? 0)
        }.prefix(10).map { [$0.key: $0.value] }

        return [
            "window_seconds": sinceSeconds,
            "records": rows.count,
            "tools": tools,
            "slowest": Array(slowest),
            "failures": failures,
            "agents": byAgent,
            "events": events,
            "focus_events": focusEvents,
            "pointer_moves": pointerMoves,
            "total_seconds": round2(totalMs / 1000),
            "log_directory": directory,
        ]
    }
}

/// Keep a log record readable: one value per argument, strings bounded, and no
/// giant payloads. The point is to see what happened, not to store the contents
/// of a document.
func loggableArguments(_ args: [String: Any]) -> [String: Any] {
    var out: [String: Any] = [:]
    for (key, value) in args {
        switch value {
        case let s as String:
            out[key] = s.count > 120 ? String(s.prefix(120)) + "…" : s
        case let n as NSNumber:
            out[key] = n
        case let b as Bool:
            out[key] = b
        case let arr as [Any]:
            out[key] = "[\(arr.count) items]"
        case let dict as [String: Any]:
            out[key] = "{\(dict.keys.sorted().joined(separator: ","))}"
        default:
            out[key] = String(describing: value)
        }
    }
    return out
}

func isoTimestamp(_ date: Date) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    f.timeZone = TimeZone.current
    return f.string(from: date)
}
