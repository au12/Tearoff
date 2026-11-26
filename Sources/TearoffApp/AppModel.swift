import AppKit
import Combine
import Foundation
import ServiceManagement
import SwiftUI
import TearoffCore
import TearoffKit
import UniformTypeIdentifiers
import UserNotifications

/// One opened PDF/image and the labels found in it.
struct LabelDocument: Identifiable {
    let id = UUID()
    let url: URL
    var name: String
    var labels: [ExtractedLabel]
    var selected: Set<UUID>
    let added = Date()
    var printedAt: Date?
    var error: String?
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var isError = false
}

enum PrinterHealth: Equatable {
    case unknown, checking, ready(String), problem(String), offline(String), queue(String)
    /// Connected, with one setup step left (a USB printer that isn't on the Mac's printer list yet).
    case needsSetup(String)

    var text: String {
        switch self {
        case .unknown: return "No printer"
        case .checking: return "Checking…"
        case .ready(let s), .problem(let s), .offline(let s), .queue(let s), .needsSetup(let s): return s
        }
    }
}

final class AppModel: ObservableObject {
    static let shared = AppModel()

    /// Off in --demo mode (screenshots), so nothing touches the real settings.
    var persist = true
    var demo = false
    @Published var requestedPane: Pane?

    @Published var settings = TearoffSettings.load() {
        didSet {
            guard settings != oldValue else { return }
            if persist { settings.save() }
            if settings.printer != oldValue.printer {
                identity = nil
                refreshStatus()
            }
            if settings.watchDownloads != oldValue.watchDownloads { updateWatcher() }
        }
    }
    @Published var documents: [LabelDocument] = []
    @Published var working = 0
    @Published var toast: Toast?
    @Published var health: PrinterHealth = .unknown
    @Published var identity: ZebraIdentity?
    @Published var discovered: [DiscoveredPrinter] = []
    @Published var queues: [QueueInfo] = []
    /// Looking for printers on the network / plugged in by USB.
    @Published var scanning = false
    @Published var scanningUSB = false
    var searching: Bool { scanning || scanningUSB }
    @Published var driverInstalled = Driver.isInstalled
    @Published var driverOutdated = false
    @Published var tearoffQueues: [String] = []
    @Published var alert: String?
    @Published var benchRunning = false
    @Published var benchStatus = ""
    @Published var perfSummary = ""

    let work = DispatchQueue(label: "tearoff.work", qos: .userInitiated)
    let net = DispatchQueue(label: "tearoff.net", qos: .utility)
    lazy var watcher = DownloadsWatcher { [weak self] url in self?.downloaded(url) }
    var statusTimer: Timer?

    private init() {}

    let hangMonitor = HangMonitor()
    var mergeTimer: Timer?

