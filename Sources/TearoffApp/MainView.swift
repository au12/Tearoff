import AppKit
import SwiftUI
import TearoffCore
import TearoffKit

enum Pane: String, CaseIterable, Identifiable {
    case labels, printer, driver, automation
    var id: String { rawValue }
    var title: String {
        switch self {
        case .labels: return "Labels"
        case .printer: return "Printer"
        case .driver: return "Print Driver"
        case .automation: return "Automation"
        }
    }
    var icon: String {
        switch self {
        case .labels: return "doc.viewfinder"
        case .printer: return "printer"
        case .driver: return "gearshape.2"
        case .automation: return "bolt.badge.clock"
        }
    }
}

struct MainView: View {
    @EnvironmentObject var model: AppModel
    @State private var pane: Pane? = .labels
    @State private var dropping = false

    var body: some View {
        NavigationSplitView {
            List(selection: $pane) {
                ForEach(Pane.allCases) { p in
                    HStack {
                        Label(p.title, systemImage: p.icon)
                        Spacer()
                        badge(for: p)
                    }
                    .tag(p)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
            .safeAreaInset(edge: .bottom) { PrinterChip().padding(10) }
        } detail: {
            ZStack(alignment: .bottom) {
                switch pane ?? .labels {
                case .labels: LabelsPane()
                case .printer: PrinterPane()
                case .driver: DriverPane()
                case .automation: AutomationPane()
                }
                if let t = model.toast {
                    ToastView(toast: t)
                        .padding(.bottom, 18)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.toast)
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.open(urls)
            pane = .labels
            return !urls.isEmpty
        } isTargeted: { dropping = $0 }
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showPrinterSetup)) { _ in pane = .printer }
        .onReceive(model.$requestedPane) { p in if let p = p { pane = p } }
        .alert("Tearoff", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK", role: .cancel) { model.alert = nil }
        } message: {
            Text(model.alert ?? "")
        }
        .onAppear {
            if let p = model.requestedPane { pane = p } else if model.settings.printer == nil { pane = .printer }
        }
    }

    @ViewBuilder func badge(for p: Pane) -> some View {
        switch p {
        case .labels:
            let n = model.documents.first?.labels.count ?? 0
            if n > 0 { Text("\(n)").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
        case .printer:
            StatusDot(health: model.health)
        case .driver:
            if model.driverInstalled && !model.tearoffQueues.isEmpty {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
            }
        case .automation:
            if model.settings.watchDownloads { Image(systemName: "eye").foregroundStyle(.secondary).font(.caption) }
        }
    }
}

// MARK: - Labels

struct LabelsPane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            if model.documents.isEmpty {
                DropZone()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        ForEach(model.documents) { doc in
                            DocumentSection(doc: doc)
                        }
                    }
                    .padding(24)
                }
            }
        }
        .navigationTitle("Labels")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if model.working > 0 { ProgressView().controlSize(.small) }
                Button { model.openPanel() } label: { Label("Open", systemImage: "folder") }
                    .help("Open a PDF or image (⌘O)")
                Button {
                    if let d = model.documents.first { model.printDocument(d.id) }
                } label: { Label("Print", systemImage: "printer.fill") }
                    .help("Print the selected labels (⌘P)")
                    .disabled(model.documents.first?.labels.isEmpty ?? true)
            }
        }
    }
}

struct DropZone: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "doc.viewfinder")
                .font(.system(size: 64, weight: .thin))
                .foregroundStyle(.secondary)
            Text("Drop a shipping label PDF")
                .font(.title2.weight(.semibold))
            Text("Tearoff finds the 4×6 label on the page — embedded image or vector, framed or not, upright or sideways — and prints it crisp on your Zebra.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 440)
            HStack(spacing: 12) {
                Button("Open PDF…") { model.openPanel() }
                    .keyboardShortcut("o")
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.top, 4)
            VStack(alignment: .leading, spacing: 6) {
                tip("printer", "From any app: ⌘P and pick your Zebra (install it under Print Driver).")
                tip("arrow.down.circle", "Or let Tearoff watch Downloads and offer to print new labels.")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.top, 10)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    func tip(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 8) { Image(systemName: icon).frame(width: 18); Text(text) }
    }
}

