import AppKit
import SwiftUI
import TearoffCore
import TearoffKit

enum SetupStep: Int, CaseIterable, Identifiable {
    case welcome, find, add, test, ready

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .find: return "Find Your Printer"
        case .add: return "Add to Your Mac"
        case .test: return "Test Print"
        case .ready: return "Start Printing"
        }
    }

    init?(name: String) {
        switch name.lowercased() {
        case "welcome": self = .welcome
        case "find": self = .find
        case "add": self = .add
        case "test": self = .test
        case "ready", "done": self = .ready
        default: return nil
        }
    }
}

/// First-run Setup Assistant: find the Zebra, add it to the Mac's printers, print a test label,
/// then see how printing whole pages works. Shown once on first launch; Tearoff ▸ Setup Assistant…
/// opens it again.
struct SetupAssistant: View {
    @EnvironmentObject var model: AppModel
    @State private var step: SetupStep
    @State private var forward = true
    let onFinish: () -> Void

    /// Demo mode (screenshots): open the test step as if a test label had just printed.
    static var demoTestSent = false

    init(step: SetupStep = .welcome, onFinish: @escaping () -> Void) {
        _step = State(initialValue: step)
        self.onFinish = onFinish
    }

    var body: some View {
        HStack(spacing: 0) {
            SetupSidebar(step: step)
                .frame(width: 214)
            Divider()
            VStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    page
                        .id(step)
                        .transition(.asymmetric(
                            insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                            removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
                Divider()
                footer
            }
        }
        .frame(width: 900, height: 640)
    }

    @ViewBuilder var page: some View {
        switch step {
        case .welcome: WelcomeStep()
        case .find: FindStep()
        case .add: AddStep()
        case .test: TestStep()
        case .ready: ReadyStep()
        }
    }

    var footer: some View {
        HStack(spacing: 12) {
            if step != .welcome {
                Button("Back") { go(to: SetupStep(rawValue: step.rawValue - 1) ?? .welcome) }
                    .controlSize(.large)
            }
            Spacer()
            if let skip = skipTitle {
                Button(skip) {
                    if step == .find { onFinish() } else { go(to: next) }
                }
                .buttonStyle(.link)
            }
            Button(primaryTitle) {
                if step == .ready { onFinish() } else { go(to: next) }
            }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(!canContinue)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    var next: SetupStep { SetupStep(rawValue: step.rawValue + 1) ?? .ready }

    var primaryTitle: String {
        switch step {
        case .welcome: return "Get Started"
        case .ready: return "Start Using Tearoff"
        default: return "Continue"
        }
    }

    var canContinue: Bool {
        switch step {
        case .find: return model.settings.printer != nil
        case .add: return model.printerAdded
        default: return true
        }
    }

    var skipTitle: String? {
        switch step {
        case .find: return model.settings.printer == nil ? "Set Up Later" : nil
        case .add: return model.printerAdded ? nil : "Skip This Step"
        default: return nil
        }
    }

    func go(to target: SetupStep) {
        forward = target.rawValue > step.rawValue
        // let the outgoing page pick up the new direction before it animates away
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.3)) { step = target }
        }
    }
}

// MARK: - Sidebar

struct SetupSidebar: View {
    let step: SetupStep

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                    .resizable()
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Tearoff").font(.headline)
                    Text("Setup").font(.subheadline).foregroundColor(.secondary)
                }
            }
            .padding(.bottom, 26)
            ForEach(SetupStep.allCases) { s in
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(s.rawValue < step.rawValue ? Color.green : (s == step ? Color.accentColor : Color.secondary.opacity(0.18)))
                            .frame(width: 22, height: 22)
                        if s.rawValue < step.rawValue {
                            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundColor(.white)
                        } else {
                            Text("\(s.rawValue + 1)")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(s == step ? .white : .secondary)
                        }
                    }
                    Text(s.title)
                        .fontWeight(s == step ? .semibold : .regular)
                        .foregroundColor(s.rawValue > step.rawValue ? .secondary : .primary)
                }
                .padding(.vertical, 8)
            }
            Spacer()
            Text("Open this again any time: Tearoff ▸ Setup Assistant…")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 46)
        .padding(.horizontal, 22)
        .padding(.bottom, 20)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.primary.opacity(0.035))
    }
}

struct StepHeader: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 26, weight: .bold))
            Text(text)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - 1 Welcome

