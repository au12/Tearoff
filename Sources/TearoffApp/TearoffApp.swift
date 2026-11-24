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
        Divider()
        Button("Quit Tearoff") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, NSWindowDelegate {
    static weak var shared: AppDelegate?
    var mainWindow: NSWindow?

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--demo") {
            var files: [URL] = []
            var pane = Pane.labels
            var j = i + 1
            while j < a.count {
                if a[j] == "--pane", j + 1 < a.count { pane = Pane(rawValue: a[j + 1]) ?? .labels; j += 2; continue }
                files.append(URL(fileURLWithPath: a[j]))
                j += 1
            }
            showMainWindow()
            AppModel.shared.startDemo(files: files, pane: pane)
            return
        }
        UNUserNotificationCenter.current().delegate = self
        AppModel.shared.start()
        showMainWindow()
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
