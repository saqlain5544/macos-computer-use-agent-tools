import Foundation

/// Agent workspaces and the friction log.
///
/// Everything disposable lives under /tmp/quiet-driver so a test session leaves
/// nothing behind in the project or the person's home directory.
enum Workspace {
    static let root = "/tmp/quiet-driver"

    /// Sanitise an agent name into a safe directory component.
    static func slug(_ name: String) -> String {
        var cleaned = ""
        for ch in name {
            if ch.isLetter || ch.isNumber || ch == "-" || ch == "_" {
                cleaned.append(ch)
            } else {
                cleaned.append("-")
            }
        }
        let trimmed = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if trimmed.isEmpty { return "agent" }
        return String(trimmed.prefix(48))
    }

    static func agentDir(_ id: String) -> String {
        "\(root)/agent-\(slug(id))"
    }

    @discardableResult
    static func ensureAgentDir(_ id: String) throws -> String {
        let dir = agentDir(id)
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        } catch {
            throw SessionError.failed("could not create \(dir): \(error.localizedDescription)")
        }
        return dir
    }

    /// A readable, monotonic-enough stamp for artifact names.
    private static func timestamp() -> String {
        let now = Date()
        let secs = UInt64(now.timeIntervalSince1970)
        let millis = UInt64((now.timeIntervalSince1970 - Double(secs)) * 1000)
        return String(format: "%llu%03llu", secs, millis)
    }

    static func artifactPath(_ id: String, _ kind: String, _ ext: String) throws -> String {
        let dir = try ensureAgentDir(id)
        let cleanExt = ext.hasPrefix(".") ? String(ext.dropFirst()) : ext
        return "\(dir)/\(kind)-\(timestamp()).\(cleanExt)"
    }

    /// Where a path should go: an explicit path wins, otherwise the agent's
    /// workspace. A relative path resolves inside the agent directory so an
    /// agent can never scribble into the working directory by accident.
    static func resolveOutput(_ id: String, _ kind: String, _ ext: String, requested: String?) throws -> String {
        if let raw = requested?.trimmingCharacters(in: .whitespaces), !raw.isEmpty {
            if raw.hasPrefix("/") {
                let dir = (raw as NSString).deletingLastPathComponent
                if !dir.isEmpty {
                    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                }
                return raw
            }
            let dir = try ensureAgentDir(id)
            return "\(dir)/\(raw)"
        }
        return try artifactPath(id, kind, ext)
    }

    // MARK: friction log

    static var frictionLogPath: String { "\(root)/friction.jsonl" }

    @discardableResult
    static func logFriction(_ entry: [String: Any]) throws -> String {
        let path = frictionLogPath
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let line = jsonString(entry) + "\n"
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        guard let fh = FileHandle(forWritingAtPath: path) else {
            throw SessionError.failed("could not open \(path)")
        }
        defer { try? fh.close() }
        fh.seekToEndOfFile()
        fh.write(line.data(using: .utf8) ?? Data())
        return path
    }

    static func readFriction(limit: Int) -> [[String: Any]] {
        guard let text = try? String(contentsOfFile: frictionLogPath, encoding: .utf8) else { return [] }
        var out: [[String: Any]] = []
        for line in text.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            if let obj = jsonObject(String(line)) { out.append(obj) }
        }
        if out.count > limit { out = Array(out.suffix(limit)) }
        return out
    }

    /// Files an agent has produced, for the dashboard and `workspace`.
    static func listFiles(_ id: String) -> [[String: Any]] {
        let dir = agentDir(id)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        return names.sorted().map { name in
            let path = "\(dir)/\(name)"
            let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int ?? 0
            return ["name": name, "bytes": size]
        }
    }
}

/// Per-tool latency, measured inside the daemon.
///
/// The harness measures end-to-end over HTTP; this measures the same calls
/// without the HTTP layer, which is how a regression is attributed to a tool
/// rather than to the socket.
final class Metrics {
    private struct Stats {
        var count = 0
        var errors = 0
        var samples: [Double] = []   // milliseconds, capped
    }

    private let lock = NSLock()
    private var stats: [String: Stats] = [:]
    private let cap = 512
    private let startedAt = UInt64(Date().timeIntervalSince1970)

