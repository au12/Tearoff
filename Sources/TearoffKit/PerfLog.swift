import Darwin
import Foundation
import TearoffCore

/// Local performance log: one JSON object per line in ~/Library/Logs/Tearoff/perf.jsonl
/// (Console.app shows it under Log Reports). Nothing leaves the Mac. Barcode contents are never
/// logged — only timings, counts and sizes.
public enum PerfLog {
    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Tearoff")
    }
    public static var file: URL { directory.appendingPathComponent("perf.jsonl") }
    /// Copies of what the CUPS filter logged (merged by the app).
    public static var filterFile: URL { directory.appendingPathComponent("filter.jsonl") }

    /// Places the sandboxed CUPS filter tries, in order. The installer creates the first two
    /// world-writable; which one the sandbox allows depends on the macOS version.
    public static let filterCandidates = [
        "/Library/Logs/Tearoff/filter.jsonl",
        "/Users/Shared/Tearoff/filter.jsonl",
        "/private/tmp/tearoff-filter.jsonl",
    ]

    public static var enabled: Bool {
        get { !TearoffSettings.store.bool(forKey: "perfLogDisabled") }
        set { TearoffSettings.store.set(!newValue, forKey: "perfLogDisabled") }
    }

    public static let queue = DispatchQueue(label: "tearoff.perflog", qos: .utility)
    static let maxBytes = 5 * 1024 * 1024

    // MARK: Machine

    static func sysctlString(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return "" }
        return String(cString: buf)
    }

    public static let machine: [String: Any] = {
        let pi = ProcessInfo.processInfo
        let v = pi.operatingSystemVersion
        return [
            "model": sysctlString("hw.model"),
            "cpu": sysctlString("machdep.cpu.brand_string"),
            "cores": pi.activeProcessorCount,
            "ram_gb": Int((Double(pi.physicalMemory) / 1_073_741_824).rounded()),
            "macos": "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
        ]
    }()

    /// Current memory footprint of this process (what Activity Monitor shows), in MB.
    public static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? (Double(info.phys_footprint) / 1_048_576 * 10).rounded() / 10 : 0
    }

    // MARK: Records

    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// A log record: op ("extract", "print", "filter", "bench", "launch", "hang", …), where it ran
    /// ("app", "cli", "filter", "downloads"), the trace's phases and anything extra.
    public static func record(op: String, source: String, trace: PerfTrace? = nil, ms: Double? = nil,
                              extra: [String: Any] = [:]) -> [String: Any] {
        var r: [String: Any] = [
            "ts": iso.string(from: Date()),
            "id": UUID().uuidString,
            "op": op,
            "source": source,
            "app": BuildInfo.version,
            "build": BuildInfo.build,
            "commit": BuildInfo.commit,
            "machine": machine,
            "mem_mb": footprintMB(),
        ]
        if let t = trace {
            r["ms"] = (t.elapsedMs * 10).rounded() / 10
            r["phases"] = t.phaseDictionary
            r["counters"] = t.counters
        }
        if let m = ms { r["ms"] = (m * 10).rounded() / 10 }
        for (k, v) in extra { r[k] = v }
        return r
    }

    static func line(_ record: [String: Any]) -> Data? {
        guard JSONSerialization.isValidJSONObject(record),
              var d = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return nil }
        d.append(0x0A)
        return d
    }

    /// Appends to the user's log (app and CLI). Rotates at 5 MB, keeping one old file.
    public static func append(_ record: [String: Any]) {
        guard enabled, let data = line(record) else { return }
        queue.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
            if let size = (try? fm.attributesOfItem(atPath: file.path))?[.size] as? Int, size > maxBytes {
                let old = directory.appendingPathComponent("perf.1.jsonl")
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: file, to: old)
            }
            appendRaw(data, path: file.path)
        }
    }

    /// Appends synchronously (for short-lived processes like the CLI).
    public static func appendNow(_ record: [String: Any]) {
        append(record)
        queue.sync {}
    }

    @discardableResult
    static func appendRaw(_ data: Data, path: String) -> Bool {
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o666)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let ok = data.withUnsafeBytes { buf -> Bool in
            guard let base = buf.baseAddress else { return false }
            return write(fd, base, buf.count) == buf.count
        }
        fchmod(fd, 0o666)
        return ok
    }

    /// From the CUPS filter: tries each candidate location and returns the one that worked.
    public static func appendFromFilter(_ record: [String: Any]) -> String? {
        guard let data = line(record) else { return nil }
        for path in filterCandidates {
            let dir = (path as NSString).deletingLastPathComponent
            if !FileManager.default.fileExists(atPath: dir) {
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                         attributes: [.posixPermissions: 0o1777])
            }
            if let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int, size > maxBytes {
                try? FileManager.default.removeItem(atPath: path)
            }
            if appendRaw(data, path: path) { return path }
        }
        return nil
    }

    /// App: copies new lines the filter wrote into ~/Library/Logs/Tearoff/filter.jsonl.
    public static func mergeFilterLogs() {
        queue.async {
            let defaults = TearoffSettings.store
            var offsets = defaults.dictionary(forKey: "filterLogOffsets") as? [String: Int] ?? [:]
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for path in filterCandidates {
                guard let h = FileHandle(forReadingAtPath: path) else { continue }
                defer { try? h.close() }
                let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int ?? 0
                var start = offsets[path] ?? 0
                if start > size { start = 0 }   // the filter rotated its file
                guard size > start else { continue }
                try? h.seek(toOffset: UInt64(start))
                let data = h.readData(ofLength: size - start)
                // only whole lines
                guard let lastNewline = data.lastIndex(of: 0x0A) else { continue }
                let chunk = data[data.startIndex...lastNewline]
                appendRaw(Data(chunk), path: filterFile.path)
                offsets[path] = start + chunk.count
            }
            defaults.set(offsets, forKey: "filterLogOffsets")
        }
    }

    // MARK: Reading (Diagnostics view)

    /// The most recent records of one op, newest first.
    public static func recent(op: String, limit: Int = 50, includeFilter: Bool = true) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for url in includeFilter ? [file, filterFile] : [file] {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for l in text.split(separator: "\n").suffix(2000) {
                guard let d = l.data(using: .utf8),
                      let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                      o["op"] as? String == op else { continue }
                out.append(o)
            }
        }
        out.sort { ($0["ts"] as? String ?? "") > ($1["ts"] as? String ?? "") }
        return Array(out.prefix(limit))
    }
}
