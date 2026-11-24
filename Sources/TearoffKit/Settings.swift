import Foundation
import TearoffCore

/// Settings shared by the app and the `tearoff` command (stored in the app's defaults domain).
public struct TearoffSettings: Codable, Equatable {
    public var printer: PrinterTarget?
    public var printerName: String = ""
    public var dpi: Int = 203
    public var labelWidth: Double = 4
    public var labelHeight: Double = 6
    public var darkness: Int?
    public var speed: Int?
    public var topOffset: Int = 0
    public var leftOffset: Int = 0
    public var gridFit: Bool = true
    /// Also print barcodes and QR codes found outside the label, each on a label of its own.
    public var extraCodes: Bool = true
    public var threshold: Int = 128
    public var autoPrintOnOpen: Bool = false
    public var watchDownloads: Bool = false
    public var watchAutoPrint: Bool = false
    public var installedQueue: String?

    public init() {}

    enum CodingKeys: String, CodingKey {
        case printer, printerName, dpi, labelWidth, labelHeight, darkness, speed, topOffset, leftOffset
        case gridFit, extraCodes, threshold, autoPrintOnOpen, watchDownloads, watchAutoPrint, installedQueue
    }

    // Tolerant decoding: settings written by older/newer builds never fail to load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        printer = try? c.decodeIfPresent(PrinterTarget.self, forKey: .printer)
        printerName = (try? c.decodeIfPresent(String.self, forKey: .printerName)) ?? ""
        dpi = (try? c.decodeIfPresent(Int.self, forKey: .dpi)) ?? 203
        labelWidth = (try? c.decodeIfPresent(Double.self, forKey: .labelWidth)) ?? 4
        labelHeight = (try? c.decodeIfPresent(Double.self, forKey: .labelHeight)) ?? 6
        darkness = try? c.decodeIfPresent(Int.self, forKey: .darkness)
        speed = try? c.decodeIfPresent(Int.self, forKey: .speed)
        topOffset = (try? c.decodeIfPresent(Int.self, forKey: .topOffset)) ?? 0
        leftOffset = (try? c.decodeIfPresent(Int.self, forKey: .leftOffset)) ?? 0
        gridFit = (try? c.decodeIfPresent(Bool.self, forKey: .gridFit)) ?? true
        extraCodes = (try? c.decodeIfPresent(Bool.self, forKey: .extraCodes)) ?? true
        threshold = (try? c.decodeIfPresent(Int.self, forKey: .threshold)) ?? 128
        autoPrintOnOpen = (try? c.decodeIfPresent(Bool.self, forKey: .autoPrintOnOpen)) ?? false
        watchDownloads = (try? c.decodeIfPresent(Bool.self, forKey: .watchDownloads)) ?? false
        watchAutoPrint = (try? c.decodeIfPresent(Bool.self, forKey: .watchAutoPrint)) ?? false
        installedQueue = try? c.decodeIfPresent(String.self, forKey: .installedQueue)
    }

    public var labelSize: LabelSize { LabelSize(width: labelWidth, height: labelHeight) }

    public var renderOptions: RenderOptions {
        RenderOptions(dpi: dpi, size: labelSize, gridFit: gridFit, threshold: threshold)
    }

    public var printSettings: PrintSettings {
        PrintSettings(darkness: darkness, speed: speed, topOffset: topOffset, leftOffset: leftOffset)
    }

    public static let domain = "com.au12.tearoff"
    static let key = "settings.v1"

    static var store: UserDefaults {
        if Bundle.main.bundleIdentifier == domain { return .standard }
        return UserDefaults(suiteName: domain) ?? .standard
    }

    public static func load() -> TearoffSettings {
        guard let data = store.data(forKey: key),
              let s = try? JSONDecoder().decode(TearoffSettings.self, from: data) else { return TearoffSettings() }
        return s
    }

    public func save() {
        if let data = try? JSONEncoder().encode(self) { TearoffSettings.store.set(data, forKey: TearoffSettings.key) }
    }
}