    func start() {
        refreshStatus()
        refreshDriver()
        updateWatcher()
        hangMonitor.start()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.refreshStatus(quiet: true)
        }
        PerfLog.mergeFilterLogs()
        mergeTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in PerfLog.mergeFilterLogs() }
        // the installer pre-creates these; make sure the sandboxed driver can log timings here
        for dir in ["/Users/Shared/Tearoff"] where !FileManager.default.fileExists(atPath: dir) {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o1777])
        }
    }

    // MARK: Opening

    var renderOptions: RenderOptions { settings.renderOptions }

    /// Opens files; prints right away when asked to (or when Auto-print is on).
    func open(_ urls: [URL], autoPrint: Bool? = nil, source: String = "app") {
        for url in urls {
            let opts = ExtractOptions(render: renderOptions, fallbackToPages: true, extraCodes: settings.extraCodes)
            let shouldPrint = autoPrint ?? settings.autoPrintOnOpen
            let dpi = settings.dpi
            working += 1
            work.async { [weak self] in
                var doc = LabelDocument(url: url, name: url.lastPathComponent, labels: [], selected: [])
                let trace = PerfTrace()
                defer {
                    PerfLog.append(PerfLog.record(op: "extract", source: source, trace: trace, extra: [
                        "file": url.lastPathComponent, "bytes": (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0,
                        "labels": doc.labels.count, "kinds": doc.labels.map { $0.kind }, "dpi": dpi, "error": doc.error ?? "",
                    ]))
                }
                do {
                    doc.labels = try LabelExtractor.extract(url: url, options: opts, trace: trace)
                    doc.selected = Set(doc.labels.filter { $0.kind != "fallback" }.map { $0.id })
                    if doc.selected.isEmpty { doc.selected = Set(doc.labels.map { $0.id }) }
                } catch {
                    doc.error = error.localizedDescription
                }
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.working -= 1
                    self.documents.removeAll { $0.url == url }
                    self.documents.insert(doc, at: 0)
                    if doc.labels.isEmpty {
                        self.show(doc.error ?? "No label found in “\(doc.name)”.", error: true)
                    } else if shouldPrint {
                        self.printDocument(doc.id)
                    }
                    NSDocumentController.shared.noteNewRecentDocumentURL(url)
                }
            }
        }
    }

    func reprocessAll() {
        let urls = documents.map { $0.url }.reversed()
        documents.removeAll()
        open(Array(urls), autoPrint: false)
    }

    func remove(_ id: UUID) { documents.removeAll { $0.id == id } }

    func toggle(_ label: UUID, in doc: UUID) {
        guard let i = documents.firstIndex(where: { $0.id == doc }) else { return }
        if documents[i].selected.contains(label) { documents[i].selected.remove(label) } else { documents[i].selected.insert(label) }
    }

    func flip(_ label: UUID, in doc: UUID) {
        guard let i = documents.firstIndex(where: { $0.id == doc }),
              let j = documents[i].labels.firstIndex(where: { $0.id == label }) else { return }
        documents[i].labels[j].flip()
    }

    // MARK: Printing

    func printDocument(_ id: UUID, copies: Int = 1) {
        guard let doc = documents.first(where: { $0.id == id }) else { return }
        let picked = doc.labels.filter { doc.selected.contains($0.id) }
        printLabels(picked.isEmpty ? doc.labels : picked, copies: copies, docID: id)
    }

    func printLabels(_ labels: [ExtractedLabel], copies: Int = 1, docID: UUID? = nil) {
        guard !labels.isEmpty else { return }
        guard let target = settings.printer else {
            show("Choose your printer first (Printer, in the sidebar).", error: true)
            NotificationCenter.default.post(name: .showPrinterSetup, object: nil)
            return
        }
        let trace = PerfTrace()
        let job = trace.measure("zpl.encode") { ZPL.job(labels.map { $0.image }, copies: copies, settings: settings.printSettings) }
        let name = settings.printerName.isEmpty ? target.description : settings.printerName
        working += 1
        net.async { [weak self] in
            var err: String? = nil
            do { try trace.measure("send") { try ZebraPrinter.send(job, to: target) } } catch { err = error.localizedDescription }
            PerfLog.append(PerfLog.record(op: "print", source: "app", trace: trace, extra: [
                "labels": labels.count, "copies": copies, "bytes": job.utf8.count, "target": target.kind, "error": err ?? "",
            ]))
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.working -= 1
                if let e = err {
                    self.show(e, error: true)
                } else {
                    let n = labels.count * copies
                    self.show("Printed \(n) label\(n == 1 ? "" : "s") on \(name)")
                    if let d = docID, let i = self.documents.firstIndex(where: { $0.id == d }) { self.documents[i].printedAt = Date() }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.refreshStatus(quiet: true) }
                }
            }
        }
    }

    /// Test label, calibrate, feed or configuration label. `completion` gets an error message or nil.
    func printerCommand(_ what: String, completion: ((String?) -> Void)? = nil) {
        if demo {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { completion?(nil) }
            return
        }
        guard let target = settings.printer else {
            show("Choose your printer first.", error: true)
            completion?("Choose your printer first.")
            return
        }
        let (w, h) = settings.labelSize.dots(dpi: settings.dpi)
        let dpi = settings.dpi
        let shift = settings.printSettings
        net.async { [weak self] in
            var err: String? = nil
            do {
                switch what {
                case "test": try ZebraPrinter.send(ZPL.testLabel(widthDots: w, heightDots: h, dpi: dpi, settings: shift), to: target, title: "Test label")
                case "calibrate": try ZebraPrinter.calibrate(target)
                case "feed": try ZebraPrinter.feed(target)
                case "config": try ZebraPrinter.printConfiguration(target)
                default: break
                }
            } catch { err = error.localizedDescription }
            DispatchQueue.main.async {
                if let e = err { self?.show(e, error: true) } else {
                    let done = ["test": "Test label sent", "calibrate": "Calibrating — the printer will feed a few labels",
                                "feed": "Fed one label", "config": "Printing the configuration label"]
                    self?.show(done[what] ?? "Done")
                    if what == "test" { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self?.refreshStatus(quiet: true) } }
                }
                completion?(err)
            }
        }
    }

    // MARK: Printer status & discovery

    func refreshStatus(quiet: Bool = false) {
        if demo { return }
        guard let target = settings.printer else { health = .unknown; return }
        switch target {
        case .network(let host, let port):
            refreshNetworkStatus(host: host, port: port, quiet: quiet)
        case .usb(let uri):
            refreshUSBStatus(uri: uri, quiet: quiet)
        case .queue(let name):
            // a queue that prints to a USB Zebra: at least say whether it's plugged in
            if let uri = queues.first(where: { $0.name == name })?.uri, uri.hasPrefix("usb:") {
                refreshUSBStatus(uri: uri, quiet: quiet)
            } else {
                health = .queue("macOS queue “\(name)”")
            }
        }
    }

    /// USB can't report paper or head problems the way the network does, but it can say whether
    /// the printer is plugged in and switched on, and whether the Mac has a printer for it yet.
    private func refreshUSBStatus(uri: String, quiet: Bool) {
        if !quiet { health = .checking }
        net.async { [weak self] in
            let trace = PerfTrace()
            let connected = trace.measure("usb_presence") { USBPrinters.isConnected(uri: uri) }
            let added = trace.measure("queues") { Discovery.queues().contains { USBDevices.sameDevice($0.uri, uri) } }
            if trace.elapsedMs > 800 {
                PerfLog.append(PerfLog.record(op: "status", source: "app", trace: trace, extra: ["target": "usb"]))
            }
            let h: PrinterHealth
            if !connected {
                h = .offline("Not connected (USB)")
            } else if !added {
                h = .needsSetup("Connected by USB · not added to your Mac yet")
            } else {
                h = .ready("Connected by USB")
            }
            DispatchQueue.main.async { self?.health = h }
        }
    }

    private func refreshNetworkStatus(host: String, port: Int, quiet: Bool) {
        if !quiet { health = .checking }
        net.async { [weak self] in
            var h: PrinterHealth
            var ident: ZebraIdentity? = nil
            let trace = PerfTrace()
            var failure = ""
            do {
                let s = try trace.measure("status") { try ZebraPrinter.status(host: host, port: port) }
                h = s.isReady ? .ready(s.summary) : .problem(s.summary)
                if self?.identity == nil { ident = trace.measure("identity") { try? ZebraPrinter.identity(host: host, port: port) } }
            } catch {
                h = .offline("Offline")
                failure = error.localizedDescription
            }
            if trace.elapsedMs > 800 || !failure.isEmpty {
                PerfLog.append(PerfLog.record(op: "status", source: "app", trace: trace, extra: ["error": failure]))
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.health = h
                if let i = ident { self.identity = i }
            }
        }
    }

    /// Looks for Zebras plugged in by USB (quick) and printers on the network (a few seconds), side by side.
    func scan(network: Bool = true, usb: Bool = true) {
        if demo { return }
        if usb && !scanningUSB {
            scanningUSB = true
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let trace = PerfTrace()
                let found = trace.measure("usb") { Discovery.usbPrinters() }
                PerfLog.append(PerfLog.record(op: "discover", source: "app", trace: trace, extra: [
                    "via": "usb", "found": found.count, "zebras": found.filter { $0.isZebra }.count,
                ]))
                DispatchQueue.main.async {
                    guard let self = self, !self.demo else { return }
                    self.discovered = found + self.discovered.filter { !$0.isUSB }
                    self.scanningUSB = false
                }
            }
        }
        if network && !scanning {
            scanning = true
            net.async { [weak self] in
                let trace = PerfTrace()
                let found = trace.measure("scan") { Discovery.scan() }
                let qs = Discovery.queues()
                PerfLog.append(PerfLog.record(op: "discover", source: "app", trace: trace, extra: [
                    "via": "network", "found": found.count, "zebras": found.filter { $0.isZebra }.count,
                ]))
                DispatchQueue.main.async {
                    guard let self = self, !self.demo else { return }
                    self.discovered = self.discovered.filter { $0.isUSB } + found
                    self.queues = qs
                    self.scanning = false
                }
            }
        }
    }

    func choose(_ p: DiscoveredPrinter) {
        settings.printer = p.target
        settings.printerName = p.name
        if let d = p.dpi { settings.dpi = d }
    }

    /// Asks the printer for its resolution and adopts it.
    func detectResolution() {
        guard case .network(let host, let port)? = settings.printer else { return }
        net.async { [weak self] in
            let id = try? ZebraPrinter.identity(host: host, port: port)
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let id = id {
                    self.identity = id
                    self.settings.dpi = id.dpi
                    if self.settings.printerName.isEmpty || self.settings.printerName == host { self.settings.printerName = id.model }
                    self.show("\(id.model): \(id.dpi) dpi")
                } else {
                    self.show("The printer didn’t answer.", error: true)
                }
            }
        }
    }

    // MARK: Driver

    func refreshDriver() {
        driverInstalled = Driver.isInstalled
        let bundled = filterInBundle
        net.async { [weak self] in
            let qs = Driver.tearoffQueues()
            let all = Discovery.queues()
            let outdated = bundled.map { Driver.isOutdated(comparedTo: $0) } ?? false
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.tearoffQueues = qs
                self.queues = all
                self.driverOutdated = outdated
                // USB status depends on the printer list (has the Mac got a printer for it yet?)
                if let t = self.settings.printer, !t.isNetwork { self.refreshStatus(quiet: true) }
            }
        }
    }

    /// Re-installs the filter and PPD from this copy of the app and refreshes every Tearoff queue.
    func updateDriver() {
        installDriver(queueName: "", displayName: "", uri: "", convert: tearoffQueues)
    }

    var filterInBundle: URL? {
        let u = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/tearoff-filter")
        return FileManager.default.isExecutableFile(atPath: u.path) ? u : nil
    }

    func installDriver(queueName: String, displayName: String, uri: String, convert: [String]) {
        guard let filter = filterInBundle else {
            alert = "This copy of Tearoff is missing its printer filter. Reinstall Tearoff.app."
            return
        }
        var req = Driver.InstallRequest(queueName: queueName, displayName: displayName, deviceURI: uri,
                                        dpi: settings.dpi, label: settings.labelSize,
                                        darkness: settings.darkness, speed: settings.speed,
                                        extraCodes: settings.extraCodes, convertQueues: convert)
        req.topOffset = settings.topOffset
        req.leftOffset = settings.leftOffset
        let trace = PerfTrace()
        do {
            // driver files from the installer package: just add the printer (usually no password)
            let quick = Driver.isInstalled && !driverOutdated && trace.measure("lpadmin") { Driver.addQueuesWithoutPrompt(req) }
            if !quick { try trace.measure("admin_install") { try Driver.install(req, filterSource: filter) } }
            if !uri.isEmpty { settings.installedQueue = queueName }
            show(uri.isEmpty ? "Driver updated." : "Added. Choose “\(displayName)” in any Print dialog.")
            PerfLog.append(PerfLog.record(op: "driver_install", source: "app", trace: trace, extra: ["password_prompt": !quick]))
        } catch {
            alert = error.localizedDescription
        }
        refreshDriver()
    }

    func uninstallDriver() {
        do {
            try Driver.uninstall(queues: tearoffQueues)
            settings.installedQueue = nil
            show("Removed the Tearoff driver.")
        } catch {
            alert = error.localizedDescription
        }
        refreshDriver()
    }

    private var syncItem: DispatchWorkItem?

    /// Debounced: copies darkness/speed/stock to the Tearoff print queues.
    func scheduleQueueSync() {
        syncItem?.cancel()
        guard !tearoffQueues.isEmpty else { return }
        let item = DispatchWorkItem { [weak self] in self?.syncQueueDefaults() }
        syncItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: item)
    }

    // MARK: PDF menu item

    var pdfServiceURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/PDF Services/Print Label with Tearoff")
    }

    var pdfServiceInstalled: Bool { FileManager.default.fileExists(atPath: pdfServiceURL.path) }

    /// Adds "Print Label with Tearoff" to the PDF ▾ menu of every Print dialog.
    func installPDFService() {
        let script = """
        #!/bin/sh
        # Print dialog PDF service: $1 title, $2 options, $3 PDF. Copy it (the print system deletes
        # its temp file when we return) and hand it to Tearoff, which prints it right away.
        dest="/tmp/tearoff-print-$$.pdf"; touch "$dest" 2>/dev/null || dest="${TMPDIR:-/tmp}/tearoff-print-$$.pdf"
        cp "$3" "$dest" && open -b com.au12.tearoff "$dest"
        """
        do {
            try FileManager.default.createDirectory(at: pdfServiceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try script.write(to: pdfServiceURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pdfServiceURL.path)
            objectWillChange.send()
            show("Added “Print Label with Tearoff” to the PDF menu of the Print dialog.")
        } catch {
            alert = "Couldn’t add the PDF menu item: \(error.localizedDescription)"
        }
    }

    /// Pushes darkness/speed/stock to the system queue so ⌘P jobs match the app.
    func syncQueueDefaults() {
        let s = settings
        let qs = tearoffQueues
        net.async {
            for q in qs {
                Driver.setDefaults(queue: q, dpi: s.dpi, label: s.labelSize, darkness: s.darkness, speed: s.speed, extras: s.extraCodes,
                                   topOffset: s.topOffset, leftOffset: s.leftOffset)
            }
        }
    }

    // MARK: Downloads watching

    func updateWatcher() {
        if settings.watchDownloads {
            watcher.start()
            Notifier.requestPermission()
        } else {
            watcher.stop()
        }
    }

    func downloaded(_ url: URL) {
        let opts = ExtractOptions(render: renderOptions, fallbackToPages: false, extraCodes: settings.extraCodes)
        work.async { [weak self] in
            let trace = PerfTrace()
            let found = (try? LabelExtractor.extract(url: url, options: opts, trace: trace)) ?? []
            PerfLog.append(PerfLog.record(op: "extract", source: "downloads", trace: trace, extra: [
                "file": url.lastPathComponent, "labels": found.count, "kinds": found.map { $0.kind },
            ]))
            let labels = found
            // only shipping labels count: a downloaded invoice or ticket with a barcode is not a label
            guard labels.contains(where: { !$0.isExtraCode && !$0.barcodes.isEmpty }) else { return }
            DispatchQueue.main.async {
                guard let self = self else { return }
                var doc = LabelDocument(url: url, name: url.lastPathComponent, labels: labels, selected: Set(labels.map { $0.id }))
                doc.error = nil
                self.documents.removeAll { $0.url == url }
                self.documents.insert(doc, at: 0)
                let what = labels.first?.carrier.map { "\($0) label" } ?? "Shipping label"
                if self.settings.watchAutoPrint && self.settings.printer != nil {
                    self.printDocument(doc.id)
                    Notifier.post(title: "Printed \(what)", body: url.lastPathComponent, path: nil)
                } else {
                    Notifier.post(title: "\(what) downloaded", body: "\(url.lastPathComponent) — click Print to send it to your Zebra.",
                                  path: url.path)
                }
            }
        }
    }

    func printFromNotification(path: String) {
        if let doc = documents.first(where: { $0.url.path == path }) {
            printDocument(doc.id)
        } else {
            open([URL(fileURLWithPath: path)], autoPrint: true)
        }
    }

    // MARK: Login item

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                alert = "macOS didn’t allow that: \(error.localizedDescription)"
            }
            objectWillChange.send()
        }
    }

    // MARK: Diagnostics

    func runBenchmark() {
        guard !benchRunning else { return }
        let files = Benchmark.defaultFiles()
        guard !files.isEmpty else { show("No benchmark PDFs in this build.", error: true); return }
        benchRunning = true
        benchStatus = "Starting…"
        let opts = renderOptions
        work.async { [weak self] in
            let r = Benchmark.run(files: files, runs: 3, options: opts) { msg in
                DispatchQueue.main.async { self?.benchStatus = msg }
            }
            PerfLog.append(Benchmark.record(r, source: "app"))
            DispatchQueue.main.async {
                self?.benchRunning = false
                self?.benchStatus = r.summary + String(format: " · peak %.0f MB", r.peakMB)
            }
        }
    }

    /// One line about recent real-world timings, for the Diagnostics section.
    func refreshPerfSummary() {
        PerfLog.mergeFilterLogs()
        PerfLog.queue.async { [weak self] in
            func ms(_ r: [String: Any]?) -> String? { (r?["ms"] as? Double).map { "\(Int($0.rounded())) ms" } }
            var parts: [String] = []
            if let x = ms(PerfLog.recent(op: "extract", limit: 1).first) { parts.append("last label found in \(x)") }
            if let x = ms(PerfLog.recent(op: "filter", limit: 1).first) { parts.append("last ⌘P job \(x) in the driver") }
            if let x = ms(PerfLog.recent(op: "print", limit: 1).first) { parts.append("last send \(x)") }
            DispatchQueue.main.async { self?.perfSummary = parts.isEmpty ? "No timings yet." : parts.joined(separator: " · ").capitalizedFirst }
        }
    }

    // MARK: Demo (README screenshots)

    /// `Tearoff --demo [--pane printer] FILE…` shows the UI with a pretend printer.
    func startDemo(files: [URL], pane: Pane, captureMain: Bool = true) {
        demo = true
        persist = false
        settings.printer = .network(host: "10.0.10.50", port: 9100)
        settings.printerName = "Zebra GX420d"
        health = .ready("Ready")
        identity = ZebraIdentity.parse("\u{02}GX420d-200dpi,V61.17.17Z,8,8192KB\u{03}")
        discovered = [DiscoveredPrinter(target: .usb(uri: "usb://Zebra%20Technologies/ZTC%20ZD421-203dpi%20ZPL?serial=D2J213901234"),
                                        name: "ZD421-203dpi", detail: "Connected by USB · serial D2J213901234", isZebra: true, dpi: 203),
                      DiscoveredPrinter(target: .network(host: "10.0.10.50", port: 9100), name: "GX420d-200dpi",
                                        detail: "10.0.10.50 · firmware V61.17.17Z", isZebra: true, dpi: 203),
                      DiscoveredPrinter(target: .network(host: "10.0.10.31", port: 9100), name: "Office printer",
                                        detail: "10.0.10.31 · port 9100", isZebra: false, dpi: nil)]
        tearoffQueues = []
        requestedPane = pane
        if !files.isEmpty { open(files, autoPrint: false) }
        guard captureMain else { return }
        // let CI capture just this window: write its CGWindowID where the screenshot script looks
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            guard let w = AppDelegate.shared?.mainWindow else { return }
            let vf = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
            w.setContentSize(NSSize(width: min(1120, vf.width - 24), height: min(740, vf.height - 24)))
            w.center()
            w.makeKeyAndOrderFront(nil)
            let path = ProcessInfo.processInfo.environment["TEAROFF_WINDOW_ID_FILE"] ?? "/tmp/tearoff-window-id"
            try? String(w.windowNumber).write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    // MARK: Feedback

    func show(_ text: String, error: Bool = false) {
        let t = Toast(text: text, isError: error)
        toast = t
        DispatchQueue.main.asyncAfter(deadline: .now() + (error ? 6 : 3.5)) { [weak self] in
            if self?.toast == t { self?.toast = nil }
        }
    }

    func savePNG(_ label: ExtractedLabel, suggestedName: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = suggestedName
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? label.image.pngData(dpi: label.dpi)?.write(to: url)
    }

    func saveZPL(_ labels: [ExtractedLabel], suggestedName: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? Data(ZPL.job(labels.map { $0.image }, settings: settings.printSettings).utf8).write(to: url)
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .png, .jpeg, .tiff, .heic, .image]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        open(panel.urls)
    }
}