struct WelcomeStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 18) {
                Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                    .resizable()
                    .frame(width: 76, height: 76)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome to Tearoff").font(.system(size: 30, weight: .bold))
                    Text("Shipping labels from any PDF, straight to your Zebra.")
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
            }
            Text("Setup takes about a minute:").font(.headline).padding(.top, 8)
            VStack(alignment: .leading, spacing: 18) {
                WelcomeRow(icon: "dot.radiowaves.left.and.right", title: "Find your Zebra",
                           detail: "Tearoff looks for it on your network.")
                WelcomeRow(icon: "plus.rectangle.on.rectangle", title: "Add it to your Mac",
                           detail: "So it’s in the Print dialog of every app.")
                WelcomeRow(icon: "printer", title: "Print a test label",
                           detail: "Check that the bars are crisp and the label lines up.")
                WelcomeRow(icon: "scissors", title: "Print whole pages",
                           detail: "Tearoff keeps the labels, barcodes and QR codes, and skips everything else.")
            }
            Spacer(minLength: 0)
        }
        .padding(40)
    }
}

struct WelcomeRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(.accentColor)
                .frame(width: 32, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - 2 Find

struct FindStep: View {
    @EnvironmentObject var model: AppModel
    @State private var host = ""

    var printers: [DiscoveredPrinter] { model.discovered.filter { $0.isZebra } + model.discovered.filter { !$0.isZebra } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepHeader(title: "Find your Zebra",
                       text: "Turn the printer on and connect it to the same network as this Mac, by Ethernet or Wi-Fi. Tearoff looks for it automatically.")
            HStack(spacing: 10) {
                if model.scanning {
                    ProgressView().controlSize(.small)
                    Text("Searching your network…").foregroundColor(.secondary)
                } else {
                    Text(summary).foregroundColor(.secondary)
                }
                Spacer()
                Button { model.scan() } label: { Label("Search Again", systemImage: "arrow.clockwise") }
                    .disabled(model.scanning)
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(printers) { p in
                        PrinterRow(printer: p, selected: model.settings.printer == p.target) { model.choose(p) }
                    }
                    if printers.isEmpty && !model.scanning { NotFoundHelp() }
                }
            }
            .frame(maxHeight: 210)
            HStack(spacing: 8) {
                Text("Not listed? Type its IP address:")
                TextField("IP address", text: $host, prompt: Text("10.0.10.50"))
                    .frame(width: 150)
                    .onSubmit(useHost)
                Button("Use", action: useHost)
                    .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if model.settings.printer != nil {
                HStack(spacing: 8) {
                    StatusDot(health: model.health)
                    Text(statusLine).foregroundColor(.secondary)
                }
            }
            Spacer(minLength: 0)
            Label("If macOS asks to let Tearoff find devices on your local network, click Allow.", systemImage: "lock.shield")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(40)
        .onAppear {
            if model.discovered.isEmpty && !model.scanning { model.scan() }
            if case .network(let h, _)? = model.settings.printer { host = h }
        }
        .onChange(of: model.discovered) { found in
            // one Zebra on the network and none chosen yet: that's the one
            let zebras = found.filter { $0.isZebra }
            if model.settings.printer == nil, zebras.count == 1 { model.choose(zebras[0]) }
        }
    }

    var summary: String {
        let z = model.discovered.filter { $0.isZebra }.count
        let other = model.discovered.count - z
        if model.discovered.isEmpty { return "No printers found yet." }
        var s = "Found \(z) Zebra\(z == 1 ? "" : "s")"
        if other > 0 { s += " and \(other) other printer\(other == 1 ? "" : "s")" }
        return s + "."
    }

    var statusLine: String {
        let name = model.settings.printerName.isEmpty ? (model.settings.printer?.description ?? "") : model.settings.printerName
        return "\(name): \(model.health.text)"
    }

    func useHost() {
        if model.useHost(host) { host = model.settings.printer?.description ?? host }
    }
}

struct PrinterRow: View {
    let printer: DiscoveredPrinter
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: printer.isZebra ? "printer.fill" : "printer")
                    .font(.title2)
                    .foregroundColor(printer.isZebra ? .accentColor : .secondary)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(printer.name).font(.headline)
                    Text(printer.isZebra ? printer.detail : "\(printer.detail) · may not speak ZPL")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundColor(selected ? .accentColor : .secondary)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 1.5))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}

struct NotFoundHelp: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("No Zebra found yet", systemImage: "magnifyingglass").font(.headline)
            Text("• Is the printer on, with a solid green light?")
            Text("• Is its network cable plugged in, or is it on your Wi-Fi?")
            Text("• Is this Mac on the same network?")
            Text("To find its IP address, hold the Feed button until the light flashes once, then let go: it prints its settings.")
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
        .font(.callout)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.09)))
    }
}

// MARK: - 3 Add

struct AddStep: View {
    @EnvironmentObject var model: AppModel
    @State private var name = ""

