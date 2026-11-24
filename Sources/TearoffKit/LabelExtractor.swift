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
    /// image | frame | block | page | fallback
    public var kind: String
    public var detail: String
    public var rect: PageRect
    public var quarterTurns: Int
    public var gridFitted: Int
    public var barcodes: [String]
    public var dpi: Int

    public var carrier: String? { Carrier.name(for: barcodes) }
    public var tracking: String? { Carrier.trackingNumber(in: barcodes) }

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
    public init(render: RenderOptions = RenderOptions(), fallbackToPages: Bool = true, wholePages: Bool = false) {
        self.render = render; self.fallbackToPages = fallbackToPages; self.wholePages = wholePages
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

    public static func extract(url: URL, options: ExtractOptions = ExtractOptions()) throws -> [ExtractedLabel] {
        extract(pages: try pages(of: url), options: options)
    }

    public static func extract(pages: [PageSource], options: ExtractOptions) -> [ExtractedLabel] {
        var out: [ExtractedLabel] = []
        if !options.wholePages {
            for (i, p) in pages.enumerated() {
                let content = p.content()
                let found = LabelFinder.find(page: content, label: options.render.size, render: p.renderer)
                for c in found {
                    let r = LabelRenderer.render(c, options: options.render, render: p.renderer)
                    out.append(ExtractedLabel(image: r.image, page: i + 1, kind: c.kind.rawValue, detail: describe(c),
                                              rect: c.rect, quarterTurns: c.quarterTurns, gridFitted: r.gridFitted,
                                              barcodes: unique(r.barcodeTexts + c.texts), dpi: options.render.dpi))
                }
            }
        }
        if out.isEmpty && (options.fallbackToPages || options.wholePages) {
            for (i, p) in pages.enumerated() {
                if let l = wholePage(p, index: i + 1, options: options.render) { out.append(l) }
            }
        }
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
