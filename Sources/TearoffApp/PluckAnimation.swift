import AppKit
import SwiftUI

/// The "how it works" animation on the Setup Assistant's last page. A return page open in a
/// browser (or, every other loop, in Preview) → ⌘P → the Print dialog → Tearoff finds the
/// shipping label, the return barcode and the QR code → only those come out of the printer.
struct PluckAnimationView: View {
    /// A fixed moment to show instead of animating (screenshots).
    var frozenTime: Double? = nil
    /// Set by `--pluck-time` in demo mode.
    static var frozenOverride: Double? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()

    var body: some View {
        if let t = frozenTime ?? Self.frozenOverride {
            PluckScene(t: t)
        } else if reduceMotion {
            // no motion: step through the key moments instead
            TimelineView(.periodic(from: start, by: 3)) { context in
                let i = Int(max(0, context.date.timeIntervalSince(start)) / 3)
                PluckScene(t: PluckScene.keyFrames[i % PluckScene.keyFrames.count])
            }
        } else {
            TimelineView(.animation) { context in
                PluckScene(t: max(0, context.date.timeIntervalSince(start)))
            }
        }
    }
}

/// One frame of the animation: a pure function of time, so CI can render exact frames.
struct PluckScene: View {
    let t: Double
    @Environment(\.colorScheme) private var scheme

    static let period = 12.0
    static let size = CGSize(width: 640, height: 320)
    static let keyFrames: [Double] = [1.0, 3.2, 5.6, 11.2, 13.0, 15.2, 17.6, 23.2]

    var loop: Int { Int(t / Self.period) }
    var local: Double { t - Double(loop) * Self.period }
    /// Every other loop the page is open in a Preview-style app instead of a browser.
    var inPreview: Bool { loop % 2 == 1 }

