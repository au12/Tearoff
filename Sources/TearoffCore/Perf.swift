import Foundation

/// Lightweight timing of pipeline phases. One trace per document/operation. Thread-safe: phases
/// measured on several threads at once add up (so they can exceed wall time).
public final class PerfTrace {
    private var _phases: [(name: String, ms: Double)] = []
    private var _counters: [String: Int] = [:]
    private let lock = NSLock()
    private let started: TimeInterval

    /// Accumulated milliseconds per phase, in first-seen order.
    public var phases: [(name: String, ms: Double)] { lock.lock(); defer { lock.unlock() }; return _phases }
    public var counters: [String: Int] { lock.lock(); defer { lock.unlock() }; return _counters }

    public init() { started = ProcessInfo.processInfo.systemUptime }

    /// Milliseconds since the trace was created.
    public var elapsedMs: Double { (ProcessInfo.processInfo.systemUptime - started) * 1000 }

    @discardableResult
    public func measure<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        let t0 = ProcessInfo.processInfo.systemUptime
        defer { add(name, ms: (ProcessInfo.processInfo.systemUptime - t0) * 1000) }
        return try body()
    }

    public func add(_ name: String, ms: Double) {
        lock.lock(); defer { lock.unlock() }
        if let i = _phases.firstIndex(where: { $0.name == name }) {
            _phases[i].ms += ms
        } else {
            _phases.append((name, ms))
        }
    }

    public func count(_ name: String, _ n: Int = 1) { lock.lock(); _counters[name, default: 0] += n; lock.unlock() }

    public func set(_ name: String, _ n: Int) { lock.lock(); _counters[name] = n; lock.unlock() }

    /// Folds another trace in (e.g. per-page traces into a document trace).
    public func merge(_ other: PerfTrace) {
        let ps = other.phases, cs = other.counters
        for p in ps { add(p.name, ms: p.ms) }
        lock.lock(); for (k, v) in cs { _counters[k, default: 0] += v }; lock.unlock()
    }

    public var phaseDictionary: [String: Double] {
        var d = [String: Double]()
        for p in phases { d[p.name] = (p.ms * 10).rounded() / 10 }
        return d
    }

    /// "analysis 34ms · barcodes 120ms · …" (largest first).
    public var summary: String {
        phases.sorted { $0.ms > $1.ms }.prefix(6).map { "\($0.name) \(Int($0.ms.rounded()))ms" }.joined(separator: " · ")
    }
}
