import XCTest
@testable import TearoffCore

/// Tiny Code 128 (set B) encoder for building test symbols.
func code128Modules(_ text: String) -> [Int] {
    var vals = [104] + text.unicodeScalars.map { Int($0.value) - 32 }
    var sum = vals[0]
    for (i, v) in vals.dropFirst().enumerated() { sum += v * (i + 1) }
    vals.append(sum % 103)
    vals.append(106)
    return vals.flatMap { BarcodeFinder.code128Patterns[$0].map { Int(String($0))! } }
}

/// Draws a symbol with vertical bars: `module` px per module, `quiet` px of white each side.
func drawBarcode(_ img: inout GrayImage, modules: [Int], x: Int, y: Int, module: Int, height: Int) {
    var cx = x
    for (k, m) in modules.enumerated() {
        let w = m * module
        if k % 2 == 0 { img.fill(PixelRect(x0: cx, y0: y, x1: cx + w, y1: y + height), value: 0) }
        cx += w
    }
}

func drawFrame(_ img: inout GrayImage, _ r: PixelRect, thickness: Int = 2, dash: Int = 0, gap: Int = 0) {
    func seg(_ a: Int, _ b: Int, horizontal: Bool, at p: Int) {
        var i = a
        while i < b {
            let e = dash > 0 ? min(b, i + dash) : b
            if horizontal { img.fill(PixelRect(x0: i, y0: p, x1: e, y1: p + thickness), value: 0) }
            else { img.fill(PixelRect(x0: p, y0: i, x1: p + thickness, y1: e), value: 0) }
            i = dash > 0 ? e + max(1, gap) : b
        }
    }
    seg(r.x0, r.x1, horizontal: true, at: r.y0)
    seg(r.x0, r.x1, horizontal: true, at: r.y1 - thickness)
    seg(r.y0, r.y1, horizontal: false, at: r.x0)
    seg(r.y0, r.y1, horizontal: false, at: r.x1 - thickness)
}

/// A RegionRenderer over a synthetic page raster (`dpi` px per inch).
func renderer(for page: GrayImage, dpi: Double) -> RegionRenderer {
    return { rect, w, h, _ in
        let s = dpi / 72
        let crop = page.cropped(PixelRect(x0: Int((rect.x0 * s).rounded()), y0: Int((rect.y0 * s).rounded()),
                                          x1: Int((rect.x1 * s).rounded()), y1: Int((rect.y1 * s).rounded())))
        return crop.resampled(width: w, height: h)
    }
}

final class GrayImageTests: XCTestCase {
    func testRotationRoundTrip() {
        var img = GrayImage(width: 7, height: 3)
        for i in 0..<img.pixels.count { img.pixels[i] = UInt8(i * 9 % 256) }
        XCTAssertEqual(img.rotated(quarterTurnsCW: 4), img)
        XCTAssertEqual(img.rotated(quarterTurnsCW: 1).rotated(quarterTurnsCW: 3), img)
        XCTAssertEqual(img.rotated(quarterTurnsCW: 2).rotated(quarterTurnsCW: 2), img)
        let r = img.rotated(quarterTurnsCW: 1)
        XCTAssertEqual(r.width, 3); XCTAssertEqual(r.height, 7)
        // the top-left pixel moves to the top-right after a clockwise turn
        XCTAssertEqual(r[2, 0], img[0, 0])
        // the bottom-left pixel moves to the top-left
        XCTAssertEqual(r[0, 0], img[0, 2])
    }

    func testBoxResamplePreservesMeanAndEdges() {
        var img = GrayImage(width: 300, height: 10)
        img.fill(PixelRect(x0: 0, y0: 0, x1: 150, y1: 10), value: 0)
        let half = img.resampled(width: 100, height: 10)
        XCTAssertEqual(half[49, 5], 0)
        XCTAssertEqual(half[50, 5], 255)
        let odd = img.resampled(width: 203, height: 10)   // 300 -> 203: edge at 101.5
        XCTAssertEqual(odd[100, 0], 0)
        XCTAssertEqual(odd[102, 0], 255)
    }
}

final class ZPLTests: XCTestCase {
    func testCompressedHexRoundTrip() {
        var img = GrayImage(width: 812, height: 300)
        var seed: UInt32 = 12345
        for y in 0..<300 {
            for x in 0..<812 {
                seed = seed &* 1664525 &+ 1013904223
                if y % 37 < 20 && (seed >> 24) < 90 { img[x, y] = 0 }
                if y % 50 == 7 { img[x, y] = 0 }      // a full black row
            }
        }
        img.fill(PixelRect(x0: 100, y0: 200, x1: 700, y1: 260), value: 0)
        let gf = ZPL.graphicField(img)
        XCTAssertEqual(gf.bytesPerRow, 102)
        let bytes = ZPL.decodeGraphicField(gf.data, bytesPerRow: gf.bytesPerRow, rows: img.height)
        XCTAssertNotNil(bytes)
        let back = ZPL.rasters(in: ZPL.label(img), widthDots: 812)
        XCTAssertEqual(back.count, 1)
        XCTAssertEqual(back.first, img)
        XCTAssertLessThan(gf.data.count, gf.total * 2)
    }

