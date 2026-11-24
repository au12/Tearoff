import Foundation

/// A 1D barcode found by scanning a raster, with its Code 128 reading direction when known.
public struct LinearBarcode: CustomStringConvertible {
    /// Pixel bounds in the raster it was found in.
    public var rect: PixelRect
    /// 0: bars are vertical (symbol reads along x). 1: bars are horizontal (reads along y).
    public var axis: Int
    /// Scanlines whose Code 128 start/stop patterns read in +x/+y (forward) or -x/-y (reverse).
    public var forward: Int
    public var reverse: Int
    public var lines: Int
    /// Narrowest element width in pixels.
    public var module: Double
    /// Bars + spaces in the symbol.
    public var elements: Int
    /// Decoded Code 128 text, when a scanline decoded with a valid checksum.
    public var text: String?

    public var length: Int { axis == 0 ? rect.width : rect.height }
    public var midX: Double { Double(rect.x0 + rect.x1) / 2 }
    public var midY: Double { Double(rect.y0 + rect.y1) / 2 }

    public var description: String {
        "bar(\(rect.x0),\(rect.y0)-\(rect.x1),\(rect.y1) axis \(axis) f\(forward)/r\(reverse) " +
            String(format: "x=%.2f", module) + " \(text ?? "?"))"
    }
}

/// Vision-free 1D barcode finder. Looks for runs of bars and spaces that quantize to 1–4 module
/// widths on several consecutive scanlines; Code 128 start/stop patterns give the reading direction
/// and a full decode + checksum makes grid-fitting safe.
public enum BarcodeFinder {

    struct Seq {
        var line: Int
        var a: Int
        var b: Int
        var module: Double
        var dir: Int
        var count: Int
        var text: String?
    }

    struct Region {
        var y0: Int
        var y1: Int
        var a: Int
        var b: Int
        var lastLine: Int
        var lastA: Int
        var lastB: Int
        var fwd = 0
        var rev = 0
        var n = 0
        var modules: [Double] = []
        var counts: [Int] = []
        var texts: [String] = []
    }

    /// Finds linear barcodes in `img`. `ppi` is pixels per inch *at label scale*: it sets the size
    /// limits (bars up to 0.11 in, symbols at least 0.35 in long, quiet zones of 0.05 in).
    /// `robust` also accepts symbols whose module estimate needs refining (thin bars at 3–4 px per
    /// module); the extra-code search uses it, label finding keeps the original, proven behaviour.
    public static func find(in img: GrayImage, ppi: Double, threshold: UInt8 = 128, robust: Bool = false) -> [LinearBarcode] {
        let w = img.width, h = img.height
        guard w > 2, h > 2, ppi > 1 else { return [] }
        var bw = [UInt8](repeating: 0, count: w * h)
        img.pixels.withUnsafeBufferPointer { p in
            for i in 0..<(w * h) { bw[i] = p[i] < threshold ? 1 : 0 }
        }
        let step = max(1, Int((ppi / 60).rounded()))
        var out: [LinearBarcode] = []
        for r in group(scan(bw, width: w, height: h, ppi: ppi, step: step, robust: robust), step: step, ppi: ppi) {
            out.append(make(r, axis: 0, rect: PixelRect(x0: r.a, y0: r.y0, x1: r.b, y1: r.y1)))
        }
        var t = [UInt8](repeating: 0, count: w * h)
        bw.withUnsafeBufferPointer { s in
            t.withUnsafeMutableBufferPointer { d in
                for y in 0..<h { for x in 0..<w { d[x * h + y] = s[y * w + x] } }
            }
        }
        for r in group(scan(t, width: h, height: w, ppi: ppi, step: step, robust: robust), step: step, ppi: ppi) {
            out.append(make(r, axis: 1, rect: PixelRect(x0: r.y0, y0: r.a, x1: r.y1, y1: r.b)))
        }
        return out
    }

    static func make(_ r: Region, axis: Int, rect: PixelRect) -> LinearBarcode {
        LinearBarcode(rect: rect, axis: axis, forward: r.fwd, reverse: r.rev, lines: r.n,
                      module: median(r.modules), elements: Int(median(r.counts.map(Double.init))),
                      text: mostCommon(r.texts))
    }

