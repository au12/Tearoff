import CoreGraphics
import CoreText
import Foundation
import TearoffCore
import Vision

/// Apple's on-device text engines for TearoffCore: Vision reads the line printed beside a barcode
/// (to confirm it says what the barcode says), Core Text draws its replacement.
public enum SystemText {

    public static let services = TextServices(read: read, draw: draw)

    /// On-device OCR (nothing leaves the Mac). Nil when Vision can't run here.
    static func read(_ img: GrayImage) -> [String]? {
        guard let cg = img.cgImage() else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false        // codes aren't words
        request.usesCPUOnly = true                    // stays in-process, which a sandboxed print filter needs
        do {
            try VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])
        } catch {
            return nil
        }
        let lines = (request.results ?? []).sorted { $0.boundingBox.minX < $1.boundingBox.minX }
        var out = [lines.compactMap { $0.topCandidates(1).first?.string }.joined()]
        for l in lines { out += l.topCandidates(3).map { $0.string } }
        return out.filter { !$0.isEmpty }
    }

    /// Black text on white at `pixelsPerEm`, in Menlo Bold (its l, I, 1, O and 0 all differ).
    static func draw(_ text: String, _ pixelsPerEm: Double) -> GrayImage? {
        guard !text.isEmpty, pixelsPerEm >= 3, pixelsPerEm <= 1500 else { return nil }
        let font = CTFontCreateWithName("Menlo-Bold" as CFString, CGFloat(pixelsPerEm), nil)
        let attrs: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs) as CFAttributedString)
        let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        let w = Int(ink.width.rounded(.up)) + 4, h = Int(ink.height.rounded(.up)) + 4
        guard w > 4, h > 4, w * h <= 40_000_000,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setShouldAntialias(true)
        ctx.setShouldSmoothFonts(false)
        ctx.textPosition = CGPoint(x: 2 - ink.minX, y: 2 - ink.minY)
        CTLineDraw(line, ctx)
        guard let data = ctx.data else { return nil }
        let bpr = ctx.bytesPerRow
        let src = data.bindMemory(to: UInt8.self, capacity: bpr * h)
        var px = [UInt8](repeating: 255, count: w * h)
        for y in 0..<h {
            for x in 0..<w { px[y * w + x] = src[y * bpr + x] }
        }
        return GrayImage(width: w, height: h, pixels: px)
    }
}