    func testRowCompressionRules() {
        func row(_ s: String) -> String { String(decoding: ZPL.compressRow(Array(s.utf8)), as: UTF8.self) }
        XCTAssertEqual(row("0000"), ",")
        XCTAssertEqual(row("FFFF"), "!")
        XCTAssertEqual(row("A000"), "A0,")           // odd trailing zeros keep one literal zero
        XCTAssertEqual(row("AB00"), "AB,")
        XCTAssertEqual(row("7777777A"), "M7A")       // 7 x '7'
        XCTAssertEqual(ZPL.countCode(20), Array("g".utf8))
        XCTAssertEqual(ZPL.countCode(47), Array("hM".utf8))
        XCTAssertEqual(ZPL.countCode(400), Array("z".utf8))
    }

    func testJobHeader() {
        let img = GrayImage(width: 812, height: 1218)
        let z = ZPL.label(img, copies: 2, settings: PrintSettings(darkness: 22, speed: 4))
        XCTAssertTrue(z.hasPrefix("~SD22^XA^PW812^LL1218"))
        XCTAssertTrue(z.contains("^PR4,4,4"))
        XCTAssertTrue(z.contains("^PQ2,0,0,N^XZ"))
    }
}

final class Code128Tests: XCTestCase {
    func testDecodeAndDirection() {
        let m = code128Modules("1Z999AA10123456784")
        XCTAssertEqual(BarcodeFinder.code128Direction(m), 1)
        XCTAssertEqual(BarcodeFinder.code128Direction(Array(m.reversed())), -1)
        let vals = BarcodeFinder.code128Values(m)
        XCTAssertNotNil(vals)
        XCTAssertEqual(BarcodeFinder.code128Text(vals!), "1Z999AA10123456784")
        var bad = m
        bad[10] = bad[10] == 1 ? 2 : 1
        XCTAssertNil(BarcodeFinder.code128Values(bad))
    }

    func testFinderReadsAllFourOrientations() {
        let modules = code128Modules("RETURN-0042")
        var img = GrayImage(width: 900, height: 300)
        drawBarcode(&img, modules: modules, x: 120, y: 60, module: 3, height: 160)
        for k in 0..<4 {
            let rotated = img.rotated(quarterTurnsCW: k)
            let found = BarcodeFinder.find(in: rotated, ppi: 300)
            XCTAssertEqual(found.count, 1, "rotation \(k)")
            XCTAssertEqual(found.first?.text, "RETURN-0042", "rotation \(k)")
            XCTAssertEqual(BarcodeFinder.uprightQuarterTurns(found), (4 - k) % 4, "rotation \(k)")
        }
    }

    func testTextIsNotABarcode() {
        var img = GrayImage(width: 900, height: 200)
        // irregular strokes like large bold text
        var x = 50
        var seed: UInt32 = 7
        while x < 850 {
            seed = seed &* 1103515245 &+ 12345
            let w = 4 + Int(seed >> 28)
            img.fill(PixelRect(x0: x, y0: 40, x1: x + w, y1: 40 + 30 + Int((seed >> 20) & 31)), value: 0)
            x += w + 3 + Int((seed >> 16) & 7)
        }
        XCTAssertTrue(BarcodeFinder.find(in: img, ppi: 300).filter { $0.text != nil }.isEmpty)
    }
}

final class GridFitTests: XCTestCase {
    func testRedrawsWholeDotModules() {
        // 300 dpi source with 4.8 px modules (16 mil), like a UPS label image
        let modules = code128Modules("1Z999AA10123456784")
        let total = modules.reduce(0, +)
        var src = GrayImage(width: 1500, height: 400)
        var x = 100.0
        for (k, m) in modules.enumerated() {
            let w = Double(m) * 4.8
            if k % 2 == 0 {
                src.fill(PixelRect(x0: Int(x.rounded()), y0: 100, x1: Int((x + w).rounded()), y1: 300), value: 0)
            }
            x += w
        }
        let opts = RenderOptions(dpi: 203, size: LabelSize(width: 5, height: 4.0 / 3), gridFit: true)
        let out = LabelRenderer.finish(src, options: opts)
        XCTAssertEqual(out.gridFitted, 1)
        XCTAssertTrue(out.barcodeTexts.contains("1Z999AA10123456784"))
        // every bar/space in the output is a multiple of 3 dots
        let y = out.image.height / 2
        var runs: [Int] = []
        var cur = out.image[0, y], len = 0
        for xx in 0..<out.image.width {
            if out.image[xx, y] == cur { len += 1 } else { runs.append(len); cur = out.image[xx, y]; len = 1 }
        }
        runs.append(len)
        let inner = runs.dropFirst().dropLast()
        XCTAssertEqual(inner.count, modules.count)
        XCTAssertTrue(inner.allSatisfy { $0 % 3 == 0 }, "\(Array(inner))")
        XCTAssertEqual(inner.reduce(0, +), total * 3)
    }
}

