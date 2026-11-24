import Foundation

public struct RenderOptions: Equatable {
    public var dpi: Int = 203
    public var size: LabelSize = .fourBySix
    /// Redraw verified Code 128 symbols with whole-dot modules.
    public var gridFit = true
    /// Gray level below which a dot prints (128 = 50% coverage). Higher = bolder.
    public var threshold = 128
    public init(dpi: Int = 203, size: LabelSize = .fourBySix, gridFit: Bool = true, threshold: Int = 128) {
        self.dpi = dpi; self.size = size; self.gridFit = gridFit; self.threshold = threshold
    }
}

/// The finished, printer-ready label.
public struct RenderedLabel {
    /// Binary raster at the printer's resolution (0 = burn a dot).
    public var image: GrayImage
    /// Code 128 symbols that were redrawn on the dot grid.
    public var gridFitted: Int
    /// Decoded Code 128 texts (tracking numbers etc.).
    public var barcodeTexts: [String]
    /// Quarter turns clockwise from the page to the printed label, when the renderer chose them.
    public var quarterTurns: Int? = nil
}

/// How a found region maps onto the label stock.
public enum LabelFit {
    /// The region *is* the label (embedded label image, cut-line frame, label-sized page): fill the stock.
    case fill
    /// Unframed content: keep true size when it was drawn at true size, otherwise fit with a small margin.
    case natural
    /// Arbitrary content: fit inside the stock with a small margin.
    case contain
}

public enum LabelRenderer {

    /// Renders a found label to a binary raster of exactly `options.size` at `options.dpi`.
    public static func render(_ c: LabelCandidate, options: RenderOptions, fit: LabelFit? = nil, trace: PerfTrace? = nil,
                              render: RegionRenderer) -> RenderedLabel {
        let (TW, TH) = options.size.dots(dpi: options.dpi)
        let q = ((c.quarterTurns % 4) + 4) % 4
        let mode = fit ?? (c.kind == .block ? .natural : .fill)
        var rect = c.rect
        // a frame is usually a printed cut line: keep it out of the label
        if c.kind == .frame && rect.width > 20 && rect.height > 20 { rect = rect.insetBy(1.5) }
        var rw: Int, rh: Int
        var exact = false
        if c.kind == .image, let n = c.native {
            rw = n.width; rh = n.height
            exact = true
            if max(rw, rh) < Int(1.2 * Double(max(TW, TH))) { rw *= 3; rh *= 3 }
        } else {
            let (cw, ch) = q % 2 == 0 ? (TW, TH) : (TH, TW)
            let s = min(Double(cw) / rect.width, Double(ch) / rect.height)
            rw = max(1, Int((rect.width * s * 3).rounded()))
            rh = max(1, Int((rect.height * s * 3).rounded()))
        }
        // keep memory sane for very large embedded images
        let maxPixels = 40_000_000
        if rw * rh > maxPixels {
            let f = (Double(maxPixels) / Double(rw * rh)).squareRoot()
            rw = max(1, Int(Double(rw) * f)); rh = max(1, Int(Double(rh) * f))
            exact = false
        }
        let raw = trace.measureOrRun("render.region") { render(rect, rw, rh, exact) }
        let g = trace.measureOrRun("render.rotate") { raw.rotated(quarterTurnsCW: q) }
        trace?.count("render_pixels", rw * rh)
        var dest: PixelRect? = nil
        if mode != .fill {
            // upright size in points → dots
            let (pw, ph) = q % 2 == 0 ? (rect.width, rect.height) : (rect.height, rect.width)
            let natural = Double(options.dpi) / 72
            let W = Double(TW), H = Double(TH)
            var k = min(W * 0.96 / pw, H * 0.96 / ph)
            if mode == .natural {
                let w0 = pw * natural, h0 = ph * natural
                if w0 <= W && h0 <= H && (w0 >= 0.8 * W || h0 >= 0.8 * H) { k = natural }   // drawn at true size
            }
            let ow = max(1, min(TW, Int((pw * k).rounded()))), oh = max(1, min(TH, Int((ph * k).rounded())))
            dest = PixelRect(x0: (TW - ow) / 2, y0: (TH - oh) / 2, x1: (TW - ow) / 2 + ow, y1: (TH - oh) / 2 + oh)
        }
        return finish(g, options: options, into: dest, trace: trace)
    }

