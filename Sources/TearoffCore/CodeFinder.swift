import Foundation

/// Barcodes and QR codes that sit *outside* the labels on a page (a return-authorization slip, a
/// drop-off QR code, an order barcode…). Each becomes its own label: the symbol plus the
/// human-readable text printed right next to it, nothing else.
public enum CodeFinder {

    /// Most extra codes taken from one page.
    public static let maxPerPage = 6

    /// - Parameters:
    ///   - big: the page rendered at `scale` pixels per point.
    ///   - linear: 1D barcodes found in `big`.
    ///   - labels: regions already printed as labels (codes inside them are skipped).
    public static func find(big: GrayImage, scale hb: Double, linear: [LinearBarcode], labels: [PageRect],
                            trace: PerfTrace? = nil) -> [LabelCandidate] {
        guard big.width > 2, big.height > 2, hb > 0 else { return [] }
        let qrs = trace.measureOrRun("find.extras_qr") { QRFinder.find(in: big, ppi: hb * 72) }
        func toPage(_ r: PixelRect) -> PageRect {
            PageRect(x0: Double(r.x0) / hb, y0: Double(r.y0) / hb, x1: Double(r.x1) / hb, y1: Double(r.y1) / hb)
        }
        func insideLabel(_ r: PageRect) -> Bool {
            labels.contains { l in
                let m = 0.04 * max(l.width, l.height)
                return l.contains(x: r.midX, y: r.midY, pad: m) || r.intersectionArea(l) > 0.25 * r.area
            }
        }
        var inkCache: Ink? = nil
        func ink() -> Ink {
            if let i = inkCache { return i }
            let i = Ink(big.mask(below: 160), width: big.width, height: big.height)
            inkCache = i
            return i
        }
        var out: [LabelCandidate] = []

        for b in linear {
            // decoded Code 128, or a clearly barcode-shaped block of bars in another symbology: tall
            // enough (a quarter inch) that a line of big, regular lettering can't pass for one
            let across = Double(b.axis == 0 ? b.rect.height : b.rect.width) / hb
            guard b.text != nil || (b.lines >= 8 && b.elements >= 30 && across >= 18) else { continue }
            let symbol = toPage(b.rect)
            if insideLabel(symbol) { continue }
            let grown = grow(ink(), b.rect, textBeside: b.axis == 1, scale: hb, qr: false)
            var c = LabelCandidate(kind: .code, rect: toPage(grown).insetBy(-1))
            c.barcodes = [b]
            c.symbology = b.text != nil ? "Code 128" : "barcode"
            let up = BarcodeFinder.uprightQuarterTurns([b])
            c.quarterTurns = up ?? (b.axis == 0 ? 0 : 3)
            // Code 128 wants 10 modules of white either end
            let quiet = 10 * b.module / hb
            c.quietZone = b.axis == 0 ? (quiet, 0) : (0, quiet)
            out.append(c)
        }
        for q in qrs {
            let symbol = toPage(q.rect)
            if insideLabel(symbol) { continue }
            if out.contains(where: { $0.rect.intersectionArea(symbol) > 0.25 * symbol.area }) { continue }
            let grown = grow(ink(), q.rect, textBeside: false, scale: hb, qr: true)
            var c = LabelCandidate(kind: .code, rect: toPage(grown).insetBy(-1))
            c.symbology = "QR code"
            c.quarterTurns = 0
            let quiet = 4 * q.module / hb
            c.quietZone = (quiet, quiet)
            out.append(c)
        }
        // one entry per symbol (a code's text growth can swallow a neighbour), reading order
        var keep: [LabelCandidate] = []
        for c in out where !keep.contains(where: { $0.rect.intersectionArea(c.rect) > 0.5 * min($0.rect.area, c.rect.area) }) {
            keep.append(c)
        }
        keep.sort {
            let ra = ($0.rect.midY / 144).rounded(), rb = ($1.rect.midY / 144).rounded()
            return ra != rb ? ra < rb : $0.rect.midX < $1.rect.midX
        }
        return Array(keep.prefix(maxPerPage))
    }

    /// Binary ink raster, read in a code's own frame: `u` runs along the symbol, `v` across it.
    struct Ink {
        let px: [UInt8]
        let width: Int
        let height: Int
        init(_ px: [UInt8], width: Int, height: Int) { self.px = px; self.width = width; self.height = height }
    }

