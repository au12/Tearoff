import Foundation

/// Per-job printer settings. `nil` leaves the printer's own setting alone.
public struct PrintSettings: Codable, Equatable {
    /// 0…30 (~SD).
    public var darkness: Int?
    /// Inches per second (^PR), 2…6 on desktop printers.
    public var speed: Int?
    /// Shift the image down (+) or up (-), in dots (^LT).
    public var topOffset: Int = 0
    /// Shift the image right (+) or left (-), in dots.
    public var leftOffset: Int = 0
    public init(darkness: Int? = nil, speed: Int? = nil, topOffset: Int = 0, leftOffset: Int = 0) {
        self.darkness = darkness; self.speed = speed; self.topOffset = topOffset; self.leftOffset = leftOffset
    }

    /// ^LT / ^LS, only when Tearoff's own shift isn't zero. Sending them in every format would
    /// overwrite the printer's saved Label Top / Left Position, which is where Zebra says a
    /// printer's fixed offset belongs (it then applies to every Mac and app).
    public var shiftCommands: String {
        var s = ""
        if topOffset != 0 { s += "^LT\(max(-120, min(120, topOffset)))" }
        if leftOffset != 0 { s += "^LS\(-max(-200, min(200, leftOffset)))" }
        return s
    }
}

/// ZPL II output. Each label is one ^GF graphic field using Zebra's compressed ASCII hex
/// (run-length letters, `,` `!` row fills and `:` row repeats), so a 4×6 label at 203 dpi is
/// ~30–40 KB instead of ~250 KB and prints in one pass without pausing mid-label.
public enum ZPL {

    static let hexDigits: [UInt8] = Array("0123456789ABCDEF".utf8)
    static let lowerCounts: [UInt8] = Array("ghijklmnopqrstuvwxyz".utf8)   // 20, 40 … 400
    static let upperCounts: [UInt8] = Array("GHIJKLMNOPQRSTUVWXY".utf8)    // 1 … 19

    /// Compressed ^GFA payload for a binary raster.
    public static func graphicField(_ img: GrayImage) -> (data: String, bytesPerRow: Int, total: Int) {
        let bpr = (img.width + 7) / 8
        var out = [UInt8]()
        out.reserveCapacity(img.height * 24)
        var prev = [UInt8]()
        var hex = [UInt8](repeating: 0, count: bpr * 2)
        for y in 0..<img.height {
            let row = y * img.width
            for b in 0..<bpr {
                var byte: UInt8 = 0
                for bit in 0..<8 {
                    let x = b * 8 + bit
                    if x < img.width && img.pixels[row + x] < 128 { byte |= UInt8(0x80 >> bit) }
                }
                hex[2 * b] = hexDigits[Int(byte >> 4)]
                hex[2 * b + 1] = hexDigits[Int(byte & 0x0F)]
            }
            if hex == prev {
                out.append(UInt8(ascii: ":"))
            } else {
                out.append(contentsOf: compressRow(hex))
                prev = hex
            }
        }
        return (String(decoding: out, as: UTF8.self), bpr, bpr * img.height)
    }

    static func countCode(_ n: Int) -> [UInt8] {
        var c = [UInt8]()
        var n = n
        if n >= 20 { c.append(lowerCounts[n / 20 - 1]); n %= 20 }
        if n > 0 { c.append(upperCounts[n - 1]) }
        return c
    }

    static func compressRow(_ hex: [UInt8]) -> [UInt8] {
        var n = hex.count
        var tail: UInt8? = nil
        let zero = UInt8(ascii: "0"), f = UInt8(ascii: "F")
        var t = 0
        while t < n && hex[n - 1 - t] == zero { t += 1 }
        if t >= 2 {
            n -= t % 2 == 1 ? t - 1 : t      // an odd run keeps one literal zero
            tail = UInt8(ascii: ",")
        } else {
            t = 0
            while t < n && hex[n - 1 - t] == f { t += 1 }
            if t >= 2 {
                n -= t % 2 == 1 ? t - 1 : t
                tail = UInt8(ascii: "!")
            }
        }
        var out = [UInt8]()
        var i = 0
        while i < n {
            var j = i
            while j < n && hex[j] == hex[i] && j - i < 400 { j += 1 }
            let cnt = j - i
            if cnt > 1 { out.append(contentsOf: countCode(cnt)) }
            out.append(hex[i])
            i = j
        }
        if let t = tail { out.append(t) }
        return out
    }

    /// One complete label format.
    public static func label(_ img: GrayImage, copies: Int = 1, settings: PrintSettings = PrintSettings()) -> String {
        let gf = graphicField(img)
        var s = ""
        if let d = settings.darkness { s += String(format: "~SD%02d", max(0, min(30, d))) }
        s += "^XA"
        s += "^PW\(img.width)^LL\(img.height)^LH0,0^PON^FWN"
        if let sp = settings.speed { let v = max(1, min(14, sp)); s += "^PR\(v),\(v),\(v)" }
        s += settings.shiftCommands
        s += "^FO0,0^GFA,\(gf.total),\(gf.total),\(gf.bytesPerRow),"
        s += gf.data
        s += "^FS"
        s += "^PQ\(max(1, copies)),0,0,N"
        s += "^XZ\n"
        return s
    }