extension Notification.Name {
    static let showPrinterSetup = Notification.Name("tearoff.showPrinterSetup")
}

// MARK: - Setup helpers

extension AppModel {
    /// Name for the Mac printer, from the printer's model ("Zebra GX420d").
    var suggestedPrinterName: String {
        let n = identity?.model ?? settings.printerName
        let base = n.replacingOccurrences(of: #"-\d{3}dpi"#, with: "", options: .regularExpression)
        let looksLikeAddress = base.allSatisfy { $0.isNumber || $0 == "." || $0 == ":" }
        if base.isEmpty || looksLikeAddress { return "Zebra Label Printer" }
        return base.lowercased().hasPrefix("zebra") ? base : "Zebra \(base)"
    }

    /// CUPS device URI for the chosen printer.
    var deviceURI: String {
        switch settings.printer {
        case .network(let h, let p)?: return "socket://\(h):\(p)"
        case .queue(let n)?: return queues.first(where: { $0.name == n })?.uri ?? ""
        case .usb(let u)?: return u
        case nil: return ""
        }
    }

    /// Where the Mac printer will connect, for people: "socket://10.0.10.50:9100", "GX420d over USB · serial 28J…".
    var connectionText: String {
        guard case .usb(let u)? = settings.printer else { return deviceURI }
        let info = USBPrinterInfo(uri: u)
        return "\(info.displayName) over USB" + (info.serial.map { " · serial \($0)" } ?? "")
    }

    /// Uses a typed address or hostname as the printer. False if it doesn't parse.
    @discardableResult
    func useHost(_ text: String) -> Bool {
        guard let t = PrinterTarget(string: text.trimmingCharacters(in: .whitespaces)) else { return false }
        settings.printer = t
        if settings.printerName.isEmpty || PrinterTarget(string: settings.printerName) != nil {
            settings.printerName = t.description
        }
        detectResolution()
        return true
    }

    /// A Mac printer using the Tearoff driver exists.
    var printerAdded: Bool { !tearoffQueues.isEmpty }

    /// How the Tearoff printer appears in Print dialogs (queue names use _ for spaces).
    var addedPrinterName: String? {
        let q = settings.installedQueue.flatMap { tearoffQueues.contains($0) ? $0 : nil } ?? tearoffQueues.first
        return q?.replacingOccurrences(of: "_", with: " ")
    }

    /// Adds the chosen Zebra as a Mac printer using the Tearoff driver.
    func addPrinter(displayName: String) {
        let queue = Driver.queueName(for: displayName)
        if demo {
            tearoffQueues = [queue]
            show("Added. Choose “\(displayName)” in any Print dialog.")
            return
        }
        installDriver(queueName: queue, displayName: displayName, uri: deviceURI, convert: [])
        // show it as added straight away; refreshDriver() confirms from CUPS a moment later
        if alert == nil && !tearoffQueues.contains(queue) { tearoffQueues.append(queue) }
    }

    /// The sample return page (a label, a return barcode and a QR code) shipped in the app.
    var sampleURL: URL? { Bundle.main.url(forResource: "Sample Return", withExtension: "pdf") }

    /// Opens the sample in Preview, to try ⌘P for real.
    func openSample() {
        guard let url = sampleURL else {
            show("This copy of Tearoff is missing its sample page.", error: true)
            return
        }
        // a copy in a temp folder: Preview shows a friendly name and nothing touches the app bundle
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("Tearoff Sample Return.pdf")
        try? FileManager.default.removeItem(at: copy)
        let file = (try? FileManager.default.copyItem(at: url, to: copy)) != nil ? copy : url
        if let preview = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") {
            NSWorkspace.shared.open([file], withApplicationAt: preview, configuration: NSWorkspace.OpenConfiguration(),
                                    completionHandler: nil)
        } else {
            NSWorkspace.shared.open(file)
        }
    }
}

