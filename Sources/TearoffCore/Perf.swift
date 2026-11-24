import Foundation

/// Lightweight timing of pipeline phases. One trace per document/operation; not thread-safe
/// (each extraction runs on one queue).
public final class PerfTrace {
    /// Accumulated milliseconds per phase, in first-seen order.
    public private(set) var phases: [(name: String, ms: Double)] = []
    public private(set) var counters: [String: Int] = [:]
    private let started: TimeInterval

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
        if let i = phases.firstIndex(where: { $0.name == name }) {
            phases[i].ms += ms
        } else {
            phases.append((name, ms))
        }
    }

    public func count(_ name: String, _ n: Int = 1) { counters[name, default: 0] += n }

    public func set(_ name: String, _ n: Int) { counters[name] = n }

    /// Folds another trace in (e.g. per-page traces into a document trace).
    public func merge(_ other: PerfTrace) {
        for p in other.phases { add(p.name, ms: p.ms) }
        for (k, v) in other.counters { counters[k, default: 0] += v }
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
