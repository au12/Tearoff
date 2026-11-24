import Foundation

/// Enumerates whitespace-bounded blocks of ink: every rectangle you can get by cutting the page
/// (recursively, along either axis) through empty channels at least `minGap` wide, keeping any
/// contiguous run of the resulting strips. That reliably isolates unframed labels, including
/// two-up sheets where a plain XY-cut would slice through both labels at once.
public final class BlockFinder {
    let w: Int
    let h: Int
    private var sums: [Int32]   // (h+1) x (w+1) integral image

    public init(mask: [UInt8], width: Int, height: Int) {
        w = width
        h = height
        sums = [Int32](repeating: 0, count: (width + 1) * (height + 1))
        let W = width + 1
        mask.withUnsafeBufferPointer { m in
            sums.withUnsafeMutableBufferPointer { s in
                for y in 0..<height {
                    var rowSum: Int32 = 0
                    for x in 0..<width {
                        rowSum += Int32(m[y * width + x] != 0 ? 1 : 0)
                        s[(y + 1) * W + (x + 1)] = s[y * W + (x + 1)] + rowSum
                    }
                }
            }
        }
    }

    @inline(__always) public func count(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> Int {
        let W = w + 1
        return Int(sums[y1 * W + x1] - sums[y0 * W + x1] - sums[y1 * W + x0] + sums[y0 * W + x0])
    }

    /// Shrinks a rectangle to the bounding box of the ink inside it.
    public func trim(_ r: PixelRect) -> PixelRect? {
        var x0 = max(0, r.x0), y0 = max(0, r.y0), x1 = min(w, r.x1), y1 = min(h, r.y1)
        guard x1 > x0, y1 > y0, count(x0, y0, x1, y1) > 0 else { return nil }
        while count(x0, y0, x1, y0 + 1) == 0 { y0 += 1 }
        while count(x0, y1 - 1, x1, y1) == 0 { y1 -= 1 }
        while count(x0, y0, x0 + 1, y1) == 0 { x0 += 1 }
        while count(x1 - 1, y0, x1, y1) == 0 { x1 -= 1 }
        return PixelRect(x0: x0, y0: y0, x1: x1, y1: y1)
    }

    /// Ink strips of `r` separated by empty channels >= minGap. axis 0 = columns, 1 = rows.
    func segments(_ r: PixelRect, axis: Int, minGap: Int) -> [(Int, Int)] {
        var segs: [(Int, Int)] = []
        let n = axis == 0 ? r.width : r.height
        var start = -1, last = -1, gap = 0
        for i in 0..<n {
            let occupied: Bool
            if axis == 0 {
                occupied = count(r.x0 + i, r.y0, r.x0 + i + 1, r.y1) > 0
            } else {
                occupied = count(r.x0, r.y0 + i, r.x1, r.y0 + i + 1) > 0
            }
            if occupied {
                if start < 0 {
                    start = i
                } else if gap >= minGap {
                    segs.append((start, last + 1))
                    start = i
                }
                gap = 0
                last = i
            } else {
                gap += 1
            }
        }
        if start >= 0 { segs.append((start, last + 1)) }
        let base = axis == 0 ? r.x0 : r.y0
        return segs.map { ($0.0 + base, $0.1 + base) }
    }

    /// All blocks with short side >= minSide that contain at least one seed point.
    public func blocks(minGap: Int, minSide: Int, seeds: [(Int, Int)], maxDepth: Int = 3, budget: Int = 3000) -> [PixelRect] {
        guard let root = trim(PixelRect(x0: 0, y0: 0, x1: w, y1: h)) else { return [] }
        var seen = Set<PixelRect>()
        var order: [PixelRect] = []
        func hasSeed(_ r: PixelRect) -> Bool {
            seeds.contains { $0.0 >= r.x0 && $0.0 < r.x1 && $0.1 >= r.y0 && $0.1 < r.y1 }
        }
        func visit(_ r: PixelRect, _ depth: Int) {
            if seen.contains(r) || seen.count >= budget { return }
            seen.insert(r)
            order.append(r)
            if depth >= maxDepth { return }
            for axis in 0..<2 {
                let segs = segments(r, axis: axis, minGap: minGap)
                let m = segs.count
                if m <= 1 { continue }
                for i in 0..<m {
                    for j in i..<m {
                        if i == 0 && j == m - 1 { continue }
                        let c: PixelRect?
                        if axis == 0 {
                            c = trim(PixelRect(x0: segs[i].0, y0: r.y0, x1: segs[j].1, y1: r.y1))
                        } else {
                            c = trim(PixelRect(x0: r.x0, y0: segs[i].0, x1: r.x1, y1: segs[j].1))
                        }
                        guard let cand = c else { continue }
                        if min(cand.width, cand.height) < minSide || !hasSeed(cand) { continue }
                        visit(cand, depth + 1)
                    }
                }
            }
        }
        visit(root, 0)
        return order
    }
}