struct DocumentSection: View {
    @EnvironmentObject var model: AppModel
    let doc: LabelDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "doc.richtext").foregroundStyle(.secondary)
                Text(doc.name).font(.headline).lineLimit(1).truncationMode(.middle)
                Text(summary).font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                if let p = doc.printedAt {
                    Label("Printed \(p.formatted(date: .omitted, time: .shortened))", systemImage: "checkmark")
                        .font(.caption).foregroundStyle(.green)
                }
                Menu {
                    Button("Save ZPL…") { model.saveZPL(selected, suggestedName: base + ".zpl") }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([doc.url]) }
                    Divider()
                    Button("Remove from List") { model.remove(doc.id) }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                Button {
                    model.printDocument(doc.id)
                } label: {
                    Label(doc.selected.count > 1 ? "Print \(doc.selected.count)" : "Print", systemImage: "printer.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(doc.labels.isEmpty)
            }
            if let e = doc.error {
                Text(e).foregroundStyle(.red)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 18) {
                    ForEach(doc.labels) { l in
                        LabelTile(label: l, selected: doc.selected.contains(l.id), multi: doc.labels.count > 1,
                                  onToggle: { model.toggle(l.id, in: doc.id) },
                                  onFlip: { model.flip(l.id, in: doc.id) },
                                  onPrint: { model.printLabels([l]) },
                                  onSave: { model.savePNG(l, suggestedName: "\(base)-label.png") })
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    var base: String { doc.url.deletingPathExtension().lastPathComponent }
    var selected: [ExtractedLabel] { doc.labels.filter { doc.selected.contains($0.id) } }

    var summary: String {
        let n = doc.labels.count
        if n == 0 { return "no label" }
        let fallback = doc.labels.allSatisfy { $0.kind == "fallback" }
        return fallback ? "no label found — whole page" : "\(n) label\(n == 1 ? "" : "s")"
    }
}

struct LabelTile: View {
    let label: ExtractedLabel
    let selected: Bool
    let multi: Bool
    let onToggle: () -> Void
    let onFlip: () -> Void
    let onPrint: () -> Void
    let onSave: () -> Void
    @State private var zoom = false

    var displayWidth: CGFloat { 230 }
    var displayHeight: CGFloat {
        displayWidth * CGFloat(label.image.height) / CGFloat(max(1, label.image.width))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                LabelImage(image: label.image)
                    .frame(width: displayWidth, height: displayHeight)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(selected && multi ? Color.accentColor : Color.black.opacity(0.08), lineWidth: selected && multi ? 3 : 1)
                    )
                    .onTapGesture(count: 2) { zoom = true }
                    .onTapGesture { if multi { onToggle() } }
                if multi {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                        .background(Circle().fill(.background).padding(2))
                        .padding(8)
                        .onTapGesture { onToggle() }
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.semibold)).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            .frame(width: displayWidth, alignment: .leading)
            HStack(spacing: 6) {
                Button(action: onPrint) { Image(systemName: "printer") }.help("Print just this label")
                Button(action: onFlip) { Image(systemName: "arrow.triangle.2.circlepath") }.help("Turn 180°")
                Button { zoom = true } label: { Image(systemName: "magnifyingglass") }.help("View at printer resolution")
                Button(action: onSave) { Image(systemName: "square.and.arrow.down") }.help("Save as PNG")
            }
            .buttonStyle(.borderless)
        }
        .contextMenu {
            Button("Print This Label", action: onPrint)
            Button("Turn 180°", action: onFlip)
            Button("Save PNG…", action: onSave)
        }
        .sheet(isPresented: $zoom) { ZoomSheet(label: label) }
    }

    var title: String {
        if let t = label.tracking {
            return [label.carrier, t].compactMap { $0 }.joined(separator: " · ")
        }
        return label.kind == "fallback" ? "Whole page" : "Label \(label.page > 1 ? "on page \(label.page)" : "")"
    }

    var detail: String {
        var parts = [label.detail]
        if label.quarterTurns != 0 { parts.append("turned \(label.quarterTurns * 90)°") }
        if label.gridFitted > 0 { parts.append("\(label.gridFitted) barcode\(label.gridFitted == 1 ? "" : "s") snapped to dots") }
        return parts.joined(separator: " · ")
    }
}

/// Renders a 1-bit label crisply at any size.
struct LabelImage: View {
    let image: GrayImage
    var exact = false

    var body: some View {
        if let cg = image.cgImage() {
            Image(decorative: cg, scale: 1)
                .resizable()
                .interpolation(exact ? .none : .high)
                .aspectRatio(contentMode: .fit)
        } else {
            Color.white
        }
    }
}

struct ZoomSheet: View {
    let label: ExtractedLabel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Exactly what the printer receives: \(label.image.width) × \(label.image.height) dots at \(label.dpi) dpi")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()
            ScrollView([.horizontal, .vertical]) {
                LabelImage(image: label.image, exact: true)
                    .frame(width: CGFloat(label.image.width), height: CGFloat(label.image.height))
                    .background(Color.white)
                    .padding(20)
            }
        }
        .frame(minWidth: 700, idealWidth: 900, minHeight: 600, idealHeight: 900)
    }
}

struct ToastView: View {
    let toast: Toast
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(toast.isError ? Color.orange : Color.green)
            Text(toast.text).lineLimit(3)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
        .frame(maxWidth: 560)
    }
}

struct StatusDot: View {
    let health: PrinterHealth
    var body: some View {
        Circle().fill(color).frame(width: 9, height: 9)
    }
    var color: Color {
        switch health {
        case .ready, .queue: return .green
        case .problem: return .orange
        case .offline: return .red
        case .checking, .unknown: return .gray
        }
    }
}

struct PrinterChip: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack(spacing: 8) {
            StatusDot(health: model.health)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.settings.printerName.isEmpty ? (model.settings.printer?.description ?? "No printer") : model.settings.printerName)
                    .font(.caption.weight(.semibold)).lineLimit(1)
                Text(model.health.text).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        .onTapGesture { model.refreshStatus() }
        .help("Click to refresh printer status")
    }
}
