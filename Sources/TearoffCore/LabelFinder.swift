import Foundation

/// An embedded raster image drawn on the page.
public struct ImagePlacement {
    /// Display-space bounds.
    public var rect: PageRect
    /// Native samples along display X and Y (already swapped for images drawn rotated 90°).
    public var pixelWidth: Int
    public var pixelHeight: Int
    public init(rect: PageRect, pixelWidth: Int, pixelHeight: Int) {
        self.rect = rect; self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
    }
}

/// A run of real (vector) text and the direction it reads in display space.
public struct TextRun {
    public var x: Double
    public var y: Double
    /// 0 = reads left→right, 1 = top→bottom, 2 = right→left, 3 = bottom→top.
    public var quarter: Int
    public var weight: Int
    public init(x: Double, y: Double, quarter: Int, weight: Int) {
        self.x = x; self.y = y; self.quarter = quarter; self.weight = weight
    }
}

/// What the label finder needs to know about one page.
public struct PageContent {
    public var width: Double    // display points
    public var height: Double
    public var images: [ImagePlacement]
    public var texts: [TextRun]
    public init(width: Double, height: Double, images: [ImagePlacement] = [], texts: [TextRun] = []) {
        self.width = width; self.height = height; self.images = images; self.texts = texts
    }
    public var rect: PageRect { PageRect(x0: 0, y0: 0, x1: width, y1: height) }
}

/// Renders a page region (display points) into exactly `width` x `height` gray pixels.
/// `exactPixels` disables interpolation (used to read an embedded image at its native resolution).
public typealias RegionRenderer = (_ rect: PageRect, _ width: Int, _ height: Int, _ exactPixels: Bool) -> GrayImage

public struct LabelCandidate {
    public enum Kind: String { case image, frame, block, page }
    public var kind: Kind
    public var rect: PageRect
    /// Native pixel size (image candidates).
    public var native: (width: Int, height: Int)?
    public var barcodes: [LinearBarcode] = []
    public var aspect: Double = 1
    public var bigBarcodes = 0
    public var score = 0.0
    public var barcodeQuarter: Int?
    /// Quarter turns clockwise that make this label upright.
    public var quarterTurns = 0

    public init(kind: Kind, rect: PageRect) {
        self.kind = kind
        self.rect = rect
    }

    /// Region size in its own pixels/points, as used for aspect/orientation decisions.
    var dims: (Double, Double) {
        if let n = native { return (Double(n.width), Double(n.height)) }
        return (rect.width, rect.height)
    }

    public var texts: [String] { barcodes.compactMap { $0.text } }
}

public enum LabelFinder {

    static func aspectScore(_ a: Double, target t: Double) -> Double {
        var d = abs(a - t)
        if abs(t - 1.5) < 0.01 { d = min(d, abs(a - 1.5625)) }   // 4x6.25 stock
        return max(0, 1 - d / 0.35)
    }

