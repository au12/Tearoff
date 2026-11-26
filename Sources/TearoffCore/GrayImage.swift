import Foundation

/// 8-bit grayscale raster, row-major, top row first. 0 = black, 255 = white.
/// A *binary* GrayImage only holds 0 and 255; that is what goes to the printer.
public struct GrayImage: Equatable {
    public let width: Int
    public let height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, fill: UInt8 = 255) {
        self.width = max(0, width)
        self.height = max(0, height)
        pixels = [UInt8](repeating: fill, count: self.width * self.height)
    }

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height, "pixel count mismatch")
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    @inline(__always) public subscript(x: Int, y: Int) -> UInt8 {
        get { pixels[y * width + x] }
        set { pixels[y * width + x] = newValue }
    }

    /// Rotates by quarter turns *clockwise*.
    public func rotated(quarterTurnsCW q: Int) -> GrayImage {
        let k = ((q % 4) + 4) % 4
        if k == 0 { return self }
        let nw = k % 2 == 0 ? width : height
        let nh = k % 2 == 0 ? height : width
        var out = GrayImage(width: nw, height: nh)
        let w = width, h = height
        pixels.withUnsafeBufferPointer { src in
            out.pixels.withUnsafeMutableBufferPointer { dst in
                for y in 0..<h {
                    let row = y * w
                    for x in 0..<w {
                        let v = src[row + x]
                        switch k {
                        case 1: dst[x * nw + (h - 1 - y)] = v              // (x,y) -> (h-1-y, x)
                        case 2: dst[(h - 1 - y) * nw + (w - 1 - x)] = v    // (x,y) -> (w-1-x, h-1-y)
                        default: dst[(w - 1 - x) * nw + y] = v             // (x,y) -> (y, w-1-x)
                        }
                    }
                }
            }
        }
        return out
    }

    public func cropped(_ r: PixelRect) -> GrayImage {
        let x0 = max(0, min(width, r.x0)), x1 = max(x0, min(width, r.x1))
        let y0 = max(0, min(height, r.y0)), y1 = max(y0, min(height, r.y1))
        var out = GrayImage(width: x1 - x0, height: y1 - y0)
        for y in y0..<y1 {
            let s = y * width + x0, d = (y - y0) * out.width
            for i in 0..<(x1 - x0) { out.pixels[d + i] = pixels[s + i] }
        }
        return out
    }

    /// Box-filter weights mapping `inCount` samples onto `outCount` samples (exact area coverage).
    struct BoxWeights {
        var start: [Int] = []
        var count: [Int] = []
        var weights: [Float] = []
        var offset: [Int] = []

        init() {}

        /// Lanczos-3 weights, widened when shrinking so the filter still averages. Taps past the
        /// edges repeat the first/last pixel.
        init(lanczosFrom inCount: Int, to outCount: Int, lobes a: Double = 3) {
            let scale = Double(inCount) / Double(max(1, outCount))
            let stretch = max(1, scale)
            let support = a * stretch
            start.reserveCapacity(outCount); count.reserveCapacity(outCount); offset.reserveCapacity(outCount)
            for o in 0..<outCount {
                let c = (Double(o) + 0.5) * scale - 0.5
                let i0 = Int((c - support).rounded(.up)), i1 = max(i0, Int((c + support).rounded(.down)))
                let lo = max(0, min(inCount - 1, i0)), hi = max(lo, min(inCount - 1, i1))
                var ws = [Double](repeating: 0, count: hi - lo + 1)
                var total = 0.0
                for i in i0...i1 {
                    let w = Self.lanczos((Double(i) - c) / stretch, a)
                    ws[max(lo, min(hi, i)) - lo] += w
                    total += w
                }
                if abs(total) < 1e-9 { ws = [Double](repeating: 0, count: ws.count); ws[0] = 1; total = 1 }
                start.append(lo)
                count.append(ws.count)
                offset.append(weights.count)
                for w in ws { weights.append(Float(w / total)) }
            }
        }

        static func lanczos(_ x: Double, _ a: Double) -> Double {
            if x == 0 { return 1 }
            if abs(x) >= a { return 0 }
            let px = Double.pi * x
            return a * sin(px) * sin(px / a) / (px * px)
        }

        init(inCount: Int, outCount: Int) {
            let scale = Double(inCount) / Double(max(1, outCount))
            start.reserveCapacity(outCount); count.reserveCapacity(outCount); offset.reserveCapacity(outCount)
            for o in 0..<outCount {
                let s = Double(o) * scale, e = Double(o + 1) * scale
                let i0 = Int(s.rounded(.down)), i1 = min(inCount, Int(e.rounded(.up)))
                var ws = [Float]()
                var total: Float = 0
                var i = i0
                while i < i1 {
                    let w = Float(min(e, Double(i + 1)) - max(s, Double(i)))
                    ws.append(max(0, w)); total += max(0, w)
                    i += 1
                }
                if total <= 0 { ws = [1]; total = 1 }
                start.append(min(i0, inCount - 1))
                count.append(ws.count)
                offset.append(weights.count)
                for w in ws { weights.append(w / total) }
            }
        }
    }

    /// Area-averaging resample. Each output pixel is the exact mean of the source area it covers,
    /// so a 50% threshold afterwards puts every edge on the nearest printer dot.
    public func resampled(width ow: Int, height oh: Int) -> GrayImage {
        guard ow > 0, oh > 0, width > 0, height > 0 else { return GrayImage(width: ow, height: oh) }
        if ow == width && oh == height { return self }
        return separable(BoxWeights(inCount: width, outCount: ow), BoxWeights(inCount: height, outCount: oh), ow: ow, oh: oh)
    }

    /// Lanczos-3 resample: for enlarging, it rebuilds edges at their sub-pixel positions instead of
    /// copying pixels into blocks.
    public func lanczosResampled(width ow: Int, height oh: Int) -> GrayImage {
        guard ow > 0, oh > 0, width > 0, height > 0 else { return GrayImage(width: ow, height: oh) }
        if ow == width && oh == height { return self }
        return separable(BoxWeights(lanczosFrom: width, to: ow), BoxWeights(lanczosFrom: height, to: oh), ow: ow, oh: oh)
    }

    /// True when (nearly) every pixel is pure black or white: a 1-bit source, with no
    /// anti-aliasing to say where its edges really are.
    public var isBlackAndWhite: Bool {
        guard !pixels.isEmpty else { return true }
        var gray = 0
        for p in pixels where p > 24 && p < 232 { gray += 1 }
        return gray * 1000 < pixels.count * 3
    }

    /// Scale2x (EPX): doubles a black-and-white image and rounds off the staircase on diagonals
    /// and curves, without dropping or merging any pixel.
    public func scale2x(threshold: UInt8 = 128) -> GrayImage {
        let w = width, h = height
        guard w > 0, h > 0 else { return self }
        var b = [Bool](repeating: false, count: w * h)
        for i in 0..<(w * h) { b[i] = pixels[i] < threshold }
        var out = GrayImage(width: 2 * w, height: 2 * h)
        let ow = 2 * w
        b.withUnsafeBufferPointer { b in
            out.pixels.withUnsafeMutableBufferPointer { o in
                for y in 0..<h {
                    let up = max(0, y - 1) * w, row = y * w, down = min(h - 1, y + 1) * w
                    for x in 0..<w {
                        let e = b[row + x]
                        let a = b[up + x], d = b[down + x]
                        let l = b[row + max(0, x - 1)], r = b[row + min(w - 1, x + 1)]
                        var e0 = e, e1 = e, e2 = e, e3 = e
                        if l == a && l != d && a != r { e0 = a }
                        if a == r && a != l && r != d { e1 = r }
                        if d == l && d != r && l != a { e2 = l }
                        if r == d && r != a && d != l { e3 = d }
                        let k = 2 * y * ow + 2 * x
                        o[k] = e0 ? 0 : 255
                        o[k + 1] = e1 ? 0 : 255
                        o[k + ow] = e2 ? 0 : 255
                        o[k + ow + 1] = e3 ? 0 : 255
                    }
                }
            }
        }
        return out
    }

    /// Enlarges a low-resolution raster for printing by rebuilding smooth edges instead of copying
    /// pixels into blocks. Anti-aliased (gray) sources go through Lanczos, which keeps their
    /// sub-pixel edge positions; black-and-white sources are first rounded off with Scale2x
    /// (unless `keepSquares`, for symbols such as QR codes whose corners must stay square).
    public func smoothlyEnlarged(width ow: Int, height oh: Int, keepSquares: Bool = false) -> (image: GrayImage, blackAndWhite: Bool) {
        let bw = isBlackAndWhite
        var src = self
        if bw && !keepSquares {
            var n = 0
            while n < 2 && Double(src.width * 2) <= Double(ow) * 1.5 && Double(src.height * 2) <= Double(oh) * 1.5 {
                src = src.scale2x()
                n += 1
            }
        }
        let out = src.width < ow || src.height < oh ? src.lanczosResampled(width: ow, height: oh) : src.resampled(width: ow, height: oh)
        return (out, bw)
    }

    func separable(_ wx: BoxWeights, _ wy: BoxWeights, ow: Int, oh: Int) -> GrayImage {
        var tmp = [Float](repeating: 0, count: height * ow)
        let w = width, h = height
        pixels.withUnsafeBufferPointer { src in
            tmp.withUnsafeMutableBufferPointer { t in
                wx.weights.withUnsafeBufferPointer { ww in
                    for y in 0..<h {
                        let row = y * w
                        for o in 0..<ow {
                            let st = wx.start[o], n = wx.count[o], off = wx.offset[o]
                            var acc: Float = 0
                            for i in 0..<n { acc += Float(src[row + st + i]) * ww[off + i] }
                            t[y * ow + o] = acc
                        }
                    }
                }
            }
        }
        var out = GrayImage(width: ow, height: oh)
        tmp.withUnsafeBufferPointer { t in
            out.pixels.withUnsafeMutableBufferPointer { dst in
                wy.weights.withUnsafeBufferPointer { ww in
                    for o in 0..<oh {
                        let st = wy.start[o], n = wy.count[o], off = wy.offset[o]
                        for x in 0..<ow {
                            var acc: Float = 0
                            for i in 0..<n { acc += t[(st + i) * ow + x] * ww[off + i] }
                            dst[o * ow + x] = UInt8(max(0, min(255, acc.rounded())))
                        }
                    }
                }
            }
        }
        return out
    }

    /// Pure black/white at `level` (pixels darker than level become black).
    public func thresholded(_ level: Int = 128) -> GrayImage {
        var out = self
        let l = UInt8(max(1, min(255, level)))
        for i in 0..<out.pixels.count { out.pixels[i] = out.pixels[i] < l ? 0 : 255 }
        return out
    }

    /// Floyd–Steinberg error diffusion to pure black/white (for photos/logos).
    public func dithered() -> GrayImage {
        var err = pixels.map { Float($0) }
        var out = GrayImage(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                let old = err[i]
                let new: Float = old < 128 ? 0 : 255
                out.pixels[i] = UInt8(new)
                let e = old - new
                if x + 1 < width { err[i + 1] += e * 7 / 16 }
                if y + 1 < height {
                    if x > 0 { err[i + width - 1] += e * 3 / 16 }
                    err[i + width] += e * 5 / 16
                    if x + 1 < width { err[i + width + 1] += e * 1 / 16 }
                }
            }
        }
        return out
    }

    /// Binary mask (1 = ink) at `level`.
    public func mask(below level: UInt8) -> [UInt8] {
        pixels.map { $0 < level ? 1 : 0 }
    }

    /// Pastes `img` with its top-left at (ox, oy), clipping to bounds.
    public mutating func paste(_ img: GrayImage, x ox: Int, y oy: Int) {
        for y in 0..<img.height {
            let ty = oy + y
            if ty < 0 || ty >= height { continue }
            for x in 0..<img.width {
                let tx = ox + x
                if tx < 0 || tx >= width { continue }
                pixels[ty * width + tx] = img.pixels[y * img.width + x]
            }
        }
    }

    public mutating func fill(_ r: PixelRect, value: UInt8) {
        let x0 = max(0, r.x0), x1 = min(width, r.x1), y0 = max(0, r.y0), y1 = min(height, r.y1)
        guard x1 > x0, y1 > y0 else { return }
        for y in y0..<y1 {
            let row = y * width
            for x in x0..<x1 { pixels[row + x] = value }
        }
    }

    /// Fraction of pixels darker than 128 in row `y` between x0..<x1.
    public func darkFraction(row y: Int, from x0: Int, to x1: Int) -> Double {
        guard y >= 0, y < height else { return 0 }
        let a = max(0, x0), b = min(width, x1)
        guard b > a else { return 0 }
        var n = 0
        for x in a..<b where pixels[y * width + x] < 128 { n += 1 }
        return Double(n) / Double(b - a)
    }

    /// Number of black pixels (binary images).
    public var blackCount: Int { pixels.reduce(0) { $0 + ($1 < 128 ? 1 : 0) } }
}
