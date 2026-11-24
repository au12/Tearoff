import Darwin
import Foundation
import TearoffCore

/// Where labels go.
public enum PrinterTarget: Codable, Hashable, CustomStringConvertible {
    /// Raw TCP (port 9100) straight to a network printer.
    case network(host: String, port: Int)
    /// A macOS print queue, fed raw ZPL (works for USB printers too).
    case queue(name: String)

    public var description: String {
        switch self {
        case .network(let h, let p): return p == 9100 ? h : "\(h):\(p)"
        case .queue(let n): return n
        }
    }

    /// "10.0.10.50", "10.0.10.50:9100" or "queue:Zebra_GX420d".
    public init?(string: String) {
        let s = string.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        if s.hasPrefix("queue:") { self = .queue(name: String(s.dropFirst(6))); return }
        if let u = URL(string: s), let scheme = u.scheme, ["socket", "tcp", "raw"].contains(scheme), let h = u.host {
            self = .network(host: h, port: u.port ?? 9100); return
        }
        let parts = s.split(separator: ":")
        if parts.count == 2, let p = Int(parts[1]) { self = .network(host: String(parts[0]), port: p); return }
        self = .network(host: s, port: 9100)
    }
}

/// Blocking TCP client (POSIX sockets) with timeouts; used off the main thread.
public final class TCPClient {
    let fd: Int32

    public init(host: String, port: Int, timeout: TimeInterval) throws {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>? = nil
        let rc = getaddrinfo(host, String(port), &hints, &res)
        guard rc == 0, let first = res else {
            throw TearoffError.printer("Can’t find printer “\(host)” on the network.")
        }
        defer { freeaddrinfo(res) }
        var ai: UnsafeMutablePointer<addrinfo>? = first
        var connected: Int32 = -1
        while let a = ai, connected < 0 {
            let s = socket(a.pointee.ai_family, a.pointee.ai_socktype, a.pointee.ai_protocol)
            if s >= 0 {
                var one: Int32 = 1
                setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                let flags = fcntl(s, F_GETFL, 0)
                _ = fcntl(s, F_SETFL, flags | O_NONBLOCK)
                let c = connect(s, a.pointee.ai_addr, a.pointee.ai_addrlen)
                var ok = c == 0
                if !ok && errno == EINPROGRESS {
                    var p = pollfd(fd: s, events: Int16(POLLOUT), revents: 0)
                    if poll(&p, 1, Int32(timeout * 1000)) == 1 {
                        var err: Int32 = 0
                        var len = socklen_t(MemoryLayout<Int32>.size)
                        getsockopt(s, SOL_SOCKET, SO_ERROR, &err, &len)
                        ok = err == 0
                    }
                }
                if ok {
                    _ = fcntl(s, F_SETFL, flags)
                    connected = s
                } else {
                    close(s)
                }
            }
            ai = a.pointee.ai_next
        }
        guard connected >= 0 else {
            throw TearoffError.printer("Couldn’t connect to \(host):\(port). Is the printer on and on this network?")
        }
        fd = connected
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - Double(Int(timeout))) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    deinit { close(fd) }

    public func send(_ data: Data) throws {
        try data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            guard let base = buf.baseAddress else { return }
            var off = 0
            while off < buf.count {
                let n = Darwin.send(fd, base + off, buf.count - off, 0)
                if n <= 0 { throw TearoffError.printer("The printer stopped accepting data (\(String(cString: strerror(errno)))).") }
                off += n
            }
        }
    }

    /// Reads until `idle` seconds pass with no data (or `limit` bytes / `timeout` overall).
    public func receive(timeout: TimeInterval, idle: TimeInterval = 0.35, until done: ((Data) -> Bool)? = nil, limit: Int = 1 << 20) -> Data {
        var out = Data()
        let deadline = Date().addingTimeInterval(timeout)
        var buf = [UInt8](repeating: 0, count: 8192)
        while Date() < deadline && out.count < limit {
            let wait = out.isEmpty ? deadline.timeIntervalSinceNow : min(idle, deadline.timeIntervalSinceNow)
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            if poll(&p, 1, Int32(max(1, wait * 1000))) != 1 { break }
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { break }
            out.append(contentsOf: buf[0..<n])
            if let d = done, d(out) { break }
        }
        return out
    }
}

public enum ZebraPrinter {

    /// Sends a raw job (ZPL) to the target.
    public static func send(_ job: String, to target: PrinterTarget, title: String = "Tearoff label") throws {
        let data = Data(job.utf8)
        switch target {
        case .network(let host, let port):
            let c = try TCPClient(host: host, port: port, timeout: 5)
            try c.send(data)
            // give the print server a moment to drain before we close
            _ = c.receive(timeout: 0.2, idle: 0.1)
        case .queue(let name):
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("tearoff-\(UUID().uuidString).zpl")
            try data.write(to: tmp)
            defer { try? FileManager.default.removeItem(at: tmp) }
            let r = Shell.run("/usr/bin/lp", ["-d", name, "-o", "raw", "-t", title, tmp.path])
            if r.status != 0 {
                throw TearoffError.printer("macOS couldn’t queue the label on “\(name)”: \(r.output.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }
    }

    /// Sends a ~ command and collects the STX…ETX framed reply.
    public static func query(_ command: String, host: String, port: Int = 9100, frames: Int = 1, timeout: TimeInterval = 2.5) throws -> String {
        let c = try TCPClient(host: host, port: port, timeout: min(timeout, 3))
        try c.send(Data(command.utf8))
        let data = c.receive(timeout: timeout, idle: 0.4) { d in d.filter { $0 == 3 }.count >= frames }
        return String(decoding: data, as: UTF8.self)
    }

    public static func status(host: String, port: Int = 9100) throws -> ZebraStatus {
        let reply = try query("~HS", host: host, port: port, frames: 3)
        guard let s = ZebraStatus.parse(reply) else { throw TearoffError.printer("The printer didn’t answer the status request.") }
        return s
    }

    public static func identity(host: String, port: Int = 9100) throws -> ZebraIdentity {
        let reply = try query("~HI", host: host, port: port, frames: 1)
        guard let i = ZebraIdentity.parse(reply) else { throw TearoffError.printer("The printer didn’t identify itself.") }
        return i
    }

    /// Calibrates the media sensor (feeds a few labels).
    public static func calibrate(_ target: PrinterTarget) throws { try send("~JC", to: target, title: "Calibrate") }

    /// Feeds one blank label.
    public static func feed(_ target: PrinterTarget) throws { try send("^XA^XZ", to: target, title: "Feed") }

    /// Prints the printer's own configuration label.
    public static func printConfiguration(_ target: PrinterTarget) throws { try send("~WC", to: target, title: "Configuration") }
}

/// Runs a command and captures its output.
public enum Shell {
    public struct Result { public var status: Int32; public var output: String }

    @discardableResult
    public static func run(_ path: String, _ args: [String], input: Data? = nil) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        let inPipe = Pipe()
        if input != nil { p.standardInput = inPipe }
        do { try p.run() } catch { return Result(status: -1, output: error.localizedDescription) }
        if let input = input {
            inPipe.fileHandleForWriting.write(input)
            try? inPipe.fileHandleForWriting.close()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Result(status: p.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}
