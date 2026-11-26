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

    func testShiftIsAlwaysSentAndReachesTheTestLabel() {
        let img = GrayImage(width: 812, height: 1218)
        // no shift: leave the printer's own Label Top / Left Position alone
        XCTAssertFalse(ZPL.label(img).contains("^LT"))
        XCTAssertFalse(ZPL.label(img).contains("^LS"))
        // the picture moves; the printer's own position (^LT/^LS) is never touched
        let down = ZPL.label(img, settings: PrintSettings(topOffset: 60, leftOffset: 8))
        XCTAssertTrue(down.contains("^LL1278") && down.contains("^FO8,60^GFA"))
        XCTAssertFalse(down.contains("^LT") || down.contains("^LS"))
        XCTAssertTrue(ZPL.label(img, settings: PrintSettings(topOffset: 500)).contains("^FO0,120^GFA"))
        let up = ZPL.label(img, settings: PrintSettings(topOffset: -40))
        XCTAssertTrue(up.contains("^LL1218") && up.contains("^FO0,0^GFA,\(102 * 1178),"))
        let t = ZPL.testLabel(widthDots: 812, heightDots: 1218, dpi: 203, settings: PrintSettings(topOffset: -40))
        XCTAssertTrue(t.contains("^FO40,0^A0N") && !t.contains("^LT"))
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

final class USBTests: XCTestCase {
    let lpinfo = """
    Device: uri = usb://Zebra%20Technologies/ZTC%20GX420d?serial=28J154300123
            class = direct
            info = Zebra Technologies ZTC GX420d
            make-and-model = Zebra Technologies ZTC GX420d
            device-id = MANUFACTURER:Zebra Technologies;COMMAND SET:ZPL;MODEL:ZTC GX420d;CLASS:PRINTER;OPTIONS:XML;
            location =
    Device: uri = usb://Brother/HL-L2350DW%20series?serial=U63891E9N123456
            class = direct
            info = Brother HL-L2350DW series
            make-and-model = Brother HL-L2350DW series
            device-id = MFG:Brother;CMD:PJL,PCL,PCLXL,URF;MDL:HL-L2350DW series;CLS:PRINTER;
            location =
    Device: uri = socket
            class = network
            info = AppSocket/HP JetDirect
            make-and-model = Unknown
            device-id =
            location =
    """

    func testReadsCUPSDeviceList() {
        let found = USBDevices.parseLPInfo(lpinfo)
        XCTAssertEqual(found.count, 2)
        let zebra = found[0]
        XCTAssertTrue(zebra.isZebra)
        XCTAssertEqual(zebra.model, "ZTC GX420d")
        XCTAssertEqual(zebra.displayName, "GX420d")
        XCTAssertEqual(zebra.serial, "28J154300123")
        XCTAssertEqual(zebra.speaksZPL, true)
        XCTAssertEqual(zebra.dpi, 203)
        XCTAssertEqual(zebra.makeAndModel, "Zebra Technologies ZTC GX420d")
        XCTAssertFalse(found[1].isZebra)
        XCTAssertEqual(found[1].speaksZPL, false)
    }

    func testReadsTheUSBBackendsOwnList() {
        let out = """
        direct usb "Unknown" "USB Printer (usb)"
        direct usb://Zebra%20Technologies/ZTC%20LP%202844?serial=42A000001 "Zebra Technologies ZTC LP 2844" "Zebra Technologies ZTC LP 2844" "MFG:Zebra Technologies;MDL:ZTC LP 2844;" ""
        """
        let found = USBDevices.parseBackendList(out)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].model, "ZTC LP 2844")
        XCTAssertEqual(found[0].displayName, "LP 2844")
        XCTAssertTrue(found[0].isZebra)
        XCTAssertEqual(found[0].speaksZPL, false, "an LP 2844 without -Z only speaks EPL")
        XCTAssertEqual(USBDevices.tokens(#"a "b c" "" d"#), ["a", "b c", "", "d"])
    }

    func testModelFromTheURIWhenThereIsNoDeviceID() {
        let p = USBPrinterInfo(uri: "usb://Zebra%20Technologies/ZTC%20ZD421-300dpi%20ZPL?serial=D4J1")
        XCTAssertEqual(p.manufacturer, "Zebra Technologies")
        XCTAssertEqual(p.displayName, "ZD421-300dpi")
        XCTAssertEqual(p.dpi, 300)
        XCTAssertNil(p.speaksZPL)
        XCTAssertTrue(p.isZebra)
        XCTAssertEqual(USBDevices.parseDeviceID("MFG:Zebra;CMD:ZPL,EPL;MDL:ZTC ZD421;")["CMD"], "ZPL,EPL")
    }

    func testSameDevice() {
        let a = "usb://Zebra%20Technologies/ZTC%20GX420d?serial=28J1"
        XCTAssertTrue(USBDevices.sameDevice(a, "usb://Zebra%20Technologies/ZTC%20GX420d?serial=28j1"))
        XCTAssertFalse(USBDevices.sameDevice(a, "usb://Zebra%20Technologies/ZTC%20GX420d?serial=28J2"))
        XCTAssertTrue(USBDevices.sameDevice("usb://Zebra%20Technologies/ZTC%20GX420d",
                                            "usb://Zebra Technologies/ZTC GX420d?location=14100000"))
        XCTAssertFalse(USBDevices.sameDevice(a, "socket://10.0.10.50:9100"))
        XCTAssertEqual(USBDevices.uri(manufacturer: "Zebra Technologies", product: "ZTC GX420d", serial: "28J1"), a)
    }

    func testResolutionAndLanguageFromTheModel() {
        XCTAssertEqual(USBDevices.guessDPI(model: "ZTC GX420d"), 203)
        XCTAssertEqual(USBDevices.guessDPI(model: "ZTC GK420d"), 203)
        XCTAssertEqual(USBDevices.guessDPI(model: "ZTC GX430t"), 300)
        XCTAssertEqual(USBDevices.guessDPI(model: "ZTC ZT410-300dpi ZPL"), 300)
        XCTAssertEqual(USBDevices.guessDPI(model: "ZTC ZT610-600dpi ZPL"), 600)
        XCTAssertTrue(USBDevices.eplOnly("ZTC LP 2844"))
        XCTAssertTrue(USBDevices.eplOnly("ZTC ZP 505"))
        XCTAssertFalse(USBDevices.eplOnly("ZTC LP 2844-Z"))
        XCTAssertFalse(USBDevices.eplOnly("TLP 2844-Z"))
        XCTAssertFalse(USBDevices.eplOnly("ZTC ZP 450"))
        XCTAssertFalse(USBDevices.eplOnly("ZTC GX420d"))
    }
}

final class PrinterConfigTests: XCTestCase {
    // a GX420d's ^HH reply (abridged)
    let reply = "\u{02}" + """
      15.0                DARKNESS          
      -020                TEAR OFF          
      TEAR OFF            PRINT MODE        
      GAP/NOTCH           MEDIA TYPE        
      WEB                 SENSOR TYPE       
      812                 PRINT WIDTH       
      1318                LABEL LENGTH      
      39.0IN   989MM      MAXIMUM LENGTH    
      <~>  7EH            CONTROL CHAR      
      +000                LABEL TOP         
      +0000               LEFT POSITION     
      V56.17.17Z <-       FIRMWARE          
    """ + "\u{03}"

    func testReadsTheSettings() throws {
        let c = try XCTUnwrap(PrinterConfig.parse(reply))
        XCTAssertEqual(c.labelLengthDots, 1318)
        XCTAssertEqual(c.mediaType, "GAP/NOTCH")
        XCTAssertEqual(c.printMode, "TEAR OFF")
        XCTAssertEqual(c["MAXIMUM LENGTH"], "39.0IN   989MM")
        XCTAssertEqual(c["CONTROL CHAR"], "<~>  7EH")
        XCTAssertEqual(c["FIRMWARE"], "V56.17.17Z <-")
        XCTAssertEqual(c.labelTop, 0)
        XCTAssertNil(PrinterConfig.parse("nothing useful"))
    }

    func testChecksAgainstTheLabelSize() throws {
        let c = try XCTUnwrap(PrinterConfig.parse(reply))
        // 6.49 in apart against 4 × 6: longer labels, worth a note but not a warning
        let long = c.check(labelHeightDots: 1218, dpi: 203)
        XCTAssertEqual(long.map(\.level), [.info])
        XCTAssertTrue(long[0].text.contains("6.49 in"))
        // a normal 4 × 6 roll (6.12 in apart): nothing to say
        var normal = c
        normal.values["LABEL LENGTH"] = "1243"
        XCTAssertTrue(normal.check(labelHeightDots: 1218, dpi: 203).isEmpty)
        // labels shorter than the chosen size, continuous paper, the printer's own offsets
        XCTAssertEqual(normal.check(labelHeightDots: 1624, dpi: 203).map(\.level), [.warning])
        var odd = c
        odd.values["MEDIA TYPE"] = "CONTINUOUS"
        odd.values["LABEL TOP"] = "+060"
        XCTAssertEqual(odd.check(labelHeightDots: 1218, dpi: 203).map(\.level), [.warning, .info])
    }
}

final class PrintQualityTests: XCTestCase {
    static var matrix21: [Bool] { ExtraCodeTests.qr21.flatMap { row in row.map { $0 == "#" } } }

    static func drawQR21(_ img: inout GrayImage, x: Int, y: Int, module: Int) {
        for (r, row) in ExtraCodeTests.qr21.enumerated() {
            for (c, ch) in row.enumerated() where ch == "#" {
                img.fill(PixelRect(x0: x + c * module, y0: y + r * module, x1: x + (c + 1) * module, y1: y + (r + 1) * module), value: 0)
            }
        }
    }

    /// An anti-aliased disc (area coverage), the way a browser draws curves into a small image.
    static func disc(size n: Int, centre: Double, radius r: Double, supersample ss: Int = 8) -> GrayImage {
        var img = GrayImage(width: n, height: n)
        for y in 0..<n {
            for x in 0..<n {
                var inside = 0
                for sy in 0..<ss {
                    for sx in 0..<ss {
                        let px = Double(x) + (Double(sx) + 0.5) / Double(ss) - centre
                        let py = Double(y) + (Double(sy) + 0.5) / Double(ss) - centre
                        if px * px + py * py <= r * r { inside += 1 }
                    }
                }
                img[x, y] = UInt8(255 - 255 * inside / (ss * ss))
            }
        }
        return img
    }

    static func mismatches(_ a: GrayImage, _ b: GrayImage) -> Int {
        zip(a.pixels, b.pixels).filter { ($0 < 128) != ($1 < 128) }.count
    }

    func testLanczosKeepsFlatAreasAndEdgePositions() {
        let flat = GrayImage(width: 20, height: 10, fill: 180).lanczosResampled(width: 47, height: 23)
        XCTAssertEqual(flat.width, 47)
        XCTAssertEqual(flat.height, 23)
        XCTAssertTrue(flat.pixels.allSatisfy { abs(Int($0) - 180) <= 1 })
        var step = GrayImage(width: 20, height: 4)
        step.fill(PixelRect(x0: 0, y0: 0, x1: 10, y1: 4), value: 0)
        let big = step.lanczosResampled(width: 60, height: 12).thresholded(128)
        XCTAssertEqual((0..<60).filter { big[$0, 6] == 0 }.count, 30, "the edge stays exactly halfway")
    }

    func testScale2xRoundsAStaircaseAndKeepsLonePixels() {
        var dot = GrayImage(width: 5, height: 5)
        dot[2, 2] = 0
        XCTAssertEqual(dot.scale2x().pixels.filter { $0 == 0 }.count, 4)
        var diagonal = GrayImage(width: 8, height: 8)
        for i in 0..<6 { diagonal[i + 1, i + 1] = 0 }
        // six 2×2 blocks, joined by a filled corner on each side of every step
        XCTAssertEqual(diagonal.scale2x().pixels.filter { $0 == 0 }.count, 6 * 4 + 5 * 2)
    }

    func testBlackAndWhiteDetection() {
        var img = GrayImage(width: 100, height: 100)
        img.fill(PixelRect(x0: 10, y0: 10, x1: 50, y1: 50), value: 0)
        XCTAssertTrue(img.isBlackAndWhite)
        for i in 0..<100 { img[i, 60] = 128 }
        XCTAssertFalse(img.isBlackAndWhite)
    }

    func testSmoothEnlargingFollowsTheRealEdges() {
        let low = Self.disc(size: 24, centre: 12, radius: 7.3)
        let truth = Self.disc(size: 60, centre: 30, radius: 18.25, supersample: 1)
        // what Tearoff did before: copy each pixel into a block, then average down
        let blocky = GrayImage(width: 72, height: 72, pixels: (0..<(72 * 72)).map { low[($0 % 72) / 3, ($0 / 72) / 3] })
            .resampled(width: 60, height: 60)
        let smooth = low.smoothlyEnlarged(width: 60, height: 60)
        XCTAssertFalse(smooth.blackAndWhite)
        let before = Self.mismatches(blocky, truth), after = Self.mismatches(smooth.image, truth)
        XCTAssertLessThanOrEqual(Double(after), 0.6 * Double(before), "anti-aliased: \(after) vs \(before) wrong dots")
        // a black-and-white source has nothing to say where its edges really are: it can't get
        // closer to the true disc, only smoother (Scale2x is tested on its own), and never worse
        let bw = low.thresholded(128)
        let bwBlocky = GrayImage(width: 72, height: 72, pixels: (0..<(72 * 72)).map { bw[($0 % 72) / 3, ($0 / 72) / 3] })
            .resampled(width: 60, height: 60)
        let bwSmooth = bw.smoothlyEnlarged(width: 60, height: 60)
        XCTAssertTrue(bwSmooth.blackAndWhite)
        XCTAssertLessThanOrEqual(Self.mismatches(bwSmooth.image, truth), Self.mismatches(bwBlocky, truth))
    }

    func testQRModulesAreSampledInTheRastersOwnOrientation() {
        var big = GrayImage(width: 2000, height: 2000)
        Self.drawQR21(&big, x: 500, y: 450, module: 23)
        let small = big.resampled(width: 400, height: 400)       // 4.6 px modules, anti-aliased edges
        var want = Self.matrix21
        for k in 0..<4 {
            guard let s = QRFinder.find(in: small.rotated(quarterTurnsCW: k), ppi: 300).first else { return XCTFail("rotation \(k)") }
            XCTAssertEqual(s.modules, want, "rotation \(k)")
            // the same matrix turned a quarter clockwise, for the next rotation
            want = (0..<(21 * 21)).map { i in want[(20 - i % 21) * 21 + i / 21] }
        }
    }

    func testQRCodesAreRedrawnWithWholeDotModules() {
        var big = GrayImage(width: 1600, height: 1600)
        Self.drawQR21(&big, x: 300, y: 300, module: 46)
        let g = big.resampled(width: 800, height: 800)            // 23 px modules
        let r = LabelRenderer.finish(g, options: RenderOptions(), qr: true)
        XCTAssertEqual(r.gridFitted, 1)
        guard let s = QRFinder.find(in: r.image, ppi: 203).first else { return XCTFail("no QR code on the label") }
        XCTAssertEqual(s.modules, Self.matrix21)
        XCTAssertEqual(s.module, s.module.rounded(), accuracy: 0.05, "every module a whole number of dots")
    }

    func testRetypesTheBarcodesTextWhenItChecksOut() {
        var img = GrayImage(width: 812, height: 400)
        let code = PixelRect(x0: 100, y0: 150, x1: 700, y1: 350)
        img.fill(code, value: 0)
        // twelve glyphs centred over the bars
        var x = (812 - (12 * 20 + 11 * 8)) / 2
        for _ in 0..<12 {
            img.fill(PixelRect(x0: x, y0: 100, x1: x + 20, y1: 130), value: 0)
            x += 28
        }
        let blocks = TextServices(read: nil) { text, ppem in
            let h = max(4, Int(ppem)), cw = max(2, h / 2)
            var g = GrayImage(width: cw * text.count + 4, height: h + 4)
            g.fill(PixelRect(x0: 2, y0: 2, x1: 2 + cw * text.count, y1: 2 + h), value: 0)
            return g
        }
        let value = "D7SnjMlpRRMA"
        var out = img
        XCTAssertEqual(HRIText.retypeset(&out, code: code, value: value, source: nil, toSource: { $0 }, services: blocks), .layout)
        let ink = out.cropped(PixelRect(x0: 0, y0: 0, x1: 812, y1: 150)).inkBounds()
        XCTAssertEqual(ink?.y1, 130, "still ends where the old line did, next to the bars")
        XCTAssertGreaterThan(ink?.height ?? 0, 30, "and a little larger")

        // OCR reads something else: it isn't the barcode's text, so it stays
        let other = TextServices(read: { _ in ["RETURN SLIP"] }, draw: blocks.draw)
        var kept = img
        XCTAssertNil(HRIText.retypeset(&kept, code: code, value: value, source: img, toSource: { $0 }, services: other))
        XCTAssertEqual(kept, img)
        // OCR mixing up l and I still matches
        let ocr = TextServices(read: { _ in ["D7SnjMIpRRMA"] }, draw: blocks.draw)
        var read = img
        XCTAssertEqual(HRIText.retypeset(&read, code: code, value: value, source: img, toSource: { $0 }, services: ocr), .ocr)
        // two lines of text and no OCR: can't tell which is the barcode's, leave them
        var two = img
        two.fill(PixelRect(x0: 300, y0: 20, x1: 500, y1: 50), value: 0)
        XCTAssertNil(HRIText.retypeset(&two, code: code, value: value, source: nil, toSource: { $0 }, services: blocks))
        // the wrong number of characters and no OCR: leave it
        XCTAssertNil(HRIText.retypeset(&out, code: code, value: "SHORT", source: nil, toSource: { $0 }, services: blocks))
    }
}