final class FinderTests: XCTestCase {
    /// Letter page at 150 dpi with a dashed-framed portrait label at the top and an instruction
    /// barcode below it.
    func testFramedLabelOnLetterPage() {
        let dpi = 150.0
        var page = GrayImage(width: Int(8.5 * dpi), height: Int(11 * dpi))
        let L = PixelRect(x0: 75, y0: 75, x1: 75 + 600, y1: 75 + 900)       // 4x6 in
        drawFrame(&page, L, thickness: 2, dash: 8, gap: 4)
        drawBarcode(&page, modules: code128Modules("1Z999AA10123456784"), x: 160, y: 700, module: 2, height: 120)
        drawBarcode(&page, modules: code128Modules("420303490000"), x: 200, y: 300, module: 2, height: 90)
        page.fill(PixelRect(x0: 100, y0: 100, x1: 400, y1: 118), value: 0)   // "address" bars
        drawBarcode(&page, modules: code128Modules("RECEIPT01"), x: 200, y: 1250, module: 2, height: 60)
        let content = PageContent(width: 612, height: 792)
        let found = LabelFinder.find(page: content, render: renderer(for: page, dpi: dpi))
        XCTAssertEqual(found.count, 1)
        guard let f = found.first else { return }
        XCTAssertEqual(f.kind, .frame)
        XCTAssertEqual(f.rect.width / 72, 4, accuracy: 0.1)
        XCTAssertEqual(f.rect.height / 72, 6, accuracy: 0.1)
        XCTAssertEqual(f.quarterTurns, 0)
    }

    /// The same label lying on its side, unframed: must come back upright.
    func testRotatedUnframedLabel() {
        let dpi = 150.0
        var label = GrayImage(width: 600, height: 900)
        drawBarcode(&label, modules: code128Modules("1Z999AA10123456784"), x: 85, y: 650, module: 2, height: 120)
        drawBarcode(&label, modules: code128Modules("420303490000"), x: 150, y: 250, module: 2, height: 90)
        label.fill(PixelRect(x0: 30, y0: 30, x1: 330, y1: 50), value: 0)
        label.fill(PixelRect(x0: 30, y0: 60, x1: 280, y1: 78), value: 0)
        label.fill(PixelRect(x0: 20, y0: 860, x1: 220, y1: 880), value: 0)
        for k in [1, 3] {
            var page = GrayImage(width: Int(8.5 * dpi), height: Int(11 * dpi))
            let side = label.rotated(quarterTurnsCW: k)            // 900 x 600
            page.paste(side, x: 180, y: 120)
            page.fill(PixelRect(x0: 150, y0: 1000, x1: 1100, y1: 1012), value: 0)  // a text line below
            let found = LabelFinder.find(page: PageContent(width: 612, height: 792), render: renderer(for: page, dpi: dpi))
            XCTAssertEqual(found.count, 1, "rotation \(k)")
            XCTAssertEqual(found.first?.quarterTurns, (4 - k) % 4, "rotation \(k)")
        }
    }
}

final class StatusTests: XCTestCase {
    func testHostStatus() {
        let reply = "\u{02}030,1,0,1245,000,0,0,0,000,0,0,0\u{03}\r\n\u{02}000,0,0,0,0,2,6,0,00000000,1,000\u{03}\r\n\u{02}1234,0\u{03}\r\n"
        let s = ZebraStatus.parse(reply)
        XCTAssertEqual(s?.paperOut, true)
        XCTAssertEqual(s?.summary, "Out of labels")
        let ok = ZebraStatus.parse(reply.replacingOccurrences(of: "030,1,0", with: "030,0,0"))
        XCTAssertEqual(ok?.summary, "Ready")
    }

    func testHostIdentification() {
        let id = ZebraIdentity.parse("\u{02}GX420d-200dpi,V61.17.17Z,8,8192KB\u{03}\r\n")
        XCTAssertEqual(id?.model, "GX420d-200dpi")
        XCTAssertEqual(id?.dpi, 203)
        XCTAssertEqual(ZebraIdentity.parse("\u{02}ZD421-300dpi,V93.21.15Z,12,8192KB\u{03}")?.dpi, 300)
    }

    func testCarrier() {
        XCTAssertEqual(Carrier.name(for: ["420303490000", "1ZA4F2619031245673"]), "UPS")
        XCTAssertEqual(Carrier.trackingNumber(in: ["420303490000", "1ZA4F2619031245673"]), "1ZA4F2619031245673")
        XCTAssertEqual(Carrier.name(for: ["9400111899223197428490"]), "USPS")
    }
}
