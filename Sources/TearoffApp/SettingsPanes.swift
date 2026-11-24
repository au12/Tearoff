import AppKit
import SwiftUI
import TearoffCore
import TearoffKit

// MARK: - Printer

struct PrinterPane: View {
    @EnvironmentObject var model: AppModel
    @State private var hostField = ""
    @State private var useQueue = false
    @State private var queueChoice = ""

    var body: some View {
        Form {
            Section {
                Picker("Connection", selection: $useQueue) {
                    Text("Network").tag(false)
                    Text("macOS print queue").tag(true)
                }
                .pickerStyle(.segmented)

                if !useQueue {
                    HStack {
                        TextField("IP address or hostname", text: $hostField, prompt: Text("10.0.10.50"))
                            .onSubmit(applyHost)
                        Button("Use", action: applyHost).disabled(hostField.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    HStack(spacing: 10) {
                        Button { model.scan() } label: { Label("Find Printers", systemImage: "dot.radiowaves.left.and.right") }
                            .disabled(model.scanning)
                        if model.scanning {
                            ProgressView().controlSize(.small)
                            Text("Looking for Zebras on your network…").foregroundStyle(.secondary)
                        }
                    }
                    ForEach(model.discovered) { p in
                        HStack {
                            Image(systemName: p.isZebra ? "printer.fill" : "questionmark.circle")
                                .foregroundStyle(p.isZebra ? Color.accentColor : Color.secondary)
                            VStack(alignment: .leading) {
                                Text(p.name).fontWeight(.medium)
                                Text(p.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if model.settings.printer == p.target {
                                Label("In use", systemImage: "checkmark").foregroundStyle(.green).labelStyle(.titleAndIcon)
                            } else {
                                Button("Use") {
                                    model.choose(p)
                                    hostField = p.target.description
                                }
                            }
                        }
                    }
                } else {
                    Picker("Queue", selection: $queueChoice) {
                        Text("Choose…").tag("")
                        ForEach(model.queues, id: \.name) { q in Text(q.name).tag(q.name) }
                    }
                    .onChange(of: queueChoice) { q in
                        if !q.isEmpty {
                            model.settings.printer = .queue(name: q)
                            model.settings.printerName = q
                        }
                    }
                    Text("For USB printers. Tearoff sends raw ZPL to the queue, so use a queue with the Tearoff driver (Print Driver, in the sidebar) or a raw/ZPL driver.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Your Zebra")
            }

            Section("Status") {
                LabeledContent("Printer") { Text(printerLabel) }
                LabeledContent("Status") {
                    HStack(spacing: 6) { StatusDot(health: model.health); Text(model.health.text) }
                }
                if let id = model.identity {
                    LabeledContent("Model") { Text("\(id.model) · firmware \(id.firmware) · \(id.dpi) dpi") }
                }
                HStack {
                    Button("Refresh") { model.refreshStatus() }
                    Button("Print Test Label") { model.printerCommand("test") }
                    Button("Feed Label") { model.printerCommand("feed") }
                    Button("Calibrate") { model.printerCommand("calibrate") }
                        .help("Measures your label length and gap (feeds a few labels)")
                    Button("Configuration Label") { model.printerCommand("config") }
                }
                .disabled(model.settings.printer == nil)
            }

            Section("Labels") {
                Picker("Label stock", selection: stockBinding) {
                    ForEach(Driver.stocks, id: \.name) { s in Text(s.label).tag(s.name) }
                }
                HStack {
                    Picker("Resolution", selection: $model.settings.dpi) {
                        Text("203 dpi (8 dots/mm)").tag(203)
                        Text("300 dpi (12 dots/mm)").tag(300)
                        Text("600 dpi (24 dots/mm)").tag(600)
                    }
                    Button("Detect") { model.detectResolution() }
                        .disabled(!isNetwork)
                }
                Toggle("Use the printer’s own darkness", isOn: printerDarkness)
                if model.settings.darkness != nil {
                    LabeledContent("Darkness") {
                        HStack {
                            Slider(value: darknessValue, in: 0...30, step: 1, onEditingChanged: { editing in
                                if !editing { model.scheduleQueueSync() }
                            })
                            Text("\(model.settings.darkness ?? 0)").monospacedDigit().frame(width: 28)
                        }
                    }
                }
                Picker("Print speed", selection: speedBinding) {
                    Text("Printer setting").tag(0)
                    ForEach(2...6, id: \.self) { s in Text("\(s) in/s").tag(s) }
                }
                Picker("Line weight", selection: $model.settings.threshold) {
                    Text("Lighter").tag(102)
                    Text("Normal").tag(128)
                    Text("Bolder").tag(153)
                }
                .pickerStyle(.segmented)
                Toggle("Snap barcodes to the printer’s dot grid", isOn: $model.settings.gridFit)
                    .help("Redraws verified Code 128 barcodes so every bar is a whole number of dots")
                Stepper(value: $model.settings.topOffset, in: -120...120, step: 4) {
                    LabeledContent("Shift down", value: "\(model.settings.topOffset) dots")
                }
                Stepper(value: $model.settings.leftOffset, in: -200...200, step: 4) {
                    LabeledContent("Shift right", value: "\(model.settings.leftOffset) dots")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Printer")
        .onAppear {
            switch model.settings.printer {
            case .network(let h, let p)?: hostField = p == 9100 ? h : "\(h):\(p)"; useQueue = false
            case .queue(let n)?: queueChoice = n; useQueue = true
            case nil: break
            }
            if model.queues.isEmpty { model.refreshDriver() }
            if model.discovered.isEmpty && model.settings.printer == nil { model.scan() }
        }
        .onChange(of: model.settings.printer) { p in
            if case .network(let h, let port)? = p { hostField = port == 9100 ? h : "\(h):\(port)" }
        }
        .onChange(of: model.settings.renderOptions) { _ in model.reprocessAll() }
        .onChange(of: model.settings.speed) { _ in model.scheduleQueueSync() }
        .onChange(of: model.settings.darkness == nil) { _ in model.scheduleQueueSync() }
    }

    var isNetwork: Bool {
        if case .network? = model.settings.printer { return true }
        return false
    }

    var printerLabel: String {
        guard let p = model.settings.printer else { return "None" }
        return model.settings.printerName.isEmpty ? p.description : "\(model.settings.printerName) (\(p.description))"
    }

    func applyHost() {
        guard let t = PrinterTarget(string: hostField) else { return }
        model.settings.printer = t
        if model.settings.printerName.isEmpty || PrinterTarget(string: model.settings.printerName) != nil {
            model.settings.printerName = t.description
        }
        model.detectResolution()
    }

    var stockBinding: Binding<String> {
        Binding(get: { Driver.stockName(for: model.settings.labelSize) },
                set: { if let s = Driver.size(fromStock: $0) { model.settings.labelWidth = s.width; model.settings.labelHeight = s.height; model.scheduleQueueSync() } })
    }

    var printerDarkness: Binding<Bool> {
        Binding(get: { model.settings.darkness == nil }, set: { model.settings.darkness = $0 ? nil : 20 })
    }

    var darknessValue: Binding<Double> {
        Binding(get: { Double(model.settings.darkness ?? 20) }, set: { model.settings.darkness = Int($0.rounded()) })
    }

    var speedBinding: Binding<Int> {
        Binding(get: { model.settings.speed ?? 0 }, set: { model.settings.speed = $0 == 0 ? nil : $0 })
    }
}

// MARK: - Driver

struct DriverPane: View {
    @EnvironmentObject var model: AppModel
    @State private var displayName = ""
    @State private var convert = Set<String>()

    var body: some View {
        Form {
            Section {
                Text("Install Tearoff as a macOS printer so every app’s Print dialog can send labels straight to your Zebra. Whatever you print — a letter-size return page from a website, a 4×6 PDF, an image — Tearoff cuts out the label, turns it upright and prints it at full size with barcodes snapped to the dot grid.")
                    .fixedSize(horizontal: false, vertical: true)
                LabeledContent("Driver") {
                    Text(model.driverInstalled ? "Installed in /Library/Printers/Tearoff" : "Not installed")
                        .foregroundStyle(model.driverInstalled ? Color.green : Color.secondary)
                }
                LabeledContent("Printers using it") {
                    Text(model.tearoffQueues.isEmpty ? "None" : model.tearoffQueues.joined(separator: ", "))
                }
                if model.driverOutdated {
                    HStack {
                        Label("The installed driver is older than this app.", systemImage: "arrow.triangle.2.circlepath")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Update Driver…") { model.updateDriver() }
                    }
                }
            }

            Section("Add your Zebra as a printer") {
                TextField("Name in the Print dialog", text: $displayName, prompt: Text("Zebra GX420d"))
                LabeledContent("Connects to") {
                    Text(deviceURI.isEmpty ? "Choose your printer first" : deviceURI)
                        .foregroundStyle(deviceURI.isEmpty ? Color.orange : Color.primary)
                        .textSelection(.enabled)
                }
                HStack {
                    Button(model.tearoffQueues.contains(queueName) ? "Update Printer…" : "Install Driver & Add Printer…") {
                        model.installDriver(queueName: queueName, displayName: effectiveName, uri: deviceURI, convert: [])
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(deviceURI.isEmpty)
                    Text("macOS asks for an administrator password once.").font(.caption).foregroundStyle(.secondary)
                }
            }

            let others = model.queues.filter { !model.tearoffQueues.contains($0.name) }
            if !others.isEmpty {
                Section {
                    ForEach(others, id: \.name) { q in
                        Toggle(isOn: Binding(get: { convert.contains(q.name) },
                                             set: { if $0 { convert.insert(q.name) } else { convert.remove(q.name) } })) {
                            VStack(alignment: .leading) {
                                Text(q.name)
                                Text(q.uri).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Button("Switch Selected to Tearoff…") {
                        model.installDriver(queueName: "", displayName: "", uri: "", convert: Array(convert))
                        convert.removeAll()
                    }
                    .disabled(convert.isEmpty)
                } header: {
                    Text("Switch existing printers")
                } footer: {
                    Text("Keeps their names and connections, so anything else that prints to them keeps working.")
                }
            }

            Section("Printing from any app") {
                VStack(alignment: .leading, spacing: 8) {
                    step(1, "Press ⌘P in Safari, Chrome, Preview, Acrobat — anything.")
                    step(2, "Choose “\(effectiveName)”.")
                    step(3, "Print. Paper size can stay 4 × 6: Tearoff finds the label either way.")
                }
                Text("Darkness, speed and label stock from the Printer pane are copied to this printer, and also appear under Printer Features in the Print dialog.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(model.pdfServiceInstalled ? "PDF Menu Item Installed" : "Add “Print Label with Tearoff” to the PDF Menu") {
                        model.installPDFService()
                    }
                    .disabled(model.pdfServiceInstalled)
                    Text("Previews the label here before printing.").font(.caption).foregroundStyle(.secondary)
                }
            }

            if model.driverInstalled {
                Section {
                    Button("Remove Driver and Its Printers…", role: .destructive) { model.uninstallDriver() }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Print Driver")
        .onAppear {
            model.refreshDriver()
            if displayName.isEmpty { displayName = suggestedName }
        }
    }

    var suggestedName: String {
        let n = model.identity?.model ?? model.settings.printerName
        let base = n.replacingOccurrences(of: #"-\d{3}dpi"#, with: "", options: .regularExpression)
        let looksLikeAddress = base.allSatisfy { $0.isNumber || $0 == "." || $0 == ":" }
        if base.isEmpty || looksLikeAddress { return "Zebra Label Printer" }
        return base.lowercased().hasPrefix("zebra") ? base : "Zebra \(base)"
    }

    var effectiveName: String { displayName.trimmingCharacters(in: .whitespaces).isEmpty ? suggestedName : displayName }
    var queueName: String { Driver.queueName(for: effectiveName) }

    var deviceURI: String {
        switch model.settings.printer {
        case .network(let h, let p)?: return "socket://\(h):\(p)"
        case .queue(let n)?: return model.queues.first(where: { $0.name == n })?.uri ?? ""
        case nil: return ""
        }
    }

    func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)").font(.caption.bold()).frame(width: 20, height: 20).background(Circle().fill(Color.accentColor.opacity(0.18)))
            Text(text)
        }
    }
}

// MARK: - Automation

struct AutomationPane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section("When you open or drop a file") {
                Toggle("Print right away (skip the preview)", isOn: $model.settings.autoPrintOnOpen)
            }
            Section {
                Toggle("Watch Downloads for new shipping labels", isOn: $model.settings.watchDownloads)
                Toggle("Print them automatically", isOn: $model.settings.watchAutoPrint)
                    .disabled(!model.settings.watchDownloads)
            } header: {
                Text("Downloads")
            } footer: {
                Text("Tearoff only reacts to new PDFs and images that contain a shipping barcode. Without automatic printing you get a notification with a Print button.")
            }
            Section {
                Toggle("Open Tearoff at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
            } footer: {
                Text("Keeps the menu bar icon and Downloads watching running in the background.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Automation")
    }
}
