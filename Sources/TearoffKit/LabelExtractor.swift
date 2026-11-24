import CoreGraphics
import Foundation
import ImageIO
import TearoffCore

public enum TearoffError: LocalizedError {
    case unreadable(String)
    case noPrinter
    case printer(String)
    case driver(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let f): return "Couldn’t read “\(f)”. Is it a PDF or an image?"
        case .noPrinter: return "No printer is set up yet. Choose one in Settings."
        case .printer(let m): return m
        case .driver(let m): return m
        }
    }
}

/// A label ready to print, plus what we learned while finding it.
public struct ExtractedLabel: Identifiable {
    public let id = UUID()
    public var image: GrayImage
    public var page: Int
    /// image | frame | block | page | fallback, or barcode | qr for a code found outside the labels
    public var kind: String
    public var detail: String
    public var rect: PageRect
    public var quarterTurns: Int
    public var gridFitted: Int
    public var barcodes: [String]
    public var dpi: Int

    public var carrier: String? { isExtraCode ? nil : Carrier.name(for: barcodes) }
    public var tracking: String? { isExtraCode ? nil : Carrier.trackingNumber(in: barcodes) }
    /// A barcode or QR code that was printed outside the shipping label (slip, drop-off code…).
    public var isExtraCode: Bool { kind == "barcode" || kind == "qr" }

    /// Rotates the finished label 180° (manual fix-up from the UI).
    public mutating func flip() {
        image = image.rotated(quarterTurnsCW: 2)
        quarterTurns = (quarterTurns + 2) % 4
    }
}

public struct ExtractOptions {
    public var render: RenderOptions
    /// When no label is found anywhere, print each page scaled to fit the stock.
    public var fallbackToPages: Bool
    /// Skip detection and always print whole pages.
    public var wholePages: Bool
    /// Also print the barcodes and QR codes found outside the labels, each on a label of its own.
    public var extraCodes: Bool
    public init(render: RenderOptions = RenderOptions(), fallbackToPages: Bool = true, wholePages: Bool = false,
                extraCodes: Bool = true) {
        self.render = render; self.fallbackToPages = fallbackToPages; self.wholePages = wholePages
        self.extraCodes = extraCodes
    }
}

public enum LabelExtractor {

    /// Opens a PDF or raster image as pages.
    public static func pages(of url: URL) throws -> [PageSource] {
        if let doc = CGPDFDocument(url as CFURL) {
            if doc.isEncrypted && !doc.isUnlocked { _ = doc.unlockWithPassword("") }
            guard doc.numberOfPages > 0 else { throw TearoffError.unreadable(url.lastPathComponent) }
            return (1...doc.numberOfPages).compactMap { doc.page(at: $0) }.map { PDFPageSource(page: $0) }
        }
        if let img = ImagePageSource(url: url) { return [img] }
        throw TearoffError.unreadable(url.lastPathComponent)
    }

    public static func extract(url: URL, options: ExtractOptions = ExtractOptions(), trace: PerfTrace? = nil) throws -> [ExtractedLabel] {
        let docPages = try trace.measureOrRun("extract.open") { try self.pages(of: url) }
        trace?.set("pages", docPages.count)
        return extract(pages: docPages, options: options, trace: trace)
    }

    /// Most extra codes printed from one document.
    public static let maxExtraCodes = 8