    static func scan(_ bw: [UInt8], width: Int, height: Int, ppi: Double, step: Int, robust: Bool = false) -> [Seq] {
        guard width > 1 else { return [] }
        let maxRun = 0.11 * ppi, minLen = 0.35 * ppi, quiet = 0.05 * ppi
        var out: [Seq] = []
        var st = [Int](), ln = [Int](), blk = [Bool]()
        st.reserveCapacity(width); ln.reserveCapacity(width); blk.reserveCapacity(width)
        bw.withUnsafeBufferPointer { p in
            var y = 0
            while y < height {
                st.removeAll(keepingCapacity: true)
                ln.removeAll(keepingCapacity: true)
                blk.removeAll(keepingCapacity: true)
                let row = y * width
                var cur = p[row]
                var start = 0
                for x in 1..<width {
                    let v = p[row + x]
                    if v != cur {
                        st.append(start); ln.append(x - start); blk.append(cur == 1)
                        cur = v; start = x
                    }
                }
                st.append(start); ln.append(width - start); blk.append(cur == 1)
                let nr = ln.count
                var i = 0
                while i < nr {
                    if !blk[i] || Double(ln[i]) > maxRun { i += 1; continue }
                    let prevQuiet = i == 0 || Double(ln[i - 1]) >= quiet
                    if !prevQuiet { i += 1; continue }
                    var j = i
                    while j < nr && Double(ln[j]) <= maxRun { j += 1 }
                    var end = j - 1
                    if end >= i && !blk[end] { end -= 1 }
                    let nextQuiet = j == nr || (!blk[j] && Double(ln[j]) >= quiet)
                    let count = end - i + 1
                    if count >= 25 && nextQuiet && Double(st[end] + ln[end] - st[i]) >= minLen {
                        if let q = quantize(Array(ln[i...end]), robust: robust) {
                            let dir = code128Direction(q.modules)
                            var text: String? = nil
                            if dir != 0 {
                                let m = dir == 1 ? q.modules : Array(q.modules.reversed())
                                if let vals = code128Values(m) { text = code128Text(vals) }
                            }
                            out.append(Seq(line: y, a: st[i], b: st[end] + ln[end], module: q.module,
                                           dir: dir, count: count, text: text))
                        }
                    }
                    i = max(j, i + 1)
                }
                y += step
            }
        }
        return out
    }

    static func group(_ seqs: [Seq], step: Int, ppi: Double) -> [Region] {
        let sorted = seqs.sorted { $0.line != $1.line ? $0.line < $1.line : $0.a < $1.a }
        var regions: [Region] = []
        var open: [Int] = []
        for s in sorted {
            var hit: Int? = nil
            let tol = max(3.0, 2.5 * s.module)
            for idx in open {
                let r = regions[idx]
                if s.line - r.lastLine == step && Double(abs(s.a - r.lastA)) <= tol && Double(abs(s.b - r.lastB)) <= tol {
                    hit = idx
                    break
                }
            }
            let k: Int
            if let hit = hit {
                k = hit
            } else {
                regions.append(Region(y0: s.line, y1: s.line, a: s.a, b: s.b, lastLine: s.line, lastA: s.a, lastB: s.b))
                k = regions.count - 1
                open.append(k)
            }
            regions[k].lastLine = s.line
            regions[k].lastA = s.a
            regions[k].lastB = s.b
            regions[k].y1 = s.line
            regions[k].a = min(regions[k].a, s.a)
            regions[k].b = max(regions[k].b, s.b)
            if s.dir == 1 { regions[k].fwd += 1 } else if s.dir == -1 { regions[k].rev += 1 }
            regions[k].n += 1
            regions[k].modules.append(s.module)
            regions[k].counts.append(s.count)
            if let t = s.text { regions[k].texts.append(t) }
            open = open.filter { s.line - regions[$0].lastLine <= step }
        }
        var out: [Region] = []
        for var r in regions {
            if Double(r.y1 - r.y0 + step) < 0.12 * ppi || r.n < 3 { continue }
            r.y1 += step
            out.append(r)
        }
        return out
    }