    var body: some View {
        VStack(spacing: 8) {
            Canvas { context, size in
                draw(&context, size)
            }
            .aspectRatio(Self.size.width / Self.size.height, contentMode: .fit)
            Text(caption.text)
                .font(.callout.weight(.medium))
                .foregroundColor(.secondary)
                .opacity(caption.opacity)
                .frame(height: 20)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Animation: print the whole page from your browser or any app, and Tearoff prints only the shipping label, the barcode and the QR code.")
    }

    // MARK: Story

    var caption: (text: String, opacity: Double) {
        let marks: [Double] = [0, 2.0, 3.8, 6.3, Self.period]
        let texts = [
            inPreview ? "…or open it in any Mac app: Preview, Mail, your carrier’s site…" : "Open a return or shipping label in your browser…",
            "…press ⌘P and choose your Zebra.",
            "Tearoff finds the label, the barcode and the QR code…",
            "…and prints only those, each on its own 4×6 label.",
        ]
        let l = local
        var i = 0
        while i < 3 && l >= marks[i + 1] { i += 1 }
        let fade = min(1, (l - marks[i]) / 0.25, (marks[i + 1] - l) / 0.25)
        return (texts[i], max(0, fade))
    }

    enum Item: Int, CaseIterable { case label, slip, qr }

    /// Page layout in document units (300 × 240), fitted into whichever app's page area.
    static let itemRects: [CGRect] = [
        CGRect(x: 18, y: 54, width: 147, height: 98),      // shipping label in a dashed cut line
        CGRect(x: 30, y: 186, width: 112, height: 32),     // return-slip barcode with its value
        CGRect(x: 216, y: 184, width: 40, height: 47),     // QR code with a caption
    ]
    static let tags = ["Label", "Barcode", "QR code"]
    static let highlightAt: [Double] = [4.65, 4.95, 5.25]
    static let flightAt: [Double] = [6.3, 6.55, 6.8]
    static let printAt: [Double] = [7.6, 8.7, 9.8]
    static let textBars: [(CGRect, Double)] = [
        (CGRect(x: 18, y: 12, width: 118, height: 9), 0.85),
        (CGRect(x: 18, y: 28, width: 222, height: 4.5), 0.28),
        (CGRect(x: 18, y: 37, width: 184, height: 4.5), 0.28),
        (CGRect(x: 180, y: 58, width: 96, height: 4.5), 0.3),
        (CGRect(x: 180, y: 68, width: 82, height: 4.5), 0.3),
        (CGRect(x: 180, y: 78, width: 90, height: 4.5), 0.3),
        (CGRect(x: 180, y: 88, width: 64, height: 4.5), 0.3),
        (CGRect(x: 18, y: 166, width: 92, height: 6), 0.75),
        (CGRect(x: 212, y: 166, width: 50, height: 6), 0.75),
        (CGRect(x: 18, y: 228, width: 180, height: 4), 0.28),
        (CGRect(x: 18, y: 235, width: 140, height: 4), 0.28),
    ]

    // MARK: Geometry (scene units, 640 × 320)

    static let window = CGRect(x: 22, y: 20, width: 332, height: 284)
    static let titleH: CGFloat = 26
    static let printer = CGRect(x: 436, y: 62, width: 164, height: 92)
    static let slotY: CGFloat = 146
    static let slotX: CGFloat = 518
    static let card = CGSize(width: 44, height: 66)
    static let rest: [CGPoint] = [CGPoint(x: 466, y: 262), CGPoint(x: 518, y: 266), CGPoint(x: 570, y: 262)]
    static let restAngle: [Double] = [-6, 1.5, 7]

    var pageRect: CGRect {
        let w = Self.window
        if inPreview {
            let side: CGFloat = 56
            return CGRect(x: w.minX + side + 14, y: w.minY + Self.titleH + 10, width: w.width - side - 28, height: w.height - Self.titleH - 20)
        }
        return CGRect(x: w.minX, y: w.minY + Self.titleH, width: w.width, height: w.height - Self.titleH)
    }

    /// Document units → scene units for the current page.
    func doc(_ r: CGRect) -> CGRect {
        let p = pageRect
        let k = min((p.width - 8) / 300, (p.height - 8) / 240)
        let ox = p.minX + (p.width - 300 * k) / 2
        let oy = p.minY + 5
        return CGRect(x: ox + r.minX * k, y: oy + r.minY * k, width: r.width * k, height: r.height * k)
    }

    var palette: Palette { scheme == .dark ? .dark : .light }

    // MARK: Drawing

    func draw(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let s = min(size.width / Self.size.width, size.height / Self.size.height)
        ctx.translateBy(x: (size.width - Self.size.width * s) / 2, y: (size.height - Self.size.height * s) / 2)
        ctx.scaleBy(x: s, y: s)
        let T = local
        let stage = CGRect(origin: .zero, size: Self.size)
        ctx.fill(Path(roundedRect: stage, cornerRadius: 16),
                 with: .linearGradient(Gradient(colors: palette.backdrop), startPoint: .zero, endPoint: CGPoint(x: 0, y: stage.height)))
        var scene = ctx
        scene.opacity = 1 - prog(T, 11.5, 12.0)
        drawPrinter(&scene, T)
        drawWindow(&scene, T)
        drawPicked(&scene, T)
        drawPrinted(&scene, T)
        drawPrintDialog(&scene, T)
        drawKeys(&scene, T)
        drawCursor(&scene, T)
        drawBadges(&scene, T)
    }

    func drawWindow(_ base: inout GraphicsContext, _ T: Double) {
        let w = Self.window
        var c = base
        let appear = prog(T, 0, 0.5)
        c.opacity = appear
        c.scale(0.97 + 0.03 * appear, about: CGPoint(x: w.midX, y: w.midY))
        var shadow = c
        shadow.addFilter(.shadow(color: .black.opacity(0.22), radius: 12, x: 0, y: 6))
        shadow.fill(Path(roundedRect: w, cornerRadius: 10), with: .color(palette.chrome))
        var inner = c
        inner.clip(to: Path(roundedRect: w, cornerRadius: 10))
        // title bar
        let lights = [Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.2), Color(red: 0.16, green: 0.78, blue: 0.26)]
        for (i, color) in lights.enumerated() {
            inner.fill(Path(ellipseIn: CGRect(x: w.minX + 10 + CGFloat(i) * 12, y: w.minY + 9, width: 8, height: 8)), with: .color(color))
        }
        if inPreview {
            inner.draw(Text("Return Label.pdf").font(.system(size: 8, weight: .semibold)).foregroundColor(palette.chromeText),
                       at: CGPoint(x: w.minX + 62, y: w.minY + 13), anchor: .leading)
            let side = CGRect(x: w.minX, y: w.minY + Self.titleH, width: 56, height: w.height - Self.titleH)
            inner.fill(Path(side), with: .color(palette.sidebar))
            let thumb = CGRect(x: side.minX + 13, y: side.minY + 12, width: 30, height: 39)
            inner.fill(Path(roundedRect: thumb.insetBy(dx: -3, dy: -3), cornerRadius: 4), with: .color(Color.accentColor.opacity(0.4)))
            inner.fill(Path(thumb), with: .color(.white))
            for k in 0..<4 {
                inner.fill(Path(CGRect(x: thumb.minX + 4, y: thumb.minY + 5 + CGFloat(k) * 8, width: k == 1 ? 16 : 22, height: k == 1 ? 6 : 2)),
                           with: .color(Color.black.opacity(0.35)))
            }
            let canvasRect = CGRect(x: side.maxX, y: side.minY, width: w.width - side.width, height: side.height)
            inner.fill(Path(canvasRect), with: .color(palette.previewCanvas))
            var page = inner
            page.addFilter(.shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 1))
            page.fill(Path(pageRect), with: .color(.white))
        } else {
            let back = CGPoint(x: w.minX + 56, y: w.minY + 13)
            inner.draw(Text("‹  ›").font(.system(size: 11, weight: .medium)).foregroundColor(palette.chromeText.opacity(0.6)), at: back, anchor: .leading)
            let bar = CGRect(x: w.midX - 76, y: w.minY + 6, width: 176, height: 15)
            inner.fill(Path(roundedRect: bar, cornerRadius: 5), with: .color(palette.field))
            var lock = inner.resolve(Image(systemName: "lock.fill"))
            lock.shading = .color(palette.chromeText.opacity(0.6))
            inner.draw(lock, in: CGRect(x: bar.minX + 38, y: bar.minY + 4, width: 6, height: 7))
            inner.draw(Text("returns.example.com").font(.system(size: 7.5)).foregroundColor(palette.chromeText),
                       at: CGPoint(x: bar.minX + 48, y: bar.midY), anchor: .leading)
            inner.fill(Path(pageRect), with: .color(.white))
        }
        // page content
        var page = inner
        page.clip(to: Path(pageRect))
        let dim = prog(T, 5.6, 6.2)
        var text = page
        text.opacity = 1 - 0.82 * dim
        for (r, ink) in Self.textBars {
            let rr = doc(r)
            text.fill(Path(roundedRect: rr, cornerRadius: rr.height / 2), with: .color(Color(white: 0.12).opacity(ink)))
        }
        for item in Item.allCases {
            let r = doc(Self.itemRects[item.rawValue])
            if T < 5.6 {
                drawItem(&page, item, r)
            } else if T >= Self.flightAt[item.rawValue] {
                // where it was plucked from
                page.stroke(Path(roundedRect: r.insetBy(dx: -2, dy: -2), cornerRadius: 4), with: .color(Color.black.opacity(0.18)),
                            style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }
        }
        // Tearoff reading the page
        let scan = prog(T, 3.8, 4.7)
        if scan > 0 && scan < 1 {
            let p = pageRect
            let y = p.minY + p.height * scan
            page.fill(Path(CGRect(x: p.minX, y: y - 22, width: p.width, height: 22)),
                      with: .linearGradient(Gradient(colors: [Color.accentColor.opacity(0), Color.accentColor.opacity(0.28)]),
                                            startPoint: CGPoint(x: 0, y: y - 22), endPoint: CGPoint(x: 0, y: y)))
            page.fill(Path(CGRect(x: p.minX, y: y - 1, width: p.width, height: 2)), with: .color(Color.accentColor))
        }
    }