    /// Grows a symbol's pixel rect across the symbol (above/below it, or left/right when the text
    /// runs beside a sideways barcode) to take in narrow, centred lines of text: the human-readable
    /// digits, a return code under a QR code. Stops at rules, paragraphs, tables and big gaps.
    static func grow(_ ink: Ink, _ rect: PixelRect, textBeside: Bool, scale hb: Double, qr: Bool) -> PixelRect {
        let r = PixelRect(x0: max(0, min(ink.width, rect.x0)), y0: max(0, min(ink.height, rect.y0)),
                          x1: max(0, min(ink.width, rect.x1)), y1: max(0, min(ink.height, rect.y1)))
        // u: along the symbol; v: across it (the direction text lines are stacked in)
        let U = textBeside ? ink.height : ink.width
        let V = textBeside ? ink.width : ink.height
        @inline(__always) func at(_ u: Int, _ v: Int) -> Bool {
            textBeside ? ink.px[u * ink.width + v] == 1 : ink.px[v * ink.width + u] == 1
        }
        let u0 = textBeside ? r.y0 : r.x0, u1 = textBeside ? r.y1 : r.x1
        let v0 = textBeside ? r.x0 : r.y0, v1 = textBeside ? r.x1 : r.y1
        let cw = Double(u1 - u0), ch = Double(v1 - v0)
        guard cw > 2, ch > 2 else { return r }
        let slack = 0.10 * cw
        let bu0 = max(0, Int(Double(u0) - slack)), bu1 = min(U, Int(Double(u1) + slack))
        let maxGap = qr ? min(max(6 * hb, 0.12 * ch), 14 * hb) : min(max(4 * hb, 0.2 * ch), 8 * hb)
        let minLine = min(max(1.5 * hb, 0.1 * ch), 3 * hb)       // thinner: a rule, not text
        let maxLine = max(6 * hb, min(0.5 * ch, 24 * hb))         // taller: another symbol or a picture
        let maxAdd = max(12 * hb, 0.8 * ch)

        func darkCount(_ v: Int, _ a: Int, _ b: Int) -> Int {
            var n = 0
            var u = a
            while u < b { if at(u, v) { n += 1 }; u += 1 }
            return n
        }
        var lo0 = u0, hi0 = u1, lo1 = v0, hi1 = v1
        for d in [-1, 1] {
            var edge = d < 0 ? v0 : v1 - 1
            var v = edge + d
            // bars can run a little past the scanlines that found them
            while v >= 0 && v < V && Double(darkCount(v, u0, u1)) > 0.25 * cw { edge = v; v += d }
            var added = 0.0
            lines: while true {
                var gap = 0
                while v >= 0 && v < V && darkCount(v, bu0, bu1) < 2 && Double(gap) <= maxGap { v += d; gap += 1 }
                if v < 0 || v >= V || Double(gap) > maxGap { break }
                let ls = v
                while v >= 0 && v < V && darkCount(v, bu0, bu1) >= 2 && Double(abs(v - ls)) <= maxLine { v += d }
                let le = v - d
                let lh = Double(abs(le - ls) + 1)
                if lh > maxLine || lh < minLine { break }
                let lo = min(ls, le), hi = max(ls, le)
                // the line's full extent, following its ink across word gaps
                var cols = [Bool](repeating: false, count: U)
                for u in 0..<U {
                    var vv = lo
                    while vv <= hi { if at(u, vv) { cols[u] = true; break }; vv += 1 }
                }
                guard let first = (bu0..<bu1).first(where: { cols[$0] }),
                      let last = (bu0..<bu1).last(where: { cols[$0] }) else { break }
                var a = first, b = last + 1
                let wordGap = max(3 * hb, 1.2 * lh)
                var x = a - 1, blank = 0.0
                while x >= 0 && blank <= wordGap { if cols[x] { a = x; blank = 0 } else { blank += 1 }; x -= 1 }
                x = b; blank = 0
                while x < U && blank <= wordGap { if cols[x] { b = x + 1; blank = 0 } else { blank += 1 }; x += 1 }
                let inside = Double(a) >= Double(u0) - slack && Double(b) <= Double(u1) + slack
                let centred = abs(Double(a + b) / 2 - Double(u0 + u1) / 2) <= 0.2 * cw
                if !(inside && centred) { break lines }
                added += lh + Double(gap)
                if added > maxAdd { break lines }
                if d < 0 { lo1 = lo } else { hi1 = hi + 1 }
                lo0 = min(lo0, a); hi0 = max(hi0, b)
                edge = le
            }
            if d < 0 { lo1 = min(lo1, edge) } else { hi1 = max(hi1, edge + 1) }
        }
        return textBeside ? PixelRect(x0: lo1, y0: lo0, x1: hi1, y1: hi0) : PixelRect(x0: lo0, y0: lo1, x1: hi0, y1: hi1)
    }
}