    var effectiveName: String {
        let n = name.trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? model.suggestedPrinterName : n
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepHeader(title: "Add it to your Mac",
                       text: "Tearoff adds your Zebra to the Mac’s printers, so it’s in the Print dialog of every app: Safari, Chrome, Preview, Mail. Whatever you print, Tearoff takes it from there.")
            PrintDialogMock(printerName: model.addedPrinterName ?? effectiveName)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            if model.printerAdded {
                VStack(alignment: .leading, spacing: 8) {
                    Label("“\(model.addedPrinterName ?? effectiveName)” is in your printer list.", systemImage: "checkmark.circle.fill")
                        .font(.headline)
                        .foregroundColor(.green)
                    Text("Pick it in any Print dialog (⌘P). Label size, darkness and speed follow Tearoff’s settings.")
                        .foregroundColor(.secondary)
                    Button("Open Printers & Scanners") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Print-Scanner-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            } else {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        Text("Name").foregroundColor(.secondary)
                        TextField("Name", text: $name, prompt: Text(model.suggestedPrinterName))
                            .frame(maxWidth: 280)
                    }
                    GridRow {
                        Text("Connects to").foregroundColor(.secondary)
                        Text(model.deviceURI.isEmpty ? "Go back and choose your printer" : model.deviceURI)
                            .foregroundColor(model.deviceURI.isEmpty ? .orange : .primary)
                            .textSelection(.enabled)
                    }
                }
                HStack(spacing: 12) {
                    Button { model.addPrinter(displayName: effectiveName) } label: { Label("Add Printer", systemImage: "plus") }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(model.deviceURI.isEmpty)
                    Text(model.driverInstalled ? "Usually no password needed." : "macOS asks for your password once.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(40)
        .onAppear { if !model.demo { model.refreshDriver() } }
    }
}

/// The top of a macOS Print dialog with the Zebra picked, to show where it will appear.
struct PrintDialogMock: View {
    let printerName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.2), Color(red: 0.16, green: 0.78, blue: 0.26)], id: \.self) { c in
                    Circle().fill(c).frame(width: 9, height: 9)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Printer").gridColumnAlignment(.trailing)
                    popup(printerName, icon: "printer.fill", picked: true)
                }
                GridRow {
                    Text("Presets")
                    popup("Default Settings", icon: nil, picked: false)
                }
                GridRow {
                    Text("Copies")
                    Text("1")
                        .padding(.horizontal, 9)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.secondary.opacity(0.4)))
                }
            }
            .font(.system(size: 12))
            HStack(spacing: 8) {
                Spacer()
                Text("Cancel")
                    .padding(.horizontal, 14).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.16)))
                Text("Print")
                    .foregroundColor(.white)
                    .padding(.horizontal, 16).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor))
            }
            .font(.system(size: 12))
        }
        .padding(16)
        .frame(width: 380)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .windowBackgroundColor))
            .shadow(color: .black.opacity(0.18), radius: 12, y: 4))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
        .accessibilityHidden(true)
    }

    func popup(_ text: String, icon: String?, picked: Bool) -> some View {
        HStack(spacing: 6) {
            if let i = icon { Image(systemName: i) }
            Text(text).fontWeight(picked ? .semibold : .regular).lineLimit(1)
            Spacer(minLength: 12)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 9))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .frame(width: 230)
        .background(RoundedRectangle(cornerRadius: 5).fill(picked ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(picked ? Color.accentColor : Color.clear))
    }
}

// MARK: - 4 Test

struct TestStep: View {
    @EnvironmentObject var model: AppModel
    @State private var sending = false
    @State private var sent = SetupAssistant.demoTestSent
    @State private var failure: String?
    @State private var outcome: Outcome?