    /// Highlights, the lift and the flight into the printer.
    func drawPicked(_ base: inout GraphicsContext, _ T: Double) {
        for item in Item.allCases {
            let i = item.rawValue
            let r = doc(Self.itemRects[i])
            let fly = Self.flightAt[i]
            if T >= 5.6 && T < fly {
                var c = base
                let lift = prog(T, 5.6, 6.2)
                c.scale(1 + 0.07 * lift, about: CGPoint(x: r.midX, y: r.midY))
                var shadow = c
                shadow.addFilter(.shadow(color: .black.opacity(0.3 * lift), radius: 8, x: 0, y: 4))
                shadow.fill(Path(roundedRect: r.insetBy(dx: -2, dy: -2), cornerRadius: 3), with: .color(.white))
                drawItem(&c, item, r)
            }
            if T >= Self.highlightAt[i] && T < fly {
                var c = base
                let pop = backOut((T - Self.highlightAt[i]) / 0.35)
                let lift = prog(T, 5.6, 6.2)
                c.scale((0.85 + 0.15 * pop) * (1 + 0.07 * lift), about: CGPoint(x: r.midX, y: r.midY))
                c.opacity = min(1, (T - Self.highlightAt[i]) / 0.15)
                let box = r.insetBy(dx: -5, dy: -5)
                c.stroke(Path(roundedRect: box, cornerRadius: 6), with: .color(Color.accentColor), lineWidth: 2)
                let tag = c.resolve(Text(Self.tags[i]).font(.system(size: 7.5, weight: .bold)).foregroundColor(.white))
                let ts = tag.measure(in: CGSize(width: 200, height: 40))
                // the tag sits on the highlight's top edge, clear of the headings above
                let pill = CGRect(x: box.minX + 7, y: box.minY - (ts.height + 3) / 2, width: ts.width + 10, height: ts.height + 3)
                c.fill(Path(roundedRect: pill, cornerRadius: pill.height / 2), with: .color(Color.accentColor))
                c.draw(tag, at: CGPoint(x: pill.midX, y: pill.midY), anchor: .center)
            }
            if T >= fly && T < fly + 0.9 {
                let p = smooth((T - fly) / 0.9)
                let from = CGPoint(x: r.midX, y: r.midY)
                let to = CGPoint(x: Self.slotX, y: Self.printer.minY + 8)
                let control = CGPoint(x: (from.x + to.x) / 2, y: min(from.y, to.y) - 70)
                let pos = bezier(from, control, to, p)
                var c = base
                c.opacity = 1 - prog(p, 0.7, 1)
                c.translateBy(x: pos.x - from.x, y: pos.y - from.y)
                c.scale(1.07 - 0.8 * p, about: from)
                var shadow = c
                shadow.addFilter(.shadow(color: .black.opacity(0.28), radius: 8, x: 0, y: 4))
                shadow.fill(Path(roundedRect: r.insetBy(dx: -2, dy: -2), cornerRadius: 3), with: .color(.white))
                drawItem(&c, item, r)
            }
        }
    }

