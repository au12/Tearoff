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

final class ExtraCodeTests: XCTestCase {
    /// Version 1-M QR code for "TEAROFF".
    static let qr21 = [
        "#######.#..##.#######", "#.....#.##..#.#.....#", "#.###.#..#.#..#.###.#", "#.###.#.##..#.#.###.#",
        "#.###.#...##..#.###.#", "#.....#..#.##.#.....#", "#######.#.#.#.#######", "........#####........",
        "#.##.###.#.##.#..#.##", "..#....##..####...###", ".#.#######.#......###", "#.####.#...#..###.###",
        "####..##.##.#..#.#...", "........#.##..#..####", "#######.#####..#.##.#", "#.....#.#......##.###",
        "#.###.#..#..#####...#", "#.###.#.##.#..#.#..#.", "#.###.#.##..#.##.##..", "#.....#..##..#.##.#..",
        "#######.##...#.#...#.",
    ]

    func drawQR(_ img: inout GrayImage, x: Int, y: Int, module: Int, keep: (Int, Int) -> Bool = { _, _ in true }) {
        for (r, row) in Self.qr21.enumerated() {
            for (c, ch) in row.enumerated() where ch == "#" && keep(r, c) {
                img.fill(PixelRect(x0: x + c * module, y0: y + r * module, x1: x + (c + 1) * module, y1: y + (r + 1) * module), value: 0)
            }
        }
    }

    func testQRFinderLocatesTheSymbolInEveryRotation() {
        var img = GrayImage(width: 640, height: 520)
        drawQR(&img, x: 150, y: 100, module: 9)       // 189 px symbol
        for k in 0..<4 {
            let found = QRFinder.find(in: img.rotated(quarterTurnsCW: k), ppi: 300)
            XCTAssertEqual(found.count, 1, "rotation \(k)")
            XCTAssertEqual(found.first?.dimension, 21, "rotation \(k)")
            XCTAssertEqual(found.first?.module ?? 0, 9, accuracy: 1, "rotation \(k)")
        }
        let r = QRFinder.find(in: img, ppi: 300)[0].rect
        XCTAssertEqual(Double(r.x0), 150, accuracy: 4)
        XCTAssertEqual(Double(r.y0), 100, accuracy: 4)
        XCTAssertEqual(Double(r.x1), 339, accuracy: 4)
        XCTAssertEqual(Double(r.y1), 289, accuracy: 4)
    }

    func testThreeSquaresWithoutTimingPatternsAreNotAQRCode() {
        var img = GrayImage(width: 640, height: 520)
        drawQR(&img, x: 150, y: 100, module: 9) { r, c in (r < 7 && c < 7) || (r < 7 && c >= 14) || (r >= 14 && c < 7) }
        XCTAssertTrue(QRFinder.find(in: img, ppi: 300).isEmpty)
    }

    func testThinnedBarsAtThreeAndAHalfPixelsStillQuantize() {
        // 0.85 pt modules seen at 300 dpi are 3.54 px; thresholding thins every bar by ~1 px
        let modules = code128Modules("ORDER-5521-B")
        let runs = modules.enumerated().map { k, m in
            Int((Double(m) * 3.54 + (k % 2 == 0 ? -0.6 : 0.6)).rounded())
        }
        XCTAssertNil(BarcodeFinder.quantize(runs))                // label finding keeps the strict reading
        let q = BarcodeFinder.quantize(runs, robust: true)
        XCTAssertEqual(q?.modules ?? [], modules)
        XCTAssertNotNil(BarcodeFinder.code128Values(q?.modules ?? []))
    }

    /// A return slip on a 300 dpi page: the value printed centred above the bars is part of the
    /// code; a dotted rule above it and a paragraph below are not.
    func testCodeFinderTakesTheDigitsButNotTheRuleOrParagraph() {
        let ppi = 300.0, s = ppi / 72
        var page = GrayImage(width: 2550, height: 1500)
        let modules = code128Modules("RmaSLIP42x")
        let bw = modules.reduce(0, +) * 4
        let bx = (2550 - bw) / 2
        drawBarcode(&page, modules: modules, x: bx, y: 700, module: 4, height: 200)
        // the value, as letter-sized strokes centred over the bars, 10 px above them
        var tx = 1275 - 150
        var k = 0
        while tx < 1275 + 150 {
            let w = [10, 16, 12][k % 3]
            page.fill(PixelRect(x0: tx, y0: 664, x1: tx + w, y1: 690), value: 0)
            tx += w + 9; k += 1
        }
        // a dotted rule across the page just above, and a paragraph line well below
        var dx = 200
        while dx < 2350 { page.fill(PixelRect(x0: dx, y0: 641, x1: dx + 3, y1: 644), value: 0); dx += 9 }
        page.fill(PixelRect(x0: 150, y0: 990, x1: 2400, y1: 1018), value: 0)

        let codes = BarcodeFinder.find(in: page, ppi: ppi)
        XCTAssertEqual(codes.compactMap { $0.text }, ["RmaSLIP42x"])
        let found = CodeFinder.find(big: page, scale: s, linear: codes, labels: [])
        XCTAssertEqual(found.count, 1)
        guard let c = found.first else { return }
        XCTAssertEqual(c.kind, .code)
        XCTAssertEqual(c.quarterTurns, 0)
        XCTAssertEqual(c.rect.y0 * s, 664 - s, accuracy: 6)       // the digits, plus the 1 pt pad
        XCTAssertEqual(c.rect.y1 * s, 900 + s, accuracy: 6)       // the bars' foot
        XCTAssertEqual(c.rect.x0 * s, Double(bx) - s, accuracy: 6)
        XCTAssertGreaterThan(c.quietZone.x, 9)                    // 10 modules of 0.96 pt

        // inside a label it is part of that label, not an extra
        let label = PageRect(x0: 0, y0: 0, x1: 2550 / s, y1: 1000 / s)
        XCTAssertTrue(CodeFinder.find(big: page, scale: s, linear: codes, labels: [label]).isEmpty)

        // printed on its own label: lies on its side, fills the length, still scans as the same code
        let out = LabelRenderer.renderCode(c, options: RenderOptions(), render: renderer(for: page, dpi: ppi))
        XCTAssertEqual(out.image.width, 812)
        XCTAssertEqual(out.image.height, 1218)
        XCTAssertEqual(out.quarterTurns, 3)
        XCTAssertEqual(out.gridFitted, 1)
        XCTAssertTrue(out.barcodeTexts.contains("RmaSLIP42x"))
        let upright = out.image.rotated(quarterTurnsCW: 1)
        let again = BarcodeFinder.find(in: upright, ppi: 300)      // 7-dot modules: wide bars by label standards
        XCTAssertEqual(again.compactMap { $0.text }, ["RmaSLIP42x"])
        if let b = again.first(where: { $0.text != nil }) { XCTAssertGreaterThan(Double(b.rect.width), 0.75 * 1218) }
    }
}
