import Foundation

/// A thin straight line (solid or dashed): `pos` is its centre across the line, `a..<b` its extent
/// along it, `t0...t1` the rows (or columns) it occupies.
public struct LineSegment {
    public var pos: Double
    public var a: Int
    public var b: Int
    public var t0: Int
    public var t1: Int
}

/// Finds frames and cut lines (solid or dashed) in an ink mask (1 = ink).
public enum LineFinder {

    /// Horizontal thin lines. Gaps up to `gap` px are bridged (dashes), at least half the
    /// length must be ink, thickness is at most `maxThickness` rows and the rows just outside
    /// the line must be mostly empty (which rejects text baselines).
    public static func horizontal(_ mask: [UInt8], width: Int, height: Int,
                                  minLength: Int, gap: Int, maxThickness: Int) -> [LineSegment] {
        struct Band { var x0: Int; var x1: Int; var y0: Int; var y1: Int }
        var bands: [Band] = []
        var active: [Int] = []
        mask.withUnsafeBufferPointer { m in
            var runs: [(Int, Int)] = []
            for y in 0..<height {
                runs.removeAll(keepingCapacity: true)
                let row = y * width
                var s = -1, e = -1, n = 0
                func flush() {
                    let L = e - s + 1
                    if s >= 0 && L >= minLength && Double(n) / Double(L) >= 0.5 { runs.append((s, e)) }
                }
                for x in 0..<width where m[row + x] != 0 {
                    if s < 0 { s = x; e = x; n = 1 }
                    else if x - e > gap + 1 { flush(); s = x; e = x; n = 1 }
                    else { e = x; n += 1 }
                }
                flush()
                var next: [Int] = []
                for (rs, re) in runs {
                    var hit: Int? = nil
                    for bi in active {
                        let b = bands[bi]
                        let ov = min(re, b.x1) - max(rs, b.x0)
                        if Double(ov) > 0.5 * Double(min(re - rs, b.x1 - b.x0)) { hit = bi; break }
                    }
                    if let h = hit {
                        bands[h].x0 = min(bands[h].x0, rs)
                        bands[h].x1 = max(bands[h].x1, re)
                        bands[h].y1 = y
                        if !next.contains(h) { next.append(h) }
                    } else {
                        bands.append(Band(x0: rs, x1: re, y0: y, y1: y))
                        next.append(bands.count - 1)
                    }
                }
                active = active.filter { y - bands[$0].y1 <= 1 && !next.contains($0) } + next
            }
        }
        var out: [LineSegment] = []
        for b in bands {
            if b.y1 - b.y0 + 1 > maxThickness { continue }
            let L = Double(b.x1 - b.x0 + 1)
            func frac(_ y: Int) -> Double {
                guard y >= 0 && y < height else { return 0 }
                var n = 0
                for x in b.x0...b.x1 where mask[y * width + x] != 0 { n += 1 }
                return Double(n) / L
            }
            if frac(b.y0 - 3) > 0.3 || frac(b.y1 + 3) > 0.3 { continue }
            out.append(LineSegment(pos: Double(b.y0 + b.y1) / 2, a: b.x0, b: b.x1 + 1, t0: b.y0, t1: b.y1))
        }
        if out.count > 80 { out = Array(out.sorted { $0.b - $0.a > $1.b - $1.a }.prefix(80)) }
        return out
    }

    /// Vertical thin lines (runs the horizontal finder on the transposed mask).
    public static func vertical(_ mask: [UInt8], width: Int, height: Int,
                                minLength: Int, gap: Int, maxThickness: Int) -> [LineSegment] {
        var t = [UInt8](repeating: 0, count: width * height)
        mask.withUnsafeBufferPointer { s in
            t.withUnsafeMutableBufferPointer { d in
                for y in 0..<height { for x in 0..<width { d[x * height + y] = s[y * width + x] } }
            }
        }
        return horizontal(t, width: height, height: width, minLength: minLength, gap: gap, maxThickness: maxThickness)
    }

    /// Rectangles whose four sides are each supported by a detected line (in mask pixels).
    public static func frames(horizontal hs: [LineSegment], vertical vs: [LineSegment],
                              tolerance tol: Double, minSide: Double) -> [(x0: Double, y0: Double, x1: Double, y1: Double)] {
        var out: [(x0: Double, y0: Double, x1: Double, y1: Double)] = []
        guard vs.count >= 2, hs.count >= 2 else { return out }
        for i in 0..<(vs.count - 1) {
            for j in (i + 1)..<vs.count {
                let (L, R) = vs[i].pos < vs[j].pos ? (vs[i], vs[j]) : (vs[j], vs[i])
                if R.pos - L.pos < minSide { continue }
                let ylo = Double(max(L.a, R.a)), yhi = Double(min(L.b, R.b))
                if yhi - ylo < minSide { continue }
                let tops = hs.filter {
                    $0.pos >= ylo - tol && $0.pos <= yhi + tol && Double($0.a) <= L.pos + tol && Double($0.b) >= R.pos - tol
                }
                if tops.count < 2 { continue }
                for a in 0..<(tops.count - 1) {
                    for b in (a + 1)..<tops.count {
                        let (t, bt) = tops[a].pos < tops[b].pos ? (tops[a], tops[b]) : (tops[b], tops[a])
                        if bt.pos - t.pos < minSide { continue }
                        if Double(L.a) > t.pos + tol || Double(L.b) < bt.pos - tol { continue }
                        if Double(R.a) > t.pos + tol || Double(R.b) < bt.pos - tol { continue }
                        out.append((L.pos, t.pos, R.pos, bt.pos))
                        if out.count > 4000 { return out }
                    }
                }
            }
        }
        return out
    }
}