    func drawItem(_ c: inout GraphicsContext, _ item: Item, _ r: CGRect) {
        switch item {
        case .label:
            c.fill(Path(r), with: .color(.white))
            c.stroke(Path(r.insetBy(dx: 0.5, dy: 0.5)), with: .color(Color.black.opacity(0.45)), style: StrokeStyle(lineWidth: 0.8, dash: [2.5, 2]))
            let a = r.insetBy(dx: r.width * 0.03, dy: r.height * 0.05)
            let ink = Color(white: 0.1)
            for f in [0.17, 0.55, 0.75, 0.9] {
                c.fill(Path(CGRect(x: a.minX + a.width * f, y: a.minY, width: 0.8, height: a.height)), with: .color(ink))
            }
            for (k, h) in [0.55, 0.8, 0.45].enumerated() {      // sideways address lines
                c.fill(Path(CGRect(x: a.minX + a.width * (0.03 + 0.045 * Double(k)), y: a.minY + a.height * (1 - h), width: a.width * 0.022, height: a.height * h)), with: .color(ink.opacity(0.7)))
            }
            for (k, h) in [0.62, 0.72, 0.5, 0.66].enumerated() {
                c.fill(Path(CGRect(x: a.minX + a.width * (0.22 + 0.05 * Double(k)), y: a.minY + a.height * 0.06, width: a.width * 0.026, height: a.height * h * 0.6)), with: .color(ink.opacity(0.75)))
            }
            drawCode(&c, CGRect(x: a.minX + a.width * 0.21, y: a.minY + a.height * 0.6, width: a.width * 0.3, height: a.height * 0.36), dots: 11)
            drawBars(&c, CGRect(x: a.minX + a.width * 0.6, y: a.minY + a.height * 0.12, width: a.width * 0.11, height: a.height * 0.5), Self.barsA, vertical: false)
            drawBars(&c, CGRect(x: a.minX + a.width * 0.78, y: a.minY + a.height * 0.08, width: a.width * 0.1, height: a.height * 0.84), Self.barsB, vertical: false)
            c.fill(Path(CGRect(x: a.minX + a.width * 0.6, y: a.minY + a.height * 0.72, width: a.width * 0.1, height: a.height * 0.2)), with: .color(ink))
        case .slip:
            c.fill(Path(CGRect(x: r.midX - r.width * 0.2, y: r.minY, width: r.width * 0.4, height: r.height * 0.13)), with: .color(Color(white: 0.2)))
            drawBars(&c, CGRect(x: r.minX, y: r.minY + r.height * 0.26, width: r.width, height: r.height * 0.74), Self.barsC, vertical: true)
        case .qr:
            let q = CGRect(x: r.minX, y: r.minY, width: r.width, height: r.width)
            drawQR(&c, q)
            c.fill(Path(CGRect(x: r.minX + r.width * 0.1, y: r.maxY - 3.5, width: r.width * 0.8, height: 3)), with: .color(Color(white: 0.25)))
        }
    }

    func drawPrinter(_ base: inout GraphicsContext, _ T: Double) {
        var c = base
        c.opacity = prog(T, 0.2, 0.8)
        let b = Self.printer
        c.fill(Path(ellipseIn: CGRect(x: b.minX + 8, y: b.maxY - 6, width: b.width - 16, height: 16)), with: .color(Color.black.opacity(0.16)))
        c.fill(Path(roundedRect: b, cornerRadius: 18),
               with: .linearGradient(Gradient(colors: [Color(white: 0.34), Color(white: 0.17)]),
                                     startPoint: CGPoint(x: b.midX, y: b.minY), endPoint: CGPoint(x: b.midX, y: b.maxY)))
        c.stroke(Path(roundedRect: b.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 18), with: .color(Color.white.opacity(0.1)), lineWidth: 1)
        var seam = Path()
        seam.move(to: CGPoint(x: b.minX + 14, y: b.minY + 40))
        seam.addQuadCurve(to: CGPoint(x: b.maxX - 14, y: b.minY + 40), control: CGPoint(x: b.midX, y: b.minY + 47))
        c.stroke(seam, with: .color(Color.white.opacity(0.14)), lineWidth: 1.5)
        c.fill(Path(roundedRect: CGRect(x: Self.slotX - 36, y: Self.slotY - 3, width: 72, height: 6), cornerRadius: 3), with: .color(Color(white: 0.05)))
        let printing = T > Self.printAt[0] - 0.2 && T < Self.printAt[2] + 1.0
        let lit = !printing || Int(T * 6) % 2 == 0
        c.fill(Path(ellipseIn: CGRect(x: b.maxX - 27, y: b.minY + 16, width: 8, height: 8)),
               with: .color(lit ? Color(red: 0.3, green: 0.9, blue: 0.45) : Color(white: 0.32)))
        c.fill(Path(roundedRect: CGRect(x: b.maxX - 31, y: b.minY + 54, width: 16, height: 10), cornerRadius: 4), with: .color(Color(white: 0.42)))
    }

