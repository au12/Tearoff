import Foundation

/// The system's text engines, as Tearoff needs them (Apple Vision and Core Text, supplied by
/// TearoffKit so this module stays pure Swift).
public struct TextServices {
    /// Reads the text in a gray image, best guesses first. Nil when no reader can run.
    public var read: ((GrayImage) -> [String]?)?
    /// Draws `text` black on white at `pixelsPerEm`, in a face that tells l, I and 1 (and O and 0)
    /// apart.
    public var draw: (_ text: String, _ pixelsPerEm: Double) -> GrayImage?

    public init(read: ((GrayImage) -> [String]?)?, draw: @escaping (_ text: String, _ pixelsPerEm: Double) -> GrayImage?) {
        self.read = read
        self.draw = draw
    }
}

/// The human-readable line printed beside a barcode (its "HRI"). On an extra-code label it is
/// usually a few pixels high in the source and comes out jagged when enlarged, so it's swapped for
/// crisp type drawn from the barcode's own checksum-verified value. That only happens when the
/// printed line provably says the same thing: on-device OCR reads it as the barcode's value, or,
/// when OCR can't run, it is the only text on the label, right next to the bars and the right
/// number of characters long.
public enum HRIText {

    public enum Verification: String { case ocr, layout }

    struct Band: Equatable {
        var x0: Int, y0: Int, x1: Int, y1: Int
        var width: Int { x1 - x0 }
        var height: Int { y1 - y0 }
        var rect: PixelRect { PixelRect(x0: x0, y0: y0, x1: x1, y1: y1) }
    }

    /// Lines of text: runs of inked rows above and below the barcode (its own rows excluded).
    static func bands(in img: GrayImage, excluding box: PixelRect) -> [Band] {
        let w = img.width, h = img.height
        var lo = [Int](repeating: Int.max, count: h), hi = [Int](repeating: -1, count: h)
        for y in 0..<h where y < box.y0 - 2 || y >= box.y1 + 2 {
            let row = y * w
            for x in 0..<w where img.pixels[row + x] < 128 {
                if x < lo[y] { lo[y] = x }
                hi[y] = x
            }
        }
        var out: [Band] = []
        var y = 0
        while y < h {
            if hi[y] < 0 { y += 1; continue }
            var b = Band(x0: lo[y], y0: y, x1: hi[y] + 1, y1: y + 1)
            var yy = y + 1, gap = 0
            while yy < h {
                if hi[yy] >= 0 {
                    b.y1 = yy + 1; b.x0 = min(b.x0, lo[yy]); b.x1 = max(b.x1, hi[yy] + 1); gap = 0
                } else {
                    gap += 1
                    // an i's dot or a colon's gap, but not the space between two lines
                    if gap > max(2, b.height / 5) { break }
                }
                yy += 1
            }
            out.append(b)
            y = b.y1 + 1
        }
        return out
    }

    /// Characters in a line: ink separated by blank columns.
    static func glyphCount(_ img: GrayImage, in b: Band) -> Int {
        guard b.width > 0 else { return 0 }
        var cols = [Bool](repeating: false, count: b.width)
        for y in b.y0..<b.y1 {
            let row = y * img.width
            for x in b.x0..<b.x1 where img.pixels[row + x] < 128 { cols[x - b.x0] = true }
        }
        var n = 0, inside = false
        for c in cols {
            if c && !inside { n += 1 }
            inside = c
        }
        return n
    }

    /// Folds characters OCR mixes up (and drops spaces and dashes), for comparing a reading with
    /// the barcode's value.
    static func canonical(_ s: String) -> String {
        var out = ""
        for ch in s.uppercased() {
            switch ch {
            case " ", "-", "_", ".", ":", "\t", "\n": continue
            case "O", "Q", "Ø": out.append("0")
            case "I", "L", "|", "!", "Í", "Ì": out.append("1")
            case "S", "$": out.append("5")
            case "Z": out.append("2")
            case "B": out.append("8")
            case "G": out.append("6")
            default: out.append(ch)
            }
        }
        return out
    }

    static func matches(_ readings: [String], _ value: String) -> Bool {
        let want = canonical(value)
        guard !want.isEmpty else { return false }
        return readings.contains { canonical($0) == want }
    }

