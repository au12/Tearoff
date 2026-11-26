import Foundation
import TearoffCore

/// The CUPS side: a PPD whose filter is `tearoff-filter`, so *any* app's Print dialog can send
/// labels to the Zebra. Installed into /Library/Printers/Tearoff (needs an admin password once).
public enum Driver {
    public static let root = "/Library/Printers/Tearoff"
    public static let filterPath = root + "/Filters/tearoff-filter"
    public static let ppdPath = root + "/Tearoff.ppd"

    public static var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: filterPath) }

    /// True when the installed filter differs from the one inside this app (i.e. needs updating).
    public static func isOutdated(comparedTo bundled: URL) -> Bool {
        guard isInstalled, let a = try? Data(contentsOf: URL(fileURLWithPath: filterPath)),
              let b = try? Data(contentsOf: bundled) else { return false }
        return a != b
    }

    public struct Stock { public var name: String; public var label: String; public var w: Int; public var h: Int }

    /// Label stocks offered (points).
    public static let stocks: [Stock] = [
        Stock(name: "w288h432", label: "4 x 6 in", w: 288, h: 432),
        Stock(name: "w288h468", label: "4 x 6.5 in", w: 288, h: 468),
        Stock(name: "w288h576", label: "4 x 8 in", w: 288, h: 576),
        Stock(name: "w288h288", label: "4 x 4 in", w: 288, h: 288),
        Stock(name: "w288h216", label: "4 x 3 in", w: 288, h: 216),
        Stock(name: "w288h144", label: "4 x 2 in", w: 288, h: 144),
        Stock(name: "w216h144", label: "3 x 2 in", w: 216, h: 144),
        Stock(name: "w162h90", label: "2.25 x 1.25 in", w: 162, h: 90),
        Stock(name: "w144h72", label: "2 x 1 in", w: 144, h: 72),
    ]

    public static func stockName(for size: LabelSize) -> String {
        "w\(Int((size.width * 72).rounded()))h\(Int((size.height * 72).rounded()))"
    }

    /// Parses "w288h432" back into inches.
    public static func size(fromStock name: String) -> LabelSize? {
        guard name.hasPrefix("w"), let h = name.firstIndex(of: "h"),
              let w = Double(name[name.index(after: name.startIndex)..<h]),
              let hh = Double(name[name.index(after: h)...]), w > 0, hh > 0 else { return nil }
        return LabelSize(width: w / 72, height: hh / 72)
    }

    /// The PPD. Page sizes only steer how apps lay out the page; the filter always finds the
    /// label and fits it to the *Label Stock* option.
    public static func ppd(dpi: Int = 203, label: LabelSize = .fourBySix) -> String {
        let defStock = stockName(for: label)
        var stocks = self.stocks
        if !stocks.contains(where: { $0.name == defStock }) {
            stocks.insert(Stock(name: defStock, label: "\(label) in", w: Int(label.width * 72), h: Int(label.height * 72)), at: 0)
        }
        let pages = stocks.map { ($0.name, $0.label, $0.w, $0.h) } + [("Letter", "US Letter (label is cut out)", 612, 792), ("A4", "A4 (label is cut out)", 595, 842)]
        var p = """
        *PPD-Adobe: "4.3"
        *% Tearoff: crisp Zebra ZPL labels from any app. https://github.com/au12/Tearoff
        *FormatVersion: "4.3"
        *FileVersion: "1.0"
        *LanguageVersion: English
        *LanguageEncoding: ISOLatin1
        *PCFileName: "TEAROFF.PPD"
        *Manufacturer: "Zebra"
        *Product: "(Tearoff ZPL)"
        *ModelName: "Zebra ZPL Label Printer Tearoff"
        *ShortNickName: "Zebra ZPL (Tearoff)"
        *NickName: "Zebra ZPL Label Printer (Tearoff)"
        *PSVersion: "(3010.000) 0"
        *LanguageLevel: "3"
        *ColorDevice: False
        *DefaultColorSpace: Gray
        *FileSystem: False
        *Throughput: "4"
        *LandscapeOrientation: Plus90
        *TTRasterizer: Type42
        *cupsVersion: 2.2
        *cupsModelNumber: 0
        *cupsManualCopies: False
        *cupsFilter: "application/pdf 0 \(filterPath)"
        *cupsFilter: "image/png 0 \(filterPath)"
        *cupsFilter: "image/jpeg 0 \(filterPath)"

        *OpenUI *PageSize/Media Size: PickOne
        *OrderDependency: 10 AnySetup *PageSize
        *DefaultPageSize: \(defStock)

        """
        for (n, l, w, h) in pages { p += "*PageSize \(n)/\(l): \"<</PageSize[\(w) \(h)]/ImagingBBox null>>setpagedevice\"\n" }
        p += "*CloseUI: *PageSize\n\n*OpenUI *PageRegion: PickOne\n*OrderDependency: 10 AnySetup *PageRegion\n*DefaultPageRegion: \(defStock)\n"
        for (n, l, w, h) in pages { p += "*PageRegion \(n)/\(l): \"<</PageSize[\(w) \(h)]/ImagingBBox null>>setpagedevice\"\n" }
        p += "*CloseUI: *PageRegion\n\n*DefaultImageableArea: \(defStock)\n"
        for (n, l, w, h) in pages { p += "*ImageableArea \(n)/\(l): \"0 0 \(w) \(h)\"\n" }
        p += "\n*DefaultPaperDimension: \(defStock)\n"
        for (n, l, w, h) in pages { p += "*PaperDimension \(n)/\(l): \"\(w) \(h)\"\n" }

        p += "\n*OpenUI *Resolution/Resolution: PickOne\n*OrderDependency: 10 AnySetup *Resolution\n*DefaultResolution: \(dpi)dpi\n"
        for r in [203, 300, 600] { p += "*Resolution \(r)dpi/\(r) dpi: \"<</HWResolution[\(r) \(r)]>>setpagedevice\"\n" }
        p += "*CloseUI: *Resolution\n"

        p += "\n*OpenUI *TearoffLabel/Label Stock: PickOne\n*OrderDependency: 20 AnySetup *TearoffLabel\n*DefaultTearoffLabel: \(defStock)\n"
        for s in stocks { p += "*TearoffLabel \(s.name)/\(s.label): \"\"\n" }
        p += "*CloseUI: *TearoffLabel\n"

        p += """

        *OpenUI *TearoffMode/Label Handling: PickOne
        *OrderDependency: 20 AnySetup *TearoffMode
        *DefaultTearoffMode: Auto
        *TearoffMode Auto/Find labels automatically: ""
        *TearoffMode Page/Print whole pages: ""
        *CloseUI: *TearoffMode

        *OpenUI *TearoffShiftDown/Shift Label Down: PickOne
        *OrderDependency: 20 AnySetup *TearoffShiftDown
        *DefaultTearoffShiftDown: 0

        """
        for d in stride(from: -120, through: 120, by: 4) {
            p += "*TearoffShiftDown \(shiftChoice(d))/\(d == 0 ? "None" : d > 0 ? "Down \(d) dots" : "Up \(-d) dots"): \"\"\n"
        }
        p += "*CloseUI: *TearoffShiftDown\n"
        p += """

        *OpenUI *TearoffShiftRight/Shift Label Right: PickOne
        *OrderDependency: 20 AnySetup *TearoffShiftRight
        *DefaultTearoffShiftRight: 0

        """
        for d in stride(from: -200, through: 200, by: 4) {
            p += "*TearoffShiftRight \(shiftChoice(d))/\(d == 0 ? "None" : d > 0 ? "Right \(d) dots" : "Left \(-d) dots"): \"\"\n"
        }
        p += "*CloseUI: *TearoffShiftRight\n"
        p += """

        *OpenUI *Darkness/Darkness: PickOne
        *OrderDependency: 20 AnySetup *Darkness
        *DefaultDarkness: Printer
        *Darkness Printer/Printer setting: ""

        """
        for d in stride(from: 0, through: 30, by: 2) { p += "*Darkness \(d)/\(d): \"\"\n" }
        p += "*CloseUI: *Darkness\n"
        p += """

        *OpenUI *PrintSpeed/Print Speed: PickOne
        *OrderDependency: 20 AnySetup *PrintSpeed
        *DefaultPrintSpeed: Printer
        *PrintSpeed Printer/Printer setting: ""
        *PrintSpeed 2/2 in/s: ""
        *PrintSpeed 3/3 in/s: ""
        *PrintSpeed 4/4 in/s: ""
        *PrintSpeed 5/5 in/s: ""
        *PrintSpeed 6/6 in/s: ""
        *CloseUI: *PrintSpeed

        *OpenUI *TearoffWeight/Line Weight: PickOne
        *OrderDependency: 20 AnySetup *TearoffWeight
        *DefaultTearoffWeight: Normal
        *TearoffWeight Light/Lighter: ""
        *TearoffWeight Normal/Normal: ""
        *TearoffWeight Bold/Bolder: ""
        *CloseUI: *TearoffWeight

        *OpenUI *TearoffGridFit/Snap Barcodes to Dot Grid: Boolean
        *OrderDependency: 20 AnySetup *TearoffGridFit
        *DefaultTearoffGridFit: True
        *TearoffGridFit True/On: ""
        *TearoffGridFit False/Off: ""
        *CloseUI: *TearoffGridFit

        *OpenUI *TearoffExtras/Also Print Other Barcodes and QR Codes: Boolean
        *OrderDependency: 20 AnySetup *TearoffExtras
        *DefaultTearoffExtras: True
        *TearoffExtras True/On: ""
        *TearoffExtras False/Off: ""
        *CloseUI: *TearoffExtras

        """
        return p
    }

    public struct InstallRequest {
        public var queueName: String
        public var displayName: String
        public var deviceURI: String
        public var dpi: Int
        public var label: LabelSize
        public var darkness: Int?
        public var speed: Int?
        public var topOffset = 0
        public var leftOffset = 0
        /// Print barcodes/QR codes found outside the label too (the queue's default).
        public var extraCodes: Bool
        /// Existing queues to switch over to this driver (names and URIs are kept).
        public var convertQueues: [String]
        public init(queueName: String, displayName: String, deviceURI: String, dpi: Int, label: LabelSize,
                    darkness: Int? = nil, speed: Int? = nil, extraCodes: Bool = true, convertQueues: [String] = []) {
            self.queueName = queueName; self.displayName = displayName; self.deviceURI = deviceURI; self.dpi = dpi
            self.label = label; self.darkness = darkness; self.speed = speed; self.extraCodes = extraCodes
            self.convertQueues = convertQueues
        }
    }

    /// A CUPS-safe queue name ("Zebra GX420d" -> "Zebra_GX420d").
    public static func queueName(for name: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-.")
        let s = String(name.map { allowed.contains($0) ? $0 : "_" })
        let trimmed = s.split(separator: "_", omittingEmptySubsequences: true).joined(separator: "_")
        return trimmed.isEmpty ? "Zebra_Tearoff" : String(trimmed.prefix(60))
    }

    static func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// PPD choice for a shift in dots: "0", "8", "n8" (PPD keywords can't safely start with "-").
    public static func shiftChoice(_ dots: Int) -> String { dots < 0 ? "n\(-dots)" : "\(dots)" }
    public static func shift(fromChoice c: String?) -> Int {
        guard let c = c else { return 0 }
        if c.hasPrefix("n") { return -(Int(c.dropFirst()) ?? 0) }
        return Int(c) ?? 0
    }

    static func optionArgs(dpi: Int, label: LabelSize, darkness: Int?, speed: Int?, extras: Bool = true,
                           topOffset: Int = 0, leftOffset: Int = 0) -> String {
        let stock = stockName(for: label)
        return [
            "-o Resolution=\(dpi)dpi", "-o TearoffLabel=\(stock)", "-o PageSize=\(stock)",
            "-o TearoffExtras=\(extras ? "True" : "False")",
            "-o TearoffShiftDown=\(shiftChoice(max(-120, min(120, topOffset / 4 * 4))))",
            "-o TearoffShiftRight=\(shiftChoice(max(-200, min(200, leftOffset / 4 * 4))))",
            "-o Darkness=\(darkness.map { String(min(30, max(0, $0 / 2 * 2))) } ?? "Printer")",
            "-o PrintSpeed=\(speed.map { String(min(6, max(2, $0))) } ?? "Printer")",
        ].joined(separator: " ")
    }

    /// The root shell script the installer runs.
    public static func installScript(_ r: InstallRequest, filterSource: String, ppdSource: String) -> String {
        let opts = optionArgs(dpi: r.dpi, label: r.label, darkness: r.darkness, speed: r.speed, extras: r.extraCodes,
                              topOffset: r.topOffset, leftOffset: r.leftOffset)
        var s = """
        #!/bin/bash
        set -e
        ROOT=\(q(root))
        mkdir -p "$ROOT/Filters"
        cp -f \(q(filterSource)) "$ROOT/Filters/tearoff-filter"
        cp -f \(q(ppdSource)) "$ROOT/Tearoff.ppd"
        xattr -c "$ROOT/Filters/tearoff-filter" 2>/dev/null || true
        chown -R root:wheel "$ROOT"
        chmod 755 "$ROOT" "$ROOT/Filters" "$ROOT/Filters/tearoff-filter"
        chmod 644 "$ROOT/Tearoff.ppd"

        """
        if !r.deviceURI.isEmpty {
            s += "/usr/sbin/lpadmin -p \(q(r.queueName)) -E -v \(q(r.deviceURI)) -P \"$ROOT/Tearoff.ppd\" -D \(q(r.displayName)) -L Tearoff -o printer-is-shared=false \(opts)\n"
            s += "/usr/sbin/cupsenable \(q(r.queueName)) || true\n/usr/sbin/cupsaccept \(q(r.queueName)) || true\n"
        }
        for c in r.convertQueues where c != r.queueName {
            s += "/usr/sbin/lpadmin -p \(q(c)) -P \"$ROOT/Tearoff.ppd\" \(opts)\n"
        }
        return s
    }

    /// When the driver files are already installed (the .pkg does that), adds/converts queues with
    /// plain `lpadmin`, which admin users may do without a password. Returns false if macOS refused.
    public static func addQueuesWithoutPrompt(_ r: InstallRequest) -> Bool {
        guard isInstalled, FileManager.default.fileExists(atPath: ppdPath) else { return false }
        let opts = optionArgs(dpi: r.dpi, label: r.label, darkness: r.darkness, speed: r.speed, extras: r.extraCodes,
                              topOffset: r.topOffset, leftOffset: r.leftOffset)
            .split(separator: " ").map(String.init)
        if !r.deviceURI.isEmpty {
            let res = Shell.run("/usr/sbin/lpadmin", ["-p", r.queueName, "-E", "-v", r.deviceURI, "-P", ppdPath,
                                                      "-D", r.displayName, "-L", "Tearoff", "-o", "printer-is-shared=false"] + opts)
            if res.status != 0 { return false }
        }
        for c in r.convertQueues where c != r.queueName {
            if Shell.run("/usr/sbin/lpadmin", ["-p", c, "-P", ppdPath] + opts).status != 0 { return false }
        }
        return true
    }

    /// Installs the filter + PPD and creates/updates the queue. Shows the macOS admin prompt.
    /// Must be called on the main thread.
    public static func install(_ r: InstallRequest, filterSource: URL) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tearoff-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ppdURL = dir.appendingPathComponent("Tearoff.ppd")
        try ppd(dpi: r.dpi, label: r.label).write(to: ppdURL, atomically: true, encoding: .isoLatin1)
        let script = dir.appendingPathComponent("install.sh")
        try installScript(r, filterSource: filterSource.path, ppdSource: ppdURL.path).write(to: script, atomically: true, encoding: .utf8)
        try runAsAdmin("/bin/bash " + q(script.path), prompt: "Tearoff wants to install its Zebra printer driver.")
    }

    public static func uninstall(queues: [String]) throws {
        var s = "set -e\n"
        for qn in queues { s += "/usr/sbin/lpadmin -x \(q(qn)) || true\n" }
        s += "rm -rf \(q(root))\n"
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tearoff-uninstall-\(UUID().uuidString).sh")
        try s.write(to: dir, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: dir) }
        try runAsAdmin("/bin/bash " + q(dir.path), prompt: "Tearoff wants to remove its printer driver.")
    }

    /// Queues currently using the Tearoff PPD.
    public static func tearoffQueues() -> [String] {
        Discovery.queues().map { $0.name }.filter { name in
            let ppd = "/etc/cups/ppd/\(name).ppd"
            guard let text = try? String(contentsOfFile: ppd, encoding: .isoLatin1) else { return false }
            return text.contains("Tearoff")
        }
    }

    /// Updates a queue's defaults (works without a password for admin users; falls back to a prompt).
    public static func setDefaults(queue: String, dpi: Int, label: LabelSize, darkness: Int?, speed: Int?, extras: Bool = true,
                                   topOffset: Int = 0, leftOffset: Int = 0) {
        let args = ["-p", queue] + optionArgs(dpi: dpi, label: label, darkness: darkness, speed: speed, extras: extras,
                                               topOffset: topOffset, leftOffset: leftOffset)
            .split(separator: " ").map(String.init)
        let r = Shell.run("/usr/sbin/lpadmin", args)
        if r.status != 0 {
            try? runAsAdmin("/usr/sbin/lpadmin " + args.map(q).joined(separator: " "), prompt: "Tearoff wants to update the printer’s defaults.")
        }
    }

    static func runAsAdmin(_ command: String, prompt: String) throws {
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        let source = "do shell script \"\(esc(command))\" with prompt \"\(esc(prompt))\" with administrator privileges"
        var err: NSDictionary?
        guard let script = NSAppleScript(source: source) else { throw TearoffError.driver("Couldn’t prepare the installer.") }
        script.executeAndReturnError(&err)
        if let e = err {
            let code = e[NSAppleScript.errorNumber] as? Int ?? 0
            if code == -128 { throw TearoffError.driver("Installation was cancelled.") }
            throw TearoffError.driver((e[NSAppleScript.errorMessage] as? String) ?? "The installer failed.")
        }
    }
}