    /// Renders an extra code (a barcode or QR code plus its text) as large as the stock allows,
    /// keeping its quiet zone, and lays it on its side when that makes it bigger. Barcodes are
    /// grid-fitted in the upright frame first, so the turn (a lossless bit rotation) keeps them exact.
    public static func renderCode(_ c: LabelCandidate, options: RenderOptions, trace: PerfTrace? = nil,
                                  render: RegionRenderer) -> RenderedLabel {
        let (TW, TH) = options.size.dots(dpi: options.dpi)
        let q = ((c.quarterTurns % 4) + 4) % 4
        let rect = c.rect
        guard rect.width > 0, rect.height > 0 else {
            return RenderedLabel(image: GrayImage(width: TW, height: TH), gridFitted: 0, barcodeTexts: [])
        }
        // upright size in points, quiet zone included
        let pw = rect.width + 2 * c.quietZone.x, ph = rect.height + 2 * c.quietZone.y
        let (uw, uh) = q % 2 == 0 ? (pw, ph) : (ph, pw)
        let kUpright = min(Double(TW) * 0.96 / uw, Double(TH) * 0.96 / uh)
        let kSideways = min(Double(TH) * 0.96 / uw, Double(TW) * 0.96 / uh)
        let sideways = kSideways > kUpright * 1.02
        let k = sideways ? kSideways : kUpright          // dots per point
        var canvas = options
        if sideways { canvas.size = LabelSize(width: options.size.height, height: options.size.width) }
        let (CW, CH) = canvas.size.dots(dpi: options.dpi)

        // render the region 3x oversampled onto white that carries the quiet zone, so nothing next
        // to the code comes along and the barcode finder sees clean margins
        var f = 3 * k                                     // pixels per point
        let maxPixels = 40_000_000.0
        if pw * ph * f * f > maxPixels { f = (maxPixels / (pw * ph)).squareRoot() }
        let rw = max(1, Int((rect.width * f).rounded())), rh = max(1, Int((rect.height * f).rounded()))
        let raw = trace.measureOrRun("render.region") { render(rect, rw, rh, false) }
        trace?.count("render_pixels", rw * rh)
        var padded = GrayImage(width: max(rw, Int((pw * f).rounded())), height: max(rh, Int((ph * f).rounded())))
        padded.paste(raw, x: (padded.width - rw) / 2, y: (padded.height - rh) / 2)
        let g = trace.measureOrRun("render.rotate") { padded.rotated(quarterTurnsCW: q) }
        let (ow, oh) = (Double(g.width) / f * k, Double(g.height) / f * k)
        let owI = max(1, min(CW, Int(ow.rounded()))), ohI = max(1, min(CH, Int(oh.rounded())))
        let dest = PixelRect(x0: (CW - owI) / 2, y0: (CH - ohI) / 2, x1: (CW - owI) / 2 + owI, y1: (CH - ohI) / 2 + ohI)
        // barcode size limits apply at the page's own scale, where the symbol had normal proportions
        var out = finish(g, options: canvas, into: dest, ppi: f * 72, trace: trace)
        if sideways {
            let turned = trace.measureOrRun("render.rotate") { out.image.rotated(quarterTurnsCW: 3) }
            out.image = turned
        }
        out.quarterTurns = (q + (sideways ? 3 : 0)) % 4
        return out
    }

