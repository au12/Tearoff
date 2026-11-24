import Foundation

/// A QR code located by its three finder patterns. Not decoded: Tearoff only needs to know where
/// it is to print it, and the printed copy is what gets scanned.
public struct QRSymbol: CustomStringConvertible {
    /// Pixel bounds of the symbol (quiet zone excluded) in the raster it was found in.
    public var rect: PixelRect
    /// Modules per side (21, 25, 29 … 177).
    public var dimension: Int
    /// Module size in pixels.
    public var module: Double

    public var description: String {
        "qr(\(rect.x0),\(rect.y0)-\(rect.x1),\(rect.y1) \(dimension)x\(dimension) " + String(format: "m=%.1f)", module)
    }
}

/// Vision-free QR locator: 1:1:3:1:1 finder patterns confirmed across and down, grouped in threes
/// that form a right isosceles triangle, then checked against the alternating timing patterns
/// between them (which rules out bullseyes, MaxiCode, logos and text).
public enum QRFinder {

    struct Candidate {
        var x: Double
        var y: Double
        var module: Double
        var count: Int
    }

    /// Finds QR codes in `img`. `ppi` is pixels per inch on the page: modules from 0.006 in up to
    /// 0.3 in are considered.
    public static func find(in img: GrayImage, ppi: Double, threshold: UInt8 = 128) -> [QRSymbol] {
        let w = img.width, h = img.height
        guard w > 20, h > 20, ppi > 1 else { return [] }
        var bw = [UInt8](repeating: 0, count: w * h)
        img.pixels.withUnsafeBufferPointer { p in
            for i in 0..<(w * h) { bw[i] = p[i] < threshold ? 1 : 0 }
        }
        let minModule = max(1.5, 0.006 * ppi)
        let maxModule = 0.3 * ppi
        let step = max(1, Int(minModule.rounded()))
        var cands: [Candidate] = []

        var st = [Int](), ln = [Int](), blk = [Bool]()
        st.reserveCapacity(w); ln.reserveCapacity(w); blk.reserveCapacity(w)
        var y = 0
        while y < h {
            st.removeAll(keepingCapacity: true)
            ln.removeAll(keepingCapacity: true)
            blk.removeAll(keepingCapacity: true)
            let row = y * w
            var cur = bw[row], start = 0
            for x in 1..<w where bw[row + x] != cur {
                st.append(start); ln.append(x - start); blk.append(cur == 1)
                cur = bw[row + x]; start = x
            }
            st.append(start); ln.append(w - start); blk.append(cur == 1)
            if ln.count >= 5 {
                for k in 0...(ln.count - 5) where blk[k] {
                    let r = (ln[k], ln[k + 1], ln[k + 2], ln[k + 3], ln[k + 4])
                    let total = r.0 + r.1 + r.2 + r.3 + r.4
                    let m = Double(total) / 7
                    guard m >= minModule, m <= maxModule, ratioOK(r, total: total) else { continue }
                    let cx = st[k + 2] + ln[k + 2] / 2
                    let maxTotal = Int(Double(total) * 1.5)
                    guard let v = cross(bw, w, h, x: cx, y: y, vertical: true, maxTotal: maxTotal) else { continue }
                    guard let hz = cross(bw, w, h, x: cx, y: Int(v.centre), vertical: false, maxTotal: maxTotal) else { continue }
                    if abs(Double(v.total - hz.total)) > 0.4 * Double(max(v.total, hz.total)) { continue }
                    let mod = Double(v.total + hz.total) / 14
                    let px = hz.centre, py = v.centre
                    if let i = cands.firstIndex(where: {
                        abs($0.x - px) <= 2 * mod && abs($0.y - py) <= 2 * mod && abs($0.module - mod) < 0.5 * mod
                    }) {
                        let n = Double(cands[i].count)
                        cands[i].x = (cands[i].x * n + px) / (n + 1)
                        cands[i].y = (cands[i].y * n + py) / (n + 1)
                        cands[i].module = (cands[i].module * n + mod) / (n + 1)
                        cands[i].count += 1
                    } else {
                        cands.append(Candidate(x: px, y: py, module: mod, count: 1))
                    }
                }
            }
            y += step
        }
        cands = cands.filter { $0.count >= 2 }
        if cands.count > 48 { cands = Array(cands.sorted { $0.count > $1.count }.prefix(48)) }
        guard cands.count >= 3 else { return [] }

        // --- triples of finder patterns that frame a QR symbol
        var options: [(score: Double, ids: [Int], symbol: QRSymbol)] = []
        func dist(_ a: Candidate, _ b: Candidate) -> Double { ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot() }
        let n = cands.count
        for a in 0..<(n - 2) {
            for b in (a + 1)..<(n - 1) {
                for c in (b + 1)..<n {
                    let p = [cands[a], cands[b], cands[c]]
                    let ms = p.map { $0.module }
                    guard let lo = ms.min(), let hi = ms.max(), hi <= 1.4 * lo else { continue }
                    // the corner is opposite the longest side
                    let sides = [dist(p[1], p[2]), dist(p[0], p[2]), dist(p[0], p[1])]
                    let ci = sides.firstIndex(of: sides.max()!)!
                    let hyp = sides[ci]
                    let C = p[ci]
                    let others = (0..<3).filter { $0 != ci }.map { p[$0] }
                    var A = others[0], B = others[1]
                    let la = dist(C, A), lb = dist(C, B)
                    if abs(la - lb) > 0.15 * max(la, lb) { continue }
                    if abs(hyp - (la * la + lb * lb).squareRoot()) > 0.08 * hyp { continue }
                    let mod = (ms[0] + ms[1] + ms[2]) / 3
                    let est = (la + lb) / 2 / mod + 7
                    let dim = Int(((est - 17) / 4).rounded()) * 4 + 17
                    if dim < 21 || dim > 177 || abs(est - Double(dim)) > max(2.5, 0.08 * Double(dim)) { continue }
                    // A is top-right and B bottom-left of the symbol's own frame
                    let crossZ = (A.x - C.x) * (B.y - C.y) - (A.y - C.y) * (B.x - C.x)
                    if crossZ < 0 { swap(&A, &B) }
                    let ux = (A.x - C.x) / Double(dim - 7), uy = (A.y - C.y) / Double(dim - 7)
                    let vx = (B.x - C.x) / Double(dim - 7), vy = (B.y - C.y) / Double(dim - 7)
                    func dark(_ col: Int, _ row: Int) -> Bool? {
                        let fx = C.x + ux * Double(col - 3) + vx * Double(row - 3)
                        let fy = C.y + uy * Double(col - 3) + vy * Double(row - 3)
                        let xi = Int(fx.rounded()), yi = Int(fy.rounded())
                        guard xi >= 0, xi < w, yi >= 0, yi < h else { return nil }
                        return bw[yi * w + xi] == 1
                    }
                    // timing patterns: row 6 and column 6 alternate dark/light between the finders
                    var ok = 0, tot = 0
                    if dim - 8 > 8 {
                        for t in 8..<(dim - 8) {
                            for v in [dark(t, 6), dark(6, t)] {
                                guard let v = v else { continue }
                                tot += 1
                                if v == (t % 2 == 0) { ok += 1 }
                            }
                        }
                    }
                    guard tot > 0, Double(ok) >= 0.8 * Double(tot) else { continue }
                    var xs: [Double] = [], ys: [Double] = []
                    for (col, row) in [(0, 0), (dim, 0), (0, dim), (dim, dim)] {
                        xs.append(C.x + ux * (Double(col) - 3.5) + vx * (Double(row) - 3.5))
                        ys.append(C.y + uy * (Double(col) - 3.5) + vy * (Double(row) - 3.5))
                    }
                    let r = PixelRect(x0: Int(xs.min()!.rounded(.down)), y0: Int(ys.min()!.rounded(.down)),
                                      x1: Int(xs.max()!.rounded(.up)), y1: Int(ys.max()!.rounded(.up)))
                    options.append((Double(ok) / Double(tot), [a, b, c], QRSymbol(rect: r, dimension: dim, module: mod)))
                }
            }
        }
        var used = Set<Int>()
        var out: [QRSymbol] = []
        for o in options.sorted(by: { $0.score > $1.score }) {
            if o.ids.contains(where: { used.contains($0) }) { continue }
            o.ids.forEach { used.insert($0) }
            out.append(o.symbol)
        }
        return out
    }