/// Local notifications with a Print button.
enum Notifier {
    static func requestPermission() {
        let c = UNUserNotificationCenter.current()
        c.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let print = UNNotificationAction(identifier: "PRINT", title: "Print", options: [])
        c.setNotificationCategories([UNNotificationCategory(identifier: "LABEL", actions: [print], intentIdentifiers: [], options: [])])
    }

    static func post(title: String, body: String, path: String?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let p = path {
            content.categoryIdentifier = "LABEL"
            content.userInfo = ["path": p]
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

extension String {
    var capitalizedFirst: String { self.prefix(1).uppercased() + self.dropFirst() }
}

/// Logs main-thread stalls (> 250 ms) so UI hitches show up in the performance log.
final class HangMonitor {
    private let q = DispatchQueue(label: "tearoff.hangs", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var waiting = false

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 2, repeating: 0.5)
        t.setEventHandler { [weak self] in self?.ping() }
        t.resume()
        timer = t
    }

    private func ping() {
        guard !waiting else { return }
        waiting = true
        let sent = ProcessInfo.processInfo.systemUptime
        DispatchQueue.main.async { [weak self] in
            let lag = (ProcessInfo.processInfo.systemUptime - sent) * 1000
            self?.q.async { self?.waiting = false }
            if lag > 250 {
                PerfLog.append(PerfLog.record(op: "hang", source: "app", ms: lag))
            }
        }
    }
}