    func record(_ tool: String, micros: Double, ok: Bool) {
        lock.lock()
        var s = stats[tool] ?? Stats()
        s.count += 1
        if !ok { s.errors += 1 }
        if s.samples.count >= cap { s.samples.removeFirst(s.samples.count - cap + 1) }
        s.samples.append(micros / 1000.0)
        stats[tool] = s
        lock.unlock()
    }

    func reset() {
        lock.lock(); stats.removeAll(); lock.unlock()
    }

    /// Process footprint of the daemon and its workers, read from `ps`.
    private func footprint() -> [String: Any] {
        let pid = ProcessInfo.processInfo.processIdentifier
        var rssMB = 0.0, cpuSeconds = 0.0
        var threads = 0
        var children: [[String: Any]] = []

        if let out = runPS(["-o", "rss=,time=,nlwp=", "-p", "\(pid)"]) {
            let f = out.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
            if f.count >= 3 {
                rssMB = (Double(f[0]) ?? 0) / 1024.0
                cpuSeconds = parseTime(f[1])
                threads = Int(f[2]) ?? 0
            }
        }
        if let out = runPS(["-o", "pid=,rss=,time=", "-p", "\(pid)", "--ppid", "\(pid)"]) {
            for line in out.split(separator: "\n") {
                let f = line.split(whereSeparator: { $0 == " " }).map(String.init)
                if f.count >= 3, Int(f[0]) != Int(pid) {
                    children.append(["pid": Int(f[0]) ?? 0,
                                     "rss_mb": round2((Double(f[1]) ?? 0) / 1024.0),
                                     "cpu_s": parseTime(f[2])])
                }
            }
        }
        return [
            "pid": Int(pid),
            "rss_mb": round2(rssMB),
            "cpu_s": round2(cpuSeconds),
            "threads": threads,
            "children": children,
        ]
    }

    private func runPS(_ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    private func parseTime(_ s: String) -> Double {
        // ps reports mm:ss.ss or hh:mm:ss
        let parts = s.split(separator: ":").map { Double($0) ?? 0 }
        switch parts.count {
        case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
        case 2: return parts[0] * 60 + parts[1]
        default: return parts.first ?? 0
        }
    }

    func snapshot(actionsTotal: UInt64) -> [String: Any] {
        lock.lock()
        let copy = stats
        lock.unlock()

        func percentile(_ sorted: [Double], _ p: Double) -> Double {
            if sorted.isEmpty { return 0 }
            let idx = min(sorted.count - 1, max(0, Int((p / 100.0 * Double(sorted.count)).rounded(.down))))
            return sorted[idx]
        }

        var tools: [(String, [String: Any], Double)] = []
        var totalCount = 0, totalErrors = 0
        for (name, s) in copy {
            let sorted = s.samples.sorted()
            let p50 = percentile(sorted, 50)
            let p90 = percentile(sorted, 90)
            let p99 = percentile(sorted, 99)
            let maxV = sorted.last ?? 0
            let mean = sorted.isEmpty ? 0 : sorted.reduce(0, +) / Double(sorted.count)
            totalCount += s.count
            totalErrors += s.errors
            tools.append((name, [
                "count": s.count,
                "errors": s.errors,
                "p50_ms": round2(p50),
                "p90_ms": round2(p90),
                "p99_ms": round2(p99),
                "max_ms": round2(maxV),
                "mean_ms": round2(mean),
            ], p99))
        }
        tools.sort { $0.2 > $1.2 }

        var perTool: [String: Any] = [:]
        for (name, value, _) in tools { perTool[name] = value }
        let slowest: [[String: Any]] = tools.prefix(8).map { ["tool": $0.0, "stats": $0.1] }

        return [
            "uptime_seconds": Int(Date().timeIntervalSince1970) - Int(startedAt),
            "actions_total": Int(actionsTotal),
            "measured_calls": totalCount,
            "errors": totalErrors,
            "error_rate": totalCount == 0 ? 0.0 : round2(Double(totalErrors) * 100.0 / Double(totalCount)),
            "tools": perTool,
            "slowest": slowest,
            "process": footprint(),
        ]
    }
}

func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }
