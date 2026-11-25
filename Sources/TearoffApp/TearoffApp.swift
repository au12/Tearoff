import AppKit
import SwiftUI
import TearoffKit
import UserNotifications

@main
struct TearoffApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel.shared

    // The main window is created and owned by AppDelegate (a SwiftUI view in an AppKit window), so
    // it reliably appears at launch, when files are opened, on Dock clicks and from the menu bar.
    var body: some Scene {
        MenuBarExtra {
            MenuBarContent().environmentObject(model)
        } label: {
            Image(systemName: "printer.dotmatrix")
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { AppDelegate.shared?.showMainWindow(pane: .printer) }.keyboardShortcut(",")
                Button("Setup Assistant…") { AppDelegate.shared?.showSetupAssistant() }
            }
            CommandGroup(replacing: .newItem) {
                Button("Open…") {
                    AppDelegate.shared?.showMainWindow()
                    model.openPanel()
                }
                .keyboardShortcut("o")
                Button("Tearoff Window") { AppDelegate.shared?.showMainWindow() }.keyboardShortcut("0")
            }
            CommandGroup(replacing: .printItem) {
                Button("Print Labels") {
                    if let d = model.documents.first { model.printDocument(d.id) }
                }
                .keyboardShortcut("p")
                .disabled(model.documents.first?.labels.isEmpty ?? true)
            }
        }
    }
}

struct MenuBarContent: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Text(model.settings.printerName.isEmpty ? "No printer chosen" : "\(model.settings.printerName): \(model.health.text)")
        Divider()
        Button("Open Tearoff") { AppDelegate.shared?.showMainWindow() }
        Button("Open PDF…") {
            AppDelegate.shared?.showMainWindow()
            model.openPanel()
        }
        if let d = model.documents.first, !d.labels.isEmpty {
            Button("Print “\(d.name)”") { model.printDocument(d.id) }
        }
        Toggle("Watch Downloads for Labels", isOn: $model.settings.watchDownloads)
        Button("Setup Assistant…") { AppDelegate.shared?.showSetupAssistant() }
        Divider()
        Button("Quit Tearoff") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, NSWindowDelegate {
    static weak var shared: AppDelegate?
    var mainWindow: NSWindow?
    var setupWindow: NSWindow?
    private let launchedAt = ProcessInfo.processInfo.systemUptime

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let a = CommandLine.arguments
        // CI: render the Setup Assistant's animation to PNG frames, then quit
        if let i = a.firstIndex(of: "--render-pluck"), i + 1 < a.count {
            let dir = URL(fileURLWithPath: a[i + 1])
            Task { @MainActor in
                PluckFrames.render(to: dir)
                NSApp.terminate(nil)
            }
            return
        }
        if let i = a.firstIndex(of: "--demo") {
            // before any window exists, so nothing starts a real network scan
            AppModel.shared.demo = true
            AppModel.shared.persist = false
            var files: [URL] = []
            var pane = Pane.labels
            var setup: SetupStep? = nil
            var j = i + 1
            while j < a.count {
                if a[j] == "--pane", j + 1 < a.count { pane = Pane(rawValue: a[j + 1]) ?? .labels; j += 2; continue }
                if a[j] == "--setup", j + 1 < a.count { setup = SetupStep(name: a[j + 1]); j += 2; continue }
                if a[j] == "--pluck-time", j + 1 < a.count { PluckAnimationView.frozenOverride = Double(a[j + 1]); j += 2; continue }
                files.append(URL(fileURLWithPath: a[j]))
                j += 1
            }
            showMainWindow()
            AppModel.shared.startDemo(files: files, pane: pane, captureMain: setup == nil)
            if let step = setup {
                SetupAssistant.demoTestSent = step == .test
                showSetupAssistant(step: step)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    guard let w = self.setupWindow else { return }
                    let path = ProcessInfo.processInfo.environment["TEAROFF_WINDOW_ID_FILE"] ?? "/tmp/tearoff-window-id"
                    try? String(w.windowNumber).write(toFile: path, atomically: true, encoding: .utf8)
                }
            }
            return
        }
        UNUserNotificationCenter.current().delegate = self
        AppModel.shared.start()
        showMainWindow()
        if !AppModel.shared.settings.setupDone || a.contains("--setup") { showSetupAssistant() }
        DispatchQueue.main.async {
            let ms = (ProcessInfo.processInfo.systemUptime - self.launchedAt) * 1000
            PerfLog.append(PerfLog.record(op: "launch", source: "app", ms: ms))
        }
        // Launched by the Print dialog's PDF menu as a tool: argv = [exe, title, options, pdf]
        if a.count >= 4, FileManager.default.fileExists(atPath: a[3]) {
            AppModel.shared.open([URL(fileURLWithPath: a[3])], autoPrint: true)
        }
    }

    /// Shows (creating on first use) the main window.
    func showMainWindow(pane: Pane? = nil) {
        if mainWindow == nil {
            let host = NSHostingView(rootView: MainView().environmentObject(AppModel.shared))
            var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
            if #available(macOS 14.0, *) {
                host.sceneBridgingOptions = [.title, .toolbars]
                style.insert(.fullSizeContentView)
            }
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 700), styleMask: style,
                             backing: .buffered, defer: false)
            w.title = "Tearoff"
            w.contentView = host
            w.contentMinSize = NSSize(width: 820, height: 560)
            w.isReleasedWhenClosed = false
            w.toolbarStyle = .unified
            w.delegate = self
            w.setFrameAutosaveName("TearoffMainWindow")
            if !w.setFrameUsingName("TearoffMainWindow") { w.center() }
            mainWindow = w
        }
        if let p = pane { AppModel.shared.requestedPane = p }
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    /// Shows the Setup Assistant (a fresh one, at `step`, unless it's already open).
    func showSetupAssistant(step: SetupStep = .welcome) {
        if setupWindow == nil {
            let view = SetupAssistant(step: step) { [weak self] in self?.finishSetup() }
                .environmentObject(AppModel.shared)
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                             styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Tearoff Setup"
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.contentView = NSHostingView(rootView: view)
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            setupWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        setupWindow?.makeKeyAndOrderFront(nil)
    }

    func finishSetup() {
        setupWindow?.close()
        showMainWindow()
    }

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow, w === setupWindow else { return }
        // finished or closed: it won't open by itself again (Tearoff ▸ Setup Assistant… still does)
        if !AppModel.shared.demo { AppModel.shared.settings.setupDone = true }
        setupWindow = nil
    }

    func application(_ sender: NSApplication, open urls: [URL]) {
        // A PDF handed over by the Print dialog (PDF ▾ ▸ Print Label with Tearoff) lives in a temp
        // folder: print it straight away. Files opened from Finder get a preview first.
        let fromPrintDialog = urls.allSatisfy { $0.lastPathComponent.hasPrefix("tearoff-print-") }
        showMainWindow(pane: .labels)
        AppModel.shared.open(urls, autoPrint: fromPrintDialog ? true : nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let path = response.notification.request.content.userInfo["path"] as? String
        DispatchQueue.main.async {
            if let p = path, response.actionIdentifier == "PRINT" {
                AppModel.shared.printFromNotification(path: p)
            } else {
                self.showMainWindow(pane: .labels)
            }
            completionHandler()
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