    public static func job(_ labels: [GrayImage], copies: Int = 1, settings: PrintSettings = PrintSettings()) -> String {
        labels.map { label($0, copies: copies, settings: settings) }.joined()
    }

    /// A printer-generated test label (fonts and barcodes rendered by the printer itself), shifted
    /// like real labels so the shift settings can be dialled in with it.
    public static func testLabel(widthDots: Int, heightDots: Int, dpi: Int, title: String = "Tearoff test label",
                                 settings: PrintSettings = PrintSettings()) -> String {
        let m = dpi / 10
        let w = widthDots - 2 * m
        var s = "^XA^PW\(widthDots)^LL\(heightDots)^LH0,0^CI28" + settings.shiftCommands
        s += "^FO\(m),\(m)^GB\(w),\(heightDots - 2 * m),3^FS"
        s += "^FO\(2 * m),\(2 * m)^A0N,\(dpi / 4),\(dpi / 4)^FD\(title)^FS"
        s += "^FO\(2 * m),\(2 * m + dpi / 3)^A0N,\(dpi / 8),\(dpi / 8)^FD\(dpi) dpi  \(widthDots)x\(heightDots) dots^FS"
        s += "^FO\(2 * m),\(2 * m + dpi * 3 / 5)^BY\(max(2, dpi / 100)),3,\(dpi * 3 / 4)^BCN,\(dpi * 3 / 4),Y,N,N^FD1Z999AA10123456784^FS"
        s += "^FO\(2 * m),\(2 * m + dpi * 2)^BQN,2,\(max(3, dpi / 40))^FDQA,https://github.com/au12/Tearoff^FS"
        s += "^FO\(2 * m),\(heightDots - 3 * m)^A0N,\(dpi / 9),\(dpi / 9)^FDIf the bars above scan, you're set.^FS"
        s += "^XZ\n"
        return s
    }

    // MARK: Decoding (tests and previews)

    /// Expands a compressed ^GFA payload into bytes (row-major, MSB = leftmost dot).
    public static func decodeGraphicField(_ data: String, bytesPerRow bpr: Int, rows: Int) -> [UInt8]? {
        var hexRows: [[UInt8]] = []
        var cur: [UInt8] = []
        var mult = 0
        let width = bpr * 2
        func finish(_ fill: UInt8) {
            if cur.count < width { cur.append(contentsOf: [UInt8](repeating: fill, count: width - cur.count)) }
            hexRows.append(cur)
            cur = []
        }
        for ch in data.utf8 {
            switch ch {
            case UInt8(ascii: "G")...UInt8(ascii: "Y"): mult += Int(ch - UInt8(ascii: "G")) + 1
            case UInt8(ascii: "g")...UInt8(ascii: "z"): mult += (Int(ch - UInt8(ascii: "g")) + 1) * 20
            case UInt8(ascii: ","): finish(UInt8(ascii: "0"))
            case UInt8(ascii: "!"): finish(UInt8(ascii: "F"))
            case UInt8(ascii: ":"):
                guard let last = hexRows.last else { return nil }
                hexRows.append(last)
            case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "A")...UInt8(ascii: "F"):
                let n = mult == 0 ? 1 : mult
                mult = 0
                cur.append(contentsOf: [UInt8](repeating: ch, count: n))
                if cur.count >= width {
                    if cur.count > width { return nil }
                    finish(UInt8(ascii: "0"))
                }
            case 10, 13, 32: continue
            default: return nil
            }
        }
        guard hexRows.count == rows else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(bpr * rows)
        func nib(_ c: UInt8) -> UInt8 { c <= UInt8(ascii: "9") ? c - UInt8(ascii: "0") : c - UInt8(ascii: "A") + 10 }
        for r in hexRows {
            var i = 0
            while i < r.count { bytes.append(nib(r[i]) << 4 | nib(r[i + 1])); i += 2 }
        }
        return bytes
    }

    /// Rasters of every ^GFA graphic field in a ZPL stream (only the uncompressed-binary-free 'A' form).
    public static func rasters(in zpl: String, widthDots: Int? = nil) -> [GrayImage] {
        var out: [GrayImage] = []
        var rest = Substring(zpl)
        while let r = rest.range(of: "^GFA,") {
            let after = rest[r.upperBound...]
            let parts = after.split(separator: ",", maxSplits: 3, omittingEmptySubsequences: false)
            guard parts.count == 4, let total = Int(parts[0]), let bpr = Int(parts[2]), bpr > 0 else { break }
            let dataPart = parts[3]
            let end = dataPart.firstIndex(where: { $0 == "^" || $0 == "~" }) ?? dataPart.endIndex
            let data = String(dataPart[..<end])
            let rows = total / bpr
            if let bytes = decodeGraphicField(data, bytesPerRow: bpr, rows: rows) {
                let w = widthDots ?? bpr * 8
                var img = GrayImage(width: w, height: rows)
                for y in 0..<rows {
                    for x in 0..<w where x < bpr * 8 {
                        if bytes[y * bpr + x / 8] & UInt8(0x80 >> (x % 8)) != 0 { img.pixels[y * w + x] = 0 }
                    }
                }
                out.append(img)
            }
            rest = dataPart[end...]
        }
        return out
    }
}
