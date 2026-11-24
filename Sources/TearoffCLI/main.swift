import Foundation
import TearoffCore
import TearoffKit

let version = "1.0.0"

let usage = """
tearoff \(version) — crisp Zebra labels from PDFs

  tearoff print FILE…        find the label(s) and print them
          [--printer HOST[:PORT] | --queue NAME] [--copies N]
  tearoff extract FILE…      save labels as PNGs [--out DIR] [--json]
  tearoff zpl FILE           write ZPL to stdout [--out FILE] [--copies N]
  tearoff status             printer status [--printer HOST]
  tearoff discover           find Zebra printers on this network
  tearoff test-label         print a printer-rendered test label
  tearoff calibrate          calibrate the media sensor
  tearoff zpl2png FILE OUT   render ^GFA graphics in a ZPL file to OUT-N.png
  tearoff ppd                print the CUPS PPD [--dpi N] [--size WxH]

Render options: --dpi 203|300|600  --size 4x6  --no-gridfit  --whole-pages  --weight light|normal|bold
Defaults come from the Tearoff app's settings.
"""

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data(("tearoff: " + msg + "\n").utf8))
    exit(1)
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { print(usage); exit(0) }
args.removeFirst()

var settings = TearoffSettings.load()
var files: [String] = []
var outPath: String?
var json = false
var copies = 1
var wholePages = false
var target = settings.printer

var i = 0
func value() -> String {
    i += 1
    guard i < args.count else { fail("missing value for \(args[i - 1])") }
    return args[i]
}
while i < args.count {
    let a = args[i]
    switch a {
    case "--out", "-o": outPath = value()
    case "--json": json = true
    case "--copies": copies = max(1, Int(value()) ?? 1)
    case "--dpi": settings.dpi = Int(value()) ?? 203
    case "--size":
        guard let s = LabelSize(string: value()) else { fail("bad --size (use e.g. 4x6)") }
        settings.labelWidth = s.width; settings.labelHeight = s.height
    case "--no-gridfit": settings.gridFit = false
    case "--whole-pages": wholePages = true
    case "--weight":
        switch value().lowercased() {
        case "light": settings.threshold = 102
        case "bold": settings.threshold = 153
        default: settings.threshold = 128
        }
    case "--printer": target = PrinterTarget(string: value())
    case "--queue": target = .queue(name: value())
    case "-h", "--help": print(usage); exit(0)
    default: files.append(a)
    }
    i += 1
}

let extractOptions = ExtractOptions(render: settings.renderOptions, fallbackToPages: true, wholePages: wholePages)

func labels(_ path: String) -> [ExtractedLabel] {
    do {
        return try LabelExtractor.extract(url: URL(fileURLWithPath: path), options: extractOptions)
    } catch {
        fail(error.localizedDescription)
    }
}

func requireHost() -> (String, Int) {
    guard case .network(let h, let p)? = target else { fail("needs a network printer: --printer HOST") }
    return (h, p)
}

switch command {
case "extract":
    guard !files.isEmpty else { fail("extract needs a file") }
    let out = URL(fileURLWithPath: outPath ?? ".")
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    var report: [[String: Any]] = []
    for f in files {
        let started = Date()
        let found = labels(f)
        let base = URL(fileURLWithPath: f).deletingPathExtension().lastPathComponent
        for (n, l) in found.enumerated() {
            let png = out.appendingPathComponent("\(base)-\(n + 1).png")
            try? l.image.pngData(dpi: l.dpi)?.write(to: png)
            report.append([
                "file": URL(fileURLWithPath: f).lastPathComponent, "index": n + 1, "page": l.page, "kind": l.kind,
                "detail": l.detail, "quarterTurns": l.quarterTurns, "gridFitted": l.gridFitted,
                "barcodes": l.barcodes, "png": png.path, "width": l.image.width, "height": l.image.height,
                "rect": [l.rect.x0, l.rect.y0, l.rect.x1, l.rect.y1],
                "ms": Int(Date().timeIntervalSince(started) * 1000),
            ])
            if !json {
                let codes = l.barcodes.isEmpty ? "" : "  " + l.barcodes.joined(separator: ", ")
                print("\(png.lastPathComponent): page \(l.page), \(l.detail), turned \(l.quarterTurns * 90)°, \(l.gridFitted) grid-fit\(codes)")
            }
        }
        if found.isEmpty && !json { print("\(f): no label found") }
    }
    if json, let d = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        print(String(decoding: d, as: UTF8.self))
    }

case "zpl":
    guard let f = files.first else { fail("zpl needs a file") }
    let job = ZPL.job(labels(f).map { $0.image }, copies: copies, settings: settings.printSettings)
    if let o = outPath { try? Data(job.utf8).write(to: URL(fileURLWithPath: o)) } else { print(job, terminator: "") }

case "print":
    guard !files.isEmpty else { fail("print needs a file") }
    guard let t = target else { fail("no printer set: use --printer HOST or set one up in the Tearoff app") }
    for f in files {
        let found = labels(f)
        guard !found.isEmpty else { print("\(f): no label found"); continue }
        do {
            try ZebraPrinter.send(ZPL.job(found.map { $0.image }, copies: copies, settings: settings.printSettings), to: t,
                                  title: URL(fileURLWithPath: f).lastPathComponent)
            print("\(f): sent \(found.count) label\(found.count == 1 ? "" : "s") to \(t)")
        } catch {
            fail(error.localizedDescription)
        }
    }

case "status":
    let (h, p) = requireHost()
    do {
        if let id = try? ZebraPrinter.identity(host: h, port: p) {
            print("\(id.model)  firmware \(id.firmware)  \(id.dpi) dpi  \(id.memory)")
        }
        let s = try ZebraPrinter.status(host: h, port: p)
        print("Status: \(s.summary)\(s.formatsInBuffer > 0 ? "  (\(s.formatsInBuffer) queued)" : "")")
    } catch {
        fail(error.localizedDescription)
    }

case "discover":
    let found = Discovery.scan()
    if found.isEmpty { print("No printers answered on port 9100.") }
    for p in found {
        print("\(p.isZebra ? "✓" : "?") \(p.target)  \(p.name)  \(p.detail)\(p.dpi.map { "  \($0) dpi" } ?? "")")
    }
    for q in Discovery.queues() { print("  queue:\(q.name)  \(q.uri)") }

case "test-label":
    guard let t = target else { fail("no printer set") }
    let (w, h) = settings.labelSize.dots(dpi: settings.dpi)
    do { try ZebraPrinter.send(ZPL.testLabel(widthDots: w, heightDots: h, dpi: settings.dpi), to: t) } catch { fail(error.localizedDescription) }
    print("Test label sent to \(t)")

case "calibrate":
    guard let t = target else { fail("no printer set") }
    do { try ZebraPrinter.calibrate(t) } catch { fail(error.localizedDescription) }
    print("Calibrating \(t)…")

case "zpl2png":
    guard files.count == 2, let text = try? String(contentsOfFile: files[0], encoding: .utf8) else { fail("usage: zpl2png FILE.zpl OUTPREFIX") }
    let rasters = ZPL.rasters(in: text)
    for (n, r) in rasters.enumerated() {
        let url = URL(fileURLWithPath: "\(files[1])-\(n + 1).png")
        try? r.pngData()?.write(to: url)
        print(url.path)
    }
    if rasters.isEmpty { fail("no ^GFA graphics found") }

case "ppd":
    print(Driver.ppd(dpi: settings.dpi, label: settings.labelSize), terminator: "")

case "version", "--version":
    print(version)

default:
    print(usage)
    exit(command == "help" ? 0 : 1)
}