    /// Fits an upright high-resolution raster onto the label (or into `dest`), thresholds it and
    /// grid-fits barcodes. `ppi` (pixels per inch of `g` at the scale barcode limits apply to)
    /// defaults to the label's own scale.
    public static func finish(_ g: GrayImage, options: RenderOptions, into dest: PixelRect? = nil, ppi: Double? = nil,
                              trace: PerfTrace? = nil) -> RenderedLabel {
        let (TW, TH) = options.size.dots(dpi: options.dpi)
        let gw = g.width, gh = g.height
        guard gw > 0, gh > 0 else { return RenderedLabel(image: GrayImage(width: TW, height: TH), gridFitted: 0, barcodeTexts: []) }
        var ow = TW, oh = TH
        var ox = 0, oy = 0
        if let d = dest {
            ow = d.width; oh = d.height; ox = d.x0; oy = d.y0
        } else {
            let sx = Double(TW) / Double(gw), sy = Double(TH) / Double(gh)
            if abs(sx / sy - 1) >= 0.04 {
                let s = min(sx, sy)
                ow = max(1, min(TW, Int((Double(gw) * s).rounded())))
                oh = max(1, min(TH, Int((Double(gh) * s).rounded())))
            }
            ox = (TW - ow) / 2; oy = (TH - oh) / 2
        }
        let small = trace.measureOrRun("render.resample") { g.resampled(width: ow, height: oh) }
        var out = GrayImage(width: TW, height: TH)
        out.paste(small, x: ox, y: oy)
        var bits = out.thresholded(options.threshold)

        let hrPPI = ppi ?? Double(min(gw, gh)) / min(options.size.width, options.size.height)
        let codes = trace.measureOrRun("render.barcodes") { BarcodeFinder.find(in: g, ppi: hrPPI) }
        var texts = codes.compactMap { $0.text }
        var fitted = 0
        if options.gridFit {
            let plans = trace.measureOrRun("render.gridfit_plan") { planGridFit(g, codes: codes, ppi: hrPPI) }
            fitted = applyGridFit(&bits, plans: plans, scale: Double(ow) / Double(gw), offsetX: ox, offsetY: oy)
            for p in plans where !texts.contains(p.text) { texts.append(p.text) }
        }
        return RenderedLabel(image: bits, gridFitted: fitted, barcodeTexts: texts)
    }

    // MARK: Grid-fit

    public struct GridFitPlan {
        public var left: Double
        public var right: Double
        public var top: Int
        public var bottom: Int
        public var modules: [Int]
        public var module: Double
        public var text: String
    }

    /// Finds Code 128 symbols in an upright raster and measures them exactly. Only symbols that
    /// decode with a valid checksum are planned, so a redraw can never change what scans.
    public static func planGridFit(_ g: GrayImage, codes: [LinearBarcode], ppi: Double) -> [GridFitPlan] {
        var plans: [GridFitPlan] = []
        let W = g.width, H = g.height
        for r in codes where r.axis == 0 && r.forward > r.reverse {
            let y0 = r.rect.y0, y1 = min(H, r.rect.y1)
            let bandTop = y0 + (y1 - y0) / 4
            let bandBot = max(bandTop + 1, y1 - (y1 - y0) / 4)
            let lo = max(0, r.rect.x0 - Int(0.08 * ppi)), hi = min(W, r.rect.x1 + Int(0.08 * ppi))
            guard hi - lo > 10, bandBot <= H else { continue }
            // column profile: a column is "bar" if most rows of the band are dark
            var prof = [Bool](repeating: false, count: hi - lo)
            let rows = bandBot - bandTop
            for x in lo..<hi {
                var n = 0
                for y in bandTop..<bandBot where g.pixels[y * W + x] < 128 { n += 1 }
                prof[x - lo] = n * 2 > rows
            }
            var st = [Int](), ln = [Int](), blk = [Bool]()
            var cur = prof[0], start = 0
            for i in 1..<prof.count where prof[i] != cur {
                st.append(start); ln.append(i - start); blk.append(cur)
                cur = prof[i]; start = i
            }
            st.append(start); ln.append(prof.count - start); blk.append(cur)
            guard let i0 = blk.firstIndex(of: true), let i1 = blk.lastIndex(of: true), i1 - i0 >= 18 else { continue }
            guard let q = BarcodeFinder.quantize(Array(ln[i0...i1])) else { continue }
            guard let vals = BarcodeFinder.code128Values(q.modules) else { continue }
            let left = Double(lo + st[i0]), right = Double(lo + st[i1] + ln[i1])
            // vertical extent: follow the wider bars up and down from the band centre
            var tops = [Int](), bots = [Int]()
            var x = left
            let cy = (y0 + y1) / 2
            for (k, mm) in q.modules.enumerated() {
                let wpx = Double(mm) * q.module
                if k % 2 == 0 && mm >= 2 {
                    let cx = min(W - 1, max(0, Int((x + wpx / 2).rounded())))
                    var t = cy
                    while t > 0 && g.pixels[(t - 1) * W + cx] < 128 { t -= 1 }
                    var b = cy
                    while b < H - 1 && g.pixels[(b + 1) * W + cx] < 128 { b += 1 }
                    tops.append(t); bots.append(b + 1)
                }
                x += wpx
            }
            guard !tops.isEmpty else { continue }
            let mt = BarcodeFinder.median(tops.map(Double.init)), mb = BarcodeFinder.median(bots.map(Double.init))
            let tol = 0.04 * (mb - mt) + 2
            let top = tops.filter { Double($0) >= mt - tol }.min() ?? Int(mt)
            let bottom = bots.filter { Double($0) <= mb + tol }.max() ?? Int(mb)
            plans.append(GridFitPlan(left: left, right: right, top: top, bottom: bottom, modules: q.modules,
                                     module: q.module, text: BarcodeFinder.code128Text(vals)))
        }
        return plans
    }