    /// Run lengths within half a module of 1:1:3:1:1.
    static func ratioOK(_ r: (Int, Int, Int, Int, Int), total: Int) -> Bool {
        let m = Double(total) / 7, v = m / 2
        return abs(Double(r.0) - m) < v && abs(Double(r.1) - m) < v && abs(Double(r.2) - 3 * m) < 3 * v &&
            abs(Double(r.3) - m) < v && abs(Double(r.4) - m) < v
    }

    /// Measures the finder pattern through (x, y) along a column or a row: centre of its middle
    /// run and the pattern's total length.
    static func cross(_ bw: [UInt8], _ w: Int, _ h: Int, x: Int, y: Int, vertical: Bool, maxTotal: Int) -> (centre: Double, total: Int)? {
        guard x >= 0, x < w, y >= 0, y < h else { return nil }
        let n = vertical ? h : w
        let c = vertical ? y : x
        @inline(__always) func at(_ i: Int) -> Bool { vertical ? bw[i * w + x] == 1 : bw[y * w + i] == 1 }
        guard at(c) else { return nil }
        var r = [0, 0, 0, 0, 0]
        var i = c
        while i >= 0 && at(i) { r[2] += 1; i -= 1 }
        while i >= 0 && !at(i) && r[1] <= maxTotal { r[1] += 1; i -= 1 }
        while i >= 0 && at(i) && r[0] <= maxTotal { r[0] += 1; i -= 1 }
        guard r[0] > 0, r[1] > 0 else { return nil }
        var j = c + 1
        while j < n && at(j) { r[2] += 1; j += 1 }
        while j < n && !at(j) && r[3] <= maxTotal { r[3] += 1; j += 1 }
        while j < n && at(j) && r[4] <= maxTotal { r[4] += 1; j += 1 }
        guard r[3] > 0, r[4] > 0 else { return nil }
        let total = r.reduce(0, +)
        guard total <= maxTotal, ratioOK((r[0], r[1], r[2], r[3], r[4]), total: total) else { return nil }
        let top = i + 1 + r[0] + r[1]
        return (Double(top) + Double(r[2]) / 2, total)
    }
}
