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
        let wx = BoxWeights(inCount: width, outCount: ow)
        let wy = BoxWeights(inCount: height, outCount: oh)
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