    public static func extract(pages: [PageSource], options: ExtractOptions, trace: PerfTrace? = nil) -> [ExtractedLabel] {
        var out: [ExtractedLabel] = []
        var extras: [ExtractedLabel] = []
        if !options.wholePages {
            for (i, p) in pages.enumerated() {
                let content = trace.measureOrRun("extract.content_scan") { p.content() }
                trace?.count("embedded_images", content.images.count)
                let found = LabelFinder.analyze(page: content, label: options.render.size, extras: options.extraCodes,
                                                trace: trace, render: p.renderer)
                for c in found.labels {
                    let r = LabelRenderer.render(c, options: options.render, trace: trace, render: p.renderer)
                    out.append(ExtractedLabel(image: r.image, page: i + 1, kind: c.kind.rawValue, detail: describe(c),
                                              rect: c.rect, quarterTurns: c.quarterTurns, gridFitted: r.gridFitted,
                                              barcodes: unique(r.barcodeTexts + c.texts), dpi: options.render.dpi))
                }
                for c in found.codes where extras.count < maxExtraCodes {
                    // the same code repeated (a second copy of the slip, page 2 of a receipt): print it once
                    if let t = c.texts.first, extras.contains(where: { $0.barcodes.contains(t) }) { continue }
                    let r = LabelRenderer.renderCode(c, options: options.render, trace: trace, render: p.renderer)
                    extras.append(ExtractedLabel(image: r.image, page: i + 1, kind: c.symbology == "QR code" ? "qr" : "barcode",
                                                 detail: describe(c), rect: c.rect, quarterTurns: r.quarterTurns ?? c.quarterTurns,
                                                 gridFitted: r.gridFitted, barcodes: unique(c.texts + r.barcodeTexts),
                                                 dpi: options.render.dpi))
                }
            }
        }
        // shipping labels first, then the extra codes
        out += extras
        trace?.set("extra_labels", extras.count)
        if out.isEmpty && (options.fallbackToPages || options.wholePages) {
            for (i, p) in pages.enumerated() {
                if let l = trace.measureOrRun("extract.whole_page", { wholePage(p, index: i + 1, options: options.render) }) {
                    out.append(l)
                }
            }
        }
        trace?.set("labels", out.count)
        trace?.set("grid_fitted", out.reduce(0) { $0 + $1.gridFitted })
        return out
    }

    static func describe(_ c: LabelCandidate) -> String {
        switch c.kind {
        case .image:
            let n = c.native ?? (0, 0)
            let dpi = Int((Double(max(n.width, n.height)) / max(c.rect.width, c.rect.height) * 72).rounded())
            return "Embedded image \(n.width)×\(n.height) px (\(dpi) ppi on page)"
        case .frame: return "Vector label inside a cut line"
        case .block: return "Vector label (no frame)"
        case .page: return "Whole page"
        case .code:
            if c.symbology == "QR code" { return "QR code found outside the label" }
            if let t = c.texts.first { return "Barcode “\(t)” found outside the label" }
            return "Barcode found outside the label"
        }
    }

    static func unique(_ v: [String]) -> [String] {
        var seen = Set<String>()
        return v.filter { seen.insert($0).inserted }
    }

    /// The page's ink, upright and scaled to fit the stock.
    static func wholePage(_ p: PageSource, index: Int, options: RenderOptions) -> ExtractedLabel? {
        let W = Double(p.size.width), H = Double(p.size.height)
        guard W > 1, H > 1 else { return nil }
        let full = PageRect(x0: 0, y0: 0, x1: W, y1: H)
        // trim margins to the ink so app-added margins don't shrink the label
        let s = 600 / max(W, H)
        let g = p.render(full, width: max(2, Int(W * s)), height: max(2, Int(H * s)), exactPixels: false)
        let finder = BlockFinder(mask: g.mask(below: 200), width: g.width, height: g.height)
        guard let b = finder.trim(PixelRect(x0: 0, y0: 0, x1: g.width, y1: g.height)) else { return nil }
        let pad = 2.0
        let r = PageRect(x0: max(0, Double(b.x0) / s - pad), y0: max(0, Double(b.y0) / s - pad),
                         x1: min(W, Double(b.x1) / s + pad), y1: min(H, Double(b.y1) / s + pad))
        var c = LabelCandidate(kind: .page, rect: r)
        let labelLandscape = options.size.width > options.size.height
        c.quarterTurns = (r.width > r.height) != labelLandscape ? 1 : 0
        let out = LabelRenderer.render(c, options: options, fit: .contain, render: p.renderer)
        return ExtractedLabel(image: out.image, page: index, kind: "fallback", detail: "No label found — whole page fitted",
                              rect: r, quarterTurns: c.quarterTurns, gridFitted: out.gridFitted,
                              barcodes: out.barcodeTexts, dpi: options.dpi)
    }
}
