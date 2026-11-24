import Foundation
import TearoffCore
import TearoffKit

// CUPS filter:  tearoff-filter job-id user title copies options [file]
// Reads the PDF (or image) an app printed, finds the label(s) on it and writes ZPL to stdout.
// Runs inside cupsd's sandbox: no network, no user files — just stdin/stdout and the PPD.

func emit(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

/// PPD defaults first, then whatever the job carried ("key=value", "key", "nokey").
func resolveOptions(_ jobOptions: String) -> [String: String] {
    var opts = [String: String]()
    if let ppdPath = ProcessInfo.processInfo.environment["PPD"],
       let text = try? String(contentsOfFile: ppdPath, encoding: .isoLatin1) {
        for line in text.split(separator: "\n") where line.hasPrefix("*Default") {
            let body = line.dropFirst("*Default".count)
            if let colon = body.firstIndex(of: ":") {
                opts[String(body[..<colon])] = body[body.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
    }
    for tok in jobOptions.split(separator: " ") {
        if let eq = tok.firstIndex(of: "=") {
            opts[String(tok[..<eq])] = String(tok[tok.index(after: eq)...])
        } else if tok.hasPrefix("no") {
            opts[String(tok.dropFirst(2))] = "False"
        } else {
            opts[String(tok)] = "True"
        }
    }
    return opts
}

func run() -> Int32 {
    let args = CommandLine.arguments
    guard args.count == 6 || args.count == 7 else {
        emit("ERROR: usage: tearoff-filter job-id user title copies options [file]")
        return 1
    }
    let copies = max(1, Int(args[4]) ?? 1)
    let opts = resolveOptions(args[5])

    let dpi = Int((opts["Resolution"] ?? "203").prefix(while: { $0.isNumber })) ?? 203
    let stock = opts["TearoffLabel"].flatMap { Driver.size(fromStock: $0) } ?? LabelSize.fourBySix
    let threshold: Int
    switch opts["TearoffWeight"] {
    case "Light": threshold = 102
    case "Bold": threshold = 153
    default: threshold = 128
    }
    let gridFit = (opts["TearoffGridFit"] ?? "True").lowercased() != "false"
    let wholePages = opts["TearoffMode"] == "Page"
    let darkness = opts["Darkness"].flatMap { Int($0) }
    let speed = opts["PrintSpeed"].flatMap { Int($0) }

    // Input: a file argument, or the job on stdin.
    let input: URL
    var spooled: URL? = nil
    if args.count == 7 {
        input = URL(fileURLWithPath: args[6])
    } else {
        let dir = ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()
        let tmp = URL(fileURLWithPath: dir).appendingPathComponent("tearoff-\(getpid()).job")
        do {
            try FileHandle.standardInput.readDataToEndOfFile().write(to: tmp)
        } catch {
            emit("ERROR: Couldn't spool the job: \(error.localizedDescription)")
            return 1
        }
        input = tmp
        spooled = tmp
    }

    let trace = PerfTrace()
    let inputBytes = (try? FileManager.default.attributesOfItem(atPath: input.path))?[.size] as? Int ?? 0
    let render = RenderOptions(dpi: dpi, size: stock, gridFit: gridFit, threshold: threshold)
    let labels: [ExtractedLabel]
    do {
        labels = try LabelExtractor.extract(url: input, options: ExtractOptions(render: render, fallbackToPages: true, wholePages: wholePages),
                                            trace: trace)
    } catch {
        emit("ERROR: \(error.localizedDescription)")
        if let s = spooled { try? FileManager.default.removeItem(at: s) }
        return 1
    }
    if let s = spooled { try? FileManager.default.removeItem(at: s) }
    guard !labels.isEmpty else {
        emit("ERROR: Nothing to print: the document is blank.")
        return 1
    }

    var zplBytes = 0
    for (i, l) in labels.enumerated() {
        // darkness is a printer setting (~SD): send it once, ahead of the first label
        let settings = PrintSettings(darkness: i == 0 ? darkness : nil, speed: speed)
        let zpl = trace.measure("zpl.encode") { Data(ZPL.label(l.image, copies: copies, settings: settings).utf8) }
        zplBytes += zpl.count
        trace.measure("zpl.write") { FileHandle.standardOutput.write(zpl) }
        emit("PAGE: \(i + 1) \(copies)")
        let codes = l.barcodes.isEmpty ? "" : " [\(l.barcodes.joined(separator: ", "))]"
        emit("DEBUG: Tearoff label \(i + 1): page \(l.page), \(l.detail), turned \(l.quarterTurns * 90) deg, \(l.gridFitted) barcode(s) grid-fitted\(codes)")
    }
    let ms = Int(trace.elapsedMs.rounded())
    emit("INFO: Tearoff: \(labels.count) label\(labels.count == 1 ? "" : "s") at \(dpi) dpi (\(ms) ms)")
    emit("DEBUG: Tearoff timing: \(trace.summary)")
    let rec = PerfLog.record(op: "filter", source: "filter", trace: trace, extra: [
        "bytes_in": inputBytes, "bytes_out": zplBytes, "labels": labels.count, "copies": copies, "dpi": dpi,
        "kinds": labels.map { $0.kind }, "job": args[1],
    ])
    if let path = PerfLog.appendFromFilter(rec) {
        emit("DEBUG: Tearoff perf log: \(path)")
    } else {
        emit("DEBUG: Tearoff perf log: no writable location (\(String(cString: strerror(errno))))")
    }
    return 0
}

exit(run())