    /// Module width + integer module counts if the run lengths look like a 1D symbology.
    public static func quantize(_ runs: [Int], robust: Bool = false) -> (module: Double, modules: [Int])? {
        guard !runs.isEmpty else { return nil }
        let sorted = runs.sorted()
        let k = max(1, sorted.count / 4)
        var x0 = 0.0
        for i in 0..<k { x0 += Double(sorted[i]) }
        x0 /= Double(k)
        guard x0 > 0 else { return nil }
        var total = 0.0
        for r in runs { total += Double(r) }

        func fit(_ x: Double) -> (resid: Double, max: Int, modules: [Int]) {
            var m = [Int]()
            m.reserveCapacity(runs.count)
            var resid = 0.0
            var mx = 0
            for r in runs {
                let v = Double(r) / x
                let mi = max(1, Int(v.rounded()))
                resid += abs(v - Double(mi))
                mx = max(mx, mi)
                m.append(mi)
            }
            return (resid / Double(runs.count), mx, m)
        }
        func refine(_ x: Double) -> Double {
            var mtotal = 0
            for r in runs { mtotal += max(1, Int((Double(r) / x).rounded())) }
            return total / Double(mtotal)
        }

        // The narrowest elements give a first module estimate. Thresholding thins bars (or spaces),
        // so at 3–4 px per module that estimate reads small and 3–4 module elements round wrong:
        // refine it against the total length, and try the exact Code 128 module when the element
        // count fits 6n + 1. Keep whichever quantizes cleanest.
        var x = refine(x0)
        var best: (resid: Double, x: Double, modules: [Int])? = nil
        let first = fit(x)
        if first.max <= 4 { best = (first.resid, x, first.modules) }
        if robust && (best == nil || best!.resid > 0.12) {
            var xs: [Double] = []
            for _ in 0..<3 {
                let nx = refine(x)
                if abs(nx - x) < 1e-9 { break }
                xs.append(nx)
                x = nx
            }
            if runs.count >= 19 && (runs.count - 1) % 6 == 0 {
                xs.append(total / Double(11 * (runs.count - 1) / 6 + 2))
            }
            for cx in xs {
                let f = fit(cx)
                if f.max <= 4 && (best == nil || f.resid < best!.resid) { best = (f.resid, cx, f.modules) }
            }
        }
        guard let b = best, b.resid <= 0.22 else { return nil }
        return (b.x, b.modules)
    }

    // MARK: Code 128

    /// Code 128 symbol patterns (bar, space, bar, space, bar, space[, bar]) for values 0…106.
    public static let code128Patterns: [String] = [
        "212222", "222122", "222221", "121223", "121322", "131222", "122213", "122312", "132212",
        "221213", "221312", "231212", "112232", "122132", "122231", "113222", "123122", "123221",
        "223211", "221132", "221231", "213212", "223112", "312131", "311222", "321122", "321221",
        "312212", "322112", "322211", "212123", "212321", "232121", "111323", "131123", "131321",
        "112313", "132113", "132311", "211313", "231113", "231311", "112133", "112331", "132131",
        "113123", "113321", "133121", "313121", "211331", "231131", "213113", "213311", "213131",
        "311123", "311321", "331121", "312113", "312311", "332111", "314111", "221411", "431111",
        "111224", "111422", "121124", "121421", "141122", "141221", "112214", "112412", "122114",
        "122411", "142112", "142211", "241211", "221114", "413111", "241112", "134111", "111242",
        "121142", "121241", "114212", "124112", "124211", "411212", "421112", "421211", "212141",
        "214121", "412121", "111143", "111341", "131141", "114113", "114311", "411113", "411311",
        "113141", "114131", "311141", "411131", "211412", "211214", "211232", "2331112",
    ]

    static let code128Index: [String: Int] = {
        var d = [String: Int]()
        for (i, p) in code128Patterns.enumerated() { d[p] = i }
        return d
    }()

