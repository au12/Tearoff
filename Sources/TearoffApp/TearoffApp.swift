import AppKit
import SwiftUI
import TearoffKit
import UserNotifications

@main
struct TearoffApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        WindowGroup("Tearoff", id: "main") {
            MainView()
                .environmentObject(model)
                .frame(minWidth: 820, minHeight: 560)
        }
        .defaultSize(width: 1040, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") { model.openPanel() }.keyboardShortcut("o")
            }
            CommandGroup(replacing: .printItem) {
                Button("Print Labels") {
                    if let d = model.documents.first { model.printDocument(d.id) }
                }
                .keyboardShortcut("p")
                .disabled(model.documents.first?.labels.isEmpty ?? true)
            }
        }

        MenuBarExtra {
            MenuBarContent().environmentObject(model)
        } label: {
            Image(systemName: "printer.dotmatrix")
        }
    }
}

struct MenuBarContent: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.settings.printerName.isEmpty ? "No printer chosen" : "\(model.settings.printerName): \(model.health.text)")
        Divider()
        Button("Open Tearoff") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Open PDF…") {
            NSApp.activate(ignoringOtherApps: true)
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

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {

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
            AppModel.shared.startDemo(files: files, pane: pane)
            return
        }
        UNUserNotificationCenter.current().delegate = self
        AppModel.shared.start()
        // Launched by the Print dialog's PDF menu as a tool: argv = [exe, title, options, pdf]
        if a.count >= 4, FileManager.default.fileExists(atPath: a[3]) {
            AppModel.shared.open([URL(fileURLWithPath: a[3])], autoPrint: true)
        }
    }

    func application(_ sender: NSApplication, open urls: [URL]) {
        // A PDF handed over by the Print dialog (PDF ▾ ▸ Print Label with Tearoff) lives in a temp
        // folder: print it straight away. Files opened from Finder get a preview first.
        let fromPrintDialog = urls.allSatisfy { $0.path.hasPrefix("/private/var/folders") || $0.path.hasPrefix("/var/folders") }
        AppModel.shared.open(urls, autoPrint: fromPrintDialog ? true : nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let path = response.notification.request.content.userInfo["path"] as? String
        DispatchQueue.main.async {
            if let p = path {
                if response.actionIdentifier == "PRINT" {
                    AppModel.shared.printFromNotification(path: p)
                } else {
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
            completionHandler()
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