    /// Finds the barcode's printed line on `out` and, when it checks out, replaces it with `value`
    /// in clean type, a little larger where there's room.
    /// - Parameters:
    ///   - code: where the (grid-fitted) barcode is on `out`.
    ///   - source: the high-resolution raster `out` was made from, for OCR; `toSource` maps a
    ///     rectangle on `out` into it.
    /// - Returns: how the line was confirmed, or nil when it was left alone.
    static func retypeset(_ out: inout GrayImage, code: PixelRect, value: String, source: GrayImage?,
                          toSource: (PixelRect) -> PixelRect, services: TextServices) -> Verification? {
        let chars = value.filter { !$0.isWhitespace }.count
        guard chars >= 3, code.width > 20, code.height > 10 else { return nil }
        let all = bands(in: out, excluding: code)
        // the line right above or below the bars, centred on them like a barcode's text
        let cx0 = Double(code.x0) + 0.2 * Double(code.width), cx1 = Double(code.x1) - 0.2 * Double(code.width)
        var best: (band: Band, gap: Int, above: Bool)? = nil
        for b in all {
            guard b.height >= 6, b.height <= max(8, code.height * 6 / 10), b.width <= code.width * 11 / 10 + 4 else { continue }
            let mid = Double(b.x0 + b.x1) / 2
            guard mid >= cx0, mid <= cx1 else { continue }
            let above = b.y1 <= code.y0
            let gap = above ? code.y0 - b.y1 : b.y0 - code.y1
            guard gap >= 0, Double(gap) <= max(4, 1.5 * Double(b.height)) else { continue }
            if best == nil || gap < best!.gap { best = (b, gap, above) }
        }
        guard let line = best else { return nil }

        // does the printed line say what the barcode says?
        var verified: Verification? = nil
        if let read = services.read, let src = source {
            let b = line.band
            let pad = max(4, b.height / 3)
            let r = toSource(PixelRect(x0: max(0, b.x0 - pad), y0: max(0, b.y0 - pad),
                                       x1: min(out.width, b.x1 + pad), y1: min(out.height, b.y1 + pad)))
            let crop = src.cropped(r)
            if crop.width > 4, crop.height > 4, let readings = read(crop), !readings.isEmpty {
                // OCR ran and read something else: it isn't the barcode's text, leave it be
                guard matches(readings, value) else { return nil }
                verified = .ocr
            }
        }
        if verified == nil {
            // no OCR: only when it's the one line of text on the label and has the right length
            let n = glyphCount(out, in: line.band)
            guard all.count == 1, n >= chars - max(2, chars / 5), n <= chars + 1 else { return nil }
            verified = .layout
        }

        // room to grow away from the bars, up to the next line or the edge
        let limit: Int
        if line.above {
            limit = line.band.y1 - ((all.filter { $0.y1 <= line.band.y0 }.map { $0.y1 + 2 }.max()) ?? 2)
        } else {
            limit = ((all.filter { $0.y0 >= line.band.y1 }.map { $0.y0 - 2 }.min()) ?? (out.height - 2)) - line.band.y0
        }
        let targetH = min(Int((Double(line.band.height) * 1.3).rounded()), limit)
        let maxW = min(max(code.width, line.band.width), out.width - 8)
        guard targetH >= line.band.height * 3 / 4, maxW > 0,
              let probe = services.draw(value, Double(line.band.height)), let pi = probe.inkBounds() else { return nil }
        let k = min(Double(targetH) / Double(max(1, pi.height)), Double(maxW) / Double(max(1, pi.width)))
        guard let drawn = services.draw(value, Double(line.band.height) * k), let di = drawn.inkBounds() else { return nil }
        let glyphs = drawn.cropped(di)
        let gw = glyphs.width, gh = glyphs.height
        guard gw <= out.width, gh <= out.height else { return nil }
        let left = max(0, min(out.width - gw, (line.band.x0 + line.band.x1 - gw) / 2))
        let top = line.above ? line.band.y1 - gh : line.band.y0
        guard top >= 0, top + gh <= out.height else { return nil }

        out.fill(PixelRect(x0: max(0, line.band.x0 - 1), y0: max(0, line.band.y0 - 1),
                           x1: min(out.width, line.band.x1 + 1), y1: min(out.height, line.band.y1 + 1)), value: 255)
        for y in 0..<gh {
            let srow = y * gw, drow = (top + y) * out.width + left
            for x in 0..<gw where glyphs.pixels[srow + x] < 128 { out.pixels[drow + x] = 0 }
        }
        return verified
    }
}

extension GrayImage {
    /// Bounds of the pixels darker than `level`, or nil for a blank image.
    public func inkBounds(below level: UInt8 = 128) -> PixelRect? {
        var x0 = width, y0 = height, x1 = -1, y1 = -1
        for y in 0..<height {
            let row = y * width
            for x in 0..<width where pixels[row + x] < level {
                if x < x0 { x0 = x }
                if x > x1 { x1 = x }
                if y < y0 { y0 = y }
                y1 = y
            }
        }
        return x1 < 0 ? nil : PixelRect(x0: x0, y0: y0, x1: x1 + 1, y1: y1 + 1)
    }
}
