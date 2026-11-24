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

    var text: String {
        switch self {
        case .unknown: return "No printer"
        case .checking: return "Checking…"
        case .ready(let s), .problem(let s), .offline(let s), .queue(let s): return s
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
            if settings.printer != oldValue.printer { refreshStatus() }
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
    @Published var scanning = false
    @Published var driverInstalled = Driver.isInstalled
    @Published var driverOutdated = false
    @Published var tearoffQueues: [String] = []
    @Published var alert: String?

    let work = DispatchQueue(label: "tearoff.work", qos: .userInitiated)
    let net = DispatchQueue(label: "tearoff.net", qos: .utility)
    lazy var watcher = DownloadsWatcher { [weak self] url in self?.downloaded(url) }
    var statusTimer: Timer?

    private init() {}

    func start() {
        refreshStatus()
        refreshDriver()
        updateWatcher()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.refreshStatus(quiet: true)
        }
    }

    // MARK: Opening

    var renderOptions: RenderOptions { settings.renderOptions }

    /// Opens files; prints right away when asked to (or when Auto-print is on).
    func open(_ urls: [URL], autoPrint: Bool? = nil) {
        for url in urls {
            let opts = ExtractOptions(render: renderOptions, fallbackToPages: true)
            let shouldPrint = autoPrint ?? settings.autoPrintOnOpen
            working += 1
            work.async { [weak self] in
                var doc = LabelDocument(url: url, name: url.lastPathComponent, labels: [], selected: [])
                do {
                    doc.labels = try LabelExtractor.extract(url: url, options: opts)
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
        let job = ZPL.job(labels.map { $0.image }, copies: copies, settings: settings.printSettings)
        let name = settings.printerName.isEmpty ? target.description : settings.printerName
        working += 1
        net.async { [weak self] in
            var err: String? = nil
            do { try ZebraPrinter.send(job, to: target) } catch { err = error.localizedDescription }
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

    func printerCommand(_ what: String) {
        guard let target = settings.printer else { show("Choose your printer first.", error: true); return }
        let (w, h) = settings.labelSize.dots(dpi: settings.dpi)
        let dpi = settings.dpi
        net.async { [weak self] in
            var err: String? = nil
            do {
                switch what {
                case "test": try ZebraPrinter.send(ZPL.testLabel(widthDots: w, heightDots: h, dpi: dpi), to: target, title: "Test label")
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
                }
            }
        }
    }

    // MARK: Printer status & discovery

    func refreshStatus(quiet: Bool = false) {
        if demo { return }
        guard let target = settings.printer else { health = .unknown; return }
        guard case .network(let host, let port) = target else {
            health = .queue("macOS queue “\(target.description)”")
            return
        }
        if !quiet { health = .checking }
        net.async { [weak self] in
            var h: PrinterHealth
            var ident: ZebraIdentity? = nil
            do {
                let s = try ZebraPrinter.status(host: host, port: port)
                h = s.isReady ? .ready(s.summary) : .problem(s.summary)
                ident = try? ZebraPrinter.identity(host: host, port: port)
            } catch {
                h = .offline("Offline")
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.health = h
                if let i = ident { self.identity = i }
            }
        }
    }

    func scan() {
        if demo { return }
        scanning = true
        net.async { [weak self] in
            let found = Discovery.scan()
            let qs = Discovery.queues()
            DispatchQueue.main.async {
                self?.discovered = found
                self?.queues = qs
                self?.scanning = false
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
                self?.tearoffQueues = qs
                self?.queues = all
                self?.driverOutdated = outdated
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
        let req = Driver.InstallRequest(queueName: queueName, displayName: displayName, deviceURI: uri,
                                        dpi: settings.dpi, label: settings.labelSize,
                                        darkness: settings.darkness, speed: settings.speed, convertQueues: convert)
        do {
            try Driver.install(req, filterSource: filter)
            if !uri.isEmpty { settings.installedQueue = queueName }
            show("Installed. Choose “\(displayName)” in any Print dialog.")
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
            for q in qs { Driver.setDefaults(queue: q, dpi: s.dpi, label: s.labelSize, darkness: s.darkness, speed: s.speed) }
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
        let opts = ExtractOptions(render: renderOptions, fallbackToPages: false)
        work.async { [weak self] in
            guard let labels = try? LabelExtractor.extract(url: url, options: opts),
                  !labels.isEmpty, labels.contains(where: { !$0.barcodes.isEmpty }) else { return }
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

    // MARK: Demo (README screenshots)

    /// `Tearoff --demo [--pane printer] FILE…` shows the UI with a pretend printer.
    func startDemo(files: [URL], pane: Pane) {
        demo = true
        persist = false
        settings.printer = .network(host: "10.0.10.50", port: 9100)
        settings.printerName = "Zebra GX420d"
        health = .ready("Ready")
        identity = ZebraIdentity.parse("\u{02}GX420d-200dpi,V61.17.17Z,8,8192KB\u{03}")
        discovered = [DiscoveredPrinter(target: .network(host: "10.0.10.50", port: 9100), name: "GX420d-200dpi",
                                        detail: "10.0.10.50 · firmware V61.17.17Z", isZebra: true, dpi: 203)]
        requestedPane = pane
        if !files.isEmpty { open(files, autoPrint: false) }
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
