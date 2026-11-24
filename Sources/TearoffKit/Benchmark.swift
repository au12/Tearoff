import Foundation
import TearoffCore

/// Repeatable timing run over a set of PDFs (by default the synthetic test labels bundled in the
/// app), so builds can be compared on the same Mac.
public enum Benchmark {

    public struct FileResult {
        public var name: String
        public var labels: Int
        public var medianMs: Double
        public var minMs: Double
        public var zplMs: Double
    }

    public struct Result {
        public var files: [FileResult]
        public var phases: [String: Double]      // median per run, summed over files
        public var totalMedianMs: Double
        public var runs: Int
        public var peakMB: Double

        public var summary: String {
            let slow = files.max(by: { $0.medianMs < $1.medianMs })
            var s = "\(files.count) PDFs × \(runs) runs: \(Int(totalMedianMs.rounded())) ms total (median)"
            if let x = slow { s += " · slowest \(x.name) \(Int(x.medianMs.rounded())) ms" }
            return s
        }
    }

    /// Bundled fixtures: Tearoff.app/Contents/Resources/Benchmark, or tests/fixtures in a checkout.
    public static func defaultFiles() -> [URL] {
        var dirs: [URL] = []
        if let r = Bundle.main.resourceURL { dirs.append(r.appendingPathComponent("Benchmark")) }
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        // Contents/Helpers/tearoff -> Contents/Resources/Benchmark
        dirs.append(exe.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Benchmark"))
        dirs.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tests/fixtures"))
        for d in dirs {
            let files = ((try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension.lowercased() == "pdf" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            if !files.isEmpty { return files }
        }
        return []
    }

    static func median(_ v: [Double]) -> Double {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    public static func run(files: [URL], runs: Int = 3, options: RenderOptions = RenderOptions(),
                           progress: ((String) -> Void)? = nil) -> Result {
        var results: [FileResult] = []
        var phaseRuns: [String: [Double]] = [:]
        var totals: [Double] = Array(repeating: 0, count: max(1, runs))
        var peak = PerfLog.footprintMB()
        for f in files {
            var times: [Double] = []
            var zpl: [Double] = []
            var labels = 0
            var perRunPhases: [[String: Double]] = []
            for r in 0..<max(1, runs) {
                progress?("\(f.lastPathComponent) (\(r + 1)/\(runs))")
                let t = PerfTrace()
                let found = (try? LabelExtractor.extract(url: f, options: ExtractOptions(render: options), trace: t)) ?? []
                let z0 = ProcessInfo.processInfo.systemUptime
                _ = ZPL.job(found.map { $0.image })
                let zms = (ProcessInfo.processInfo.systemUptime - z0) * 1000
                t.add("zpl.encode", ms: zms)
                labels = found.count
                times.append(t.elapsedMs)
                zpl.append(zms)
                totals[r] += t.elapsedMs
                perRunPhases.append(t.phaseDictionary)
                peak = max(peak, PerfLog.footprintMB())
            }
            // per phase: median across runs, then summed over files
            let names = Set(perRunPhases.flatMap { $0.keys })
            for n in names {
                phaseRuns[n, default: []].append(median(perRunPhases.map { $0[n] ?? 0 }))
            }
            results.append(FileResult(name: f.lastPathComponent, labels: labels, medianMs: median(times),
                                      minMs: times.min() ?? 0, zplMs: median(zpl)))
        }
        var phases: [String: Double] = [:]
        for (k, v) in phaseRuns { phases[k] = (v.reduce(0, +) * 10).rounded() / 10 }
        return Result(files: results, phases: phases, totalMedianMs: median(totals), runs: max(1, runs), peakMB: peak)
    }

    public static func record(_ r: Result, source: String) -> [String: Any] {
        PerfLog.record(op: "bench", source: source, ms: r.totalMedianMs, extra: [
            "runs": r.runs,
            "phases": r.phases,
            "peak_mb": r.peakMB,
            "files": r.files.map { ["name": $0.name, "labels": $0.labels, "median_ms": ($0.medianMs * 10).rounded() / 10,
                                    "min_ms": ($0.minMs * 10).rounded() / 10, "zpl_ms": ($0.zplMs * 10).rounded() / 10] },
        ])
    }
}