    enum Outcome: String, CaseIterable, Identifiable {
        case good, faint, shifted, nothing
        var id: String { rawValue }
        var title: String {
            switch self {
            case .good: return "Looks good"
            case .faint: return "Too light or dark"
            case .shifted: return "Cut off or shifted"
            case .nothing: return "Nothing came out"
            }
        }
        var icon: String {
            switch self {
            case .good: return "checkmark.circle"
            case .faint: return "circle.lefthalf.filled"
            case .shifted: return "rectangle.dashed"
            case .nothing: return "questionmark.circle"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepHeader(title: "Print a test label",
                       text: "Load your 4×6 labels and print a test. The bars should be crisp and the border should sit just inside the edges of the label.")
            HStack(spacing: 8) {
                StatusDot(health: model.health)
                Text(statusLine).foregroundColor(.secondary)
                Button("Refresh") { model.refreshStatus() }
                    .buttonStyle(.link)
            }
            HStack(spacing: 12) {
                Button { send() } label: { Label(sent ? "Print Another" : "Print Test Label", systemImage: "printer.fill") }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(sending || model.settings.printer == nil)
                if sending { ProgressView().controlSize(.small) }
                if let f = failure {
                    Label(f, systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .lineLimit(2)
                }
            }
            if sent {
                Text("How did it come out?").font(.headline).padding(.top, 4)
                HStack(spacing: 8) {
                    ForEach(Outcome.allCases) { o in
                        Button { outcome = o } label: { Label(o.title, systemImage: o.icon) }
                            .buttonStyle(.bordered)
                            .tint(outcome == o ? Color.accentColor : nil)
                    }
                }
                detail
            }
            Spacer(minLength: 0)
            SampleCard()
        }
        .padding(40)
        .onAppear { model.refreshStatus(quiet: true) }
        .onChange(of: model.settings.darkness) { _ in model.scheduleQueueSync() }
    }

    @ViewBuilder var detail: some View {
        switch outcome {
        case .good?:
            Label("You’re set. Every label prints like that one.", systemImage: "hand.thumbsup.fill")
                .foregroundColor(.green)
        case .faint?:
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Use the printer’s own darkness", isOn: printerDarkness)
                if model.settings.darkness != nil {
                    HStack {
                        Text("Lighter").foregroundColor(.secondary)
                        Slider(value: darkness, in: 0...30, step: 1)
                        Text("Darker").foregroundColor(.secondary)
                        Text("\(model.settings.darkness ?? 0)").monospacedDigit().frame(width: 24)
                    }
                }
                Text("Then print another test.").foregroundColor(.secondary)
            }
            .frame(maxWidth: 460, alignment: .leading)
        case .shifted?:
            VStack(alignment: .leading, spacing: 8) {
                Text("Let the printer measure your labels: calibrating feeds a few blank labels while it finds the gap between them. Then print another test.")
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Button("Calibrate") { model.printerCommand("calibrate") }
                    Picker("Label stock", selection: stock) {
                        ForEach(Driver.stocks, id: \.name) { s in Text(s.label).tag(s.name) }
                    }
                    .frame(width: 280)
                }
            }
        case .nothing?:
            VStack(alignment: .leading, spacing: 4) {
                Text("• The light should be solid green. Red or flashing: open the cover, reseat the labels and close it firmly.")
                Text("• Press Feed once. A blank label should come out.")
                Text("• Still nothing? Go Back and choose the printer again; its address may have changed.")
            }
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        case nil:
            EmptyView()
        }
    }

    var statusLine: String {
        let name = model.settings.printerName.isEmpty ? (model.settings.printer?.description ?? "No printer") : model.settings.printerName
        return "\(name): \(model.health.text)"
    }

    var printerDarkness: Binding<Bool> {
        Binding(get: { model.settings.darkness == nil }, set: { model.settings.darkness = $0 ? nil : 20 })
    }

    var darkness: Binding<Double> {
        Binding(get: { Double(model.settings.darkness ?? 20) }, set: { model.settings.darkness = Int($0.rounded()) })
    }

    var stock: Binding<String> {
        Binding(get: { Driver.stockName(for: model.settings.labelSize) },
                set: {
                    if let s = Driver.size(fromStock: $0) {
                        model.settings.labelWidth = s.width
                        model.settings.labelHeight = s.height
                        model.scheduleQueueSync()
                    }
                })
    }

    func send() {
        sending = true
        failure = nil
        model.printerCommand("test") { error in
            sending = false
            if let e = error { failure = e } else { sent = true }
        }
    }
}

struct SampleCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 26))
                .foregroundColor(.accentColor)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 4) {
                Text("Now try the Print dialog for real").font(.headline)
                Text("Open a sample return page in Preview, press ⌘P, choose “\(model.addedPrinterName ?? "your Zebra")” and click Print. Tearoff prints the shipping label, the return barcode and the QR code: three labels, nothing else.")
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Open Sample") { model.openSample() }
                .controlSize(.large)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.08)))
    }
}

// MARK: - 5 Ready

struct ReadyStep: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StepHeader(title: "Just print the whole page",
                       text: "No cropping and no saving PDFs. Print from any app and Tearoff prints only the labels, barcodes and QR codes.")
            PluckAnimationView()
            HStack(spacing: 22) {
                ReadyTip(icon: "command", text: "⌘P in any app")
                ReadyTip(icon: "tray.and.arrow.down", text: "Or drop PDFs on Tearoff")
                ReadyTip(icon: "eye", text: "PDF ▸ Print Label with Tearoff previews first")
            }
            .font(.callout)
            Toggle("Also print other barcodes and QR codes found on the page", isOn: $model.settings.extraCodes)
                .onChange(of: model.settings.extraCodes) { _ in model.scheduleQueueSync() }
        }
        .padding(.horizontal, 40)
        .padding(.top, 30)
        .padding(.bottom, 14)
    }
}

struct ReadyTip: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundColor(.accentColor)
            Text(text).foregroundColor(.secondary)
        }
    }
}
