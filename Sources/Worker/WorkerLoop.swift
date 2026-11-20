import Foundation

// One message in, one JSON line out, forever.
//
// The whole iteration runs inside an explicit autorelease pool. This process is
// a readLine() loop with no run loop, so no pool is ever drained for us: the
// bridged collections and strings that Foundation creates for each request pile
// up, and the worker grows by several KB per action — tens of MB over a working
// session. Pooling the iteration keeps the working set flat.
func runWorkerLoop() -> Never {
    setvbuf(stdout, nil, _IOLBF, 0)
    while autoreleasepool(invoking: { () -> Bool in
        // If the daemon that spawned us is gone, we are an orphan: exit rather
        // than sit on an AX connection for the rest of the session.
        if getppid() == 1 { return false }
        guard let line = readLine(strippingNewline: true) else { return false }
        if line.isEmpty { return true }
        guard let data = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            print("{\"ok\":false,\"error\":\"bad json\"}")
            return true
        }
        let reply = handle(obj)
        if let out = try? JSONSerialization.data(withJSONObject: reply),
           let text = String(data: out, encoding: .utf8) {
            print(text)
        } else {
            print("{\"ok\":false,\"error\":\"encode failed\"}")
        }
        return (obj["cmd"] as? String) != "quit"
    }) {}
    exit(0)
}