    /// Redraws planned symbols on the output raster with every module an exact number of dots.
    @discardableResult
    public static func applyGridFit(_ out: inout GrayImage, plans: [GridFitPlan], scale s: Double, offsetX ox: Int, offsetY oy: Int) -> Int {
        let TW = out.width, TH = out.height
        var n = 0
        for p in plans {
            let M = p.modules.reduce(0, +)
            let xs = p.module * s
            guard xs > 0.5, M > 0 else { continue }
            var D = max(1, Int((xs + 0.35).rounded(.down)))
            if D == 1 && xs >= 1.3 { D = 2 }
            let L = p.left * s + Double(ox), R = p.right * s + Double(ox)
            let avail = (R - L) * 1.06 + 4
            while D > 1 && Double(D * M) > avail { D -= 1 }
            if abs(Double(D) - xs) / xs > 0.4 { continue }
            var top = Int((Double(p.top) * s + Double(oy)).rounded())
            var bot = Int((Double(p.bottom) * s + Double(oy)).rounded())
            var x = Int(((L + R) / 2 - Double(D * M) / 2).rounded())
            if x < 0 || x + D * M > TW || top < 0 || bot > TH || bot <= top { continue }
            let x0c = Int(min(L, Double(x)).rounded(.down)) - 1
            let x1c = Int(max(R, Double(x + D * M)).rounded(.up)) + 1
            let xa = max(0, Int(L.rounded(.down))), xb = min(TW, Int(R.rounded(.up)))
            // resampled bars can reach a row or two past the mapped extent
            for _ in 0..<3 where top > 0 && out.darkFraction(row: top - 1, from: xa, to: xb) > 0.2 { top -= 1 }
            for _ in 0..<3 where bot < TH && out.darkFraction(row: bot, from: xa, to: xb) > 0.2 { bot += 1 }
            out.fill(PixelRect(x0: x0c, y0: top, x1: x1c, y1: bot), value: 255)
            for (k, mm) in p.modules.enumerated() {
                let wd = mm * D
                if k % 2 == 0 { out.fill(PixelRect(x0: x, y0: top, x1: x + wd, y1: bot), value: 0) }
                x += wd
            }
            n += 1
        }
        return n
    }
}

extension Optional where Wrapped == PerfTrace {
    /// Times `body` when a trace is present; otherwise just runs it.
    @inline(__always)
    public func measureOrRun<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        if let t = self { return try t.measure(name, body) }
        return try body()
    }
}
