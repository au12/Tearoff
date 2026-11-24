import CoreGraphics
import Foundation
import TearoffCore

/// Walks a page's content stream (and nested Form XObjects) tracking the graphics and text
/// matrices, to learn where raster images are drawn at what native size and which way real
/// text reads.
final class PDFContentScanner {
    var ctm = CGAffineTransform.identity
    var stack: [CGAffineTransform] = []
    var tm = CGAffineTransform.identity
    var tlm = CGAffineTransform.identity
    var leading: CGFloat = 0
    var images: [ImagePlacement] = []
    var texts: [TextRun] = []
    let toDisplay: CGAffineTransform
    var depth = 0

    init(toDisplay: CGAffineTransform) { self.toDisplay = toDisplay }

    func scan(_ cs: CGPDFContentStreamRef) {
        guard let table = CGPDFOperatorTableCreate() else { return }
        CGPDFOperatorTableSetCallback(table, "q", opSave)
        CGPDFOperatorTableSetCallback(table, "Q", opRestore)
        CGPDFOperatorTableSetCallback(table, "cm", opConcat)
        CGPDFOperatorTableSetCallback(table, "Do", opDo)
        CGPDFOperatorTableSetCallback(table, "BT", opBeginText)
        CGPDFOperatorTableSetCallback(table, "Tm", opTextMatrix)
        CGPDFOperatorTableSetCallback(table, "Td", opTextMove)
        CGPDFOperatorTableSetCallback(table, "TD", opTextMoveLeading)
        CGPDFOperatorTableSetCallback(table, "T*", opNextLine)
        CGPDFOperatorTableSetCallback(table, "TL", opLeading)
        CGPDFOperatorTableSetCallback(table, "Tj", opShow)
        CGPDFOperatorTableSetCallback(table, "TJ", opShowArray)
        CGPDFOperatorTableSetCallback(table, "'", opQuote)
        CGPDFOperatorTableSetCallback(table, "\"", opDoubleQuote)
        let scanner = CGPDFScannerCreate(cs, table, Unmanaged.passUnretained(self).toOpaque())
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        CGPDFOperatorTableRelease(table)
    }

    func addImage(width: Int, height: Int) {
        guard width > 0, height > 0, images.count < 500 else { return }
        let m = ctm.concatenating(toDisplay)
        let pts = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1)].map { $0.applying(m) }
        let xs = pts.map { Double($0.x) }, ys = pts.map { Double($0.y) }
        guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max(), x1 - x0 > 1, y1 - y0 > 1 else { return }
        let rect = PageRect(x0: x0, y0: y0, x1: x1, y1: y1)
        // image columns run along (m.a, m.b), rows along (m.c, m.d)
        if abs(m.a) > 20 * abs(m.b) && abs(m.d) > 20 * abs(m.c) {
            images.append(ImagePlacement(rect: rect, pixelWidth: width, pixelHeight: height))
        } else if abs(m.b) > 20 * abs(m.a) && abs(m.c) > 20 * abs(m.d) {
            images.append(ImagePlacement(rect: rect, pixelWidth: height, pixelHeight: width))
        }
    }

    func handleForm(_ stream: CGPDFStreamRef, dict: CGPDFDictionaryRef, parent: CGPDFContentStreamRef) {
        guard depth < 12 else { return }
        depth += 1
        let saved = (ctm, tm, tlm, stack.count)
        var matrix: CGPDFArrayRef? = nil
        if CGPDFDictionaryGetArray(dict, "Matrix", &matrix), let matrix = matrix, CGPDFArrayGetCount(matrix) == 6 {
            var v = [CGFloat](repeating: 0, count: 6)
            for i in 0..<6 {
                var r: CGPDFReal = 0
                if CGPDFArrayGetNumber(matrix, i, &r) { v[i] = r }
            }
            ctm = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5]).concatenating(ctm)
        }
        var res: CGPDFDictionaryRef? = nil
        let resources: CGPDFDictionaryRef = CGPDFDictionaryGetDictionary(dict, "Resources", &res) && res != nil ? res! : dict
        let fcs = CGPDFContentStreamCreateWithStream(stream, resources, parent)
        scan(fcs)
        CGPDFContentStreamRelease(fcs)
        ctm = saved.0; tm = saved.1; tlm = saved.2
        if stack.count > saved.3 { stack.removeLast(stack.count - saved.3) }
        depth -= 1
    }

    func showText(weight: Int) {
        guard weight > 0, texts.count < 20000 else { return }
        let m = tm.concatenating(ctm).concatenating(toDisplay)
        let angle = atan2(Double(m.b), Double(m.a))      // text x-axis in display space (y down)
        var q = Int((angle / (Double.pi / 2)).rounded()) % 4
        if q < 0 { q += 4 }
        texts.append(TextRun(x: Double(m.tx), y: Double(m.ty), quarter: q, weight: weight))
    }

    func moveText(_ tx: CGFloat, _ ty: CGFloat) {
        tlm = CGAffineTransform(translationX: tx, y: ty).concatenating(tlm)
        tm = tlm
    }
}

