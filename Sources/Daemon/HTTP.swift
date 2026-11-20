import Foundation

/// Minimal loopback HTTP client. The daemon owns all state, so a dashboard or a
/// bridge only ever needs to read and post JSON to it.
enum HTTP {
    static func request(port: UInt16, method: String, path: String, body: String?) -> Data? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var tv = timeval(tv_sec: 30, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &addr) { ptr -> Bool in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        guard connected else { return nil }

        let payload = body ?? ""
        var head = "\(method) \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n"
        if body != nil {
            head += "Content-Type: application/json\r\nContent-Length: \(payload.utf8.count)\r\n"
        }
        head += "\r\n\(payload)"
        let out = Data(head.utf8)
        out.withUnsafeBytes { ptr in
            var sent = 0
            while sent < out.count {
                let n = write(fd, ptr.baseAddress!.advanced(by: sent), out.count - sent)
                if n <= 0 { break }
                sent += n
            }
        }
        var raw = Data()
        var buffer = [UInt8](repeating: 0, count: 32 * 1024)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            raw.append(contentsOf: buffer[0..<n])
        }
        guard let sep = raw.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        return raw[sep.upperBound...]
    }

    static func getJSON(port: UInt16, path: String) -> [String: Any]? {
        guard let data = request(port: port, method: "GET", path: path, body: nil) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    @discardableResult
    static func postJSON(port: UInt16, path: String, body: String) -> String? {
        guard let data = request(port: port, method: "POST", path: path, body: body) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