    static let stopPattern = [2, 3, 3, 1, 1, 1, 2]
    static let startPatterns = [[2, 1, 1, 4, 1, 2], [2, 1, 1, 2, 1, 4], [2, 1, 1, 2, 3, 2]]

    static func matches(_ m: ArraySlice<Int>, _ p: [Int]) -> Bool {
        guard m.count >= p.count else { return false }
        var i = m.startIndex
        for v in p {
            if m[i] != v { return false }
            i += 1
        }
        return true
    }

    /// +1 forward, -1 reversed, 0 unknown. `m` starts and ends with a bar.
    public static func code128Direction(_ m: [Int]) -> Int {
        guard m.count >= 13 else { return 0 }
        var fwd = 0, rev = 0
        if matches(m.suffix(7), stopPattern) { fwd += 1 }
        if startPatterns.contains(where: { matches(m.prefix(6), $0) }) { fwd += 1 }
        if matches(m.prefix(7), Array(stopPattern.reversed())) { rev += 1 }
        if startPatterns.contains(where: { matches(m.suffix(6), Array($0.reversed())) }) { rev += 1 }
        return fwd > rev ? 1 : (rev > fwd ? -1 : 0)
    }

    /// Validates a forward module sequence as Code 128 (structure, start, stop and checksum).
    public static func code128Values(_ m: [Int]) -> [Int]? {
        guard m.count >= 19, (m.count - 7) % 6 == 0 else { return nil }
        let k = (m.count - 7) / 6
        var vals = [Int]()
        vals.reserveCapacity(k)
        for i in 0..<k {
            let key = m[(6 * i)..<(6 * i + 6)].map(String.init).joined()
            guard let v = code128Index[key] else { return nil }
            vals.append(v)
        }
        guard m[(6 * k)...].map(String.init).joined() == code128Patterns[106] else { return nil }
        guard let first = vals.first, (103...105).contains(first) else { return nil }
        guard !vals.dropFirst().contains(where: { $0 >= 103 }) else { return nil }
        guard vals.count >= 2 else { return nil }
        var sum = first
        for (i, v) in vals.dropFirst().dropLast().enumerated() { sum += v * (i + 1) }
        return sum % 103 == vals.last! ? vals : nil
    }

    /// Human-readable text of validated Code 128 values (FNC codes dropped).
    public static func code128Text(_ vals: [Int]) -> String {
        guard vals.count >= 2 else { return "" }
        var set = vals[0] == 103 ? 0 : (vals[0] == 104 ? 1 : 2)   // 0 A, 1 B, 2 C
        var out = ""
        var shift = false
        for v in vals.dropFirst().dropLast() {
            let cur = shift ? (set == 0 ? 1 : 0) : set
            shift = false
            if cur == 2 {
                if v < 100 { out += String(format: "%02d", v) }
                else if v == 100 { set = 1 }
                else if v == 101 { set = 0 }
                continue
            }
            if v < 64 || (cur == 1 && v < 96) {
                out.append(Character(UnicodeScalar(UInt8(v + 32))))
                continue
            }
            if cur == 0 && v < 96 { continue }  // control characters
            switch v {
            case 98: shift = true
            case 99: set = 2
            case 100: if cur == 0 { set = 1 }
            case 101: if cur == 1 { set = 0 }
            default: break
            }
        }
        return out
    }

    /// Quarter turns clockwise that make the content upright, voted by Code 128 reading direction.
    public static func uprightQuarterTurns(_ codes: [LinearBarcode]) -> Int? {
        var votes = [0, 0, 0, 0]
        for c in codes where c.forward != c.reverse {
            let fwd = c.forward > c.reverse
            let w = abs(c.forward - c.reverse)
            if c.axis == 0 { votes[fwd ? 0 : 2] += w } else { votes[fwd ? 3 : 1] += w }
        }
        guard let best = votes.indices.max(by: { votes[$0] < votes[$1] }), votes[best] > 0 else { return nil }
        return best
    }

    static func median(_ v: [Double]) -> Double {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    static func mostCommon(_ v: [String]) -> String? {
        var c = [String: Int]()
        for s in v { c[s, default: 0] += 1 }
        return c.max { $0.value < $1.value }?.key
    }
}