    /// Finds the labels on a page, best first in reading order.
    public static func find(page: PageContent, label: LabelSize = .fourBySix, render: RegionRenderer) -> [LabelCandidate] {
        let W = page.width, H = page.height
        guard W > 1, H > 1 else { return [] }
        let T = label.aspect
        let labelShort = min(label.width, label.height)
        let pageR = page.rect

        // --- analysis raster: ~1600 px on the long side
        let A = 1600 / max(W, H) * 72      // analysis dpi
        let px = A / 72                      // pixels per point
        let aw = max(2, Int((W * px).rounded())), ah = max(2, Int((H * px).rounded()))
        let gray = render(pageR, aw, ah, false)
        let ink = gray.mask(below: 160)
        let shortPx = Double(min(aw, ah))
        let minLen = max(Int(0.14 * shortPx), Int(0.5 * A))
        let gap = max(2, Int((0.06 * A).rounded()))
        let maxThick = max(2, Int((0.035 * A).rounded()))
        let hs = LineFinder.horizontal(ink, width: aw, height: ah, minLength: minLen, gap: gap, maxThickness: maxThick)
        let vs = LineFinder.vertical(ink, width: aw, height: ah, minLength: minLen, gap: gap, maxThickness: maxThick)
        let tol = Double(max(3, Int((0.05 * A).rounded())))
        let frames = LineFinder.frames(horizontal: hs, vertical: vs, tolerance: tol, minSide: 0.22 * shortPx)

        let minSide = 0.18 * min(W, H)
        let aspectLo = max(1.0, T * 0.8), aspectHi = T * 1.3
        var cands: [LabelCandidate] = []

        for im in page.images {
            let r = im.rect
            guard im.pixelWidth > 0, im.pixelHeight > 0, min(r.width, r.height) >= minSide else { continue }
            let pa = Double(max(im.pixelWidth, im.pixelHeight)) / Double(min(im.pixelWidth, im.pixelHeight))
            if pa >= aspectLo && pa <= aspectHi && r.aspect >= T * 0.77 && r.aspect <= T * 1.33 {
                var c = LabelCandidate(kind: .image, rect: r)
                c.native = (im.pixelWidth, im.pixelHeight)
                cands.append(c)
            }
        }
        for f in frames {
            let r = PageRect(x0: f.x0 / px, y0: f.y0 / px, x1: f.x1 / px, y1: f.y1 / px)
            if r.aspect >= aspectLo && r.aspect <= aspectHi && min(r.width, r.height) >= minSide {
                cands.append(LabelCandidate(kind: .frame, rect: r))
            }
        }

        // whitespace blocks, seeded by barcodes found on a high-resolution render of the page
        var mask = ink
        for s in hs {
            for y in max(0, s.t0 - 1)...min(ah - 1, s.t1 + 1) {
                for x in s.a..<min(aw, s.b) { mask[y * aw + x] = 0 }
            }
        }
        for s in vs {
            for y in s.a..<min(ah, s.b) {
                for x in max(0, s.t0 - 1)...min(aw - 1, s.t1 + 1) { mask[y * aw + x] = 0 }
            }
        }
        let hb = (max(W, H) <= 9 * 72 ? 4400.0 : 3300.0) / max(W, H)   // px per point
        let big = render(pageR, Int(W * hb), Int(H * hb), false)
        var seeds: [(Int, Int)] = []
        for b in BarcodeFinder.find(in: big, ppi: hb * 72) {
            seeds.append((Int(b.midX / hb * px), Int(b.midY / hb * px)))
        }
        if !seeds.isEmpty {
            let finder = BlockFinder(mask: mask, width: aw, height: ah)
            let minGap = max(2, Int((0.012 * shortPx).rounded()))
            for b in finder.blocks(minGap: minGap, minSide: Int(minSide * px), seeds: seeds) {
                let r = PageRect(x0: Double(b.x0) / px, y0: Double(b.y0) / px, x1: Double(b.x1) / px, y1: Double(b.y1) / px)
                if r.aspect >= aspectLo && r.aspect <= aspectHi && min(r.width, r.height) >= minSide {
                    cands.append(LabelCandidate(kind: .block, rect: r))
                }
            }
        }
        let labelSized = max(W, H) <= 8.6 * 72 && abs(max(W, H) / min(W, H) - T) < 0.12
        if labelSized { cands.append(LabelCandidate(kind: .page, rect: pageR)) }

        // drop near-duplicates of the same kind
        var uniq: [LabelCandidate] = []
        for c in cands {
            let dup = uniq.contains { $0.kind == c.kind && c.rect.intersectionArea($0.rect) > 0.95 * max(c.rect.area, $0.rect.area) }
            if !dup { uniq.append(c) }
        }
        cands = uniq

        // --- read barcodes inside every candidate at ~300 px per label-inch
        for i in cands.indices {
            var c = cands[i]
            let raster: GrayImage
            let ppi: Double
            if c.kind == .image, let n = c.native, min(n.width, n.height) >= 900 {
                raster = render(c.rect, n.width, n.height, true)
                ppi = Double(min(n.width, n.height)) / labelShort
            } else {
                let s = 1200 / max(1, min(c.rect.width, c.rect.height))
                let rw = max(2, Int((c.rect.width * s).rounded())), rh = max(2, Int((c.rect.height * s).rounded()))
                if s <= hb * 1.05 {
                    // the high-resolution page render is sharp enough: crop it instead of re-rendering
                    let crop = big.cropped(PixelRect(x0: Int((c.rect.x0 * hb).rounded()), y0: Int((c.rect.y0 * hb).rounded()),
                                                     x1: Int((c.rect.x1 * hb).rounded()), y1: Int((c.rect.y1 * hb).rounded())))
                    raster = crop.resampled(width: rw, height: rh)
                } else {
                    raster = render(c.rect, rw, rh, false)
                }
                ppi = 1200 / labelShort
            }
            c.barcodes = BarcodeFinder.find(in: raster, ppi: ppi)
            c.barcodeQuarter = BarcodeFinder.uprightQuarterTurns(c.barcodes)
            let d = c.dims
            c.aspect = max(d.0, d.1) / max(0.001, min(d.0, d.1))
            let minDim = Double(min(raster.width, raster.height))
            c.bigBarcodes = c.barcodes.filter { Double($0.length) >= 0.22 * minDim }.count
            var s = aspectScore(c.aspect, target: T) * 2 + Double(min(c.barcodes.count, 3)) + (c.bigBarcodes > 0 ? 1 : 0)
            switch c.kind {
            case .image: s += 2
            case .frame: s += 1.5
            case .page: s += 1
            case .block: s += 0
            }
            c.score = s
            cands[i] = c
        }

        var valid = cands.filter { !$0.barcodes.isEmpty }
        if valid.isEmpty {
            // nothing scannable found: fall back to label-shaped images, frames or the page itself
            valid = cands.filter { $0.kind != .block && aspectScore($0.aspect, target: T) > 0.8 }
        }

        // --- a candidate that two complete-looking labels tile is really two labels
        func isStrong(_ c: LabelCandidate) -> Bool { c.kind == .image || c.kind == .frame }
        func twins(_ a: LabelCandidate, _ b: LabelCandidate) -> Bool {
            guard let la = a.barcodes.max(by: { $0.length < $1.length }),
                  let lb = b.barcodes.max(by: { $0.length < $1.length }) else { return false }
            return abs(la.elements - lb.elements) <= 2
        }
        var keep: [LabelCandidate] = []
        for c in valid {
            let area = c.rect.area
            var kids: [(LabelCandidate, Double)] = []
            for d in valid {
                if d.rect == c.rect && d.kind == c.kind { continue }
                if d.bigBarcodes < 1 || aspectScore(d.aspect, target: T) < 0.7 { continue }
                let ov = c.rect.intersectionArea(d.rect)
                if ov >= 0.5 * d.rect.area && ov >= 0.3 * area && d.rect.area < 0.85 * area { kids.append((d, ov)) }
            }
            kids.sort { $0.0.score > $1.0.score }
            var split = false
            if kids.count >= 2 {
                outer: for i in 0..<(kids.count - 1) {
                    for j in (i + 1)..<kids.count {
                        let (a, oa) = kids[i], (b, ob) = kids[j]
                        if a.rect.intersectionArea(b.rect) > 0.1 * min(a.rect.area, b.rect.area) { continue }
                        if oa + ob < 0.8 * area { continue }
                        if (isStrong(a) && isStrong(b)) || twins(a, b) { split = true; break outer }
                    }
                }
            }
            if !split { keep.append(c) }
        }

        // --- choose: explicit boundaries (images, frames) first, then the page, then blocks
        var chosen: [LabelCandidate] = []
        func nms(_ pool: [LabelCandidate]) {
            for c in pool.sorted(by: { $0.score > $1.score }) {
                if chosen.contains(where: { c.rect.intersectionArea($0.rect) > 0.25 * min(c.rect.area, $0.rect.area) }) { continue }
                chosen.append(c)
            }
        }
        nms(keep.filter(isStrong))
        // a small frame that is only a box *inside* an unframed label: upgrade to the whole block
        for i in chosen.indices where chosen[i].kind == .frame {
            let f = chosen[i]
            let better = keep.filter {
                $0.kind == .block && $0.rect.intersectionArea(f.rect) >= 0.9 * f.rect.area &&
                    f.rect.area < 0.6 * $0.rect.area && $0.bigBarcodes > f.bigBarcodes &&
                    aspectScore($0.aspect, target: T) >= 0.5
            }.max(by: { $0.score < $1.score })
            if let b = better, !chosen.enumerated().contains(where: { $0.offset != i && b.rect.intersectionArea($0.element.rect) > 0.25 * $0.element.rect.area }) {
                chosen[i] = b
            }
        }
        if chosen.isEmpty {
            if let p = keep.first(where: { $0.kind == .page }) {
                chosen.append(p)
            } else {
                nms(keep.filter { $0.kind == .block && aspectScore($0.aspect, target: T) >= 0.5 && $0.bigBarcodes >= 1 })
            }
        }
        chosen.sort {
            let ra = ($0.rect.midY / 144).rounded(), rb = ($1.rect.midY / 144).rounded()
            return ra != rb ? ra < rb : $0.rect.midX < $1.rect.midX
        }

        // --- orientation
        for i in chosen.indices {
            chosen[i].quarterTurns = orientation(chosen[i], texts: page.texts)
        }
        return chosen
    }

    static func orientation(_ c: LabelCandidate, texts: [TextRun]) -> Int {
        let (w, h) = c.dims
        var q: Int
        if let b = c.barcodeQuarter {
            q = b
        } else {
            var votes = [0, 0, 0, 0]
            for t in texts where c.rect.contains(x: t.x, y: t.y) {
                votes[(4 - (t.quarter % 4)) % 4] += t.weight
            }
            if let best = votes.indices.max(by: { votes[$0] < votes[$1] }), votes[best] > 0 {
                q = best
            } else {
                q = w > h ? 1 : 0
            }
        }
        // a landscape region must end up portrait (labels print portrait)
        if w > h && q % 2 == 0 { q = 1 }
        if h > w && q % 2 == 1 { q = 0 }
        return q
    }
}