// MARK: - Operator callbacks (C function pointers: no captures)

private func me(_ info: UnsafeMutableRawPointer?) -> PDFContentScanner? {
    guard let info = info else { return nil }
    return Unmanaged<PDFContentScanner>.fromOpaque(info).takeUnretainedValue()
}

private func popNumbers(_ s: CGPDFScannerRef, _ n: Int) -> [CGFloat]? {
    var out = [CGFloat](repeating: 0, count: n)
    var i = n - 1
    while i >= 0 {
        var v: CGPDFReal = 0
        guard CGPDFScannerPopNumber(s, &v) else { return nil }
        out[i] = v
        i -= 1
    }
    return out
}

private func popStringLength(_ s: CGPDFScannerRef) -> Int {
    var str: CGPDFStringRef? = nil
    guard CGPDFScannerPopString(s, &str), let str = str else { return 0 }
    return CGPDFStringGetLength(str)
}

private let opSave: CGPDFOperatorCallback = { _, info in
    guard let m = me(info) else { return }
    m.stack.append(m.ctm)
}

private let opRestore: CGPDFOperatorCallback = { _, info in
    guard let m = me(info), let last = m.stack.popLast() else { return }
    m.ctm = last
}

private let opConcat: CGPDFOperatorCallback = { s, info in
    guard let m = me(info), let v = popNumbers(s, 6) else { return }
    m.ctm = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5]).concatenating(m.ctm)
}

private let opDo: CGPDFOperatorCallback = { s, info in
    guard let m = me(info) else { return }
    var namePtr: UnsafePointer<CChar>? = nil
    guard CGPDFScannerPopName(s, &namePtr), let name = namePtr else { return }
    let cs = CGPDFScannerGetContentStream(s)
    guard let obj = CGPDFContentStreamGetResource(cs, "XObject", name) else { return }
    var stream: CGPDFStreamRef? = nil
    guard CGPDFObjectGetValue(obj, .stream, &stream), let st = stream, let dict = CGPDFStreamGetDictionary(st) else { return }
    var subtype: UnsafePointer<CChar>? = nil
    guard CGPDFDictionaryGetName(dict, "Subtype", &subtype), let sub = subtype else { return }
    switch String(cString: sub) {
    case "Image":
        var w: CGPDFInteger = 0, h: CGPDFInteger = 0
        _ = CGPDFDictionaryGetInteger(dict, "Width", &w)
        _ = CGPDFDictionaryGetInteger(dict, "Height", &h)
        m.addImage(width: Int(w), height: Int(h))
    case "Form":
        m.handleForm(st, dict: dict, parent: cs)
    default:
        break
    }
}

private let opBeginText: CGPDFOperatorCallback = { _, info in
    guard let m = me(info) else { return }
    m.tm = .identity
    m.tlm = .identity
}

private let opTextMatrix: CGPDFOperatorCallback = { s, info in
    guard let m = me(info), let v = popNumbers(s, 6) else { return }
    m.tlm = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
    m.tm = m.tlm
}

private let opTextMove: CGPDFOperatorCallback = { s, info in
    guard let m = me(info), let v = popNumbers(s, 2) else { return }
    m.moveText(v[0], v[1])
}

private let opTextMoveLeading: CGPDFOperatorCallback = { s, info in
    guard let m = me(info), let v = popNumbers(s, 2) else { return }
    m.leading = -v[1]
    m.moveText(v[0], v[1])
}

private let opNextLine: CGPDFOperatorCallback = { _, info in
    guard let m = me(info) else { return }
    m.moveText(0, -m.leading)
}

private let opLeading: CGPDFOperatorCallback = { s, info in
    guard let m = me(info), let v = popNumbers(s, 1) else { return }
    m.leading = v[0]
}

private let opShow: CGPDFOperatorCallback = { s, info in
    guard let m = me(info) else { return }
    m.showText(weight: popStringLength(s))
}

private let opShowArray: CGPDFOperatorCallback = { s, info in
    guard let m = me(info) else { return }
    var arr: CGPDFArrayRef? = nil
    guard CGPDFScannerPopArray(s, &arr), let a = arr else { return }
    var n = 0
    for i in 0..<CGPDFArrayGetCount(a) {
        var str: CGPDFStringRef? = nil
        if CGPDFArrayGetString(a, i, &str), let st = str { n += CGPDFStringGetLength(st) }
    }
    m.showText(weight: n)
}

private let opQuote: CGPDFOperatorCallback = { s, info in
    guard let m = me(info) else { return }
    let n = popStringLength(s)
    m.moveText(0, -m.leading)
    m.showText(weight: n)
}

private let opDoubleQuote: CGPDFOperatorCallback = { s, info in
    guard let m = me(info) else { return }
    let n = popStringLength(s)
    _ = popNumbers(s, 2)
    m.moveText(0, -m.leading)
    m.showText(weight: n)
}
