import Darwin
import Foundation
import TearoffCore

public struct QueueInfo: Identifiable, Hashable {
    public var name: String
    public var uri: String
    public var id: String { name }
    public init(name: String, uri: String) { self.name = name; self.uri = uri }
}

public struct DiscoveredPrinter: Identifiable, Hashable {
    public var id: String {
        if case .usb(let uri) = target { return uri }
        return target.description
    }
    /// Plugged in by USB (not on the network).
    public var isUSB: Bool { target.isUSB }
    public var target: PrinterTarget
    public var name: String
    public var detail: String
    /// We're confident it speaks ZPL.
    public var isZebra: Bool
    public var dpi: Int?

    public init(target: PrinterTarget, name: String, detail: String, isZebra: Bool, dpi: Int?) {
        self.target = target; self.name = name; self.detail = detail; self.isZebra = isZebra; self.dpi = dpi
    }
}

/// Finds Zebra printers without ever sending them anything that could print: a TCP connect scan
/// of port 9100 on the local subnet, then the printer's own web page (port 80) to recognise a
/// Zebra print server. Only confirmed Zebras are then asked ~HI for model and resolution.
public enum Discovery {

    public struct Subnet { public var address: UInt32; public var mask: UInt32; public var interface: String }

    public static func localSubnets() -> [Subnet] {
        var out: [Subnet] = []
        var ifap: UnsafeMutablePointer<ifaddrs>? = nil
        guard getifaddrs(&ifap) == 0, let first = ifap else { return out }
        defer { freeifaddrs(ifap) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = p {
            defer { p = ifa.pointee.ifa_next }
            let flags = Int32(ifa.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  let nm = ifa.pointee.ifa_netmask else { continue }
            let a = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let m = nm.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let name = String(cString: ifa.pointee.ifa_name)
            if name.hasPrefix("utun") || name.hasPrefix("awdl") || name.hasPrefix("llw") || name.hasPrefix("bridge") { continue }
            if a >> 16 == 0xA9FE { continue }   // 169.254 link-local
            out.append(Subnet(address: a, mask: m, interface: name))
        }
        return out
    }

    static func hosts(in s: Subnet) -> [UInt32] {
        var mask = s.mask
        if mask.nonzeroBitCount < 22 { mask = 0xFFFF_FF00 }   // huge networks: just our /24
        let net = s.address & mask, bcast = net | ~mask
        guard bcast > net + 1 else { return [] }
        return ((net + 1)..<bcast).filter { $0 != s.address }
    }

    static func ipString(_ a: UInt32) -> String { "\(a >> 24).\((a >> 16) & 255).\((a >> 8) & 255).\(a & 255)" }

    /// Hosts accepting TCP connections on `port` (non-blocking connect, no data sent).
    public static func openHosts(_ hosts: [UInt32], port: UInt16, timeout: TimeInterval) -> [UInt32] {
        var open: [UInt32] = []
        var start = 0
        while start < hosts.count {
            let batch = hosts[start..<min(hosts.count, start + 128)]
            start += 128
            var pending: [(Int32, UInt32)] = []
            for h in batch {
                let fd = socket(AF_INET, SOCK_STREAM, 0)
                if fd < 0 { continue }
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
                var one: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                var sa = sockaddr_in()
                sa.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                sa.sin_family = sa_family_t(AF_INET)
                sa.sin_port = port.bigEndian
                sa.sin_addr.s_addr = h.bigEndian
                let rc = withUnsafePointer(to: &sa) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                }
                if rc == 0 || errno == EINPROGRESS { pending.append((fd, h)) } else { close(fd) }
            }
            let deadline = Date().addingTimeInterval(timeout)
            while !pending.isEmpty && Date() < deadline {
                var pfds = pending.map { pollfd(fd: $0.0, events: Int16(POLLOUT), revents: 0) }
                let n = poll(&pfds, nfds_t(pfds.count), Int32(max(1, deadline.timeIntervalSinceNow * 1000)))
                if n <= 0 { break }
                var still: [(Int32, UInt32)] = []
                for (i, p) in pfds.enumerated() {
                    if p.revents != 0 {
                        var err: Int32 = 0
                        var len = socklen_t(MemoryLayout<Int32>.size)
                        getsockopt(p.fd, SOL_SOCKET, SO_ERROR, &err, &len)
                        if err == 0 && (p.revents & Int16(POLLOUT)) != 0 { open.append(pending[i].1) }
                        close(p.fd)
                    } else {
                        still.append(pending[i])
                    }
                }
                pending = still
            }
            for (fd, _) in pending { close(fd) }
        }
        return open
    }

    /// Fetches "/" from the printer's web server.
    static func webPage(_ host: String, timeout: TimeInterval = 1.5) -> String? {
        guard let c = try? TCPClient(host: host, port: 80, timeout: timeout) else { return nil }
        guard (try? c.send(Data("GET / HTTP/1.0\r\nHost: \(host)\r\nConnection: close\r\n\r\n".utf8))) != nil else { return nil }
        let d = c.receive(timeout: timeout, idle: 0.5, limit: 256 * 1024)
        return d.isEmpty ? nil : String(decoding: d, as: UTF8.self)
    }

    static func zebraModel(fromWebPage html: String) -> String? {
        let lower = html.lowercased()
        guard lower.contains("zebra") || lower.contains("ztc ") || lower.contains("zebranet") else { return nil }
        let patterns = [#"ZTC\s+([A-Za-z]{1,3}\d{3,4}[A-Za-z]{0,2}(-\d{3}dpi)?)"#,
                        #"\b((?:GX|GK|GC|GT|ZD|ZT|ZM|ZP|ZQ|LP|TLP|ZE|105SL|110Xi|S4M|R110)\d{0,4}[A-Za-z]{0,2}(-\d{3}dpi)?)\b"#]
        for p in patterns {
            if let r = html.range(of: p, options: .regularExpression) {
                return String(html[r]).replacingOccurrences(of: "ZTC ", with: "").trimmingCharacters(in: .whitespaces)
            }
        }
        if let t0 = html.range(of: "<title>", options: .caseInsensitive),
           let t1 = html.range(of: "</title>", options: .caseInsensitive, range: t0.upperBound..<html.endIndex) {
            let title = html[t0.upperBound..<t1.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { return title }
        }
        return "Zebra printer"
    }

    /// Scans the local network. Blocking: call off the main thread (takes ~1–3 s).
    public static func scan(timeout: TimeInterval = 0.7) -> [DiscoveredPrinter] {
        var hosts: [UInt32] = []
        for s in localSubnets() { hosts.append(contentsOf: self.hosts(in: s)) }
        hosts = Array(Set(hosts)).sorted()
        let open = openHosts(hosts, port: 9100, timeout: timeout)
        var found: [DiscoveredPrinter] = []
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: open.count) { i in
            let ip = ipString(open[i])
            var p = DiscoveredPrinter(target: .network(host: ip, port: 9100), name: ip,
                                      detail: "Raw printing port open (model unknown)", isZebra: false, dpi: nil)
            if let html = webPage(ip), let model = zebraModel(fromWebPage: html) {
                p.isZebra = true
                p.name = model
                p.detail = ip
                if let id = try? ZebraPrinter.identity(host: ip) {
                    p.name = id.model
                    p.dpi = id.dpi
                    p.detail = "\(ip) · firmware \(id.firmware)"
                }
            }
            lock.lock(); found.append(p); lock.unlock()
        }
        return found.sorted { ($0.isZebra ? 0 : 1, $0.name) < ($1.isZebra ? 0 : 1, $1.name) }
    }

    /// Zebras plugged in by USB. Blocking (lpinfo can take a few seconds): call off the main thread.
    public static func usbPrinters() -> [DiscoveredPrinter] {
        let queues = Self.queues()
        return USBPrinters.list().filter { $0.isZebra }.map { info in
            let zpl = info.speaksZPL
            var detail = "Connected by USB"
            if let s = info.serial { detail += " · serial \(s)" }
            if let q = queues.first(where: { USBDevices.sameDevice($0.uri, info.uri) }) {
                detail += " · on this Mac as “\(q.name.replacingOccurrences(of: "_", with: " "))”"
            }
            if zpl == false { detail += " · speaks EPL only; Tearoff needs ZPL" }
            return DiscoveredPrinter(target: .usb(uri: info.uri), name: info.displayName, detail: detail,
                                     isZebra: zpl != false, dpi: info.dpi)
        }
    }

    /// Existing macOS print queues ("device for NAME: URI").
    public static func queues() -> [QueueInfo] {
        let r = Shell.run("/usr/bin/lpstat", ["-v"])
        var out: [QueueInfo] = []
        for line in r.output.split(separator: "\n") {
            guard line.hasPrefix("device for ") else { continue }
            let rest = line.dropFirst("device for ".count)
            guard let colon = rest.range(of: ": ") else { continue }
            out.append(QueueInfo(name: String(rest[..<colon.lowerBound]), uri: String(rest[colon.upperBound...])))
        }
        return out
    }

    /// Network address of a queue that prints over raw TCP or LPD, if any.
    public static func host(ofQueueURI uri: String) -> PrinterTarget? {
        guard let u = URL(string: uri), let scheme = u.scheme, let host = u.host else { return nil }
        switch scheme {
        case "socket": return .network(host: host, port: u.port ?? 9100)
        case "lpd", "http", "ipp": return .network(host: host, port: 9100)
        default: return nil
        }
    }
}