    func drawPrinted(_ base: inout GraphicsContext, _ T: Double) {
        for i in 0..<3 where T >= Self.printAt[i] {
            let start = Self.printAt[i]
            let emerge = smooth((T - start) / 0.6)
            let settle = smooth((T - start - 0.65) / 0.4)
            let size = Self.card
            let out = CGPoint(x: Self.slotX, y: Self.slotY - size.height / 2 + size.height * emerge)
            let center = CGPoint(x: lerp(out.x, Self.rest[i].x, settle), y: lerp(out.y, Self.rest[i].y, settle))
            var c = base
            if settle <= 0 { c.clip(to: Path(CGRect(x: 0, y: Self.slotY, width: Self.size.width, height: Self.size.height))) }
            c.translateBy(x: center.x, y: center.y)
            c.rotate(by: .degrees(Self.restAngle[i] * settle))
            let r = CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height)
            var shadow = c
            shadow.addFilter(.shadow(color: .black.opacity(0.25), radius: 3, x: 0, y: 2))
            shadow.fill(Path(roundedRect: r, cornerRadius: 3), with: .color(.white))
            drawCard(&c, i, r)
        }
    }

    /// The 4×6 labels as printed: the shipping label upright, the barcode on its side, the QR code.
    func drawCard(_ c: inout GraphicsContext, _ i: Int, _ r: CGRect) {
        let a = r.insetBy(dx: 4, dy: 4)
        let ink = Color(white: 0.1)
        switch i {
        case 0:
            for (k, w) in [0.5, 0.7, 0.42].enumerated() {
                c.fill(Path(CGRect(x: a.minX, y: a.minY + CGFloat(k) * 4, width: a.width * w, height: 2)), with: .color(ink.opacity(0.7)))
            }
            c.fill(Path(CGRect(x: a.maxX - 9, y: a.minY, width: 9, height: 9)), with: .color(ink))
            c.fill(Path(CGRect(x: a.minX, y: a.minY + 15, width: a.width, height: 1.2)), with: .color(ink))
            drawCode(&c, CGRect(x: a.minX, y: a.minY + 19, width: 14, height: 14), dots: 9)
            drawBars(&c, CGRect(x: a.minX + 17, y: a.minY + 19, width: a.width - 17, height: 9), Self.barsA, vertical: true)
            c.fill(Path(CGRect(x: a.minX, y: a.minY + 36, width: a.width, height: 1.2)), with: .color(ink))
            drawBars(&c, CGRect(x: a.minX, y: a.minY + 40, width: a.width, height: 13), Self.barsB, vertical: true)
            c.fill(Path(CGRect(x: a.minX, y: a.maxY - 2, width: a.width * 0.6, height: 2)), with: .color(ink.opacity(0.6)))
        case 1:
            c.fill(Path(CGRect(x: a.minX + 3, y: a.midY - a.height * 0.2, width: 2.2, height: a.height * 0.4)), with: .color(ink.opacity(0.75)))
            drawBars(&c, CGRect(x: a.minX + 9, y: a.minY + 3, width: a.width - 12, height: a.height - 6), Self.barsC, vertical: false)
        default:
            let q = CGRect(x: a.midX - 14, y: a.minY + 9, width: 28, height: 28)
            drawQR(&c, q)
            c.fill(Path(CGRect(x: a.midX - 10, y: q.maxY + 5, width: 20, height: 2.2)), with: .color(ink.opacity(0.7)))
        }
    }

    func drawPrintDialog(_ base: inout GraphicsContext, _ T: Double) {
        let open = prog(T, 2.0, 2.4), close = prog(T, 3.5, 3.8)
        guard open > 0, close < 1 else { return }
        let w = Self.window
        let sheet = sheetRect(open: open, close: close)
        var c = base
        c.clip(to: Path(CGRect(x: w.minX, y: w.minY + Self.titleH, width: w.width, height: w.height - Self.titleH)))
        c.fill(Path(CGRect(x: w.minX, y: w.minY + Self.titleH, width: w.width, height: w.height - Self.titleH)),
               with: .color(Color.black.opacity(0.12 * open * (1 - close))))
        var shadow = c
        shadow.addFilter(.shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 4))
        shadow.fill(Path(roundedRect: sheet, cornerRadius: 9), with: .color(palette.sheet))
        let labelX = sheet.minX + 64
        let rows: [(String, String, Bool)] = [("Printer", "Zebra GX420d", true), ("Presets", "Default Settings", false), ("Copies", "1", false)]
        for (k, row) in rows.enumerated() {
            let y = sheet.minY + 22 + CGFloat(k) * 22
            c.draw(Text(row.0).font(.system(size: 7.5)).foregroundColor(palette.chromeText.opacity(0.8)), at: CGPoint(x: labelX - 6, y: y), anchor: .trailing)
            let fieldW: CGFloat = row.0 == "Copies" ? 22 : 128
            let field = CGRect(x: labelX, y: y - 7.5, width: fieldW, height: 15)
            c.fill(Path(roundedRect: field, cornerRadius: 4), with: .color(row.2 ? Color.accentColor.opacity(0.14) : palette.field))
            if row.2 {
                c.stroke(Path(roundedRect: field, cornerRadius: 4), with: .color(Color.accentColor), lineWidth: 1)
                var icon = c.resolve(Image(systemName: "printer.fill"))
                icon.shading = .color(palette.chromeText)
                c.draw(icon, in: CGRect(x: field.minX + 5, y: field.minY + 3.5, width: 9, height: 8))
            }
            c.draw(Text(row.1).font(.system(size: 7.5, weight: row.2 ? .semibold : .regular)).foregroundColor(palette.chromeText),
                   at: CGPoint(x: field.minX + (row.2 ? 18 : 6), y: field.midY), anchor: .leading)
            if fieldW > 40 {
                var chevron = c.resolve(Image(systemName: "chevron.up.chevron.down"))
                chevron.shading = .color(palette.chromeText.opacity(0.6))
                c.draw(chevron, in: CGRect(x: field.maxX - 11, y: field.minY + 3.5, width: 6, height: 8))
            }
        }
        let cancel = CGRect(x: sheet.maxX - 112, y: sheet.maxY - 26, width: 48, height: 16)
        c.fill(Path(roundedRect: cancel, cornerRadius: 4), with: .color(palette.field))
        c.draw(Text("Cancel").font(.system(size: 7.5)).foregroundColor(palette.chromeText), at: CGPoint(x: cancel.midX, y: cancel.midY))
        let printRect = printButton(sheet)
        let pressed = T > 3.3 && T < 3.48
        c.fill(Path(roundedRect: printRect, cornerRadius: 4), with: .color(pressed ? Color.accentColor.opacity(0.7) : Color.accentColor))
        c.draw(Text("Print").font(.system(size: 7.5, weight: .semibold)).foregroundColor(.white), at: CGPoint(x: printRect.midX, y: printRect.midY))
    }

    func sheetRect(open: Double, close: Double) -> CGRect {
        let w = Self.window
        let width: CGFloat = 232, height: CGFloat = 112
        let top = w.minY + Self.titleH - height * CGFloat(1 - open) - height * CGFloat(close)
        return CGRect(x: w.midX - width / 2, y: top, width: width, height: height)
    }

    func printButton(_ sheet: CGRect) -> CGRect { CGRect(x: sheet.maxX - 58, y: sheet.maxY - 26, width: 46, height: 16) }

    func drawKeys(_ base: inout GraphicsContext, _ T: Double) {
        let a = prog(T, 1.1, 1.35) * (1 - prog(T, 1.85, 2.1))
        guard a > 0 else { return }
        let w = Self.window
        let center = CGPoint(x: w.midX, y: w.midY + 14)
        var c = base
        c.opacity = a
        c.scale(0.75 + 0.25 * backOut((T - 1.1) / 0.4), about: center)
        let down: CGFloat = (T > 1.5 && T < 1.72) ? 2.5 : 0
        for (i, key) in ["⌘", "P"].enumerated() {
            let r = CGRect(x: center.x - 47 + CGFloat(i) * 52, y: center.y - 21 + down, width: 42, height: 42)
            var shadow = c
            shadow.addFilter(.shadow(color: .black.opacity(0.35), radius: down > 0 ? 2 : 5, x: 0, y: down > 0 ? 1 : 3))
            shadow.fill(Path(roundedRect: r, cornerRadius: 8), with: .color(palette.key))
            c.stroke(Path(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 8), with: .color(Color.black.opacity(0.12)), lineWidth: 1)
            c.draw(Text(key).font(.system(size: 19, weight: .semibold)).foregroundColor(palette.keyText), at: CGPoint(x: r.midX, y: r.midY))
        }
    }

    func drawCursor(_ base: inout GraphicsContext, _ T: Double) {
        let a = prog(T, 2.45, 2.6) * (1 - prog(T, 3.55, 3.75))
        guard a > 0 else { return }
        let w = Self.window
        let target = printButton(sheetRect(open: 1, close: 0))
        let from = CGPoint(x: w.maxX - 26, y: w.maxY - 30)
        let to = CGPoint(x: target.midX + 4, y: target.midY + 3)
        let p = smooth((T - 2.55) / 0.7)
        let pos = CGPoint(x: lerp(from.x, to.x, p), y: lerp(from.y, to.y, p))
        var c = base
        c.opacity = a
        c.translateBy(x: pos.x, y: pos.y)
        if T > 3.3 && T < 3.48 { c.scaleBy(x: 0.86, y: 0.86) }
        var arrow = Path()
        arrow.addLines([CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 15), CGPoint(x: 3.6, y: 11.6), CGPoint(x: 6.4, y: 17.6),
                        CGPoint(x: 8.8, y: 16.6), CGPoint(x: 6.1, y: 10.7), CGPoint(x: 11, y: 10.7)])
        arrow.closeSubpath()
        var shadow = c
        shadow.addFilter(.shadow(color: .black.opacity(0.3), radius: 1.5, x: 0, y: 1))
        shadow.fill(arrow, with: .color(.black))
        c.stroke(arrow, with: .color(.white), lineWidth: 1.1)
    }

    func drawBadges(_ base: inout GraphicsContext, _ T: Double) {
        // "Tearoff" at work while it reads the page
        let reading = prog(T, 3.7, 3.95) * (1 - prog(T, 6.1, 6.4))
        if reading > 0 {
            var c = base
            c.opacity = reading
            let chip = c.resolve(Text("Tearoff").font(.system(size: 8, weight: .bold)).foregroundColor(.white))
            let size = chip.measure(in: CGSize(width: 200, height: 40))
            let r = CGRect(x: Self.window.maxX - size.width - 34, y: Self.window.minY + Self.titleH + 8, width: size.width + 24, height: size.height + 6)
            c.fill(Path(roundedRect: r, cornerRadius: r.height / 2), with: .color(Color.accentColor))
            var icon = c.resolve(Image(systemName: "scissors"))
            icon.shading = .color(.white)
            c.draw(icon, in: CGRect(x: r.minX + 6, y: r.midY - 4, width: 8, height: 8))
            c.draw(chip, at: CGPoint(x: r.minX + 17, y: r.midY), anchor: .leading)
        }
        // done: three labels, nothing else
        let done = prog(T, 10.9, 11.15)
        if done > 0 {
            var c = base
            c.opacity = done
            let center = CGPoint(x: Self.slotX, y: 208)
            c.scale(0.8 + 0.2 * backOut((T - 10.9) / 0.35), about: center)
            let text = c.resolve(Text("3 labels, nothing else").font(.system(size: 8.5, weight: .bold)).foregroundColor(.white))
            let size = text.measure(in: CGSize(width: 300, height: 40))
            let r = CGRect(x: center.x - (size.width + 26) / 2, y: center.y - (size.height + 7) / 2, width: size.width + 26, height: size.height + 7)
            c.fill(Path(roundedRect: r, cornerRadius: r.height / 2), with: .color(Color(red: 0.16, green: 0.68, blue: 0.33)))
            var check = c.resolve(Image(systemName: "checkmark"))
            check.shading = .color(.white)
            c.draw(check, in: CGRect(x: r.minX + 8, y: r.midY - 4, width: 8, height: 8))
            c.draw(text, at: CGPoint(x: r.minX + 19, y: r.midY), anchor: .leading)
        }
    }

    // MARK: Symbols

    static let barsA = bars(seed: 7, count: 41)
    static let barsB = bars(seed: 19, count: 57)
    static let barsC = bars(seed: 31, count: 49)

    /// Bar and space widths for a made-up barcode.
    static func bars(seed: UInt32, count: Int) -> [CGFloat] {
        var x = seed &* 2_654_435_761
        var out: [CGFloat] = []
        for _ in 0..<count {
            x = x &* 1_664_525 &+ 1_013_904_223
            out.append(CGFloat(1 + (x >> 24) % 3))
        }
        return out
    }

    func drawBars(_ c: inout GraphicsContext, _ r: CGRect, _ widths: [CGFloat], vertical: Bool) {
        let total = widths.reduce(0, +)
        var pos: CGFloat = 0
        var path = Path()
        for (i, w) in widths.enumerated() {
            if i % 2 == 0 {
                if vertical {
                    path.addRect(CGRect(x: r.minX + r.width * pos / total, y: r.minY, width: r.width * w / total, height: r.height))
                } else {
                    path.addRect(CGRect(x: r.minX, y: r.minY + r.height * pos / total, width: r.width, height: r.height * w / total))
                }
            }
            pos += w
        }
        c.fill(path, with: .color(Color(white: 0.08)))
    }

    /// A made-up 2D code (MaxiCode-ish dots on a shipping label).
    func drawCode(_ c: inout GraphicsContext, _ r: CGRect, dots: Int) {
        let n = CGFloat(dots)
        var path = Path()
        var x: UInt32 = 12345
        for row in 0..<dots {
            for col in 0..<dots {
                x = x &* 1_103_515_245 &+ 12_345
                if (x >> 16) & 1 == 1 {
                    path.addRect(CGRect(x: r.minX + CGFloat(col) * r.width / n, y: r.minY + CGFloat(row) * r.height / n,
                                        width: r.width / n * 0.85, height: r.height / n * 0.85))
                }
            }
        }
        c.fill(path, with: .color(Color(white: 0.1)))
    }

    static let qrModules: [[Bool]] = [
        "#######.#..##.#######", "#.....#.##..#.#.....#", "#.###.#..#.#..#.###.#", "#.###.#.##..#.#.###.#",
        "#.###.#...##..#.###.#", "#.....#..#.##.#.....#", "#######.#.#.#.#######", "........#####........",
        "#.##.###.#.##.#..#.##", "..#....##..####...###", ".#.#######.#......###", "#.####.#...#..###.###",
        "####..##.##.#..#.#...", "........#.##..#..####", "#######.#####..#.##.#", "#.....#.#......##.###",
        "#.###.#..#..#####...#", "#.###.#.##.#..#.#..#.", "#.###.#.##..#.##.##..", "#.....#..##..#.##.#..",
        "#######.##...#.#...#.",
    ].map { $0.map { $0 == "#" } }

    func drawQR(_ c: inout GraphicsContext, _ r: CGRect) {
        let n = CGFloat(Self.qrModules.count)
        let m = r.width / n
        var path = Path()
        for (y, row) in Self.qrModules.enumerated() {
            for (x, on) in row.enumerated() where on {
                path.addRect(CGRect(x: r.minX + CGFloat(x) * m, y: r.minY + CGFloat(y) * m, width: m + 0.05, height: m + 0.05))
            }
        }
        c.fill(path, with: .color(.black))
    }
}

