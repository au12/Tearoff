import CoreGraphics
import Foundation
import ImageIO
import TearoffCore

/// One page (or image) the label finder can look at.
public protocol PageSource: AnyObject {
    /// Display size in points (after /Rotate).
    var size: CGSize { get }
    /// Embedded images and text direction samples.
    func content() -> PageContent
    /// Renders a display-space region into exactly `width` x `height` gray pixels.
    func render(_ rect: PageRect, width: Int, height: Int, exactPixels: Bool) -> GrayImage
}

extension PageSource {
    public var renderer: RegionRenderer {
        let src = self
        return { rect, w, h, exact in src.render(rect, width: w, height: h, exactPixels: exact) }
    }
}

/// Maps a display-space rect onto a `w` x `h` bitmap context (CG device space is y-up).
func displayToDevice(_ rect: PageRect, _ w: Int, _ h: Int) -> CGAffineTransform {
    let sx = CGFloat(w) / CGFloat(rect.width), sy = CGFloat(h) / CGFloat(rect.height)
    return CGAffineTransform(a: sx, b: 0, c: 0, d: -sy, tx: -sx * CGFloat(rect.x0), ty: CGFloat(h) + sy * CGFloat(rect.y0))
}

func makeGrayContext(_ w: Int, _ h: Int) -> CGContext? {
    guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpaceCreateDeviceGray(),
                                            bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
    ctx.setFillColor(gray: 1, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    return ctx
}

/// A PDF page rendered through Quartz.
public final class PDFPageSource: PageSource {
    public let page: CGPDFPage
    public let box: CGRect
    public let rotation: Int
    public let size: CGSize
    /// PDF user space -> display space (points, y down).
    let toDisplay: CGAffineTransform

    public init(page: CGPDFPage) {
        self.page = page
        var b = page.getBoxRect(.cropBox).standardized
        if b.width < 1 || b.height < 1 { b = page.getBoxRect(.mediaBox).standardized }
        box = b
        let r = ((Int(page.rotationAngle) % 360) + 360) % 360
        rotation = r
        let x0 = b.minX, y0 = b.minY, w = b.width, h = b.height
        switch r {
        case 90:
            toDisplay = CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: -y0, ty: -x0)
            size = CGSize(width: h, height: w)
        case 180:
            toDisplay = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: x0 + w, ty: -y0)
            size = CGSize(width: w, height: h)
        case 270:
            toDisplay = CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: y0 + h, ty: x0 + w)
            size = CGSize(width: h, height: w)
        default:
            toDisplay = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: -x0, ty: y0 + h)
            size = CGSize(width: w, height: h)
        }
    }

    public func render(_ rect: PageRect, width w: Int, height h: Int, exactPixels: Bool) -> GrayImage {
        guard rect.width > 0, rect.height > 0, let ctx = makeGrayContext(w, h) else {
            return GrayImage(width: max(0, w), height: max(0, h))
        }
        ctx.interpolationQuality = exactPixels ? .none : .high
        ctx.setShouldAntialias(true)
        ctx.concatenate(toDisplay.concatenating(displayToDevice(rect, w, h)))
        ctx.clip(to: box)
        ctx.drawPDFPage(page)
        return GrayImage(context: ctx)
    }

    private var cached: PageContent?

    public func content() -> PageContent {
        if let c = cached { return c }
        let scanner = PDFContentScanner(toDisplay: toDisplay)
        let cs = CGPDFContentStreamCreateWithPage(page)
        scanner.scan(cs)
        CGPDFContentStreamRelease(cs)
        let c = PageContent(width: Double(size.width), height: Double(size.height),
                            images: scanner.images, texts: scanner.texts)
        cached = c
        return c
    }
}

/// A raster file (PNG, JPEG, HEIC, TIFF…) treated as a page at 300 dpi.
public final class ImagePageSource: PageSource {
    public let image: CGImage
    public let size: CGSize

    public init?(url: URL) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let pw = (props?[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let ph = (props?[kCGImagePropertyPixelHeight] as? Int) ?? 0
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // honour EXIF orientation (phone photos)
            kCGImageSourceThumbnailMaxPixelSize: max(pw, ph, 1),
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
                ?? CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        image = img
        size = CGSize(width: CGFloat(img.width) * 72 / 300, height: CGFloat(img.height) * 72 / 300)
    }

    public func content() -> PageContent {
        let r = PageRect(x0: 0, y0: 0, x1: Double(size.width), y1: Double(size.height))
        return PageContent(width: r.width, height: r.height,
                           images: [ImagePlacement(rect: r, pixelWidth: image.width, pixelHeight: image.height)])
    }

    public func render(_ rect: PageRect, width w: Int, height h: Int, exactPixels: Bool) -> GrayImage {
        guard rect.width > 0, rect.height > 0, let ctx = makeGrayContext(w, h) else {
            return GrayImage(width: max(0, w), height: max(0, h))
        }
        ctx.interpolationQuality = exactPixels ? .none : .high
        // image "user space" is y-up like PDF; flip into display space first
        let toDisplay = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: size.height)
        ctx.concatenate(toDisplay.concatenating(displayToDevice(rect, w, h)))
        ctx.draw(image, in: CGRect(origin: .zero, size: size))
        return GrayImage(context: ctx)
    }
}

extension GrayImage {
    /// Copies an 8-bit gray bitmap context (rows are stored top row first).
    public init(context ctx: CGContext) {
        let w = ctx.width, h = ctx.height, bpr = ctx.bytesPerRow
        var px = [UInt8](repeating: 255, count: w * h)
        if let data = ctx.data {
            let src = data.assumingMemoryBound(to: UInt8.self)
            px.withUnsafeMutableBufferPointer { dst in
                guard let base = dst.baseAddress else { return }
                for y in 0..<h { memcpy(base + y * w, src + y * bpr, w) }
            }
        }
        self.init(width: w, height: h, pixels: px)
    }

    public func cgImage() -> CGImage? {
        guard width > 0, height > 0, let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    public init?(cgImage: CGImage) {
        guard let ctx = makeGrayContext(cgImage.width, cgImage.height) else { return nil }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        self.init(context: ctx)
    }

    /// PNG bytes, tagged with `dpi` so it opens at true size.
    public func pngData(dpi: Int? = nil) -> Data? {
        guard let cg = cgImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, "public.png" as CFString, 1, nil) else { return nil }
        var props: [CFString: Any] = [:]
        if let d = dpi { props[kCGImagePropertyDPIWidth] = d; props[kCGImagePropertyDPIHeight] = d }
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