struct Palette {
    var backdrop: [Color]
    var chrome: Color
    var chromeText: Color
    var field: Color
    var sidebar: Color
    var previewCanvas: Color
    var sheet: Color
    var key: Color
    var keyText: Color

    static let light = Palette(
        backdrop: [Color(red: 0.93, green: 0.95, blue: 0.985), Color(red: 0.86, green: 0.895, blue: 0.95)],
        chrome: Color(white: 0.95), chromeText: Color(white: 0.22), field: Color(white: 0.87), sidebar: Color(white: 0.91),
        previewCanvas: Color(white: 0.82), sheet: Color(white: 0.975), key: Color.white, keyText: Color(white: 0.2))
    static let dark = Palette(
        backdrop: [Color(red: 0.17, green: 0.18, blue: 0.21), Color(red: 0.11, green: 0.12, blue: 0.145)],
        chrome: Color(white: 0.23), chromeText: Color(white: 0.88), field: Color(white: 0.34), sidebar: Color(white: 0.19),
        previewCanvas: Color(white: 0.3), sheet: Color(white: 0.2), key: Color(white: 0.3), keyText: Color.white)
}

/// Renders the animation to PNG frames (CI turns them into the README's GIF).
enum PluckFrames {
    @MainActor
    static func render(to dir: URL, seconds: Double = PluckScene.period * 2, fps: Double = 12) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let count = Int(seconds * fps)
        for i in 0..<count {
            let view = PluckScene(t: Double(i) / fps)
                .padding(14)
                .frame(width: 668, height: 376)
                .background(Color.white)
                .environment(\.colorScheme, .light)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            guard let image = renderer.cgImage else { continue }
            let rep = NSBitmapImageRep(cgImage: image)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appendingPathComponent(String(format: "frame-%04d.png", i)))
            }
        }
        // one dark-mode frame, to check that palette
        let dark = PluckScene(t: 5.9)
            .padding(14)
            .frame(width: 668, height: 376)
            .background(Color(white: 0.13))
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: dark)
        renderer.scale = 1
        if let image = renderer.cgImage, let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
            try? png.write(to: dir.appendingPathComponent("dark-sample.png"))
        }
    }
}

// MARK: - Easing

private func clamp01(_ x: Double) -> Double { min(1, max(0, x)) }
private func smooth(_ x: Double) -> Double { let c = clamp01(x); return c * c * (3 - 2 * c) }
private func prog(_ t: Double, _ a: Double, _ b: Double) -> Double { smooth((t - a) / (b - a)) }
private func backOut(_ x: Double) -> Double {
    let c = clamp01(x), s = 1.70158, p = c - 1
    return 1 + (s + 1) * p * p * p + s * p * p
}
private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat { a + (b - a) * CGFloat(t) }
private func bezier(_ a: CGPoint, _ c: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint {
    let u = CGFloat(1 - t), v = CGFloat(t)
    return CGPoint(x: u * u * a.x + 2 * u * v * c.x + v * v * b.x, y: u * u * a.y + 2 * u * v * c.y + v * v * b.y)
}

extension GraphicsContext {
    /// Scales everything drawn afterwards about a point.
    mutating func scale(_ k: Double, about p: CGPoint) {
        translateBy(x: p.x, y: p.y)
        scaleBy(x: CGFloat(k), y: CGFloat(k))
        translateBy(x: -p.x, y: -p.y)
    }
}
